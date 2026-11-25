"""AI 截图识别：从截图中识别工作任务。

通义千问 VL（Qwen-VL）多模态大模型，服务端中转调用。
API Key 从环境变量 DASHSCOPE_API_KEY 读取，未配置时返回提示。

功能：
- 鉴权：只有登录用户才能调用
- 限流：每用户每分钟最多 2 次，每天最多 15 次
- 使用记录：每次调用记录到 ai_usage 表
"""
import base64
import io
import json
import os
import re
import zipfile
from datetime import datetime, timedelta
from urllib.parse import quote
from xml.sax.saxutils import escape

import httpx
from fastapi import APIRouter, Depends, HTTPException
from fastapi.responses import JSONResponse, Response

from ..database import get_conn, transaction
from ..models import (
    ExportDocxRequest,
    RecognizeRequest,
    RecognizeResponse,
    RecognizedTask,
    SummarizeRequest,
    SummarizeResponse,
)
from .deps import get_current_user

router = APIRouter(prefix="/api/ai", tags=["ai"])

# 通义千问 VL 兼容模式端点（OpenAI 兼容）
_DASHSCOPE_URL = "https://dashscope.aliyuncs.com/compatible-mode/v1/chat/completions"
_DASHSCOPE_MODEL = "qwen3.8-flash"

# 限流配置（额度按天统计，月度次数仅统计不限制）
_RATE_LIMIT_PER_MINUTE = 2   # 截图识别：每分钟最多调用次数
_RATE_LIMIT_PER_DAY = 10     # 截图识别：每天最多调用次数
_RATE_LIMIT_PER_MINUTE_SUMMARIZE = 5   # 总结：每分钟最多调用次数
_RATE_LIMIT_PER_DAY_DAILY = 3          # 日报总结：每天最多调用次数
_RATE_LIMIT_PER_DAY_WEEKLY = 3         # 周报总结：每天最多调用次数

# 识别 Prompt：要求 AI 从截图中提取工作任务，合并成编号列表，转化为易懂内容
_RECOGNIZE_PROMPT = """你是一个工作任务识别助手。请从这张截图中识别所有待办工作任务。

要求：
1. 把截图中的内容整理成任务列表，每条任务对应一个 JSON 对象。"任务"指一个整体的事项组，不是单个零散条目
2. 合并规则：如果截图中的多个条目（"1、2、3"、"① ②"、"a. b."、带项目符号、换行并列等）属于同一个任务组（例如开头有"今天两个任务""本周待办""需要做以下事情"等总起句，或同一条消息/同一块内容里的并列项），把它们合并成一条任务：
   - 主标题：优先从总起句提炼，去掉数量词（如"今天两个任务"→"今日任务"、"本周需要完成"→"本周任务"）；没有总起句时，用"工作事项""今日待办"等合适名词概括
   - 子任务：每个条目一行，以"- "开头（客户端会渲染成可勾选的子任务）
3. 分组规则：不同消息、不同内容块里的任务组，分别生成一条独立任务，不要合并
4. 简单任务：截图只有一条简单内容时，直接输出一行，不要加子任务
5. 对每条任务内容进行转化，用更容易理解、更明确的语言表述：
   - 把模糊的指代改成具体内容（如"那个文档"→"完成项目需求文档"）
   - 把口语化表述改成书面语（如"明天弄一下"→"明天前完成"）
   - 补充必要的上下文，让任务单独看也能明白
6. 去掉无意义的前缀符号（原有序号、横线、方框、对勾、圆点等），子任务行统一用"- "开头
7. 整体紧急程度：根据所有任务的时间紧迫度和重要性综合判断，只能是"一般"、"重要"、"紧急"三者之一，默认"一般"
8. plan_start_at / due_at：如果截图中有明确的整体开始/截止日期就提取，否则为 null

只输出 JSON，不要任何解释、markdown 代码块标记或其他文字。格式：
{"tasks": [{"title": "今日任务\n- 开发极简工作日志\n- 给老妈做饭", "urgency": "一般", "plan_start_at": null, "due_at": null}, {"title": "筹备产品发布会\n- 确定场地\n- 邀请嘉宾\n- 准备演示PPT", "urgency": "重要", "plan_start_at": null, "due_at": null}]}"""


