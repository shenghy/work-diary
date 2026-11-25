"""备忘：同步（LWW 合并，与任务同步同模式）。

- 纯记录型数据：content + created_at + updated_at
- 同步逻辑与 /api/tasks/sync 完全一致：客户端上报全量 + 本地删除列表，
  服务端按 updated_at 较新者胜出合并，返回云端全部未删除备忘。
- 向下兼容：memos 表/接口为新增，不影响旧版客户端与现有 tasks 接口。
"""
from fastapi import APIRouter, Depends, Header

from ..database import get_conn, transaction
from ..models import (
    MemoIn,
    MemoOut,
    MemoSyncRequest,
    MemoSyncResponse,
)
from ..utils import to_utc_naive, utc_iso
from .deps import get_current_user
from ..ws_manager import ws_manager

router = APIRouter(prefix="/api/memos", tags=["memos"])


# ---------------- 序列化 ----------------
def _row_to_out(row: dict) -> MemoOut:
    return MemoOut(
        id=row["local_id"],
        remote_id=row["id"],
        content=row["content"],
        created_at=utc_iso(row["created_at"]),
        updated_at=utc_iso(row["updated_at"]),
    )


def _fetch_rows(conn, user_id: int) -> list[dict]:
    with conn.cursor() as cur:
        cur.execute(
            "SELECT * FROM memos WHERE user_id = %s", (user_id,)
        )
        return cur.fetchall()


def _all_remote(conn, user_id: int) -> list[dict]:
    with conn.cursor() as cur:
        cur.execute(
            "SELECT * FROM memos WHERE user_id = %s AND is_deleted = 0 "
            "ORDER BY created_at DESC",
            (user_id,),
        )
        return cur.fetchall()


def _insert_memo(conn, user_id: int, m: MemoIn) -> None:
    with conn.cursor() as cur:
        cur.execute(
            "INSERT INTO memos (user_id, local_id, content, created_at, "
            "updated_at, is_deleted) VALUES (%s, %s, %s, %s, %s, 0)",
            (
                user_id,
                m.id,
                m.content,
                to_utc_naive(m.created_at),
                to_utc_naive(m.updated_at or m.created_at),
            ),
        )


def _update_memo(conn, memo_id: int, user_id: int, m: MemoIn) -> None:
    with conn.cursor() as cur:
        cur.execute(
            "UPDATE memos SET content=%s, created_at=%s, updated_at=%s, "
            "is_deleted=0 WHERE id=%s AND user_id=%s",
            (
                m.content,
                to_utc_naive(m.created_at),
                to_utc_naive(m.updated_at or m.created_at),
                memo_id,
                user_id,
            ),
        )


# ---------------- 同步 ----------------
@router.post("/sync", response_model=MemoSyncResponse)
async def sync_memos(
    req: MemoSyncRequest,
    user_id: int = Depends(get_current_user),
    x_client_id: str | None = Header(default=None),
):
    """逐条合并（LWW：updated_at 较新者胜出），返回云端全部未删除备忘。"""
    from fastapi.concurrency import run_in_threadpool
    result, deleted_ids, changed = await run_in_threadpool(_do_sync, req, user_id)
    # 只有实际修改了数据才通知其他设备，避免同步循环
    if changed:
        await ws_manager.notify_data_changed(user_id, exclude_client_id=x_client_id)
    return MemoSyncResponse(memos=result, deleted_ids=deleted_ids)


def _do_sync(req: MemoSyncRequest, user_id: int) -> tuple[list, list, bool]:
    changed = False
    with get_conn() as conn:
        rows = _fetch_rows(conn, user_id)
        remote_by_id: dict[int, dict] = {}
        local_by_id: dict[int, dict] = {}
        for row in rows:
            rid = int(row["id"])
            remote_by_id[rid] = row
            lid = row["local_id"]
            if lid is not None:
                lid = int(lid)
                old = local_by_id.get(lid)
                if old is None or rid > int(old["id"]):
                    local_by_id[lid] = row

        with transaction(conn):
            # 1) 上传本地备忘
            for m in req.memos:
                if m.remote_id is not None and m.remote_id in remote_by_id:
                    cloud = remote_by_id[m.remote_id]
                    if int(cloud["is_deleted"]) == 1:
                        continue
                    if m.updated_at and to_utc_naive(m.updated_at) > cloud["updated_at"]:
                        _update_memo(conn, m.remote_id, user_id, m)
                        changed = True
                elif m.id is not None and m.id in local_by_id:
                    cloud = local_by_id[m.id]
                    if int(cloud["is_deleted"]) == 1:
                        _insert_memo(conn, user_id, m)
                        changed = True
                        continue
                    if m.updated_at and to_utc_naive(m.updated_at) > cloud["updated_at"]:
                        _update_memo(conn, int(cloud["id"]), user_id, m)
                        changed = True
                else:
                    _insert_memo(conn, user_id, m)
                    changed = True

            # 2) 本地删除 -> 云端软删除
            for d in req.deletions:
                with conn.cursor() as cur:
                    cur.execute(
                        "UPDATE memos SET is_deleted=1, updated_at=%s "
                        "WHERE id=%s AND user_id=%s",
                        (to_utc_naive(d.deleted_at), d.remote_id, user_id),
                    )
                    if cur.rowcount > 0:
                        changed = True

        # 3) 返回云端全部未删除备忘 + 云端已软删除的 id（客户端据此删除本地）
        with conn.cursor() as cur:
            cur.execute(
                "SELECT id FROM memos WHERE user_id = %s AND is_deleted = 1",
                (user_id,),
            )
            deleted_ids = [int(r["id"]) for r in cur.fetchall()]
        return [_row_to_out(r) for r in _all_remote(conn, user_id)], deleted_ids, changed
