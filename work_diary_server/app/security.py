"""密码哈希（PBKDF2）与 JWT 令牌。兼容旧版客户端 SHA256 哈希，登录成功后自动升级。"""
import hashlib
import hmac
import secrets
from datetime import datetime, timedelta, timezone

import jwt

from .config import settings

PBKDF2_ITERATIONS = 120_000
_LEGACY_SHA256_HEX_LEN = 64


def hash_password(password: str) -> str:
    salt = secrets.token_hex(16)
    digest = hashlib.pbkdf2_hmac(
        "sha256", password.encode("utf-8"), bytes.fromhex(salt), PBKDF2_ITERATIONS
    )
    return f"pbkdf2_sha256${PBKDF2_ITERATIONS}${salt}${digest.hex()}"


def _is_legacy_sha256(stored: str) -> bool:
    if len(stored) != _LEGACY_SHA256_HEX_LEN:
        return False
    try:
        bytes.fromhex(stored)
        return True
    except ValueError:
        return False


def verify_password(password: str, stored: str) -> bool:
    if not stored:
        return False
    # 旧版客户端：SHA256(明文) 直接入库
    if _is_legacy_sha256(stored):
        return hmac.compare_digest(
            hashlib.sha256(password.encode("utf-8")).hexdigest(), stored
        )
    # 新版：pbkdf2_sha256$iter$salt$hash
    try:
        scheme, iterations, salt, digest_hex = stored.split("$")
        if scheme != "pbkdf2_sha256":
            return False
        digest = hashlib.pbkdf2_hmac(
            "sha256", password.encode("utf-8"), bytes.fromhex(salt), int(iterations)
        )
        return hmac.compare_digest(digest.hex(), digest_hex)
    except (ValueError, TypeError):
        return False


def is_pbkdf2_hash(stored: str) -> bool:
    return isinstance(stored, str) and stored.startswith("pbkdf2_sha256$")


def create_token(user_id: int, email: str, expire_days: int | None = None) -> str:
    days = expire_days or settings.token_expire_days
    payload = {
        "sub": str(user_id),
        "email": email,
        "iat": datetime.now(timezone.utc),
        "exp": datetime.now(timezone.utc) + timedelta(days=days),
    }
    return jwt.encode(payload, settings.jwt_secret, algorithm="HS256")


def decode_token(token: str) -> dict:
    """解码并校验 JWT，失败抛 jwt.PyJWTError。"""
    return jwt.decode(token, settings.jwt_secret, algorithms=["HS256"])
