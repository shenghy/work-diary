"""附件：元数据同步 + 按需中转。

设计要点（与客户端约定一致）：
1. 文件原件只存在各终端本机；服务器上的文件是一次性中转，全部请求方确认下载后
   立刻删除，最长保留 TTL（默认 24h）兜底。
2. 拉取由目标端发起（/request），服务器把 attachment_request 推给该用户的其它设备，
   谁本机有这份文件谁来上传——所以"源主机"不唯一，任何持有者都能应答。
3. 上传走分片（PUT ?offset=N），可断点续传、可跨微信单次请求体积限制；
   完成时服务端按元数据里的 SHA-256 校验，不符直接丢弃。
4. 中转目录在 Web 根之外，任何接口都不会静态暴露它，只有鉴权后的 /blob 能读。
"""
import hashlib
import re
import time
from datetime import timedelta
from pathlib import Path

from fastapi import APIRouter, Depends, Header, HTTPException, Request
from fastapi.concurrency import run_in_threadpool
from fastapi.responses import FileResponse

from ..attachment_types import classify, looks_executable
from ..config import settings
from ..database import get_conn, transaction
from ..models import (
    AttachmentAckOut,
    AttachmentDeviceIn,
    AttachmentIn,
    AttachmentOut,
    AttachmentRequestOut,
    AttachmentStateOut,
    AttachmentSyncRequest,
    AttachmentSyncResponse,
    AttachmentUploadInitOut,
)
from ..utils import to_utc_naive, utc_iso, utc_now
from ..ws_manager import Conn, ws_manager
from .deps import get_current_user

router = APIRouter(prefix="/api/attachments", tags=["attachments"])

UID_RE = re.compile(r"^[0-9a-fA-F-]{8,64}$")

# 每个用户每分钟允许的"发起拉取/初始化上传"次数：按需中转会让源机上传
# 100MB 级文件，被脚本刷的话源机和服务器带宽都会被打满。
_RATE_WINDOW_SECONDS = 60
_RATE_MAX_PER_WINDOW = 60
_rate_hits: dict[int, list[float]] = {}


def _rate_limit(user_id: int) -> None:
    now = time.monotonic()
    hits = [t for t in _rate_hits.get(user_id, []) if now - t < _RATE_WINDOW_SECONDS]
    if len(hits) >= _RATE_MAX_PER_WINDOW:
        raise HTTPException(status_code=429, detail="同步请求过于频繁，请稍后再试")
    hits.append(now)
    _rate_hits[user_id] = hits


# ---------------- 中转文件路径 ----------------
def _user_dir(user_id: int) -> Path:
    path = settings.attachment_tmp_path / str(int(user_id))
    path.mkdir(parents=True, exist_ok=True)
    return path


def _blob_path(user_id: int, uid: str) -> Path:
    return _user_dir(user_id) / f"{uid}.bin"


def _part_path(user_id: int, uid: str) -> Path:
    return _user_dir(user_id) / f"{uid}.part"


def _tmp_dir_bytes() -> int:
    root = settings.attachment_tmp_path
    if not root.exists():
        return 0
    total = 0
    for p in root.rglob("*"):
        if p.is_file():
            try:
                total += p.stat().st_size
            except OSError:
                pass
    return total


def _check_quota(extra_bytes: int = 0) -> None:
    limit = settings.attachment_quota_mb * 1024 * 1024
    used = _tmp_dir_bytes()
    if used + extra_bytes > limit:
        raise HTTPException(
            status_code=507,
            detail="服务器中转空间已满，请稍后重试或联系管理员清理",
        )


def _uid_or_400(uid: str) -> str:
    if not UID_RE.match(uid or ""):
        raise HTTPException(status_code=400, detail="附件标识无效")
    return uid


