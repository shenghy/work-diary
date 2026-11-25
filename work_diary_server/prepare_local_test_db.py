"""准备本机测试库：建 workdiary_localtest 库 + 测试账号。

线上 MySQL 只允许服务器 IP 连接，开发机直连会被 1130 拒掉，所以服务端测试统一
跑在本机 MariaDB/MySQL 的独立库上。先启动本机数据库服务，再执行：

    .venv\\Scripts\\python.exe prepare_local_test_db.py

需要本机 root 密码时用环境变量传入：
    set DB_LOCAL_TEST_ROOT_PASSWORD=你的root密码
"""
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from tests.local_test_env import (  # noqa: E402
    LOCAL_HOST,
    LOCAL_PASSWORD,
    LOCAL_PORT,
    LOCAL_USER,
    TEST_DB_NAME,
    ensure_test_database,
    is_local_db_available,
)


def main() -> int:
    try:
        ensure_test_database()
    except Exception as exc:
        print(f"建库失败：{exc}")
        print("请确认本机数据库已启动，且 root 账号可用（必要时设置 DB_LOCAL_TEST_ROOT_PASSWORD）")
        return 1
    if not is_local_db_available():
        print("库已建好，但测试账号仍连不上，请检查账号权限")
        return 1
    print(f"本地测试库就绪：{LOCAL_USER}@{LOCAL_HOST}:{LOCAL_PORT}/{TEST_DB_NAME}")
    print(f"（测试密码 {LOCAL_PASSWORD}，仅本机使用）")
    return 0


if __name__ == "__main__":
    sys.exit(main())
