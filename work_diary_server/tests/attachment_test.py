"""附件中转端到端测试：真实 MySQL（远程库）+ 临时账号 + 临时中转目录，结束后全部清理。

覆盖：类型/体积/数量限制、LWW 与删除墓碑、分片续传与偏移纠正、SHA-256 校验、
下载鉴权、全部确认后删文件、TTL 与配额清理、上线补发。

运行：.venv/Scripts/python.exe tests/attachment_test.py
"""
import asyncio
import hashlib
import os
import shutil
import sys
import uuid
import tempfile
from pathlib import Path
from datetime import datetime, timedelta, timezone

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

import pymysql
from fastapi.testclient import TestClient

from app.config import settings
from app.main import app
from app.routers import attachments as att
from app.ws_manager import Conn

TEST_EMAIL = f"apitest.{uuid.uuid4().hex[:8]}@example.com"
TEST_PWD = "Test123456"
CODE = "123456"
DEVICE_A = "device-A-" + uuid.uuid4().hex[:8]
DEVICE_B = "device-B-" + uuid.uuid4().hex[:8]
DEVICE_C = "device-C-" + uuid.uuid4().hex[:8]

PASS = 0
FAIL = 0
TMP_DIR = None


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
    try:
        with conn.cursor() as cur:
            cur.execute("DELETE FROM email_codes WHERE email=%s", (TEST_EMAIL,))
            cur.execute(
                "INSERT INTO email_codes (email, purpose, code, attempts, expires_at, created_at) "
                "VALUES (%s,'auth',%s,0,%s,%s)",
                (TEST_EMAIL, CODE, now + timedelta(minutes=10), now),
            )
        conn.commit()
    finally:
        conn.close()


def cleanup(user_id=None):
    conn = db()
    try:
        with conn.cursor() as cur:
            cur.execute("DELETE FROM email_codes WHERE email=%s", (TEST_EMAIL,))
            cur.execute("SELECT id FROM users WHERE username=%s", (TEST_EMAIL,))
            row = cur.fetchone()
            if row:
                # attachments / attachment_transfers 有 ON DELETE CASCADE，删用户即删记录
                cur.execute("DELETE FROM users WHERE id=%s", (row["id"],))
        conn.commit()
    finally:
        conn.close()
    if user_id and TMP_DIR:
        shutil.rmtree(Path(TMP_DIR) / str(user_id), ignore_errors=True)


def iso(dt: datetime) -> str:
    if dt.tzinfo is None:
        dt = dt.replace(tzinfo=timezone.utc)
    return dt.strftime("%Y-%m-%dT%H:%M:%S.%f")[:-3] + "Z"


class FakeSocket:
    """只记录收到的消息，用来验证定向推送逻辑（不跑真 WebSocket，避免跨事件循环）。"""

    def __init__(self):
        self.messages = []

    async def send_json(self, payload):
        self.messages.append(payload)


def make_conn(device_id: str) -> Conn:
    conn = Conn(ws=FakeSocket(), device_id=device_id, device_name=device_id)
    return conn


def att_payload(uid: str, parent_id: int, now: datetime, name: str = "说明.txt",
                size: int = 1024, sha: str = "a" * 64, device: str = DEVICE_A):
    return {
        "uid": uid,
        "parent_kind": "task",
        "parent_remote_id": parent_id,
        "owner_device_id": device,
        "owner_device_name": "测试主机",
        "file_name": name,
        "file_size": size,
        "sha256": sha,
        "mime": "text/plain",
        "is_screenshot": False,
        "orphaned": False,
        "created_at": iso(now),
        "updated_at": iso(now),
    }


