"""鉴权依赖：客户端 Bearer Token、后台 Cookie Token。"""
from datetime import datetime, timedelta, timezone

import jwt
from fastapi import Cookie, Depends, Header, HTTPException

from ..config import settings
from ..security import decode_token


def get_current_user(authorization: str | None = Header(default=None)) -> int:
    """从 Authorization: Bearer <token> 解析出用户 id。"""
    if not authorization or not authorization.lower().startswith("bearer "):
        raise HTTPException(status_code=401, detail="未登录")
    token = authorization[7:].strip()
    try:
        payload = decode_token(token)
    except jwt.PyJWTError:
        raise HTTPException(status_code=401, detail="登录已过期，请重新登录")
    try:
        return int(payload["sub"])
    except (KeyError, TypeError, ValueError):
        raise HTTPException(status_code=401, detail="令牌无效")


def _admin_token_payload() -> dict:
    return {
        "sub": "admin",
        "role": "admin",
        "iat": datetime.now(timezone.utc),
        "exp": datetime.now(timezone.utc) + timedelta(hours=12),
    }


def create_admin_token() -> str:
    import jwt as _jwt

    return _jwt.encode(_admin_token_payload(), settings.jwt_secret, algorithm="HS256")


def is_admin_valid(token: str | None) -> bool:
    """校验管理后台 Cookie 令牌是否有效。"""
    if not token:
        return False
    try:
        payload = decode_token(token)
    except jwt.PyJWTError:
        return False
    return payload.get("role") == "admin"


def require_admin(admin_token: str | None = Cookie(default=None)) -> None:
    if not is_admin_valid(admin_token):
        raise HTTPException(status_code=401, detail="请先登录管理后台")