# ---------------- 序列化 ----------------
def _row_to_out(row: dict) -> AttachmentOut:
    return AttachmentOut(
        uid=str(row["uid"]),
        parent_kind=str(row["parent_kind"]),
        parent_remote_id=int(row["parent_remote_id"]) if row.get("parent_remote_id") is not None else None,
        owner_device_id=str(row.get("owner_device_id") or ""),
        owner_device_name=str(row.get("owner_device_name") or ""),
        file_name=str(row["file_name"]),
        file_size=int(row["file_size"]),
        sha256=str(row["sha256"]),
        mime=str(row.get("mime") or ""),
        is_screenshot=bool(int(row.get("is_screenshot") or 0)),
        orphaned=bool(int(row.get("orphaned") or 0)),
        blob_state=str(row.get("blob_state") or "none"),
        created_at=utc_iso(row["created_at"]),
        updated_at=utc_iso(row["updated_at"]),
    )


def _fetch_row(uid: str, user_id: int, for_update: bool = False) -> dict | None:
    sql = (
        "SELECT * FROM attachments WHERE uid=%s AND user_id=%s"
    )
    if for_update:
        sql += " FOR UPDATE"
    with get_conn() as conn:
        with conn.cursor() as cur:
            cur.execute(sql, (uid, user_id))
            return cur.fetchone()


def _parent_exists(conn, user_id: int, kind: str, remote_id: int) -> bool:
    table = "tasks" if kind == "task" else "memos"
    with conn.cursor() as cur:
        cur.execute(
            f"SELECT id FROM {table} WHERE id=%s AND user_id=%s AND is_deleted=0",
            (remote_id, user_id),
        )
        return cur.fetchone() is not None


def _validate_meta(a: AttachmentIn, max_bytes: int) -> str:
    """返回拒绝原因，空串表示通过。"""
    if a.file_size > max_bytes:
        return f"文件超过 {settings.attachment_max_mb}MB 上限"
    ok, _, reason = classify(a.file_name)
    if not ok:
        return reason
    return ""