def _api_key() -> str | None:
    """从环境变量读取通义千问 API Key。"""
    return os.environ.get("DASHSCOPE_API_KEY") or os.environ.get("DASHSCOPE_APIKEY")


def _check_rate_limit(user_id: int, kind: str) -> None:
    """检查用户调用频率，超限抛出 429 异常。kind: ocr / daily / weekly"""
    now = datetime.utcnow()
    one_minute_ago = now - timedelta(minutes=1)
    today_start = now.replace(hour=0, minute=0, second=0, microsecond=0)

    if kind == "daily":
        minute_limit = _RATE_LIMIT_PER_MINUTE_SUMMARIZE
        day_limit = _RATE_LIMIT_PER_DAY_DAILY
        label = "日报总结"
    elif kind == "weekly":
        minute_limit = _RATE_LIMIT_PER_MINUTE_SUMMARIZE
        day_limit = _RATE_LIMIT_PER_DAY_WEEKLY
        label = "周报总结"
    else:
        minute_limit = _RATE_LIMIT_PER_MINUTE
        day_limit = _RATE_LIMIT_PER_DAY
        label = "识别"

    # 兼容旧数据：
    # - kind 为 NULL 的旧记录按 ocr（截图识别）统计
    # - 旧 summarize 记录（未分日/周）按日报 daily 统计
    if kind == "ocr":
        kind_sql = "(kind = 'ocr' OR kind IS NULL)"
    elif kind == "daily":
        kind_sql = "(kind = 'daily' OR kind = 'summarize')"
    else:
        kind_sql = "kind = 'weekly'"

    with get_conn() as conn:
        with conn.cursor() as cur:
            # 最近 1 分钟调用次数
            cur.execute(
                f"SELECT COUNT(*) AS n FROM ai_usage WHERE user_id = %s AND {kind_sql} AND created_at >= %s",
                (user_id, one_minute_ago),
            )
            minute_count = cur.fetchone()["n"]

            # 今天调用次数
            cur.execute(
                f"SELECT COUNT(*) AS n FROM ai_usage WHERE user_id = %s AND {kind_sql} AND created_at >= %s",
                (user_id, today_start),
            )
            day_count = cur.fetchone()["n"]

    if minute_count >= minute_limit:
        raise HTTPException(
            status_code=429,
            detail=f"AI {label}使用太频繁了，每分钟最多 {minute_limit} 次，请稍后再试",
        )
    if day_count >= day_limit:
        raise HTTPException(
            status_code=429,
            detail=f"今天 AI {label}次数已用完（每天最多 {day_limit} 次），明天再试吧",
        )


def _record_usage(user_id: int, task_count: int, kind: str = "ocr") -> None:
    """记录一次 AI 调用。"""
    with get_conn() as conn:
        with transaction(conn):
            with conn.cursor() as cur:
                cur.execute(
                    "INSERT INTO ai_usage (user_id, task_count, kind) VALUES (%s, %s, %s)",
                    (user_id, task_count, kind),
                )


def _docx_run(text: str, *, bold: bool = False, size_half_pt: int = 22) -> str:
    """构造 docx 段落 run（宋体，可加粗，字号单位为半磅）。"""
    rpr = "<w:rPr>"
    rpr += '<w:rFonts w:ascii="宋体" w:eastAsia="宋体" w:hAnsi="宋体"/>'
    if bold:
        rpr += "<w:b/>"
    rpr += f'<w:sz w:val="{size_half_pt}"/><w:szCs w:val="{size_half_pt}"/>'
    rpr += "</w:rPr>"
    return f'<w:r>{rpr}<w:t xml:space="preserve">{text}</w:t></w:r>'


