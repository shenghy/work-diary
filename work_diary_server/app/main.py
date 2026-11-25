"""极简工作日记 - 后端 API 服务入口。

启动：uvicorn app.main:app --host 0.0.0.0 --port 8000
文档：http://<服务器>/docs
后台：http://<服务器>/admin
"""
from contextlib import asynccontextmanager
from pathlib import Path
import asyncio
import json
import threading

from fastapi import FastAPI
from fastapi.concurrency import run_in_threadpool
from fastapi.middleware.cors import CORSMiddleware
from fastapi.staticfiles import StaticFiles

from . import emailer
from .config import ensure_secrets, settings
from .database import init_db
from .routers import admin, ai, attachments, auth, memos, stats, tasks, version
from .ws_manager import ws_manager


# 服务端版本号：每次需要「确认线上是否已换成新代码」时就升这个号，
# 部署后用 /api/health 或 /openapi.json 一眼就能看出来。
APP_VERSION = "1.3.0"

# 中转文件兜底清理间隔（分钟）：请求方迟迟不取、上传半途而废都要靠它收口
_CLEANUP_INTERVAL_MINUTES = 15


async def _attachment_cleanup_loop():
    """后台循环：过期/超配额的中转文件清掉，落实"服务器只暂存不长期存"。"""
    from .routers.attachments import purge_expired_blobs

    while True:
        try:
            removed = await run_in_threadpool(purge_expired_blobs)
            if removed:
                print(f"[attachments] 清理中转文件 {removed} 个")
        except Exception as exc:  # 清理失败不能拖垮服务，下一轮再试
            print(f"[attachments] 清理任务异常: {exc}")
        await asyncio.sleep(_CLEANUP_INTERVAL_MINUTES * 60)


@asynccontextmanager
async def lifespan(app: FastAPI):
    ensure_secrets()
    init_db()
    settings.attachment_tmp_path.mkdir(parents=True, exist_ok=True)
    # SMTP 自检放后台线程：不拖慢启动，登录失败也会写进 server.log，
    # 避免“服务正常但验证码永远发不出去”这种只能靠用户反馈才发现的问题。
    threading.Thread(target=emailer.check_smtp, daemon=True).start()
    cleanup_task = asyncio.create_task(_attachment_cleanup_loop())
    yield
    cleanup_task.cancel()


app = FastAPI(
    title="极简工作日记 API",
    version=APP_VERSION,
    description="注册 / 登录 / 任务增删改 / 邮箱验证码 / 云端同步 / 管理后台",
    lifespan=lifespan,
)

app.add_middleware(
    CORSMiddleware,
    allow_origins=settings.cors_origins,
    allow_credentials=False,
    allow_methods=["*"],
    allow_headers=["*"],
)

app.include_router(auth.router)
app.include_router(tasks.router)
app.include_router(memos.router)
app.include_router(attachments.router)
app.include_router(admin.router)
app.include_router(ai.router)
app.include_router(stats.router)
app.include_router(version.router)

# 挂载升级包静态文件目录
_DOWNLOAD_DIR = Path(__file__).resolve().parent.parent / "downloads"
_DOWNLOAD_DIR.mkdir(parents=True, exist_ok=True)
app.mount("/downloads", StaticFiles(directory=str(_DOWNLOAD_DIR)), name="downloads")

# 挂载落地页静态资源
_STATIC_DIR = Path(__file__).resolve().parent / "static"
_STATIC_DIR.mkdir(parents=True, exist_ok=True)
app.mount("/static", StaticFiles(directory=str(_STATIC_DIR)), name="static")

# 挂载安装包下载目录
app.mount("/download", StaticFiles(directory=str(_DOWNLOAD_DIR)), name="download")


@app.get("/")
def root():
    from fastapi.responses import FileResponse
    index_file = _STATIC_DIR / "index.html"
    if index_file.exists():
        return FileResponse(index_file)
    return {
        "service": "极简工作日记 API",
        "version": APP_VERSION,
        "admin": "/admin",
        "docs": "/docs",
        "health": "/api/health",
    }


@app.get("/api/health")
def health():
    # 带上版本号：部署新代码后客户端/运维可以直接确认线上是否已生效
    return {"status": "ok", "version": APP_VERSION}


# ---------------- WebSocket：多端同步推送 ----------------
from fastapi import WebSocket, WebSocketDisconnect, Query
from .security import decode_token
import jwt as _jwt


@app.websocket("/ws")
async def websocket_endpoint(
    websocket: WebSocket,
    token: str = Query(default=""),
    client_id: str = Query(default=""),
    device_id: str = Query(default=""),
    device_name: str = Query(default=""),
):
    """客户端建立 WebSocket 连接，token 和 client_id 在 URL query 里传。

    device_id / device_name 可选：附件按需中转要靠它判断"哪台机器能应答拉取请求"。
    旧客户端不带这两个参数时走 {"type":"hello"} 消息补齐。
    """
    try:
        payload = decode_token(token)
        user_id = int(payload["sub"])
    except (_jwt.PyJWTError, KeyError, TypeError, ValueError):
        await websocket.close(code=1008)
        return

    if not client_id:
        client_id = "unknown"
    conn = await ws_manager.connect(
        user_id, client_id, websocket, device_id=device_id, device_name=device_name
    )

    async def _catchup():
        """上线补发：把这台机器欠着的上传/下载请求重新推一遍。"""
        if conn.catchup_done or not conn.device_id:
            return
        conn.catchup_done = True
        try:
            await attachments.push_pending_transfers(user_id, conn)
        except Exception as exc:
            print(f"[attachments] 补发待处理中转失败: {exc}")

    await _catchup()
    try:
        while True:
            raw = await websocket.receive_text()
            try:
                msg = json.loads(raw)
            except (ValueError, TypeError):
                continue
            if isinstance(msg, dict) and msg.get("type") == "hello":
                ws_manager.set_device(
                    user_id,
                    client_id,
                    str(msg.get("device_id") or ""),
                    str(msg.get("device_name") or ""),
                )
                await _catchup()
    except WebSocketDisconnect:
        pass
    finally:
        ws_manager.disconnect(user_id, client_id, websocket)