# ---------------- 元数据同步 ----------------
def _do_sync(req: AttachmentSyncRequest, user_id: int):
    """LWW 合并附件元数据，返回 (全量未删除列表, 是否有变更, 被拒 uid, 已删 uid)。"""
    max_bytes = settings.attachment_max_mb * 1024 * 1024
    changed = False
    rejected: list[str] = []
    deleted_uids: list[str] = []

    with get_conn() as conn:
        with conn.cursor() as cur:
            cur.execute(
                "SELECT uid, id, parent_kind, parent_remote_id, file_size, sha256, "
                "blob_state, is_deleted, updated_at FROM attachments WHERE user_id=%s",
                (user_id,),
            )
            existing = {str(r["uid"]): r for r in cur.fetchall()}

        with transaction(conn):
            for a in req.attachments:
                if not UID_RE.match(a.uid or ""):
                    rejected.append(a.uid)
                    continue
                reason = _validate_meta(a, max_bytes)
                if reason:
                    rejected.append(a.uid)
                    continue
                row = existing.get(a.uid)
                if row is not None:
                    if int(row["is_deleted"]) == 1:
                        # 墓碑：除非这条上报得更晚（例如另一端又保存了一次），否则不复活
                        if not (a.updated_at and to_utc_naive(a.updated_at) > row["updated_at"]):
                            continue
                    elif a.updated_at and to_utc_naive(a.updated_at) > row["updated_at"]:
                        with conn.cursor() as cur:
                            cur.execute(
                                "UPDATE attachments SET parent_kind=%s, parent_remote_id=%s, "
                                "owner_device_id=%s, owner_device_name=%s, file_name=%s, "
                                "file_size=%s, sha256=%s, mime=%s, is_screenshot=%s, "
                                "orphaned=%s, updated_at=%s "
                                "WHERE id=%s AND user_id=%s",
                                (
                                    a.parent_kind, a.parent_remote_id, a.owner_device_id,
                                    a.owner_device_name[:128], a.file_name[:255], a.file_size,
                                    a.sha256.lower(), a.mime[:128], 1 if a.is_screenshot else 0,
                                    1 if a.orphaned else 0,
                                    to_utc_naive(a.updated_at or a.created_at),
                                    row["id"], user_id,
                                ),
                            )
                            changed = True
                            if str(row["sha256"] or "").lower() != a.sha256.lower():
                                # 内容换版了：服务器上那份中转文件是旧内容，留着它，正在等的
                                # 目标端会拿到旧版，按新哈希校验后只报"文件校验失败"。
                                # 作废它，让持有新版的主机重新上传（中转本来就是一次性的）。
                                _drop_blob(user_id, a.uid, cur, state="none")
                                # 已经取过旧版的那台也要重新取一次：状态回到 pending，
                                # 否则源机传完新版后它收到推送会认为自己已拿到，不再下载
                                cur.execute(
                                    "UPDATE attachment_transfers SET status='pending', "
                                    "updated_at=%s WHERE attachment_uid=%s AND user_id=%s "
                                    "AND expires_at > %s",
                                    (utc_now(), a.uid, user_id, utc_now()),
                                )
                    continue

                # 新附件：父记录必须已经同步上来，否则客户端拿到的是还没入库的任务，
                # 这条元数据先拒掉，等任务同步完下一轮再报（避免悬空引用）。
                if a.parent_remote_id is None:
                    rejected.append(a.uid)
                    continue
                if not _parent_exists(conn, user_id, a.parent_kind, a.parent_remote_id):
                    rejected.append(a.uid)
                    continue
                with conn.cursor() as cur:
                    cur.execute(
                        "SELECT COUNT(*) AS n FROM attachments "
                        "WHERE user_id=%s AND parent_kind=%s AND parent_remote_id=%s "
                        "AND is_deleted=0 AND orphaned=0",
                        (user_id, a.parent_kind, a.parent_remote_id),
                    )
                    count = int(cur.fetchone()["n"])
                if count >= settings.attachment_max_per_parent:
                    rejected.append(a.uid)
                    continue
                created = to_utc_naive(a.created_at)
                updated = to_utc_naive(a.updated_at or a.created_at)
                with conn.cursor() as cur:
                    cur.execute(
                        "INSERT INTO attachments (user_id, uid, parent_kind, parent_remote_id, "
                        "owner_device_id, owner_device_name, file_name, file_size, sha256, mime, "
                        "is_screenshot, orphaned, blob_state, created_at, updated_at) "
                        "VALUES (%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,'none',%s,%s) "
                        "ON DUPLICATE KEY UPDATE updated_at=updated_at",
                        (
                            user_id, a.uid, a.parent_kind, a.parent_remote_id,
                            a.owner_device_id[:64], a.owner_device_name[:128],
                            a.file_name[:255], a.file_size, a.sha256.lower(),
                            a.mime[:128], 1 if a.is_screenshot else 0,
                            1 if a.orphaned else 0, created, updated,
                        ),
                    )
                    if cur.rowcount:
                        changed = True

            # 删除墓碑：只有删除时间晚于云端最后修改才生效（与任务同步同一套 LWW）
            for d in req.deletions:
                row = existing.get(d.uid)
                if row is None:
                    continue
                deleted_at = to_utc_naive(d.deleted_at)
                with conn.cursor() as cur:
                    cur.execute(
                        "UPDATE attachments SET is_deleted=1, updated_at=%s "
                        "WHERE id=%s AND user_id=%s AND updated_at < %s",
                        (deleted_at, row["id"], user_id, deleted_at),
                    )
                    if cur.rowcount > 0:
                        changed = True
                        deleted_uids.append(d.uid)
                        # 中转文件跟着元数据一起消失，否则删掉的附件还占着服务器
                        _drop_blob(user_id, d.uid, cur)

            with conn.cursor() as cur:
                cur.execute(
                    "SELECT * FROM attachments WHERE user_id=%s AND is_deleted=0 "
                    "ORDER BY created_at",
                    (user_id,),
                )
                rows = cur.fetchall()
            # 云端已软删除的 uid 也要告诉客户端，否则别的设备删掉的附件会在本机复活
            cur2_sql = "SELECT uid FROM attachments WHERE user_id=%s AND is_deleted=1"
            with conn.cursor() as cur:
                cur.execute(cur2_sql, (user_id,))
                for r in cur.fetchall():
                    if str(r["uid"]) not in deleted_uids:
                        deleted_uids.append(str(r["uid"]))

        return ([_row_to_out(r) for r in rows], changed, rejected, deleted_uids)


