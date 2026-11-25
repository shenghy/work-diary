"""WebSocket 定向推送验证：真跑一个 uvicorn 服务，验证"按需中转"的推送链路。

覆盖：
1. 带 device_id 建连后，其它设备发起拉取 -> 本机收到 attachment_request；
2. 源机把文件传到服务器 -> 请求方收到 attachment_ready；
3. 请求方下载并 ack -> 服务器删文件；
4. 不带 device_id 的老客户端用 hello 消息补身份，同样能收到推送。

用法（需要本地服务已经起来）：
    set DB_LOCAL_TEST_*=...                       # 可选，默认 127.0.0.1:3399
    .venv\\Scripts\\python.exe tests\\ws_push_test.py --base-url http://127.0.0.1:8011

默认 --base-url 指向本机 8011：线上服务器只允许真实客户端连，测试账号
也不该往生产库灌。不带 --base-url 时脚本会自己拉起一个本机服务。
"""
import argparse
import hashlib
import json
import os
import subprocess
import sys
import threading
import time
import uuid
from datetime import datetime, timedelta, timezone

import httpx
import websockets.sync.client as ws_client

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

from app.config import settings  # noqa: E402
from tests.local_test_env import (  # noqa: E402
    LOCAL_HOST,
    LOCAL_PASSWORD,
    LOCAL_PORT,
    LOCAL_USER,
    TEST_DB_NAME,
    is_local_db_available,
)

PASS = 0
FAIL = 0
SERVER_PORT = 8011


def check(name: str, cond: bool, extra: str = ""):
    global PASS, FAIL
    if cond:
        PASS += 1
        print(f"  [PASS] {name}")
    else:
        FAIL += 1
        print(f"  [FAIL] {name} {extra}")


def start_local_server() -> subprocess.Popen:
    """自己拉起一个连本地测试库的服务，避免测试要手工开窗口。"""
    env = dict(os.environ)
    env.update(
        DB_HOST=LOCAL_HOST,
        DB_PORT=str(LOCAL_PORT),
        DB_USER=LOCAL_USER,
        DB_PASSWORD=LOCAL_PASSWORD,
        DB_NAME=TEST_DB_NAME,
        PYTHONIOENCODING="utf-8",
    )
    root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    proc = subprocess.Popen(
        [sys.executable, "-m", "uvicorn", "app.main:app",
         "--host", "127.0.0.1", "--port", str(SERVER_PORT)],
        cwd=root, env=env, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
    )
    deadline = time.time() + 40
    while time.time() < deadline:
        try:
            if httpx.get(f"http://127.0.0.1:{SERVER_PORT}/api/health", timeout=2, trust_env=False).is_success:
                return proc
        except Exception:
            pass
        if proc.poll() is not None:
            print(proc.stdout.read().decode("utf-8", "replace"))
            raise SystemExit("本地服务启动失败")
        time.sleep(0.5)
    raise SystemExit("本地服务启动超时")


def register(client: httpx.Client, base: str, email: str) -> str:
    """用验证码直灌的方式注册测试账号（不依赖真实发信）。"""
    import pymysql

    now = datetime.now(timezone.utc).replace(tzinfo=None)
    conn = pymysql.connect(
        host=LOCAL_HOST, port=LOCAL_PORT, user=LOCAL_USER, password=LOCAL_PASSWORD,
        database=TEST_DB_NAME, charset="utf8mb4", cursorclass=pymysql.cursors.DictCursor,
        autocommit=True, connect_timeout=8,
    )
    with conn.cursor() as cur:
        cur.execute("DELETE FROM email_codes WHERE email=%s", (email,))
        cur.execute(
            "INSERT INTO email_codes (email, purpose, code, attempts, expires_at, created_at) "
            "VALUES (%s,'auth',%s,0,%s,%s)",
            (email, "123456", now + timedelta(minutes=10), now),
        )
    conn.close()
    r = client.post(f"{base}/api/auth/register",
                      json={"email": email, "code": "123456", "password": "Test123456"},
                      timeout=15)
    r.raise_for_status()
    return r.json()["token"]


