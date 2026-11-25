"""本地测试数据库开关。

测试必须跑在本机独立库 `workdiary_localtest` 上：线上库（`workdiary`）已经
对开发机开放远程连接，一旦测试沿用 `.env` 就是往真实用户数据里写删 —— 连接
能通不代表可以拿它当测试库，所以这里默认拒绝，见 `test_database()`。

一次性准备（本机执行一次即可）：

    set DB_LOCAL_TEST_ROOT_PASSWORD=...           # 可选，本机 root 有密码时才需要
    .venv\\Scripts\\python.exe scripts\\prepare_local_test_db.py

用法：测试脚本里 `with local_test_db(): ...` 包住即可。
"""
import os
import re
from contextlib import contextmanager

import pymysql

from app.config import settings

IDENT_RE = re.compile(r"^[A-Za-z0-9_]{1,60}$")
TEST_DB_NAME = os.getenv("DB_LOCAL_TEST_NAME", "workdiary_localtest")
LOCAL_HOST = os.getenv("DB_LOCAL_TEST_HOST", "127.0.0.1")
LOCAL_PORT = int(os.getenv("DB_LOCAL_TEST_PORT", "3399"))
LOCAL_USER = os.getenv("DB_LOCAL_TEST_USER", "workdiary")
LOCAL_PASSWORD = os.getenv("DB_LOCAL_TEST_PASSWORD", "localtest")
ROOT_USER = os.getenv("DB_LOCAL_TEST_ROOT_USER", "root")
ROOT_PASSWORD = os.getenv("DB_LOCAL_TEST_ROOT_PASSWORD", "")


def _admin_conn():
    return pymysql.connect(
        host=LOCAL_HOST, port=LOCAL_PORT, user=ROOT_USER, password=ROOT_PASSWORD,
        charset="utf8mb4", cursorclass=pymysql.cursors.DictCursor, connect_timeout=8,
        autocommit=True,
    )


def ensure_test_database() -> None:
    """建库 + 建测试账号；需要本机以 root 权限运行一次。"""
    if not IDENT_RE.match(TEST_DB_NAME):
        raise ValueError(f"测试库名不合法：{TEST_DB_NAME}")
    conn = _admin_conn()
    try:
        with conn.cursor() as cur:
            cur.execute(
                f"CREATE DATABASE IF NOT EXISTS `{TEST_DB_NAME}` "
                "CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci"
            )
            cur.execute(
                "CREATE USER IF NOT EXISTS %s@'127.0.0.1' IDENTIFIED BY %s",
                (LOCAL_USER, LOCAL_PASSWORD),
            )
            cur.execute(
                "CREATE USER IF NOT EXISTS %s@'localhost' IDENTIFIED BY %s",
                (LOCAL_USER, LOCAL_PASSWORD),
            )
            # 库名不能参数化，已用 IDENT_RE 白名单校验
            for host in ("127.0.0.1", "localhost"):
                cur.execute(
                    f"GRANT ALL PRIVILEGES ON `{TEST_DB_NAME}`.* TO %s@'{host}'",
                    (LOCAL_USER,),
                )
            cur.execute("FLUSH PRIVILEGES")
    finally:
        conn.close()


def is_local_db_available() -> bool:
    try:
        conn = pymysql.connect(
            host=LOCAL_HOST, port=LOCAL_PORT, user=LOCAL_USER, password=LOCAL_PASSWORD,
            database=TEST_DB_NAME, charset="utf8mb4", connect_timeout=5,
        )
        conn.close()
        return True
    except Exception:
        return False


@contextmanager
def local_test_db():
    """把全局配置临时指向本地测试库（退出时还原）。"""
    if not is_local_db_available():
        raise RuntimeError(
            f"本地测试库不可用（{LOCAL_USER}@{LOCAL_HOST}:{LOCAL_PORT}/{TEST_DB_NAME}）。"
            "请先启动本机 MariaDB/MySQL 并执行 scripts/prepare_local_test_db.py。"
        )
    saved = (
        settings.db_host, settings.db_port, settings.db_user,
        settings.db_password, settings.db_name,
    )
    settings.db_host = LOCAL_HOST
    settings.db_port = LOCAL_PORT
    settings.db_user = LOCAL_USER
    settings.db_password = LOCAL_PASSWORD
    settings.db_name = TEST_DB_NAME
    try:
        yield
    finally:
        (
            settings.db_host, settings.db_port, settings.db_user,
            settings.db_password, settings.db_name,
        ) = saved


def drop_test_database() -> None:
    if not IDENT_RE.match(TEST_DB_NAME):
        raise ValueError(f"测试库名不合法：{TEST_DB_NAME}")
    conn = _admin_conn()
    try:
        with conn.cursor() as cur:
            cur.execute(f"DROP DATABASE IF EXISTS `{TEST_DB_NAME}`")
    finally:
        conn.close()


@contextmanager
def test_database():
    """测试用数据库：只允许本机测试库。

    线上库现在能被开发机连上，所以"连不上本地库就退回 `.env`"这条老退路等于
    把测试写进真实数据。真要在服务器上自测，显式设 `DB_ALLOW_REMOTE_TEST_DB=1`。
    """
    if is_local_db_available():
        with local_test_db():
            yield
        return
    if os.getenv("DB_ALLOW_REMOTE_TEST_DB") == "1":
        yield
        return
    raise RuntimeError(
        f"本地测试库不可用（{LOCAL_USER}@{LOCAL_HOST}:{LOCAL_PORT}/{TEST_DB_NAME}），"
        "而线上库虽然能连但不许当测试库用。"
        "请先启动本机 MariaDB/MySQL 并执行 scripts/prepare_local_test_db.py。"
    )