@router.post("/sync", response_model=AttachmentSyncResponse)
async def sync_attachments(
    req: AttachmentSyncRequest,
    user_id: int = Depends(get_current_user),
    x_client_id: str | None = Header(default=None),
):
    result, changed, rejected, deleted_uids = await run_in_threadpool(_do_sync, req, user_id)
    if changed:
        await ws_manager.notify_data_changed(user_id, exclude_client_id=x_client_id)
    return AttachmentSyncResponse(
        attachments=result, deleted_uids=deleted_uids, rejected_uids=rejected
    )


# ---------------- 按需中转 ----------------
def _live_transfers(conn, uid: str, user_id: int) -> list[dict]:
    with conn.cursor() as cur:
        cur.execute(
            "SELECT * FROM attachment_transfers "
            "WHERE attachment_uid=%s AND user_id=%s AND expires_at > %s",
            (uid, user_id, utc_now()),
        )
        return list(cur.fetchall())


def _drop_blob(user_id: int, uid: str, cur=None, state: str = "taken") -> None:
    """删掉服务器上的中转文件与残留分片（幂等）。

    `state` 是删完后回填的状态：ack 走 'taken'（这台机器取过了，别再给它推），
    内容换版走 'none'（文件作废了，谁都可以重新传一份上来）。
    """
    for path in (_blob_path(user_id, uid), _part_path(user_id, uid)):
        try:
            if path.exists():
                path.unlink()
        except OSError:
            pass
    if cur is not None:
        cur.execute(
            "UPDATE attachments SET blob_state=%s, blob_expires_at=NULL "
            "WHERE uid=%s AND user_id=%s",
            (state, uid, user_id),
        )


@router.post("/{uid}/request", response_model=AttachmentRequestOut)
async def request_pull(
    uid: str,
    body: AttachmentDeviceIn,
    user_id: int = Depends(get_current_user),
    x_client_id: str | None = Header(default=None),
):
    """目标端发起拉取：登记请求 + 通知该用户的其它设备上传。

    源主机不在线也登记（保留 TTL）：设备重连时服务端会补发 attachment_request，
    上传完成后自动通知请求方，不需要用户再点一次。
    """
    _uid_or_400(uid)
    _rate_limit(user_id)
    ttl = timedelta(hours=settings.attachment_ttl_hours)

    def _prepare():
        row = _fetch_row(uid, user_id)
        if row is None or int(row["is_deleted"]) == 1:
            raise HTTPException(status_code=404, detail="附件不存在或已删除")
        now = utc_now()
        with get_conn() as conn:
            with transaction(conn):
                with conn.cursor() as cur:
                    cur.execute(
                        "INSERT INTO attachment_transfers "
                        "(user_id, attachment_uid, requester_device_id, requester_device_name, "
                        "status, created_at, updated_at, expires_at) "
                        "VALUES (%s,%s,%s,%s,'pending',%s,%s,%s) "
                        "ON DUPLICATE KEY UPDATE "
                        "status=IF(status='downloaded', status, 'pending'), "
                        "requester_device_name=VALUES(requester_device_name), "
                        "updated_at=%s, expires_at=%s",
                        (
                            user_id, uid, body.device_id[:64], body.device_name[:128],
                            now, now, now + ttl, now, now + ttl,
                        ),
                    )
            transfers = _live_transfers(conn, uid, user_id)
            mine = [t for t in transfers if str(t["requester_device_id"]) == body.device_id]
            already = mine and str(mine[0]["status"]) == "downloaded"
        return row, bool(already)

    row, already_downloaded = await run_in_threadpool(_prepare)

    if str(row["blob_state"]) == "ready":
        return AttachmentRequestOut(state="ready", sources=0, message="服务器已有文件，可直接下载")
    if already_downloaded and str(row["blob_state"]) == "taken":
        return AttachmentRequestOut(state="done", sources=0, message="本机已同步过该文件")

    sources = await ws_manager.send_to_user(
        user_id,
        {
            "type": "attachment_request",
            "uid": uid,
            "file_name": str(row["file_name"]),
            "requester_device_id": body.device_id,
            "requester_device_name": body.device_name,
        },
        exclude_client_id=x_client_id,
    )
    if sources == 0:
        return AttachmentRequestOut(
            state="waiting",
            sources=0,
            message=f"其它主机当前都不在线，已登记请求；{settings.attachment_ttl_hours} 小时内任一主机上线都会自动继续同步",
        )
    return AttachmentRequestOut(
        state="requested", sources=sources, message="已通知其它主机上传"
    )