def _md_to_docx_bytes(markdown: str) -> bytes:
    """把 Markdown 日志转成最小可用 .docx 字节（标准库实现，零第三方依赖）。

    解析规则（与桌面端 buildDocxFromMarkdown 一致）：
    # → 一级标题、## → 二级、### → 三级；- / * → 项目符号；数字. → 保留原文；其余 → 正文。
    """
    paragraphs = []
    for raw in markdown.split("\n"):
        t = raw.strip()
        if not t:
            paragraphs.append("<w:p/>")
            continue
        if t.startswith("### "):
            paragraphs.append(
                f'<w:p><w:pPr><w:spacing w:before="120" w:after="60"/></w:pPr>{_docx_run(escape(t[4:].strip()), bold=True, size_half_pt=25)}</w:p>'
            )
        elif t.startswith("## "):
            paragraphs.append(
                f'<w:p><w:pPr><w:spacing w:before="160" w:after="80"/></w:pPr>{_docx_run(escape(t[3:].strip()), bold=True, size_half_pt=28)}</w:p>'
            )
        elif t.startswith("# "):
            paragraphs.append(
                f'<w:p><w:pPr><w:spacing w:before="200" w:after="100"/></w:pPr>{_docx_run(escape(t[2:].strip()), bold=True, size_half_pt=32)}</w:p>'
            )
        elif t.startswith("- ") or t.startswith("* "):
            paragraphs.append(
                f'<w:p><w:pPr><w:ind w:left="360"/></w:pPr>{_docx_run(escape("• " + t[2:].strip()))}</w:p>'
            )
        elif re.match(r"^\d+\.\s", t):
            paragraphs.append(
                f'<w:p><w:pPr><w:ind w:left="360"/></w:pPr>{_docx_run(escape(t))}</w:p>'
            )
        else:
            paragraphs.append(f"<w:p>{_docx_run(escape(t))}</w:p>")

    document_xml = (
        '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
        '<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">'
        "<w:body>" + "".join(paragraphs) + "</w:body></w:document>"
    )
    content_types_xml = (
        '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
        '<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">'
        '<Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>'
        '<Default Extension="xml" ContentType="application/xml"/>'
        '<Override PartName="/word/document.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/>'
        "</Types>"
    )
    rels_xml = (
        '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
        '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">'
        '<Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="word/document.xml"/>'
        "</Relationships>"
    )

    buf = io.BytesIO()
    with zipfile.ZipFile(buf, "w", zipfile.ZIP_DEFLATED) as zf:
        zf.writestr("[Content_Types].xml", content_types_xml)
        zf.writestr("_rels/.rels", rels_xml)
        zf.writestr("word/document.xml", document_xml)
    return buf.getvalue()


def _parse_ai_response(text: str) -> list[RecognizedTask]:
    """从 AI 返回文本中解析 JSON 任务列表。"""
    # 去掉可能的 markdown 代码块标记
    text = text.strip()
    text = re.sub(r"^```(?:json)?\s*", "", text)
    text = re.sub(r"\s*```$", "", text)

    try:
        data = json.loads(text)
    except json.JSONDecodeError:
        # 尝试从文本中提取第一个 {...}
        match = re.search(r"\{.*\}", text, re.DOTALL)
        if not match:
            return []
        try:
            data = json.loads(match.group())
        except json.JSONDecodeError:
            return []

    tasks_raw = data.get("tasks", [])
    if not isinstance(tasks_raw, list):
        return []

    result: list[RecognizedTask] = []
    for item in tasks_raw:
        if not isinstance(item, dict):
            continue
        title = str(item.get("title", "")).strip()
        if not title:
            continue
        urgency = str(item.get("urgency", "一般")).strip()
        if urgency not in ("一般", "重要", "紧急"):
            urgency = "一般"
        plan_start = item.get("plan_start_at")
        due = item.get("due_at")
        result.append(RecognizedTask(
            title=title,
            urgency=urgency,
            plan_start_at=str(plan_start) if plan_start else None,
            due_at=str(due) if due else None,
        ))
    return result


