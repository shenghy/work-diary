"""端到端冒烟测试：使用真实 MySQL（远程库），全程使用临时测试账号，结束后自动清理。

运行：.venv/Scripts/python.exe tests/smoke_test.py
"""
import os
import sys
import uuid
from datetime import datetime, timedelta, timezone

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

import pymysql
from fastapi.testclient import TestClient

from app.config import settings
from app.main import app

TEST_EMAIL = f"apitest.{uuid.uuid4().hex[:8]}@example.com"
TEST_PWD = "Test123456"
CODE = "123456"

PASS = 0
FAIL = 0


def check(name: str, cond: bool, extra: str = ""):
    global PASS, FAIL
    if cond:
        PASS += 1
        print(f"  [PASS] {name}")
    else:
        FAIL += 1
        print(f"  [FAIL] {name} {extra}")


def db():
    return pymysql.connect(
        host=settings.db_host, port=settings.db_port, user=settings.db_user,
        password=settings.db_password, database=settings.db_name,
        charset="utf8mb4", cursorclass=pymysql.cursors.DictCursor,
        connect_timeout=10, init_command="SET time_zone = '+00:00'",
        autocommit=False,
    )


def seed_code(conn):
    now = datetime.now(timezone.utc).replace(tzinfo=None)
    with conn.cursor() as cur:
        cur.execute("DELETE FROM email_codes WHERE email=%s", (TEST_EMAIL,))
        cur.execute(
            "INSERT INTO email_codes (email, purpose, code, attempts, expires_at, created_at) "
            "VALUES (%s,'auth',%s,0,%s,%s)",
            (TEST_EMAIL, CODE, now + timedelta(minutes=10), now),
        )
    conn.commit()


def cleanup():
    conn = db()
    try:
        with conn.cursor() as cur:
            cur.execute("DELETE FROM email_codes WHERE email=%s", (TEST_EMAIL,))
            cur.execute("SELECT id FROM users WHERE username=%s", (TEST_EMAIL,))
            row = cur.fetchone()
            if row:
                cur.execute("DELETE FROM users WHERE id=%s", (row["id"],))
        conn.commit()
    finally:
        conn.close()


def iso(dt: datetime) -> str:
    if dt.tzinfo is None:
        dt = dt.replace(tzinfo=timezone.utc)
    return dt.strftime("%Y-%m-%dT%H:%M:%S.%f")[:-3] + "Z"