def recv_until(sock, predicate, timeout=15.0):
    """在超时前不断收消息，直到命中 predicate；返回命中的消息。"""
    deadline = time.time() + timeout
    while time.time() < deadline:
        try:
            raw = sock.recv(timeout=max(0.2, deadline - time.time()))
        except TimeoutError:
            break
        try:
            msg = json.loads(raw)
        except ValueError:
            continue
        if predicate(msg):
            return msg
    return None


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--base-url", default="")
    args = parser.parse_args()

    proc = None
    if args.base_url:
        base = args.base_url.rstrip("/")
    else:
        if not is_local_db_available():
            print("本地测试库不可用：先跑 prepare_local_test_db.py，或用 --base-url 指定服务")
            return 1
        base = f"http://127.0.0.1:{SERVER_PORT}"
        proc = start_local_server()
        print(f"已启动本地服务：{base}")

    try:
        tag = uuid.uuid4().hex[:8]
        # trust_env=False：本机 NO_PROXY 里有 [::1]/127.0.0.0/8，httpx 会把它当 URL 解析报错
        client = httpx.Client(trust_env=False, timeout=25)
        # 同一账号、两台设备：附件中转是"自己的设备之间"搬运，不存在跨账号
        email_a = f"wsA.{tag}@example.com"
        token_a = register(client, base, email_a)
        auth = {"Authorization": f"Bearer {token_a}", "Content-Type": "application/json"}

        auth = {"Authorization": f"Bearer {token_a}", "Content-Type": "application/json"}
        now = datetime.now(timezone.utc)
        parent = client.post(f"{base}/api/tasks/sync", headers=auth, json={
            "tasks": [{"id": 1, "title": "推送用例", "status": 0, "urgency": 0,
                       "created_at": now.isoformat(), "updated_at": now.isoformat()}],
            "deletions": [],
        }, timeout=15).json()["tasks"][0]["remote_id"]

        blob = ("推送内容-" * 120).encode("utf-8")
        digest = hashlib.sha256(blob).hexdigest()
        uid = str(uuid.uuid4())
        meta = {
            "uid": uid, "parent_kind": "task", "parent_remote_id": parent,
            "owner_device_id": f"devA-{tag}", "owner_device_name": "A 主机",
            "file_name": "推送说明.txt", "file_size": len(blob), "sha256": digest,
            "mime": "text/plain", "is_screenshot": False, "orphaned": False,
            "created_at": now.isoformat(), "updated_at": now.isoformat(),
        }
        r = client.post(f"{base}/api/attachments/sync", headers=auth,
                          json={"attachments": [meta], "deletions": []}, timeout=15)
        check("附件元数据入库", uid not in r.json()["rejected_uids"], r.text)

        ws_url = base.replace("http://", "ws://")

        # A 是源主机（本机有文件），B 是请求方
        with ws_client.connect(f"{ws_url}/ws?token={token_a}&client_id=ca&"
                               f"device_id=devA-{tag}&device_name=A%20主机") as sock_a, \
                ws_client.connect(f"{ws_url}/ws?token={token_a}&client_id=cb&"
                                  f"device_id=devB-{tag}&device_name=B%20主机") as sock_b:
            r = client.post(f"{base}/api/attachments/{uid}/request",
                              headers={"Authorization": f"Bearer {token_a}",
                                       "Content-Type": "application/json",
                                       "X-Client-Id": "cb"},
                              json={"device_id": f"devB-{tag}", "device_name": "B 主机"},
                              timeout=15)
            check("请求方收到 requested", r.json()["state"] == "requested", r.text)
            hit = recv_until(sock_a, lambda m: m.get("type") == "attachment_request")
            check("源主机收到 attachment_request", hit is not None, "")
            check("推送里带上请求方设备",
                  hit is not None and hit.get("requester_device_id") == f"devB-{tag}", str(hit))
            check("推送不会发给请求方自己",
                  recv_until(sock_b, lambda m: m.get("type") == "attachment_request", 1.0) is None)

            # 源主机分片上传
            init = client.post(f"{base}/api/attachments/{uid}/upload/init",
                                 headers={"Authorization": f"Bearer {token_a}",
                                          "Content-Type": "application/json"},
                                 json={"device_id": f"devA-{tag}", "device_name": "A 主机"},
                                 timeout=15).json()
            check("上传初始化给了偏移与分片大小",
                  init["state"] == "upload" and init["chunk_size"] > 0, str(init))
            offset = init["next_offset"]
            chunk = max(1024, init["chunk_size"])
            while offset < len(blob):
                piece = blob[offset:offset + chunk]
                rr = client.put(f"{base}/api/attachments/{uid}/upload?offset={offset}",
                                  headers={"Authorization": f"Bearer {token_a}"},
                                  data=piece, timeout=20)
                offset = rr.json()["next_offset"]
            rr = client.post(f"{base}/api/attachments/{uid}/upload/complete",
                               headers={"Authorization": f"Bearer {token_a}",
                                        "Content-Type": "application/json"},
                               json={"device_id": f"devA-{tag}", "device_name": "A 主机"},
                               timeout=20)
            check("上传完成", rr.status_code == 200 and rr.json()["state"] == "ready", rr.text)

            hit = recv_until(sock_b, lambda m: m.get("type") == "attachment_ready")
            check("请求方收到 attachment_ready", hit is not None and hit.get("uid") == uid, str(hit))

            dl = client.get(f"{base}/api/attachments/{uid}/blob",
                              headers={"Authorization": f"Bearer {token_a}"},
                              params={"device_id": f"devB-{tag}"}, timeout=30)
            check("请求方下载内容一致", dl.status_code == 200 and dl.content == blob, str(dl.status_code))
            ack = client.post(f"{base}/api/attachments/{uid}/ack",
                                 headers={"Authorization": f"Bearer {token_a}",
                                          "Content-Type": "application/json"},
                                 json={"device_id": f"devB-{tag}", "device_name": "B 主机"},
                                 timeout=15)
            check("确认后服务器删文件", ack.json()["blob_deleted"] is True, ack.text)
            hit = recv_until(sock_a, lambda m: m.get("type") == "attachment_taken")
            check("源主机收到 attachment_taken", hit is not None, "")

        # ---- 老客户端：连接不带 device_id，用 hello 补身份后应收到补发 ----
        token_c = register(client, base, email_c := f"wsC.{tag}@example.com")
        hdr_c = {"Authorization": f"Bearer {token_c}", "Content-Type": "application/json",
                 "X-Client-Id": "cc"}
        parent_c = client.post(f"{base}/api/tasks/sync", headers=hdr_c, json={
            "tasks": [{"id": 1, "title": "补引用例", "status": 0, "urgency": 0,
                       "created_at": now.isoformat(), "updated_at": now.isoformat()}],
            "deletions": [],
        }, timeout=15).json()["tasks"][0]["remote_id"]
        uid2 = str(uuid.uuid4())
        meta2 = dict(meta, uid=uid2, parent_remote_id=parent_c, file_size=12,
                     sha256=hashlib.sha256(b"0123456789ab").hexdigest())
        client.post(f"{base}/api/attachments/sync", headers=hdr_c,
                      json={"attachments": [meta2], "deletions": []}, timeout=15)
        # D 先登记一个拉取请求（此时没有任何在线设备）
        client.post(f"{base}/api/attachments/{uid2}/request", headers=hdr_c,
                      json={"device_id": "devD", "device_name": "D 手机"}, timeout=15)
        with ws_client.connect(f"{ws_url}/ws?token={token_c}&client_id=c2") as sock_c:
            sock_c.send(json.dumps({"type": "hello", "device_id": "devC", "device_name": "C 主机"}))
            hit = recv_until(sock_c, lambda m: m.get("type") == "attachment_request")
            check("hello 补身份后收到待处理中转",
                  hit is not None and hit.get("uid") == uid2
                  and hit.get("requester_device_id") == "devD", str(hit))

        # 清理测试账号（CASCADE 清掉任务与附件记录）
        import pymysql
        conn = pymysql.connect(
            host=LOCAL_HOST, port=LOCAL_PORT, user=LOCAL_USER, password=LOCAL_PASSWORD,
            database=TEST_DB_NAME, charset="utf8mb4", cursorclass=pymysql.cursors.DictCursor,
            autocommit=True, connect_timeout=8,
        )
        with conn.cursor() as cur:
            for mail in (email_a, email_c):
                cur.execute("DELETE FROM email_codes WHERE email=%s", (mail,))
                cur.execute("DELETE FROM users WHERE username=%s", (mail,))
        conn.close()
    finally:
        if proc is not None:
            proc.terminate()
            try:
                proc.wait(10)
            except Exception:
                proc.kill()

    print(f"\n通过 {PASS}，失败 {FAIL}")
    return 1 if FAIL else 0


if __name__ == "__main__":
    sys.exit(main())