@router.post("/{uid}/upload/init", response_model=AttachmentUploadInitOut)
async def upload_init(
    uid: str,
    body: AttachmentDeviceIn,
    user_id: int = Depends(get_current_user),
):
    """源主机开始/继续上传：返回续传偏移。"""
    _uid_or_400(uid)
    _rate_limit(user_id)
    row = _fetch_row(uid, user_id)
    if row is None or int(row["is_deleted"]) == 1:
        raise HTTPException(status_code=404, detail="附件不存在或已删除")
    if str(row["blob_state"]) == "ready":
        return AttachmentUploadInitOut(
            state="ready", file_size=int(row["file_size"]), sha256=str(row["sha256"])
        )

    def _offset():
        part = _part_path(user_id, uid)
        size = int(row["file_size"])
        if part.exists():
            have = part.stat().st_size
            if have > size:
                # 上次传坏了（或元数据被改过）：整个丢掉重传
                part.unlink(missing_ok=True)
                return 0
            return have
        return 0

    next_offset = await run_in_threadpool(_offset)
    await run_in_threadpool(_check_quota, int(row["file_size"]) - next_offset)
    return AttachmentUploadInitOut(
        state="upload",
        next_offset=next_offset,
        chunk_size=settings.attachment_chunk_mb * 1024 * 1024,
        file_size=int(row["file_size"]),
        sha256=str(row["sha256"]),
    )


@router.put("/{uid}/upload")
async def upload_chunk(
    uid: str,
    request: Request,
    offset: int,
    user_id: int = Depends(get_current_user),
):
    """按偏移写入一片。offset 必须等于当前已收字节数，否则 409 并回真实偏移。"""
    _uid_or_400(uid)
    if offset < 0:
        raise HTTPException(status_code=400, detail="偏移无效")
    row = _fetch_row(uid, user_id)
    if row is None or int(row["is_deleted"]) == 1:
        raise HTTPException(status_code=404, detail="附件不存在或已删除")
    max_bytes = settings.attachment_max_mb * 1024 * 1024
    if int(row["file_size"]) > max_bytes:
        raise HTTPException(status_code=413, detail="文件超过服务器上限")

    chunk = await request.body()
    if not chunk:
        raise HTTPException(status_code=400, detail="空分片")

    def _write():
        part = _part_path(user_id, uid)
        _user_dir(user_id)
        have = part.stat().st_size if part.exists() else 0
        if have != offset:
            return ("offset", have)
        if offset + len(chunk) > int(row["file_size"]):
            return ("oversize", have)
        with open(part, "ab") as fh:
            fh.write(chunk)
        return ("ok", offset + len(chunk))

    status, value = await run_in_threadpool(_write)
    if status == "offset":
        return {"state": "resume", "next_offset": value}
    if status == "oversize":
        raise HTTPException(status_code=413, detail="分片超出文件大小")
    return {"state": "ok", "next_offset": value}


