"""全局配置：从环境变量 / .env 读取。"""
import os
import secrets
from pathlib import Path

from dotenv import load_dotenv

# 项目根目录 = 本文件上两级（app/config.py -> 项目根）
BASE_DIR = Path(__file__).resolve().parent.parent
load_dotenv(BASE_DIR / ".env")


def _int(name: str, default: int) -> int:
    try:
        return int(os.getenv(name, default))
    except (TypeError, ValueError):
        return default


def _list(name: str, default: list[str]) -> list[str]:
    raw = os.getenv(name, "")
    if not raw:
        return default
    return [item.strip() for item in raw.split(",") if item.strip()]


class Settings:
    # ---- 数据库 ----
    db_host: str = os.getenv("DB_HOST", "127.0.0.1")
    db_port: int = _int("DB_PORT", 3306)
    db_user: str = os.getenv("DB_USER", "workdiary")
    db_password: str = os.getenv("DB_PASSWORD", "")
    db_name: str = os.getenv("DB_NAME", "workdiary")

    # ---- 鉴权 ----
    jwt_secret: str = os.getenv("JWT_SECRET", "")
    token_expire_days: int = _int("TOKEN_EXPIRE_DAYS", 30)

    # ---- 邮箱 SMTP ----
    smtp_host: str = os.getenv("SMTP_HOST", "smtp.163.com")
    smtp_port: int = _int("SMTP_PORT", 465)
    smtp_user: str = os.getenv("SMTP_USER", "")
    smtp_password: str = os.getenv("SMTP_PASSWORD", "")
    smtp_from: str = os.getenv("SMTP_FROM", "")

    # ---- 管理后台 ----
    admin_username: str = os.getenv("ADMIN_USERNAME", "admin")
    admin_password: str = os.getenv("ADMIN_PASSWORD", "change-me-now")

    # ---- 服务 ----
    port: int = _int("PORT", 8000)
    cors_origins: list[str] = _list("CORS_ORIGINS", ["*"])

    # ---- 验证码规则 ----
    code_expire_minutes: int = _int("CODE_EXPIRE_MINUTES", 10)
    code_max_attempts: int = _int("CODE_MAX_ATTEMPTS", 5)
    code_rate_limit_per_minute: int = _int("CODE_RATE_LIMIT_PER_MINUTE", 2)
    code_rate_window_seconds: int = _int("CODE_RATE_WINDOW_SECONDS", 60)

    # ---- 附件中转（服务器只做一次性搬运，不长期存文件）----
    # 单个文件大小上限（MB），桌面与手机一致
    attachment_max_mb: int = _int("ATTACHMENT_MAX_MB", 100)
    # 每个任务/备忘最多几个附件
    attachment_max_per_parent: int = _int("ATTACHMENT_MAX_PER_PARENT", 5)
    # 中转文件最长保留时间（小时）：超时没人下载就删，避免"源机一直离线"时占盘
    attachment_ttl_hours: int = _int("ATTACHMENT_TTL_HOURS", 24)
    # 分片大小（MB）：微信单次请求有体积限制，2MB 分片让手机也能传 100MB
    attachment_chunk_mb: int = _int("ATTACHMENT_CHUNK_MB", 2)
    # 中转目录总容量上限（MB），超过直接拒绝新上传，防止磁盘被塞满影响站点
    attachment_quota_mb: int = _int("ATTACHMENT_QUOTA_MB", 2048)
    # 中转目录位置；留空则用 <项目根>/storage/attachments_tmp（必须在静态目录之外）
    attachment_tmp_dir: str = os.getenv("ATTACHMENT_TMP_DIR", "").strip()

    @property
    def attachment_tmp_path(self) -> Path:
        raw = self.attachment_tmp_dir
        if raw:
            path = Path(raw)
            return path if path.is_absolute() else BASE_DIR / path
        return BASE_DIR / "storage" / "attachments_tmp"


settings = Settings()


def ensure_secrets() -> None:
    """启动时校验关键配置。

    JWT_SECRET 缺失/过短必须直接拒绝启动：PyJWT 允许用空 key 做 HS256 签名，
    任何人自签一个 {"sub": "1"} 就能登录任意账号（管理员 token 用的是同一个
    key，等于直接进后台）。这里不能只打印警告。
    """
    if not settings.jwt_secret:
        raise RuntimeError(
            "JWT_SECRET 未设置，拒绝启动。请在 .env 中配置一个至少 32 位的随机字符串。"
        )
    if len(settings.jwt_secret) < 32:
        raise RuntimeError(
            f"JWT_SECRET 过短（{len(settings.jwt_secret)} 位），拒绝启动。"
            "请使用至少 32 位的随机字符串（例如 python -c "
            "\"import secrets;print(secrets.token_hex(32))\" ）。"
        )

    problems: list[str] = []
    if not settings.smtp_user or not settings.smtp_password:
        problems.append("SMTP_USER / SMTP_PASSWORD 未设置（发送验证码邮件需要）")
    if settings.admin_password == "change-me-now":
        problems.append("ADMIN_PASSWORD 还是默认值 change-me-now，请务必修改")
    if problems:
        print("=" * 60)
        print("【配置警告】请检查 .env 文件：")
        for p in problems:
            print("  -", p)
        print("=" * 60)