@router.post("/recognize-tasks", response_model=RecognizeResponse)
async def recognize_tasks(req: RecognizeRequest, user_id: int = Depends(get_current_user)):
    """从截图中 AI 识别工作任务（需登录，有限流）。

    - 请求体：{"image": "base64编码的图片"}
    - 返回：{"tasks": [{"title", "urgency", "plan_start_at", "due_at"}]}
    - 限流：每分钟 2 次，每天 15 次
    """
    # 1. 限流检查
    _check_rate_limit(user_id, "ocr")

    # 2. 检查 API Key
    api_key = _api_key()
    if not api_key:
        raise HTTPException(
            status_code=503,
            detail="AI 识别服务未配置：请在服务端 .env 中设置 DASHSCOPE_API_KEY（通义千问 API Key）",
        )

    # 3. 校验 base64 图片
    image_b64 = req.image.strip()
    # 去掉可能的 data:image/...;base64, 前缀
    if "," in image_b64 and image_b64.startswith("data:"):
        image_b64 = image_b64.split(",", 1)[1]
    try:
        base64.b64decode(image_b64, validate=True)
    except Exception:
        raise HTTPException(status_code=400, detail="图片 base64 编码无效")

    # 4. 构造通义千问 VL 请求（OpenAI 兼容格式）
    payload = {
        "model": _DASHSCOPE_MODEL,
        "messages": [
            {
                "role": "user",
                "content": [
                    {
                        "type": "image_url",
                        "image_url": {"url": f"data:image/png;base64,{image_b64}"},
                    },
                    {"type": "text", "text": _RECOGNIZE_PROMPT},
                ],
            }
        ],
        "temperature": 0.3,
    }
    headers = {
        "Authorization": f"Bearer {api_key}",
        "Content-Type": "application/json",
    }

    try:
        async with httpx.AsyncClient(timeout=30) as client:
            resp = await client.post(_DASHSCOPE_URL, json=payload, headers=headers)
            resp.raise_for_status()
            data = resp.json()
    except httpx.HTTPStatusError as e:
        detail = f"AI 服务返回错误 ({e.response.status_code})"
        try:
            err_body = e.response.json()
            if "error" in err_body:
                detail += f": {err_body['error'].get('message', str(err_body['error']))}"
        except Exception:
            pass
        raise HTTPException(status_code=502, detail=detail)
    except Exception as e:
        raise HTTPException(status_code=502, detail=f"AI 服务请求失败: {e}")

    # 5. 解析 AI 返回
    try:
        ai_text = data["choices"][0]["message"]["content"]
    except (KeyError, IndexError, TypeError):
        raise HTTPException(status_code=502, detail="AI 返回格式异常")

    tasks = _parse_ai_response(ai_text)

    # 6. 记录使用情况（无论是否识别出任务都记录，因为消耗了 API 调用）
    _record_usage(user_id, len(tasks), "ocr")

    return RecognizeResponse(tasks=tasks)

# ---------------- 工作日志总结 ----------------
_SUMMARIZE_MODEL = "qwen-plus"

_SUMMARIZE_PROMPT = """你是一位工作日志撰写助手，擅长把零散的任务记录整理成正式、简洁、适合向上级汇报的工作日志。

日期范围：{period}（共 {days} 天）
总结范围：{scope_label}
任务记录（JSON 数组；status: 0计划中 1执行中 2已完成；urgency: 0一般 1紧急 2重要；task_type: 0个人任务 1工作任务）：

{tasks_json}

要求：
1. 输出一篇结构化 Markdown 工作日志，包含以下章节：
   # {title}
   ## 一、总体概述（用 2-4 句话概括该期间的主要成果与节奏）
   ## 二、完成情况（统计已完成/进行中/计划中的任务数量；任务为空则如实说明）
   ## 三、任务明细（按【已完成】【进行中】【计划中】分组，每条格式：- 标题（紧急度/类型），必要时一句话补充进展）
   ## 四、小结（1-2 句收尾）
2. 语言正式、客观、简洁，站在写日志的人的角度叙述，不编造任务之外的事实，不出现"AI""模型"等字样
3. 若任务列表为空，概述与小结点明"该期间暂无记录"即可
4. 只输出 Markdown 正文，不要任何解释"""