@router.post("/{uid}/upload/complete", response_model=AttachmentRequestOut)
async def upload_complete(
    uid: str,
    body: AttachmentDeviceIn,
    user_id: int = Depends(get_current_user),
):
    """收片完成：校验大小与 SHA-256，落到 .bin 并通知请求方。"""
    _uid_or_400(uid)
    row = _fetch_row(uid, user_id)
    if row is None or int(row["is_deleted"]) == 1:
        raise HTTPException(status_code=404, detail="附件不存在或已删除")
    size = int(row["file_size"])
    expected = str(row["sha256"]).lower()

    def _finalize():
        part = _part_path(user_id, uid)
        if not part.exists():
            return "size"
        # 以元数据声明大小为准：多写的尾巴既不进哈希也不落盘，防止校验过了文件却超长
        declared = int(row["file_size"])
        have = part.stat().st_size
        if have < declared:
            return "size"
        head = part.open("rb").read(4)
        if looks_executable(head):
            part.unlink(missing_ok=True)
            return "executable"
        digest = hashlib.sha256()
        read = 0
        with part.open("rb") as fh:
            while read < declared:
                block = fh.read(min(1024 * 1024, declared - read))
                if not block:
                    break
                read += len(block)
                digest.update(block)
        if read != declared or digest.hexdigest() != expected:
            part.unlink(missing_ok=True)
            return "hash"
        blob = _blob_path(user_id, uid)
        part.replace(blob)
        if blob.stat().st_size != declared:
            blob.unlink(missing_ok=True)
            return "size"
        return "ok"

    result = await run_in_threadpool(_finalize)
    if result == "size":
        raise HTTPException(status_code=422, detail="文件大小与元数据不符，请重新上传")
    if result == "executable":
        raise HTTPException(status_code=415, detail="该文件实际是可执行程序，已拒绝保存")
    if result == "hash":
        raise HTTPException(status_code=422, detail="内容校验失败（SHA-256 不匹配）")

    ttl = timedelta(hours=settings.attachment_ttl_hours)
    with get_conn() as conn:
        with transaction(conn):
            with conn.cursor() as cur:
                cur.execute(
                    "UPDATE attachments SET blob_state='ready', blob_expires_at=%s "
                    "WHERE uid=%s AND user_id=%s",
                    (utc_now() + ttl, uid, user_id),
                )

    await ws_manager.send_to_user(
        user_id, {"type": "attachment_ready", "uid": uid, "file_name": str(row["file_name"])}
    )
    return AttachmentRequestOut(state="ready", sources=0, message="文件已就绪，等待目标端下载")


@router.get("/{uid}/blob")
async def download_blob(
    uid: str,
    device_id: str,
    user_id: int = Depends(get_current_user),
):
    """请求方下载中转文件；必须有过这台设备的拉取请求。"""
    _uid_or_400(uid)
    row = _fetch_row(uid, user_id)
    if row is None or int(row["is_deleted"]) == 1:
        raise HTTPException(status_code=404, detail="附件不存在或已删除")
    if str(row["blob_state"]) != "ready":
        raise HTTPException(status_code=410, detail="服务器上没有该文件的中转副本")

    def _allowed():
        with get_conn() as conn:
            for t in _live_transfers(conn, uid, user_id):
                if str(t["requester_device_id"]) == device_id[:64]:
                    return True
            return False

    if not await run_in_threadpool(_allowed):
        raise HTTPException(status_code=403, detail="请先发起同步请求")

    blob = _blob_path(user_id, uid)
    if not blob.exists():
        # 数据库说 ready、文件却没了（被清理/磁盘异常）：把状态纠正过来
        with get_conn() as conn:
            with transaction(conn):
                with conn.cursor() as cur:
                    cur.execute(
                        "UPDATE attachments SET blob_state='none', blob_expires_at=NULL "
                        "WHERE uid=%s AND user_id=%s",
                        (uid, user_id),
                    )
        raise HTTPException(status_code=410, detail="中转文件已过期，请重新发起同步")

    return FileResponse(
        path=str(blob),
        media_type="application/octet-stream",
        filename=str(row["file_name"]),
        headers={"X-Attachment-Sha256": str(row["sha256"])},
    )