def upload_all(client, auth, uid: str, blob: bytes, chunk: int = 700):
    """按 upload/init 的偏移分片上传（模拟源主机的行为）。"""
    init = client.post(f"/api/attachments/{uid}/upload/init", headers=auth,
                       json={"device_id": DEVICE_A, "device_name": "测试主机"}).json()
    offset = init["next_offset"]
    while offset < len(blob):
        piece = blob[offset:offset + chunk]
        r = client.put(f"/api/attachments/{uid}/upload", headers=auth,
                       params={"offset": offset}, content=piece)
        body = r.json()
        if r.status_code == 200 and body.get("state") == "resume":
            offset = body["next_offset"]
            continue
        assert r.status_code == 200, (r.status_code, r.text)
        offset = body["next_offset"]
    return client.post(f"/api/attachments/{uid}/upload/complete", headers=auth,
                       json={"device_id": DEVICE_A, "device_name": "测试主机"})


def put_blob(user_id: int, uid: str, data: bytes):
    """直接往中转目录写文件（模拟服务器已有的副本），目录可能被清理任务删空。"""
    path = att._blob_path(user_id, uid)
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(data)
    return path


def main():
    global PASS, FAIL, TMP_DIR
    from app.database import init_db

    init_db()
    cleanup()
    print(f"测试账号: {TEST_EMAIL}")
    print(f"测试数据库: {settings.db_user}@{settings.db_host}:{settings.db_port}/{settings.db_name}")

    # 中转目录指向临时路径：绝不能把测试文件写进真实 storage
    TMP_DIR = tempfile.mkdtemp(prefix="wd_att_test_")
    settings.attachment_tmp_dir = TMP_DIR
    settings.attachment_chunk_mb = 1
    settings.attachment_quota_mb = 2048

    now = datetime.now(timezone.utc).replace(tzinfo=None)

    with TestClient(app, follow_redirects=False) as client:
        seed_code(db())
        r = client.post("/api/auth/register",
                        json={"email": TEST_EMAIL, "code": CODE, "password": TEST_PWD})
        check("注册成功", r.status_code == 200 and r.json().get("token"), str(r.text))
        auth = {"Authorization": f"Bearer {r.json()['token']}"}
        user_id = r.json()["user"]["id"]

        # ---- 先建一个任务，附件必须有真实父记录 ----
        r = client.post("/api/tasks/sync", headers=auth, json={
            "tasks": [{"id": 1, "remote_id": None, "title": "带附件的任务", "status": 0,
                       "urgency": 0, "created_at": iso(now), "updated_at": iso(now)}],
            "deletions": [],
        })
        check("任务同步成功", r.status_code == 200, str(r.text))
        parent_id = r.json()["tasks"][0]["remote_id"]
        # 第二个任务：附件有"每父最多 5 个"上限，超出上限的用例需要另一个父记录
        r = client.post("/api/tasks/sync", headers=auth, json={
            "tasks": [
                {"id": 1, "remote_id": parent_id, "title": "带附件的任务", "status": 0,
                 "urgency": 0, "created_at": iso(now), "updated_at": iso(now)},
                {"id": 2, "remote_id": None, "title": "第二个带附件的任务", "status": 0,
                 "urgency": 0, "created_at": iso(now), "updated_at": iso(now)},
            ],
            "deletions": [],
        })
        parent2 = r.json()["tasks"][1]["remote_id"]

        # ---- 类型/大小/父记录限制 ----
        exe_uid, big_uid, orphan_uid, ok_uid = (str(uuid.uuid4()) for _ in range(4))
        payloads = [
            att_payload(ok_uid, parent_id, now),
            att_payload(exe_uid, parent_id, now, name="工具.exe"),
            att_payload(big_uid, parent_id, now, name="超大.pdf",
                        size=settings.attachment_max_mb * 1024 * 1024 + 1),
            att_payload(orphan_uid, parent_id + 99999, now, name="悬空.png"),
        ]
        r = client.post("/api/attachments/sync", headers=auth,
                        json={"attachments": payloads, "deletions": []})
        check("附件元数据同步返回200", r.status_code == 200, str(r.text))
        body = r.json()
        rejected = set(body["rejected_uids"])
        check("可执行文件被拒", exe_uid in rejected, str(rejected))
        check("超过 100MB 被拒", big_uid in rejected, str(rejected))
        check("父记录不存在被拒", orphan_uid in rejected, str(rejected))
        check("合法附件入库", ok_uid not in rejected and
              any(a["uid"] == ok_uid for a in body["attachments"]), str(body))
        check("入库默认无中转副本",
              all(a["blob_state"] == "none" for a in body["attachments"]), str(body))

        # 视频/压缩包同样不允许
        for label, name in (("视频", "短片.mp4"), ("压缩包", "资料.zip"), ("未知类型", "数据.xyz")):
            u = str(uuid.uuid4())
            rr = client.post("/api/attachments/sync", headers=auth, json={
                "attachments": [att_payload(u, parent_id, now, name=name)], "deletions": []})
            check(f"{label}被拒", u in set(rr.json()["rejected_uids"]), str(rr.text))

        # ---- 每父最多 5 个 ----
        uids = [ok_uid]
        for i in range(6):
            u = str(uuid.uuid4())
            uids.append(u)
            rr = client.post("/api/attachments/sync", headers=auth, json={
                "attachments": [att_payload(u, parent_id, now, name=f"文件{i}.txt")],
                "deletions": []})
            if u not in rr.json()["rejected_uids"]:
                pass
        rr = client.post("/api/attachments/sync", headers=auth, json={"attachments": [], "deletions": []})
        live = [a for a in rr.json()["attachments"] if a["parent_remote_id"] == parent_id]
        check("单任务附件上限 5 个", len(live) == settings.attachment_max_per_parent,
              f"实际 {len(live)}")

        # ---- 非法 uid ----
        rr = client.post(f"/api/attachments/{'..%2F..%2Fetc'}/request", headers=auth,
                         json={"device_id": DEVICE_B, "device_name": "手机"})
        check("路径穿越式 uid 被拒", rr.status_code in (400, 404), f"{rr.status_code} {rr.text}")
        rr = client.post(f"/api/attachments/{str(uuid.uuid4())}/request", headers=auth,
                         json={"device_id": DEVICE_B, "device_name": "手机"})
        check("不存在附件返回404", rr.status_code == 404, str(rr.text))

        # ---- 无人应答时的等待语义 ----
        rr = client.post(f"/api/attachments/{ok_uid}/request", headers=auth,
                         json={"device_id": DEVICE_B, "device_name": "公司笔记本"})
        check("源机离线返回 waiting",
              rr.status_code == 200 and rr.json()["state"] == "waiting" and rr.json()["sources"] == 0,
              str(rr.text))
        check("等待时给出可读提示", "在线" in rr.json()["message"], str(rr.text))

        # 模拟有源机在线（不打真 WebSocket，直接替换推送返回值）
        real_send = att.ws_manager.send_to_user

        async def fake_send(user_id_, payload, exclude_client_id=None, only_device_id=None):
            fake_send.last = payload
            return 1

        att.ws_manager.send_to_user = fake_send
        rr = client.post(f"/api/attachments/{ok_uid}/request", headers=auth,
                         json={"device_id": DEVICE_B, "device_name": "公司笔记本"})
        check("有源机在线返回 requested",
              rr.status_code == 200 and rr.json()["state"] == "requested", str(rr.text))
        check("推送内容带请求方设备", fake_send.last.get("requester_device_id") == DEVICE_B,
              str(fake_send.last))
        # 后面的用例都按"没有其它设备在线"的真实语义跑
        att.ws_manager.send_to_user = real_send

        # ---- 分片上传 ----
        blob = ("附件内容-" * 200).encode("utf-8")
        digest = hashlib.sha256(blob).hexdigest()
        # 先把元数据的 sha256 换成真实值
        meta = att_payload(ok_uid, parent_id, now, size=len(blob), sha=digest)
        meta["updated_at"] = iso(now + timedelta(seconds=5))
        rr = client.post("/api/attachments/sync", headers=auth,
                         json={"attachments": [meta], "deletions": []})
        check("元数据 LWW 更新", rr.status_code == 200, str(rr.text))

        init = client.post(f"/api/attachments/{ok_uid}/upload/init", headers=auth,
                           json={"device_id": DEVICE_A, "device_name": "测试主机"})
        check("初始化上传返回 upload",
              init.json()["state"] == "upload" and init.json()["next_offset"] == 0, str(init.text))
        check("分片大小来自配置",
              init.json()["chunk_size"] == settings.attachment_chunk_mb * 1024 * 1024, str(init.text))

        # 偏移不对：服务器纠正为真实已收字节数
        rr = client.put(f"/api/attachments/{ok_uid}/upload", headers=auth,
                        params={"offset": 500}, content=b"x" * 10)
        check("偏移错误返回 resume",
              rr.status_code == 200 and rr.json()["state"] == "resume" and rr.json()["next_offset"] == 0,
              str(rr.text))

        # 传一半就断，再 init 应给出续传偏移
        client.put(f"/api/attachments/{ok_uid}/upload", headers=auth,
                   params={"offset": 0}, content=blob[:1000])
        part = att._part_path(user_id, ok_uid)
        check("半途中断留下分片", part.exists() and part.stat().st_size == 1000,
              "" if part.exists() else "no part")
        init = client.post(f"/api/attachments/{ok_uid}/upload/init", headers=auth,
                           json={"device_id": DEVICE_A, "device_name": "测试主机"})
        check("断点续传偏移正确", init.json()["next_offset"] == 1000, str(init.text))

        # 未完成就 complete -> 拒绝
        rr = client.post(f"/api/attachments/{ok_uid}/upload/complete", headers=auth,
                         json={"device_id": DEVICE_A, "device_name": "测试主机"})
        check("未传完不能完成", rr.status_code == 422, str(rr.text))

        # 传完但内容不符 -> 校验失败（改动落在续传写入的那一段，确保真的进了分片）
        wrong = bytearray(blob)
        wrong[1500] ^= 0xFF
        client.put(f"/api/attachments/{ok_uid}/upload", headers=auth,
                   params={"offset": 1000}, content=bytes(wrong[1000:]))
        rr = upload_all(client, auth, ok_uid, bytes(wrong))
        check("SHA-256 不符拒绝", rr.status_code == 422 and "校验" in rr.json()["detail"], str(rr.text))
        check("校验失败丢弃分片", not part.exists())

        # 正确上传
        rr = upload_all(client, auth, ok_uid, blob)
        check("上传完成", rr.status_code == 200 and rr.json()["state"] == "ready", str(rr.text))
        blob_path = att._blob_path(user_id, ok_uid)
        check("中转文件落盘", blob_path.exists() and blob_path.stat().st_size == len(blob))
        st = client.get(f"/api/attachments/{ok_uid}/state", headers=auth).json()
        check("状态 ready", st["blob_state"] == "ready", str(st))
        check("状态里带请求方", any(t["device_id"] == DEVICE_B for t in st["transfers"]), str(st))

        # 重复 init 直接告知已就绪，源机不必再传
        init = client.post(f"/api/attachments/{ok_uid}/upload/init", headers=auth,
                           json={"device_id": DEVICE_A, "device_name": "测试主机"})
        check("已就绪时不再要求上传", init.json()["state"] == "ready", str(init.text))

        # ---- 下载鉴权 ----
        rr = client.get(f"/api/attachments/{ok_uid}/blob", headers=auth,
                        params={"device_id": DEVICE_C})
        check("未请求过的设备不能下载", rr.status_code == 403, str(rr.text))

        rr = client.get(f"/api/attachments/{ok_uid}/blob", headers=auth,
                        params={"device_id": DEVICE_B})
        check("请求方下载到内容",
              rr.status_code == 200 and rr.content == blob, str(rr.status_code))
        check("下载头带哈希", rr.headers.get("x-attachment-sha256") == digest, str(rr.headers))

        # ---- 全部确认后服务器立刻删文件 ----
        rr = client.post(f"/api/attachments/{ok_uid}/ack", headers=auth,
                         json={"device_id": DEVICE_B, "device_name": "公司笔记本"})
        check("确认后删除中转文件",
              rr.status_code == 200 and rr.json()["blob_deleted"] is True and not blob_path.exists(),
              str(rr.text))
        st = client.get(f"/api/attachments/{ok_uid}/state", headers=auth).json()
        check("状态转为 taken", st["blob_state"] == "taken", str(st))
        rr = client.get(f"/api/attachments/{ok_uid}/blob", headers=auth,
                        params={"device_id": DEVICE_B})
        check("取走后不再可下载", rr.status_code == 410, str(rr.text))

        # ---- 第二个请求方：源机离线 -> 等待，上线后补发 ----
        rr = client.post(f"/api/attachments/{ok_uid}/request", headers=auth,
                         json={"device_id": DEVICE_C, "device_name": "手机"})
        check("已取走的附件重新请求返回 waiting",
              rr.status_code == 200 and rr.json()["state"] in ("waiting", "done"), str(rr.text))
        pending = asyncio.run(att.push_pending_transfers(user_id, make_conn(DEVICE_A)))
        check("源机上线补发上传请求", pending >= 1, str(pending))

        # ---- 上传中途改文件：分片超过声明大小要拒绝 ----
        # 用第二个任务当父记录：原任务已经挂满 5 个附件，再挂会被数量上限拒掉
        u2 = str(uuid.uuid4())
        small = b"S" * 30
        meta2 = att_payload(u2, parent2, now, size=len(small),
                            sha=hashlib.sha256(small).hexdigest())
        rr = client.post("/api/attachments/sync", headers=auth,
                         json={"attachments": [meta2], "deletions": []})
        check("新任务的附件入库", u2 not in rr.json()["rejected_uids"], str(rr.text))
        rr = client.put(f"/api/attachments/{u2}/upload", headers=auth,
                        params={"offset": 0}, content=b"x" * (len(small) + 10))
        check("超出声明大小拒绝", rr.status_code == 413, str(rr.text))

        # ---- 源机改了原件：新哈希报上来，服务器上那份旧中转副本必须作废 ----
        # 否则目标端拿到的是旧内容，客户端按新 sha256 校验只会报"文件校验失败"
        rr = client.post(f"/api/attachments/{u2}/request", headers=auth,
                         json={"device_id": DEVICE_B, "device_name": "公司笔记本"})
        check("换版前请求登记成功", rr.status_code == 200, str(rr.text))
        put_blob(user_id, u2, b"old-version-on-server")
        with db() as conn:
            with conn.cursor() as cur:
                cur.execute("UPDATE attachments SET blob_state='ready' "
                            "WHERE uid=%s AND user_id=%s", (u2, user_id))
                cur.execute("UPDATE attachment_transfers SET status='downloaded' "
                            "WHERE attachment_uid=%s AND user_id=%s", (u2, user_id))
            conn.commit()
        newer = b"R" * 40
        meta3 = att_payload(u2, parent2, now + timedelta(minutes=5), size=len(newer),
                            sha=hashlib.sha256(newer).hexdigest())
        rr = client.post("/api/attachments/sync", headers=auth,
                         json={"attachments": [meta3], "deletions": []})
        row3 = next((a for a in rr.json()["attachments"] if a["uid"] == u2), {})
        check("换版后云端哈希已更新",
              row3.get("sha256") == hashlib.sha256(newer).hexdigest(), str(row3))
        check("换版后旧中转副本作废",
              row3.get("blob_state") == "none" and not att._blob_path(user_id, u2).exists(),
              str(row3))
        st = client.get(f"/api/attachments/{u2}/state", headers=auth).json()
        check("换版后请求方重新排队",
              any(t["device_id"] == DEVICE_B and t["status"] == "pending"
                  for t in st["transfers"]), str(st))
        # 内容没变的一次上报（只是改名）不该把副本打掉
        put_blob(user_id, u2, b"new-version-on-server")
        with db() as conn:
            with conn.cursor() as cur:
                cur.execute("UPDATE attachments SET blob_state='ready' "
                            "WHERE uid=%s AND user_id=%s", (u2, user_id))
            conn.commit()
        meta4 = {**meta3, "file_name": "改名了.txt",
                 "updated_at": iso(now + timedelta(minutes=8))}
        rr = client.post("/api/attachments/sync", headers=auth,
                         json={"attachments": [meta4], "deletions": []})
        row4 = next((a for a in rr.json()["attachments"] if a["uid"] == u2), {})
        check("仅改名不动中转副本",
              row4.get("file_name") == "改名了.txt"
              and att._blob_path(user_id, u2).exists(), str(row4))

        # ---- TTL 过期清理 ----
        blob_path.unlink(missing_ok=True)
        with db() as conn:
            with conn.cursor() as cur:
                # 只把状态改成 ready 不算过期：过期判定看 blob_expires_at（或文件落盘时间），
                # 上一段刚写入的新文件还没到期，清理任务本就不该动它。
                cur.execute("UPDATE attachments SET blob_state='ready', blob_expires_at=%s "
                            "WHERE uid=%s AND user_id=%s",
                            (now - timedelta(minutes=5), u2, user_id))
                cur.execute("UPDATE attachment_transfers SET expires_at=%s "
                            "WHERE attachment_uid=%s AND user_id=%s",
                            (now - timedelta(minutes=5), u2, user_id))
            conn.commit()
        stale_part = att._part_path(user_id, u2)
        stale_part.parent.mkdir(parents=True, exist_ok=True)
        stale_part.write_bytes(b"halfway")
        os.utime(stale_part, (now.timestamp() - 90000, now.timestamp() - 90000))
        removed = att.purge_expired_blobs()
        check("过期分片被清理", removed >= 1 and not stale_part.exists(), str(removed))
        st = client.get(f"/api/attachments/{u2}/state", headers=auth).json()
        check("过期后状态复位", st["blob_state"] == "none", str(st))
        check("过期同时删掉中转文件", not att._blob_path(user_id, u2).exists())

        # ---- 配额清理 ----
        settings.attachment_quota_mb = 0
        put_blob(user_id, ok_uid, blob)
        with db() as conn:
            with conn.cursor() as cur:
                cur.execute("UPDATE attachments SET blob_state='ready', blob_expires_at=%s "
                            "WHERE uid=%s AND user_id=%s",
                            (now + timedelta(hours=1), ok_uid, user_id))
            conn.commit()
        dropped = att.enforce_storage_quota()
        check("超配额丢最老的中转文件", dropped >= 1 and not blob_path.exists(), str(dropped))
        settings.attachment_quota_mb = 2048

        # ---- 删除墓碑连带清文件 ----
        put_blob(user_id, ok_uid, blob)
        with db() as conn:
            with conn.cursor() as cur:
                cur.execute("UPDATE attachments SET blob_state='ready' WHERE uid=%s AND user_id=%s",
                            (ok_uid, user_id))
            conn.commit()
        rr = client.post("/api/attachments/sync", headers=auth, json={
            "attachments": [],
            "deletions": [{"uid": ok_uid, "deleted_at": iso(now + timedelta(minutes=3))}],
        })
        check("删除墓碑生效", ok_uid in rr.json()["deleted_uids"], str(rr.text))
        check("删除后不再下发", all(a["uid"] != ok_uid for a in rr.json()["attachments"]), str(rr.text))
        check("删除附件同时清掉中转文件", not blob_path.exists())

        # ---- 鉴权 ----
        rr = client.get(f"/api/attachments/{ok_uid}/state")
        check("未登录访问附件接口 401", rr.status_code == 401, str(rr.text))

        att.ws_manager.send_to_user = real_send

    cleanup(user_id)
    shutil.rmtree(TMP_DIR, ignore_errors=True)
    print(f"\n通过 {PASS}，失败 {FAIL}")
    sys.exit(1 if FAIL else 0)


if __name__ == "__main__":
    from tests.local_test_env import test_database

    with test_database():
        main()
