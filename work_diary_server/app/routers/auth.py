"""认证：发送验证码 / 注册 / 登录 / 找回密码 / 当前用户。"""
import random
from datetime import timedelta

import pymysql
from fastapi import APIRouter, Depends, HTTPException

from .. import emailer
from ..config import settings
from ..database import get_conn, transaction
from ..models import (
    AuthResponse,
    LoginRequest,
    RegisterRequest,
    ResetPasswordRequest,
    SendCodeRequest,
    UserOut,
    VerifyCodeRequest,
)
from ..security import (
    create_token,
    hash_password,
    is_pbkdf2_hash,
    verify_password,
)
from ..utils import is_valid_email, utc_iso, utc_now
from .deps import get_current_user

router = APIRouter(prefix="/api/auth", tags=["auth"])

PURPOSE = "auth"


# ---------------- 验证码 ----------------
def _latest_code(conn, email: str) -> dict | None:
    with conn.cursor() as cur:
        cur.execute(
            "SELECT id, code, attempts, expires_at FROM email_codes "
            "WHERE email = %s AND purpose = %s ORDER BY id DESC LIMIT 1",
            (email, PURPOSE),
        )
        return cur.fetchone()


def _consume_code(conn, code_id: int) -> None:
    with conn.cursor() as cur:
        cur.execute("DELETE FROM email_codes WHERE id = %s", (code_id,))


def _verify_code_or_raise(conn, email: str, code: str) -> None:
    """校验验证码并消费。失败抛 HTTPException。"""
    row = _latest_code(conn, email)
    if row is None:
        raise HTTPException(status_code=400, detail="请先获取验证码")
    now = utc_now()
    if row["expires_at"] < now:
        _consume_code(conn, row["id"])
        conn.commit()
        raise HTTPException(status_code=400, detail="验证码已过期，请重新获取")
    if row["attempts"] >= settings.code_max_attempts:
        _consume_code(conn, row["id"])
        conn.commit()
        raise HTTPException(status_code=400, detail="验证码错误次数过多，请重新获取")
    if row["code"] != code:
        with conn.cursor() as cur:
            cur.execute(
                "UPDATE email_codes SET attempts = attempts + 1 WHERE id = %s",
                (row["id"],),
            )
        conn.commit()
        raise HTTPException(status_code=400, detail="验证码错误")
    _consume_code(conn, row["id"])
    conn.commit()


@router.post("/send-code")
def send_code(req: SendCodeRequest):
    email = req.email.strip().lower()
    if not is_valid_email(email):
        raise HTTPException(status_code=400, detail="邮箱格式不正确")

    now = utc_now()
    with get_conn() as conn:
        # 限频：同邮箱 1 分钟窗口内最多 code_rate_limit_per_minute 条
        # （窗口内的历史记录保留在 email_codes 表中用于计数）
        with conn.cursor() as cur:
            cur.execute(
                "SELECT COUNT(*) AS cnt FROM email_codes WHERE email = %s "
                "AND purpose = %s AND created_at >= %s",
                (
                    email,
                    PURPOSE,
                    now - timedelta(seconds=settings.code_rate_window_seconds),
                ),
            )
            sent_in_window = cur.fetchone()["cnt"]
        if sent_in_window >= settings.code_rate_limit_per_minute:
            raise HTTPException(
                status_code=429,
                detail="发送过于频繁，请稍后再试",
            )

        code = f"{random.randint(0, 999999):06d}"
        expires_at = now + timedelta(minutes=settings.code_expire_minutes)
        try:
            with transaction(conn):
                with conn.cursor() as cur:
                    # 只清理已过期的旧验证码；窗口内的记录保留，供限频计数
                    cur.execute(
                        "DELETE FROM email_codes WHERE email = %s AND purpose = %s "
                        "AND created_at < %s",
                        (
                            email,
                            PURPOSE,
                            now - timedelta(minutes=settings.code_expire_minutes),
                        ),
                    )
                    cur.execute(
                        "INSERT INTO email_codes "
                        "(email, purpose, code, attempts, expires_at, created_at) "
                        "VALUES (%s, %s, %s, 0, %s, %s)",
                        (email, PURPOSE, code, expires_at, now),
                    )
                # 发邮件失败则回滚（不留无效验证码）
                emailer.send_code_email(email, code)
        except Exception as e:
            if isinstance(e, HTTPException):
                raise
            # 详细原因只写服务端日志：SMTP 原始错误（如 535 授权失败）不该
            # 直接回给终端用户，既看不懂，也会把发信账号的配置暴露出去。
            print(
                f"[send-code] 邮件发送失败 email={email} "
                f"error={type(e).__name__}: {e}"
            )
            raise HTTPException(
                status_code=500, detail="验证码发送失败，请稍后重试"
            )
    return {
        "sent": True,
        "rate_limit_per_minute": settings.code_rate_limit_per_minute,
    }