def _build_summarize_prompt(req: SummarizeRequest) -> str:
    """构造总结 Prompt：把任务转成精简 JSON，交给文本模型。"""
    scope_label = {"all": "全部（工作+个人）", "work": "仅工作", "personal": "仅个人"}[req.scope]
    period_label = req.start_date if req.range == "day" else f"{req.start_date} 至 {req.end_date}"
    try:
        days = (
            datetime.strptime(req.end_date, "%Y-%m-%d")
            - datetime.strptime(req.start_date, "%Y-%m-%d")
        ).days + 1
    except ValueError:
        days = 1
    tasks_json = json.dumps(
        [t.model_dump(mode="json") for t in req.tasks], ensure_ascii=False
    )
    title = "当日工作日志" if req.range == "day" else "工作日志"
    return _SUMMARIZE_PROMPT.format(
        period=period_label,
        days=max(days, 1),
        scope_label=scope_label,
        tasks_json=tasks_json,
        title=title,
    )


@router.post("/summarize", response_model=SummarizeResponse)
async def summarize_tasks(
    req: SummarizeRequest, user_id: int = Depends(get_current_user)
):
    """AI 工作日志总结：根据客户端上报的任务生成结构化 Markdown 日志。

    - 鉴权：需登录
    - 限流：每分钟 5 次、每天 30 次（独立于截图识别）
    - 空任务列表：不调用大模型，直接返回提示文本
    """
    # 0. 参数校验
    try:
        start = datetime.strptime(req.start_date, "%Y-%m-%d")
        end = datetime.strptime(req.end_date, "%Y-%m-%d")
    except ValueError:
        raise HTTPException(status_code=400, detail="日期格式不正确，应为 YYYY-MM-DD")
    if end < start:
        raise HTTPException(status_code=400, detail="结束日期不能早于开始日期")
    if (end - start).days > 61:
        raise HTTPException(status_code=400, detail="总结日期范围最多 62 天")

    # 1. 空任务：直接返回，不消耗 API
    if not req.tasks:
        scope_label = {"all": "全部", "work": "仅工作", "personal": "仅个人"}[req.scope]
        return SummarizeResponse(
            summary=(
                f"# 工作日志\n\n"
                f"该期间（{req.start_date} 至 {req.end_date}）没有{scope_label}任务记录。\n"
            )
        )

    # 2. 限流（日报/周报分开统计，旧 summarize 记录按日报）
    _check_rate_limit(user_id, "daily" if req.range == "day" else "weekly")

    # 3. 检查 API Key
    api_key = _api_key()
    if not api_key:
        raise HTTPException(
            status_code=503,
            detail="AI 总结服务未配置：请在服务端 .env 中设置 DASHSCOPE_API_KEY",
        )

    # 4. 调文本模型
    payload = {
        "model": _SUMMARIZE_MODEL,
        "messages": [{"role": "user", "content": _build_summarize_prompt(req)}],
        "temperature": 0.4,
    }
    headers = {
        "Authorization": f"Bearer {api_key}",
        "Content-Type": "application/json",
    }
    try:
        async with httpx.AsyncClient(timeout=60) as client:
            resp = await client.post(_DASHSCOPE_URL, json=payload, headers=headers)
            resp.raise_for_status()
            data = resp.json()
    except httpx.HTTPStatusError as e:
        detail = f"AI 服务返回错误 ({e.response.status_code})"
        try:
            err_body = e.response.json()
            if "error" in err_body:
                detail += f": {err_body['error'].get('message', str(err_body['error']))}"
        except Exception:
            pass
        raise HTTPException(status_code=502, detail=detail)
    except Exception as e:
        raise HTTPException(status_code=502, detail=f"AI 服务请求失败: {e}")

    try:
        summary = data["choices"][0]["message"]["content"].strip()
    except (KeyError, IndexError, TypeError):
        raise HTTPException(status_code=502, detail="AI 返回格式异常")

    if not summary:
        raise HTTPException(status_code=502, detail="AI 返回内容为空")

    # 5. 记录使用
    _record_usage(user_id, len(req.tasks), "daily" if req.range == "day" else "weekly")

    return SummarizeResponse(summary=summary)


