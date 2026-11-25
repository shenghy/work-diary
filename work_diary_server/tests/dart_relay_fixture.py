"""为桌面端（Flutter）端到端测试准备一个可用的测试账号，并写出 fixture 文件。

Dart 侧不会连 MySQL，也不该拿真实账号跑破坏性用例，所以账号由这里直灌验证码
注册，token 与地址写进 `work_diary_app/test/fixtures/attachment_relay.json`，
Dart 测试读到就用、读不到就跳过。

用法（需要本地服务已经起来，见 ws_push_test.py 的 --base-url 说明）：
    .venv\\Scripts\\python.exe tests\\dart_relay_fixture.py --base-url http://127.0.0.1:8011
    .venv\\Scripts\\python.exe tests\\dart_relay_fixture.py --cleanup   # 跑完删账号
"""
import argparse
import json
import os
import sys
import uuid
from datetime import datetime, timedelta, timezone

import httpx
import pymysql

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

from tests.local_test_env import (  # noqa: E402
    LOCAL_HOST,
    LOCAL_PASSWORD,
    LOCAL_PORT,
    LOCAL_USER,
    TEST_DB_NAME,
)

FIXTURE = os.path.normpath(
    os.path.join(
        os.path.dirname(os.path.dirname(os.path.abspath(__file__))),
        "..", "work_diary_app", "test", "fixtures", "attachment_relay.json",
    )
)


def _conn():
    return pymysql.connect(
        host=LOCAL_HOST, port=LOCAL_PORT, user=LOCAL_USER, password=LOCAL_PASSWORD,
        database=TEST_DB_NAME, charset="utf8mb4", cursorclass=pymysql.cursors.DictCursor,
        autocommit=True, connect_timeout=8,
    )


def drop_account(email: str) -> None:
    conn = _conn()
    try:
        with conn.cursor() as cur:
            cur.execute("DELETE FROM email_codes WHERE email=%s", (email,))
            cur.execute("DELETE FROM users WHERE username=%s", (email,))
    finally:
        conn.close()


def read_fixture_email() -> str | None:
    if not os.path.exists(FIXTURE):
        return None
    try:
        with open(FIXTURE, encoding="utf-8") as fh:
            return json.load(fh).get("email")
    except (ValueError, OSError):
        return None


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--base-url", default="http://127.0.0.1:8011")
    parser.add_argument("--keep-previous", action="store_true",
                        help="不要先删掉上一轮的测试账号")
    parser.add_argument("--cleanup", action="store_true",
                        help="删除 fixture 里登记的测试账号并移除 fixture 文件")
    args = parser.parse_args()

    if args.cleanup:
        email = read_fixture_email()
        if email:
            drop_account(email)
            print(f"已删除测试账号 {email}")
        if os.path.exists(FIXTURE):
            os.remove(FIXTURE)
            print(f"已移除 {FIXTURE}")
        return 0

    previous = read_fixture_email()
    if previous and not args.keep_previous:
        drop_account(previous)

    base = args.base_url.rstrip("/")
    tag = uuid.uuid4().hex[:8]
    email = f"relay.{tag}@example.com"
    now = datetime.now(timezone.utc).replace(tzinfo=None)
    conn = _conn()
    try:
        with conn.cursor() as cur:
            cur.execute("DELETE FROM email_codes WHERE email=%s", (email,))
            cur.execute(
                "INSERT INTO email_codes (email, purpose, code, attempts, expires_at, created_at) "
                "VALUES (%s,'auth',%s,0,%s,%s)",
                (email, "123456", now + timedelta(minutes=10), now),
            )
    finally:
        conn.close()

    client = httpx.Client(trust_env=False, timeout=20)
    r = client.post(f"{base}/api/auth/register",
                    json={"email": email, "code": "123456", "password": "Test123456"})
    r.raise_for_status()
    body = r.json()

    os.makedirs(os.path.dirname(FIXTURE), exist_ok=True)
    with open(FIXTURE, "w", encoding="utf-8") as fh:
        json.dump(
            {
                "base_url": base,
                "token": body["token"],
                "user_id": body["user"]["id"],
                "email": email,
                "generated_at": datetime.now().isoformat(timespec="seconds"),
            },
            fh, ensure_ascii=False, indent=2,
        )
    print(f"测试账号 {email} 已就绪，fixture 写到：{FIXTURE}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