@router.post("/{uid}/ack", response_model=AttachmentAckOut)
async def ack_download(
    uid: str,
    body: AttachmentDeviceIn,
    user_id: int = Depends(get_current_user),
):
    """下载确认：所有请求方都确认后服务器立刻删文件。"""
    _uid_or_400(uid)

    def _ack():
        with get_conn() as conn:
            with transaction(conn):
                with conn.cursor() as cur:
                    cur.execute(
                        "UPDATE attachment_transfers SET status='downloaded', updated_at=%s "
                        "WHERE attachment_uid=%s AND user_id=%s AND requester_device_id=%s",
                        (utc_now(), uid, user_id, body.device_id[:64]),
                    )
                    cur.execute(
                        "SELECT COUNT(*) AS n FROM attachment_transfers "
                        "WHERE attachment_uid=%s AND user_id=%s AND status='pending' AND expires_at > %s",
                        (uid, user_id, utc_now()),
                    )
                    remaining = int(cur.fetchone()["n"])
                    if remaining == 0:
                        _drop_blob(user_id, uid, cur)
                        return 0, True
                return remaining, False

    remaining, deleted = await run_in_threadpool(_ack)
    if deleted:
        await ws_manager.send_to_user(user_id, {"type": "attachment_taken", "uid": uid})
    return AttachmentAckOut(remaining=remaining, blob_deleted=deleted)


@router.get("/{uid}/state", response_model=AttachmentStateOut)
async def attachment_state(
    uid: str,
    user_id: int = Depends(get_current_user),
):
    """轮询兜底：WebSocket 掉线时客户端用它确认中转状态。"""
    _uid_or_400(uid)
    row = _fetch_row(uid, user_id)
    if row is None or int(row["is_deleted"]) == 1:
        raise HTTPException(status_code=404, detail="附件不存在或已删除")

    def _transfers():
        with get_conn() as conn:
            return [
                {
                    "device_id": str(t["requester_device_id"]),
                    "device_name": str(t["requester_device_name"] or ""),
                    "status": str(t["status"]),
                    "expires_at": utc_iso(t["expires_at"]),
                }
                for t in _live_transfers(conn, uid, user_id)
            ]

    return AttachmentStateOut(
        blob_state=str(row["blob_state"]), transfers=await run_in_threadpool(_transfers)
    )


# ---------------- 设备上线补发 ----------------
def _pending_rows(user_id: int) -> list[dict]:
    """这台账号名下仍未完成的中转请求（含附件当前中转状态）。"""
    with get_conn() as conn:
        with conn.cursor() as cur:
            cur.execute(
                "SELECT t.attachment_uid AS uid, t.requester_device_id, t.requester_device_name, "
                "a.file_name, a.blob_state "
                "FROM attachment_transfers t "
                "JOIN attachments a ON a.uid = t.attachment_uid AND a.user_id = t.user_id "
                "WHERE t.user_id=%s AND t.status='pending' AND t.expires_at > %s AND a.is_deleted=0",
                (user_id, utc_now()),
            )
            return list(cur.fetchall())


async def push_pending_transfers(user_id: int, conn: Conn) -> int:
    """设备报上身份后补发未完成的中转。

    两类消息：
    - 别人在等这台机器上传的文件 → attachment_request（本机是源，该上传）
    - 这台机器自己要的文件已经 ready → attachment_ready（本机该下载）
    没有这一步，"源机上线后自动继续同步"就得靠用户再点一次。
    """
    device_id = conn.device_id
    if not device_id:
        return 0
    rows = await run_in_threadpool(_pending_rows, user_id)
    sent = 0
    for row in rows:
        uid = str(row["uid"])
        requester = str(row["requester_device_id"])
        blob_state = str(row["blob_state"])
        if requester == device_id:
            if blob_state == "ready":
                if await ws_manager.send_to_conn(
                    conn,
                    {"type": "attachment_ready", "uid": uid, "file_name": str(row["file_name"])},
                ):
                    sent += 1
            continue
        if blob_state == "ready":
            continue  # 已经在服务器上了，不需要这台机器再传
        if await ws_manager.send_to_conn(
            conn,
            {
                "type": "attachment_request",
                "uid": uid,
                "file_name": str(row["file_name"]),
                "requester_device_id": requester,
                "requester_device_name": str(row["requester_device_name"] or ""),
            },
        ):
            sent += 1
    return sent