# ---------------- 额度详情 ----------------

@router.get("/usage")
def get_usage(user_id: int = Depends(get_current_user)):
    """额度详情：今日已用/可用 + 本月已用次数（需登录）。

    返回 items.ocr / items.daily / items.weekly：
      today_used: 今日已用；today_limit: 今日可用上限；month_used: 本月已用（仅统计，不限制）
    兼容旧数据：kind NULL 按 ocr、旧 summarize 按 daily 统计。
    """
    now = datetime.utcnow()
    today_start = now.replace(hour=0, minute=0, second=0, microsecond=0)
    month_start = now.replace(day=1, hour=0, minute=0, second=0, microsecond=0)

    def _count(kind_sql: str) -> tuple[int, int]:
        with get_conn() as conn:
            with conn.cursor() as cur:
                cur.execute(
                    f"SELECT COUNT(*) AS n FROM ai_usage WHERE user_id = %s AND {kind_sql} AND created_at >= %s",
                    (user_id, today_start),
                )
                today = cur.fetchone()["n"]
                cur.execute(
                    f"SELECT COUNT(*) AS n FROM ai_usage WHERE user_id = %s AND {kind_sql} AND created_at >= %s",
                    (user_id, month_start),
                )
                month = cur.fetchone()["n"]
        return today, month

    ocr_today, ocr_month = _count("(kind = 'ocr' OR kind IS NULL)")
    daily_today, daily_month = _count("(kind = 'daily' OR kind = 'summarize')")
    weekly_today, weekly_month = _count("kind = 'weekly'")

    return JSONResponse({
        "date": today_start.strftime("%Y-%m-%d"),
        "items": {
            "ocr": {
                "today_used": ocr_today,
                "today_limit": _RATE_LIMIT_PER_DAY,
                "month_used": ocr_month,
            },
            "daily": {
                "today_used": daily_today,
                "today_limit": _RATE_LIMIT_PER_DAY_DAILY,
                "month_used": daily_month,
            },
            "weekly": {
                "today_used": weekly_today,
                "today_limit": _RATE_LIMIT_PER_DAY_WEEKLY,
                "month_used": weekly_month,
            },
        },
    })


# ---------------- 导出 Word 文档 ----------------

@router.post("/export-docx")
def export_docx(req: ExportDocxRequest, user_id: int = Depends(get_current_user)):
    """把 AI 总结的 Markdown 导出为 .docx 文件（需登录，不消耗 AI 额度）。

    - 请求体：{"markdown": "...", "filename": "工作日志_2026-10-01"}
    - 返回：.docx 文件流
    """
    if not req.markdown or not req.markdown.strip():
        raise HTTPException(status_code=400, detail="内容为空，无法导出")
    data = _md_to_docx_bytes(req.markdown)
    safe_name = re.sub(r'[\\/:*?"<>|]', "_", req.filename).strip() or "工作日志"
    return Response(
        content=data,
        media_type="application/vnd.openxmlformats-officedocument.wordprocessingml.document",
        headers={
            "Content-Disposition": f"attachment; filename*=UTF-8''{quote(safe_name)}.docx"
        },
    )