def main():
    global PASS, FAIL
    from app.database import init_db

    init_db()  # 确保新表已建（email_codes 等）
    cleanup()  # 确保起点干净
    print(f"测试账号: {TEST_EMAIL}")

    with TestClient(app, follow_redirects=False) as client:
        # ---- 基础 ----
        r = client.get("/api/health")
        check("健康检查", r.status_code == 200 and r.json()["status"] == "ok", str(r.text))

        r = client.post("/api/auth/send-code", json={"email": "not-an-email"})
        check("发送验证码-非法邮箱返回400", r.status_code == 400)

        r = client.get("/api/auth/email-status", params={"email": TEST_EMAIL})
        check("邮箱未注册检测", r.status_code == 200 and r.json()["registered"] is False)

        # ---- 注册（先灌一条验证码，避免真实发信）----
        conn = db()
        seed_code(conn)
        conn.close()

        r = client.post("/api/auth/register",
                        json={"email": TEST_EMAIL, "code": "000000", "password": TEST_PWD})
        check("注册-错误验证码被拒", r.status_code == 400)

        conn = db()
        seed_code(conn)
        conn.close()
        r = client.post("/api/auth/register",
                        json={"email": TEST_EMAIL, "code": CODE, "password": TEST_PWD})
        check("注册成功返回token", r.status_code == 200 and "token" in r.json(), str(r.text))
        token = r.json()["token"]
        user_id = r.json()["user"]["id"]

        r = client.post("/api/auth/register",
                        json={"email": TEST_EMAIL, "code": CODE, "password": TEST_PWD})
        check("重复注册返回409", r.status_code == 409)

        # ---- 登录 ----
        r = client.post("/api/auth/login", json={"email": TEST_EMAIL, "password": "wrong"})
        check("登录-错误密码被拒", r.status_code == 401)

        r = client.post("/api/auth/login", json={"email": TEST_EMAIL, "password": TEST_PWD})
        check("登录成功", r.status_code == 200 and r.json()["token"], str(r.text))
        login_token = r.json()["token"]

        r = client.get("/api/auth/email-status", params={"email": TEST_EMAIL})
        check("邮箱已注册检测", r.status_code == 200 and r.json()["registered"] is True)

        auth = {"Authorization": f"Bearer {login_token}"}
        r = client.get("/api/auth/me", headers=auth)
        check("me 返回用户信息",
              r.status_code == 200 and r.json().get("email") == TEST_EMAIL,
              f"status={r.status_code} body={r.text}")

        r = client.get("/api/tasks", headers=auth)
        check("空任务列表", r.status_code == 200 and r.json() == [])

        # ---- 同步 ----
        now = datetime.now(timezone.utc).replace(tzinfo=None)
        tasks = [
            {"id": 1, "remote_id": None, "title": "同步任务A", "status": 0, "urgency": 1,
             "created_at": iso(now), "started_at": None, "completed_at": None, "updated_at": iso(now)},
            {"id": 2, "remote_id": None, "title": "同步任务B", "status": 1, "urgency": 2,
             "created_at": iso(now), "started_at": iso(now), "completed_at": None, "updated_at": iso(now)},
        ]
        r = client.post("/api/tasks/sync", headers=auth, json={"tasks": tasks, "deletions": []})
        body = r.json()
        check("首次同步插入2条", r.status_code == 200 and len(body["tasks"]) == 2, str(r.text))
        remote_a = next(t for t in body["tasks"] if t["id"] == 1)
        remote_b = next(t for t in body["tasks"] if t["id"] == 2)
        check("同步返回 remote_id", remote_a["remote_id"] and remote_b["remote_id"])

        # 本地修改后再次同步（更新的 updated_at）
        later = now + timedelta(minutes=5)
        tasks = [
            {"id": 1, "remote_id": remote_a["remote_id"], "title": "同步任务A-已修改",
             "status": 2, "urgency": 1, "created_at": iso(now),
             "started_at": iso(now), "completed_at": iso(later), "updated_at": iso(later)},
            {"id": 2, "remote_id": remote_b["remote_id"], "title": "同步任务B",
             "status": 1, "urgency": 2, "created_at": iso(now),
             "started_at": iso(now), "completed_at": None, "updated_at": iso(now)},
        ]
        r = client.post("/api/tasks/sync", headers=auth, json={"tasks": tasks, "deletions": []})
        body = r.json()
        updated_a = next(t for t in body["tasks"] if t["remote_id"] == remote_a["remote_id"])
        check("LWW-本地较新则更新云端", updated_a["title"] == "同步任务A-已修改" and updated_a["status"] == 2)

        # 云端较新的任务，本地旧版本不应覆盖
        cloud_newer_updated = iso(later + timedelta(minutes=1))
        tasks = [
            {"id": 1, "remote_id": remote_a["remote_id"], "title": "旧版本不应生效",
             "status": 0, "urgency": 0, "created_at": iso(now),
             "started_at": None, "completed_at": None,
             "updated_at": iso(now - timedelta(minutes=1))},
        ]
        r = client.post("/api/tasks/sync", headers=auth, json={"tasks": tasks, "deletions": []})
        body = r.json()
        kept_a = next(t for t in body["tasks"] if t["remote_id"] == remote_a["remote_id"])
        check("LWW-云端较新则保留云端", kept_a["title"] == "同步任务A-已修改")

        # 删除同步
        r = client.post("/api/tasks/sync", headers=auth, json={
            "tasks": [],
            "deletions": [{"local_id": 2, "remote_id": remote_b["remote_id"],
                           "deleted_at": iso(later)}],
        })
        body = r.json()
        check("删除同步-任务B被软删除", r.status_code == 200 and len(body["tasks"]) == 1)

        # ---- 常规 CRUD ----
        r = client.post("/api/tasks", headers=auth,
                        json={"title": "CRUD任务", "status": 0, "urgency": 0})
        check("创建任务", r.status_code == 201, str(r.text))
        crud_id = r.json()["remote_id"]

        r = client.get("/api/tasks", headers=auth)
        check("任务列表", any(t["remote_id"] == crud_id for t in r.json()))

        r = client.patch(f"/api/tasks/{crud_id}", headers=auth, json={"title": "CRUD已改"})
        check("修改任务", r.status_code == 200 and r.json()["title"] == "CRUD已改")

        r = client.delete(f"/api/tasks/{crud_id}", headers=auth)
        check("删除任务", r.status_code == 200)

        r = client.patch("/api/tasks/999999", headers=auth, json={"title": "x"})
        check("修改不存在的任务返回404", r.status_code == 404)

        r = client.get("/api/tasks")
        check("无 token 访问被拒", r.status_code == 401)

        # ---- 个人数据看板 ----
        r = client.get("/api/stats/me", headers=auth)
        summary = r.json()["summary"] if r.status_code == 200 else {}
        check("看板接口返回完整口径",
              r.status_code == 200
              and {"completed", "completion_rate", "streak_days", "due_total"} <= set(summary),
              str(r.text))
        live = client.get("/api/tasks", headers=auth).json()
        check("看板已完成数 == 任务表 status=2 条数",
              summary.get("completed") == len([t for t in live if t["status"] == 2]),
              f"summary={summary} live={live}")
        check("看板热力图固定 84 格",
              len(r.json()["heatmap"]["days"]) == 84)
        r = client.get("/api/stats/me")
        check("看板无 token 访问被拒", r.status_code == 401)

        # ---- 找回密码 ----
        conn = db()
        seed_code(conn)
        conn.close()
        r = client.post("/api/auth/reset-password",
                        json={"email": TEST_EMAIL, "code": CODE, "password": "NewPass123"})
        check("重置密码成功", r.status_code == 200)
        r = client.post("/api/auth/login", json={"email": TEST_EMAIL, "password": "NewPass123"})
        check("新密码登录成功", r.status_code == 200)
        r = client.post("/api/auth/login", json={"email": TEST_EMAIL, "password": TEST_PWD})
        check("旧密码失效", r.status_code == 401)

        # ---- verify-code ----
        conn = db()
        seed_code(conn)
        conn.close()
        r = client.post("/api/auth/verify-code", json={"email": TEST_EMAIL, "code": CODE})
        check("verify-code 正确", r.status_code == 200 and r.json()["valid"] is True)
        r = client.post("/api/auth/verify-code", json={"email": TEST_EMAIL, "code": "000000"})
        check("verify-code 错误", r.status_code == 200 and r.json()["valid"] is False)

        # ---- 管理后台 ----
        r = client.post("/admin/login", data={"username": "admin", "password": "wrong"})
        check("后台-错误密码被拒", r.status_code == 401)

        r = client.post("/admin/login",
                        data={"username": settings.admin_username,
                              "password": settings.admin_password})
        cookie_val = r.cookies.get("admin_token")
        check("后台登录成功", r.status_code == 303 and cookie_val,
              f"status={r.status_code} cookies={r.cookies}")
        cookie = {"admin_token": cookie_val}

        r = client.get("/admin", cookies=cookie)
        check("后台看板页", r.status_code == 200 and "管理后台" in r.text)

        r = client.get("/admin/api/stats", cookies=cookie)
        stats = r.json()
        check("后台统计-注册总人数", r.status_code == 200 and stats["total_users"] >= 1, str(r.text))
        check("后台统计-趋势14天", len(stats["trend"]) == 14)
        check("后台统计-最近注册含测试账号",
              any(u["email"] == TEST_EMAIL for u in stats["recent_users"]))

        client.cookies.clear()
        r = client.get("/admin/api/stats")
        check("后台统计-未登录被拒", r.status_code == 401)

    print(f"\n结果: PASS {PASS} / FAIL {FAIL} (测试账号 {user_id})")
    cleanup()
    if FAIL:
        sys.exit(1)


if __name__ == "__main__":
    from tests.local_test_env import test_database

    # 本机测试库可用时用它（线上 MySQL 只放行服务器 IP），否则沿用 .env 配置
    with test_database():
        main()