# ---------------- 过期清理 ----------------
def purge_expired_blobs() -> int:
    """删掉超时未取走的中转文件与残留分片，返回删除的文件数。

    由后台定时循环调用：源机一直离线、或请求方中途卸载，都会留下孤儿文件，
    没有这一步"服务器只暂存"的承诺就落不了地。
    """
    now = utc_now()
    removed = 0
    with get_conn() as conn:
        with transaction(conn):
            with conn.cursor() as cur:
                # 所有"库里说 ready"的记录都要复核：过期要删，文件已经不在
                # 也要把状态复位，否则接口会一直返回"可下载"却 410，客户端反复重试。
                cur.execute(
                    "SELECT uid, user_id, blob_expires_at FROM attachments "
                    "WHERE blob_state='ready'",
                )
                rows = list(cur.fetchall())
                cutoff = time.time() - settings.attachment_ttl_hours * 3600
                for row in rows:
                    uid = str(row["uid"])
                    owner = int(row["user_id"])
                    blob = _blob_path(owner, uid)
                    expires = row["blob_expires_at"]
                    if blob.exists():
                        expired = (
                            expires is not None and to_utc_naive(expires) < now
                        ) or blob.stat().st_mtime < cutoff
                        if not expired:
                            continue
                    try:
                        if blob.exists():
                            blob.unlink()
                            removed += 1
                        part = _part_path(owner, uid)
                        if part.exists():
                            part.unlink()
                            removed += 1
                    except OSError:
                        pass
                    cur.execute(
                        "UPDATE attachments SET blob_state='none', blob_expires_at=NULL "
                        "WHERE uid=%s AND user_id=%s",
                        (uid, owner),
                    )
                    cur.execute(
                        "UPDATE attachment_transfers SET status='expired', updated_at=%s "
                        "WHERE attachment_uid=%s AND user_id=%s AND status='pending'",
                        (now, uid, owner),
                    )
        # 残留的 .part（上传到一半客户端再也没回来）按 TTL 一并清掉
        root = settings.attachment_tmp_path
        if root.exists():
            cutoff = time.time() - settings.attachment_ttl_hours * 3600
            for path in root.rglob("*.part"):
                try:
                    if path.stat().st_mtime < cutoff:
                        path.unlink()
                        removed += 1
                except OSError:
                    pass
    removed += enforce_storage_quota()
    cleanup_orphan_dirs()
    return removed


def enforce_storage_quota() -> int:
    """中转目录超出容量上限时，按到期时间从早到晚丢文件。

    服务器只暂存，但如果一堆大文件同时排队等着取，磁盘照样会被塞满——
    宁可让最老的请求失败（客户端会提示重新同步），也不能拖垮整个站点。
    """
    limit = settings.attachment_quota_mb * 1024 * 1024
    with get_conn() as conn:
        with conn.cursor() as cur:
            cur.execute(
                "SELECT SUM(file_size) AS total FROM attachments WHERE blob_state='ready'"
            )
            total = int(cur.fetchone()["total"] or 0)
            if total <= limit:
                return 0
            cur.execute(
                "SELECT uid, user_id FROM attachments WHERE blob_state='ready' "
                "ORDER BY blob_expires_at LIMIT 200",
            )
            victims = list(cur.fetchall())
            dropped = 0
            for row in victims:
                if total <= limit:
                    break
                uid = str(row["uid"])
                owner = int(row["user_id"])
                try:
                    blob = _blob_path(owner, uid)
                    size = blob.stat().st_size if blob.exists() else 0
                    if blob.exists():
                        blob.unlink()
                except OSError:
                    size = 0
                cur.execute(
                    "UPDATE attachments SET blob_state='none', blob_expires_at=NULL "
                    "WHERE uid=%s AND user_id=%s",
                    (uid, owner),
                )
                cur.execute(
                    "UPDATE attachment_transfers SET status='expired', updated_at=%s "
                    "WHERE attachment_uid=%s AND user_id=%s AND status='pending'",
                    (utc_now(), uid, owner),
                )
                total -= size
                dropped += 1
            return dropped


def cleanup_orphan_dirs() -> None:
    """删掉空的用户中转目录，避免长期留下无意义的一层目录树。"""
    root = settings.attachment_tmp_path
    if not root.exists():
        return
    for child in root.iterdir():
        if child.is_dir():
            try:
                if not any(child.iterdir()):
                    child.rmdir()
            except OSError:
                pass
