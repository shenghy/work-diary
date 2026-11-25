"""管理后台：登录 / 数据看板 / 统计接口。"""
import hmac
import time
from collections import defaultdict
from datetime import timedelta
from pathlib import Path

from fastapi import APIRouter, Cookie, Depends, Form, HTTPException, Request, Response
from fastapi.responses import FileResponse, JSONResponse, RedirectResponse

from ..config import settings
from ..database import get_conn
from ..utils import china_date, utc_now
from .deps import create_admin_token, is_admin_valid, require_admin

router = APIRouter(prefix="/admin", tags=["admin"])

_STATIC_DIR = Path(__file__).resolve().parent.parent  # app/
COOKIE_NAME = "admin_token"

# 后台登录失败计数：ip -> (失败次数, 锁定到期时间 monotonic)
_login_guard: dict[str, tuple[int, float]] = {}


@router.get("/login", response_class=FileResponse)
def admin_login_page():
    return FileResponse(_STATIC_DIR / "admin_login.html", headers={"Cache-Control": "no-cache"})


@router.post("/login")
def admin_login(
    request: Request,
    username: str = Form(...),
    password: str = Form(...),
):
    # 简单的按 IP 失败退避，防止在线爆破后台口令
    client = request.client.host if request.client else "unknown"
    now = time.monotonic()
    attempts, locked_until = _login_guard.get(client, (0, 0.0))
    if locked_until > now:
        raise HTTPException(status_code=429, detail="尝试过于频繁，请稍后再试")

    # 用 compare_digest 做定长比较，避免时序侧信道逐字节猜口令
    user_ok = hmac.compare_digest(username, settings.admin_username)
    pass_ok = hmac.compare_digest(password, settings.admin_password)
    if not (user_ok and pass_ok):
        attempts += 1
        # 连续 5 次失败锁定 10 分钟
        lock = now + 600 if attempts >= 5 else 0.0
        _login_guard[client] = (0 if lock else attempts, lock)
        raise HTTPException(status_code=401, detail="用户名或密码错误")

    _login_guard.pop(client, None)
    resp = RedirectResponse(url="/admin", status_code=303)
    resp.set_cookie(
        COOKIE_NAME,
        create_admin_token(),
        max_age=12 * 3600,
        httponly=True,
        samesite="lax",
        secure=False,  # 部署 HTTPS 后请改为 True（见 README）
        path="/",
    )
    return resp


@router.post("/logout")
def admin_logout(_: None = Depends(require_admin)):
    resp = RedirectResponse(url="/admin/login", status_code=303)
    resp.delete_cookie(COOKIE_NAME, path="/")
    return resp


@router.get("", response_class=FileResponse)
def admin_dashboard(admin_token: str | None = Cookie(default=None)):
    """看板页：未登录时自动跳到登录页，而不是返回 401 JSON。"""
    if not is_admin_valid(admin_token):
        return RedirectResponse(url="/admin/login", status_code=303)
    return FileResponse(_STATIC_DIR / "admin_dashboard.html", headers={"Cache-Control": "no-cache"})


@router.get("/api/stats")
def admin_stats(_: None = Depends(require_admin)):
    now = utc_now()
    window_start = now - timedelta(days=13)

    with get_conn() as conn:
        with conn.cursor() as cur:
            cur.execute("SELECT COUNT(*) AS n FROM users")
            total_users = cur.fetchone()["n"]

            cur.execute(
                "SELECT created_at FROM users WHERE created_at >= %s",
                (window_start,),
            )
            trend_rows = [r["created_at"] for r in cur.fetchall()]

            cur.execute(
                "SELECT id, username, created_at, last_login_at "
                "FROM users ORDER BY id DESC LIMIT 10"
            )
            recent = cur.fetchall()

            cur.execute(
                "SELECT COUNT(*) AS n FROM tasks WHERE is_deleted = 0"
            )
            total_tasks = cur.fetchone()["n"]

            cur.execute(
                "SELECT COUNT(*) AS n FROM tasks "
                "WHERE is_deleted = 0 AND status = 2"
            )
            completed_tasks = cur.fetchone()["n"]

            cur.execute(
                "SELECT COUNT(DISTINCT user_id) AS n FROM tasks "
                "WHERE is_deleted = 0"
            )
            active_users = cur.fetchone()["n"]

    # 按中国时区日期聚合最近 14 天注册趋势
    by_date: dict[str, int] = defaultdict(int)
    for dt in trend_rows:
        by_date[china_date(dt)] += 1
    trend = []
    for i in range(13, -1, -1):
        day = now - timedelta(days=i)
        key = china_date(day)
        trend.append({"date": key, "count": by_date.get(key, 0)})

    today_key = china_date(now)
    yesterday_key = china_date(now - timedelta(days=1))

    return JSONResponse(
        {
            "total_users": total_users,
            "today_users": by_date.get(today_key, 0),
            "yesterday_users": by_date.get(yesterday_key, 0),
            "trend": trend,
            "total_tasks": total_tasks,
            "completed_tasks": completed_tasks,
            "active_users": active_users,
            "avg_tasks_per_active": round(total_tasks / active_users, 1)
            if active_users
            else 0,
            "recent_users": [
                {
                    "id": r["id"],
                    "email": r["username"],
                    "created_at": r["created_at"].strftime("%Y-%m-%d %H:%M"),
                    "last_login_at": r["last_login_at"].strftime("%Y-%m-%d %H:%M")
                    if r["last_login_at"]
                    else "-",
                }
                for r in recent
            ],
            "generated_at": now.strftime("%Y-%m-%d %H:%M:%S"),
        }
    )