@router.post("/verify-code")
def verify_code(req: VerifyCodeRequest):
    """只校验不消费，供调试 / 兼容旧流程使用。"""
    email = req.email.strip().lower()
    with get_conn() as conn:
        row = _latest_code(conn, email)
        if row is None:
            return {"valid": False, "error": "请先获取验证码"}
        now = utc_now()
        if row["expires_at"] < now:
            return {"valid": False, "error": "验证码已过期"}
        if row["code"] != req.code:
            with conn.cursor() as cur:
                cur.execute(
                    "UPDATE email_codes SET attempts = attempts + 1 WHERE id = %s",
                    (row["id"],),
                )
            conn.commit()
            return {"valid": False, "error": "验证码错误"}
        return {"valid": True}


# ---------------- 用户 ----------------
def _user_to_out(row: dict) -> UserOut:
    return UserOut(
        id=row["id"],
        email=row["username"],
        created_at=utc_iso(row["created_at"]),
    )


@router.post("/register", response_model=AuthResponse)
def register(req: RegisterRequest):
    email = req.email.strip().lower()
    if not is_valid_email(email):
        raise HTTPException(status_code=400, detail="邮箱格式不正确")

    with get_conn() as conn:
        with conn.cursor() as cur:
            cur.execute(
                "SELECT id FROM users WHERE username = %s", (email,)
            )
            if cur.fetchone() is not None:
                raise HTTPException(status_code=409, detail="该邮箱已注册")

        _verify_code_or_raise(conn, email, req.code)

        with conn.cursor() as cur:
            now = utc_now()
            try:
                with transaction(conn):
                    cur.execute(
                        "INSERT INTO users (username, password_hash, created_at, updated_at) "
                        "VALUES (%s, %s, %s, %s)",
                        (email, hash_password(req.password), now, now),
                    )
                    user_id = cur.lastrowid
            except pymysql.err.IntegrityError:
                raise HTTPException(status_code=409, detail="该邮箱已注册")

    return AuthResponse(
        token=create_token(user_id, email),
        user=UserOut(id=user_id, email=email, created_at=utc_iso(now)),
    )


@router.post("/login", response_model=AuthResponse)
def login(req: LoginRequest):
    email = req.email.strip().lower()
    with get_conn() as conn:
        with conn.cursor() as cur:
            cur.execute(
                "SELECT * FROM users WHERE username = %s", (email,)
            )
            row = cur.fetchone()
        if row is None or not verify_password(req.password, row["password_hash"]):
            raise HTTPException(status_code=401, detail="邮箱或密码错误")

        now = utc_now()
        with transaction(conn):
            with conn.cursor() as cur:
                # 旧版 SHA256 哈希自动升级为 PBKDF2
                if not is_pbkdf2_hash(row["password_hash"]):
                    cur.execute(
                        "UPDATE users SET password_hash = %s WHERE id = %s",
                        (hash_password(req.password), row["id"]),
                    )
                cur.execute(
                    "UPDATE users SET last_login_at = %s WHERE id = %s",
                    (now, row["id"]),
                )

    return AuthResponse(
        token=create_token(row["id"], email),
        user=_user_to_out(row),
    )


@router.post("/reset-password")
def reset_password(req: ResetPasswordRequest):
    email = req.email.strip().lower()
    with get_conn() as conn:
        _verify_code_or_raise(conn, email, req.code)
        with conn.cursor() as cur:
            cur.execute(
                "UPDATE users SET password_hash = %s WHERE username = %s",
                (hash_password(req.password), email),
            )
            if cur.rowcount == 0:
                raise HTTPException(status_code=400, detail="邮箱未注册")
        conn.commit()
    return {"success": True}


@router.get("/email-status")
def email_status(email: str):
    """检查邮箱是否已注册（客户端失焦检测 / 切换注册找回模式用）。"""
    email = email.strip().lower()
    with get_conn() as conn:
        with conn.cursor() as cur:
            cur.execute(
                "SELECT id FROM users WHERE username = %s", (email,)
            )
            registered = cur.fetchone() is not None
    return {"registered": registered}


@router.get("/me", response_model=UserOut)
def me(user_id: int = Depends(get_current_user)):
    with get_conn() as conn:
        with conn.cursor() as cur:
            cur.execute(
                "SELECT id, username, created_at FROM users WHERE id = %s",
                (user_id,),
            )
            row = cur.fetchone()
    if row is None:
        raise HTTPException(status_code=401, detail="账号不存在")
    return _user_to_out(row)
