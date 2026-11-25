"""通过 163 SMTP 发送验证码邮件。"""
import smtplib
from email.mime.text import MIMEText

from .config import settings


def _open_smtp() -> smtplib.SMTP_SSL:
    return smtplib.SMTP_SSL(settings.smtp_host, settings.smtp_port, timeout=15)


def send_code_email(to_email: str, code: str) -> None:
    body = f"您的验证码是：{code}\n\n{settings.code_expire_minutes}分钟内有效，请勿泄露给他人。\n\n——极简工作日记"
    msg = MIMEText(body, "plain", "utf-8")
    msg["Subject"] = "极简工作日记 - 邮箱验证码"
    msg["From"] = settings.smtp_from or settings.smtp_user
    msg["To"] = to_email

    server = _open_smtp()
    try:
        server.login(settings.smtp_user, settings.smtp_password)
        server.sendmail(settings.smtp_from or settings.smtp_user, [to_email], msg.as_string())
    finally:
        server.quit()


def check_smtp() -> None:
    """启动自检：只登录、不发信，失败只打印警告，不影响服务启动。

    验证码依赖邮箱的 SMTP 授权码。授权码被重置 / 换了发信账号 / 服务器上
    的 .env 没同步时，接口会一直返回 535，但服务看起来一切正常。启动时
    把自检结果写进 server.log，下次出问题能直接看到原因。
    """
    if not settings.smtp_user or not settings.smtp_password:
        print("[emailer] 未配置 SMTP_USER / SMTP_PASSWORD，验证码邮件无法发送")
        return
    try:
        server = _open_smtp()
        try:
            server.login(settings.smtp_user, settings.smtp_password)
        finally:
            try:
                server.quit()
            except Exception:
                pass
        print(
            f"[emailer] SMTP 登录成功：{settings.smtp_user} "
            f"({settings.smtp_host}:{settings.smtp_port})"
        )
    except Exception as e:
        print("=" * 60)
        print("【SMTP 警告】验证码邮件将发送失败，请检查 .env：")
        print(f"  {settings.smtp_host}:{settings.smtp_port} user={settings.smtp_user}")
        print(f"  {type(e).__name__}: {e}")
        print("  163/QQ 邮箱需要使用「客户端授权码」而不是登录密码；")
        print("  授权码重置或更换发信账号后，要同步更新服务器 .env 并重启。")
        print("=" * 60)

