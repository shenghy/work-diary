"""通用小工具：邮箱校验、时间转换、序列化。"""
import re
from datetime import datetime, timedelta, timezone

EMAIL_RE = re.compile(r"^[\w.-]+@([\w-]+\.)+[\w-]{2,}$")


def is_valid_email(email: str) -> bool:
    return bool(EMAIL_RE.match(email or ""))


def utc_now() -> datetime:
    """当前 UTC 时间（naive，直接存 MySQL DATETIME）。"""
    return datetime.now(timezone.utc).replace(tzinfo=None)


def to_utc_naive(dt: datetime) -> datetime:
    """任意 datetime -> 不带时区的 UTC。naive 输入视为 UTC。"""
    if dt.tzinfo is None:
        return dt
    return dt.astimezone(timezone.utc).replace(tzinfo=None)


def utc_iso(dt: datetime) -> str:
    """存储的 naive UTC -> ISO8601 带 Z 的字符串（毫秒精度）。"""
    if dt.tzinfo is None:
        dt = dt.replace(tzinfo=timezone.utc)
    else:
        dt = dt.astimezone(timezone.utc)
    return dt.strftime("%Y-%m-%dT%H:%M:%S.%f")[:-3] + "Z"


def parse_iso(raw: str) -> datetime:
    """ISO 字符串 -> naive UTC。"""
    dt = datetime.fromisoformat(raw)
    return to_utc_naive(dt)


def china_date(dt_naive_utc: datetime) -> str:
    """naive UTC -> 中国时区日期 (YYYY-MM-DD)，用于后台统计。"""
    cst = dt_naive_utc.replace(tzinfo=timezone.utc).astimezone(
        timezone(timedelta(hours=8))
    )
    return cst.strftime("%Y-%m-%d")
