# -*- coding: utf-8 -*-
"""截图识别：同一组并列条目合并为一条任务+子任务（服务端提示词）+ 客户端多行编辑"""
import io

# ========== 1. 服务端提示词重写 ==========
p1 = r"E:\Code\WorkDiary\work_diary_server\app\routers\ai.py"
with io.open(p1, "r", encoding="utf-8") as f:
    c1 = f.read()

old = '''_RECOGNIZE_PROMPT = """你是一个工作任务识别助手。请从这张截图中识别所有待办工作任务。

要求：
1. 逐条识别截图中的每一个任务，截图里有几条就输出几条，一条都不能遗漏、不能合并、不能只取第一条
2. 截图中的"1、2、3"、"① ②"、"1) 2)"、"a. b."等并列条目，分别代表不同的独立任务，每个条目对应一个独立的 JSON 对象；即使开头有"今天两个任务""待办事项"之类的总起句，也要把后面的每一条都识别出来
3. 对每条任务内容进行转化，用更容易理解、更明确的语言表述：
   - 把模糊的指代改成具体内容（如"那个文档"→"完成项目需求文档"）
   - 把口语化表述改成书面语（如"明天弄一下"→"明天前完成"）
   - 补充必要的上下文，让任务单独看也能明白
4. 子任务规则：只有当一条任务内部含有明确的步骤、清单或阶段层级（如"步骤：""流程：""包含：""需要做：A、B、C"等）时，才用多行输出，每行以"- "开头；普通的并列条目（1、2、3）不是子任务，是独立任务，不要合并进其他任务
5. 去掉无意义的前缀符号（原有序号、横线、方框、对勾、圆点等），子任务行统一用"- "开头
6. 整体紧急程度：根据所有任务的时间紧迫度和重要性综合判断，只能是"一般"、"重要"、"紧急"三者之一，默认"一般"
7. plan_start_at / due_at：如果截图中有明确的整体开始/截止日期就提取，否则为 null
8. 数量自检：输出前先清点截图中的任务条目总数，tasks 数组的长度必须与截图中的任务条数完全一致；聊天记录里每条消息中的每个任务条目都要算入总数，内容重复的任务也要各自保留、不能合并

只输出 JSON，不要任何解释、markdown 代码块标记或其他文字。格式：
{"tasks": [{"title": "开发极简工作日志", "urgency": "一般", "plan_start_at": null, "due_at": null}, {"title": "给老妈做饭", "urgency": "一般", "plan_start_at": null, "due_at": null}, {"title": "筹备产品发布会\\n- 确定场地\\n- 邀请嘉宾\\n- 准备演示PPT", "urgency": "重要", "plan_start_at": null, "due_at": null}]}"""'''

new = '''_RECOGNIZE_PROMPT = """你是一个工作任务识别助手。请从这张截图中识别所有待办工作任务。

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
{"tasks": [{"title": "今日任务\\n- 开发极简工作日志\\n- 给老妈做饭", "urgency": "一般", "plan_start_at": null, "due_at": null}, {"title": "筹备产品发布会\\n- 确定场地\\n- 邀请嘉宾\\n- 准备演示PPT", "urgency": "重要", "plan_start_at": null, "due_at": null}]}"""'''

if old in c1:
    c1 = c1.replace(old, new, 1)
    print("server: 提示词已重写")
else:
    print("server FAIL")

with io.open(p1, "w", encoding="utf-8", newline="\n") as f:
    f.write(c1)

# ========== 2. 客户端识别结果列表项多行编辑 ==========
p2 = r"E:\Code\WorkDiary\work_diary_app\lib\widgets\recognize_result_dialog.dart"
with io.open(p2, "r", encoding="utf-8") as f:
    c2 = f.read()

old2 = """          title: TextFormField(
            initialValue: task.title,
            style: const TextStyle(fontSize: 13),
            decoration: const InputDecoration(
              isDense: true,
              contentPadding: EdgeInsets.symmetric(vertical: 8),
              border: InputBorder.none,
            ),
            onChanged: (v) => task.title = v,
          ),"""
new2 = """          title: TextFormField(
            initialValue: task.title,
            maxLines: null,
            keyboardType: TextInputType.multiline,
            style: const TextStyle(fontSize: 13),
            decoration: const InputDecoration(
              isDense: true,
              contentPadding: EdgeInsets.symmetric(vertical: 8),
              border: InputBorder.none,
            ),
            onChanged: (v) => task.title = v,
          ),"""
if old2 in c2:
    c2 = c2.replace(old2, new2, 1)
    print("client: 列表项多行编辑已加")
else:
    print("client FAIL")

with io.open(p2, "w", encoding="utf-8", newline="\n") as f:
    f.write(c2)
print("saved")
