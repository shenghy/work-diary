"""任务：同步（LWW 合并）与常规增删改查。"""
from datetime import timedelta

import pymysql

from fastapi import APIRouter, Depends, HTTPException, Header

from ..database import get_conn, transaction
from ..models import (
    RepeatGroupOut,
    SkipItem,
    SyncRequest,
    SyncResponse,
    TaskCreate,
    TaskIn,
    TaskOut,
    TaskUpdate,
)
from ..utils import to_utc_naive, utc_iso, utc_now
from .deps import get_current_user
from ..ws_manager import ws_manager

router = APIRouter(prefix="/api/tasks", tags=["tasks"])

# 循环任务「已删除期次」的保留天数。
# 客户端本地账本保留 120 天，服务端留得更久一点，避免设备长时间离线后
# 同步回来时"删过的期次"已经被清掉而复活的边界情况。
REPEAT_SKIP_RETENTION_DAYS = 180


# ---------------- 序列化 ----------------
def _row_to_out(row: dict) -> TaskOut:
    return TaskOut(
        id=row["local_id"],
        remote_id=row["id"],
        title=row["title"],
        status=int(row["status"]),
        urgency=int(row["urgency"]),
        created_at=utc_iso(row["created_at"]),
        started_at=utc_iso(row["started_at"]) if row["started_at"] else None,
        completed_at=utc_iso(row["completed_at"]) if row["completed_at"] else None,
        plan_start_at=utc_iso(row["plan_start_at"]) if row["plan_start_at"] else None,
        due_at=utc_iso(row["due_at"]) if row["due_at"] else None,
        sort_order=int(row.get("sort_order", 0)),
        task_type=int(row.get("task_type", 1)),
        repeat_type=int(row.get("repeat_type", 0)),
        repeat_week_days=row.get("repeat_week_days"),
        repeat_month_day=int(row["repeat_month_day"]) if row.get("repeat_month_day") is not None else None,
        repeat_group_id=row.get("repeat_group_id"),
        instance_date=str(row["instance_date"]) if row.get("instance_date") is not None else None,
        updated_at=utc_iso(row["updated_at"]),
    )


def _group_row_to_out(row: dict) -> RepeatGroupOut:
    """repeat_groups 行 -> 下发给客户端的结构（时间转 ISO）"""
    return RepeatGroupOut(
        group_id=str(row["group_id"]),
        title=row.get("title") or "",
        urgency=int(row.get("urgency") or 0),
        task_type=int(row.get("task_type") or 1),
        repeat_type=int(row.get("repeat_type") or 1),
        repeat_week_days=row.get("repeat_week_days"),
        repeat_month_day=(
            int(row["repeat_month_day"])
            if row.get("repeat_month_day") is not None
            else None
        ),
        plan_start_at=(
            utc_iso(row["plan_start_at"]) if row.get("plan_start_at") else None
        ),
        due_at=utc_iso(row["due_at"]) if row.get("due_at") else None,
        stopped=bool(int(row.get("stopped") or 0)),
        deleted=bool(int(row.get("deleted") or 0)),
        updated_at=utc_iso(row["updated_at"]),
    )


def _all_groups(conn, user_id: int) -> list[RepeatGroupOut]:
    with conn.cursor() as cur:
        cur.execute(
            "SELECT * FROM repeat_groups WHERE user_id = %s ORDER BY group_id",
            (user_id,),
        )
        rows = cur.fetchall()
    return [_group_row_to_out(r) for r in rows]


def _soft_delete_group_tasks(conn, user_id: int, group_id: str, stamp) -> None:
    """永久删除循环族时，服务端直接把该族全部任务软删。

    清空 instance_date 是为了释放 uk_repeat 唯一键，避免旧客户端再补生成时
    撞唯一键（这一族已经死了，不允许再落库）。
    """
    with conn.cursor() as cur:
        cur.execute(
            "UPDATE tasks SET is_deleted=1, updated_at=%s, instance_date=NULL "
            "WHERE user_id=%s AND repeat_group_id=%s AND is_deleted=0",
            (stamp, user_id, group_id),
        )


def _deleted_group_ids(conn, user_id: int) -> set[str]:
    """已永久删除的循环族集合（用于拦住旧客户端继续补生成上传）。"""
    with conn.cursor() as cur:
        cur.execute(
            "SELECT group_id FROM repeat_groups "
            "WHERE user_id=%s AND deleted=1",
            (user_id,),
        )
        rows = cur.fetchall()
    result: set[str] = set()
    for row in rows:
        gid = row.get("group_id") if isinstance(row, dict) else row[0]
        if gid:
            result.add(str(gid))
    return result


def _merge_groups(conn, user_id: int, groups) -> bool:
    """循环规则 LWW 合并，并处理永久删除墓碑。返回是否改动了数据。

    `deleted` 是终态：一旦云端标记删除，任何非墓碑更新都不再接受，
    防止一台离线旧设备把整族重新带回来。
    """
    changed = False
    if not groups:
        return changed
    with conn.cursor() as cur:
        for g in groups:
            gid = (g.group_id or "").strip()
            if not gid:
                continue
            # repeat_type=0 的规则没有意义（正常任务不循环），跳过不落库
            if int(g.repeat_type or 0) <= 0:
                continue
            stamp = to_utc_naive(g.updated_at or utc_now())
            cur.execute(
                "SELECT id, updated_at, deleted FROM repeat_groups "
                "WHERE user_id=%s AND group_id=%s",
                (user_id, gid),
            )
            row = cur.fetchone()
            cloud_updated = None
            cloud_deleted = False
            if row is not None:
                if isinstance(row, dict):
                    cloud_updated = row["updated_at"]
                    cloud_deleted = bool(int(row.get("deleted") or 0))
                else:
                    cloud_updated = row[1]
                    cloud_deleted = bool(int(row[2] or 0))

            # 终态删除：云端已删，任何非墓碑规则都不能复活它
            if cloud_deleted:
                continue

            if g.deleted:
                # 删除是终态，不受普通 LWW 限制：即使用户设备时钟偏慢，
                # 也不允许"删不掉"。时间只用于其它设备合并墓碑。
                if row is None:
                    cur.execute(
                        "INSERT INTO repeat_groups (user_id, group_id, title, urgency, "
                        "task_type, repeat_type, repeat_week_days, repeat_month_day, "
                        "plan_start_at, due_at, stopped, deleted, updated_at) "
                        "VALUES (%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s)",
                        (
                            user_id,
                            gid,
                            g.title or "",
                            g.urgency,
                            g.task_type,
                            g.repeat_type,
                            g.repeat_week_days,
                            g.repeat_month_day,
                            to_utc_naive(g.plan_start_at) if g.plan_start_at else None,
                            to_utc_naive(g.due_at) if g.due_at else None,
                            1,
                            1,
                            stamp,
                        ),
                    )
                else:
                    cur.execute(
                        "UPDATE repeat_groups SET title=%s, urgency=%s, task_type=%s, "
                        "repeat_type=%s, repeat_week_days=%s, repeat_month_day=%s, "
                        "plan_start_at=%s, due_at=%s, stopped=1, deleted=1, updated_at=%s "
                        "WHERE user_id=%s AND group_id=%s",
                        (
                            g.title or "",
                            g.urgency,
                            g.task_type,
                            g.repeat_type,
                            g.repeat_week_days,
                            g.repeat_month_day,
                            to_utc_naive(g.plan_start_at) if g.plan_start_at else None,
                            to_utc_naive(g.due_at) if g.due_at else None,
                            stamp,
                            user_id,
                            gid,
                        ),
                    )
                _soft_delete_group_tasks(conn, user_id, gid, stamp)
                changed = True
                continue

            if row is None:
                cur.execute(
                    "INSERT INTO repeat_groups (user_id, group_id, title, urgency, "
                    "task_type, repeat_type, repeat_week_days, repeat_month_day, "
                    "plan_start_at, due_at, stopped, deleted, updated_at) "
                    "VALUES (%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s)",
                    (
                        user_id,
                        gid,
                        g.title or "",
                        g.urgency,
                        g.task_type,
                        g.repeat_type,
                        g.repeat_week_days,
                        g.repeat_month_day,
                        to_utc_naive(g.plan_start_at) if g.plan_start_at else None,
                        to_utc_naive(g.due_at) if g.due_at else None,
                        1 if g.stopped else 0,
                        0,
                        stamp,
                    ),
                )
                changed = True
                continue
            # 只有客户端的时间更新才覆盖：避免旧设备把刚改好的规则打回去
            if cloud_updated is not None and stamp <= cloud_updated:
                continue
            cur.execute(
                "UPDATE repeat_groups SET title=%s, urgency=%s, task_type=%s, "
                "repeat_type=%s, repeat_week_days=%s, repeat_month_day=%s, "
                "plan_start_at=%s, due_at=%s, stopped=%s, deleted=0, updated_at=%s "
                "WHERE user_id=%s AND group_id=%s",
                (
                    g.title or "",
                    g.urgency,
                    g.task_type,
                    g.repeat_type,
                    g.repeat_week_days,
                    g.repeat_month_day,
                    to_utc_naive(g.plan_start_at) if g.plan_start_at else None,
                    to_utc_naive(g.due_at) if g.due_at else None,
                    1 if g.stopped else 0,
                    stamp,
                    user_id,
                    gid,
                ),
            )
            changed = True
    return changed


def _fetch_rows(conn, user_id: int) -> list[dict]:
    with conn.cursor() as cur:
        cur.execute(
            "SELECT * FROM tasks WHERE user_id = %s", (user_id,)
        )
        return cur.fetchall()


def _all_remote(conn, user_id: int) -> list[dict]:
    with conn.cursor() as cur:
        cur.execute(
            "SELECT * FROM tasks WHERE user_id = %s AND is_deleted = 0 "
            "ORDER BY created_at DESC",
            (user_id,),
        )
        return cur.fetchall()


def _insert_task(conn, user_id: int, t: TaskIn) -> bool:
    """插入任务。循环任务实例重复（唯一索引冲突）时返回 False（幂等，以云端为准）。"""
    try:
        with conn.cursor() as cur:
            cur.execute(
                "INSERT INTO tasks (user_id, local_id, title, status, urgency, "
                "created_at, started_at, completed_at, plan_start_at, due_at, "
                "sort_order, task_type, repeat_type, repeat_week_days, "
                "repeat_month_day, repeat_group_id, instance_date, "
                "updated_at, is_deleted) "
                "VALUES (%s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, "
                "%s, %s, %s, %s, 0)",
                (
                    user_id,
                    t.id,
                    t.title,
                    t.status,
                    t.urgency,
                    to_utc_naive(t.created_at),
                    to_utc_naive(t.started_at) if t.started_at else None,
                    to_utc_naive(t.completed_at) if t.completed_at else None,
                    to_utc_naive(t.plan_start_at) if t.plan_start_at else None,
                    to_utc_naive(t.due_at) if t.due_at else None,
                    t.sort_order,
                    t.task_type,
                    t.repeat_type,
                    t.repeat_week_days,
                    t.repeat_month_day,
                    t.repeat_group_id,
                    t.instance_date,
                    to_utc_naive(t.updated_at or t.created_at),
                ),
            )
        return True
    except pymysql.err.IntegrityError as exc:
        # 只吞"唯一键冲突"（1062，循环任务实例已在云端，属正常的幂等重复生成）。
        # 其它完整性错误必须抛出去，否则任务会凭空消失而同步还显示成功。
        code = exc.args[0] if exc.args else None
        if code == 1062:
            return False
        raise


def _update_task(conn, task_id: int, user_id: int, t: TaskIn) -> None:
    with conn.cursor() as cur:
        cur.execute(
            "UPDATE tasks SET title=%s, status=%s, urgency=%s, created_at=%s, "
            "started_at=%s, completed_at=%s, plan_start_at=%s, due_at=%s, "
            "sort_order=%s, task_type=%s, repeat_type=%s, repeat_week_days=%s, "
            "repeat_month_day=%s, repeat_group_id=%s, instance_date=%s, "
            "updated_at=%s, is_deleted=0 "
            "WHERE id=%s AND user_id=%s",
            (
                t.title,
                t.status,
                t.urgency,
                to_utc_naive(t.created_at),
                to_utc_naive(t.started_at) if t.started_at else None,
                to_utc_naive(t.completed_at) if t.completed_at else None,
                to_utc_naive(t.plan_start_at) if t.plan_start_at else None,
                to_utc_naive(t.due_at) if t.due_at else None,
                t.sort_order,
                t.task_type,
                t.repeat_type,
                t.repeat_week_days,
                t.repeat_month_day,
                t.repeat_group_id,
                t.instance_date,
                to_utc_naive(t.updated_at or t.created_at),
                task_id,
                user_id,
            ),
        )


# ---------------- 同步 ----------------
@router.post("/sync", response_model=SyncResponse)
async def sync_tasks(
    req: SyncRequest,
    user_id: int = Depends(get_current_user),
    x_client_id: str | None = Header(default=None),
):
    """逐条合并（LWW：updated_at 较新者胜出），返回云端全部未删除任务。"""
    from fastapi.concurrency import run_in_threadpool
    result, skips, groups, changed = await run_in_threadpool(_do_sync, req, user_id)
    # 只有实际修改了数据才通知其他设备，避免同步循环
    if changed:
        await ws_manager.notify_data_changed(user_id, exclude_client_id=x_client_id)
    return SyncResponse(tasks=result, skips=skips, repeat_groups=groups)


def _do_sync(req: SyncRequest, user_id: int) -> tuple[list, list, list, bool]:
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
            # 0) 已被用户删掉的循环实例：任何设备都不允许再补回来。
            #    老版本客户端（安卓旧包）没有跳过账本，仍会本地补生成并上传，
            #    这一层是服务端兜底，保证多端不会再"复活"这一期。
            _prune_skips(conn, user_id)
            skipped_keys = _skip_keys(conn, user_id)

            # 永久删除的族：旧客户端可能还在本地补生成并上传，这里直接拦掉。
            # 同时把本轮请求里的墓碑也算进去，避免"先传任务、后合并墓碑"的窗口。
            deleted_groups = _deleted_group_ids(conn, user_id)
            for g in req.repeat_groups:
                if g.deleted and (g.group_id or "").strip():
                    deleted_groups.add(g.group_id.strip())

            # 1) 上传本地任务
            for t in req.tasks:
                if t.repeat_group_id and t.repeat_group_id in deleted_groups:
                    continue
                if (
                    t.repeat_group_id
                    and t.instance_date
                    and (t.repeat_group_id, str(t.instance_date)) in skipped_keys
                ):
                    continue
                if t.remote_id is not None and t.remote_id in remote_by_id:
                    cloud = remote_by_id[t.remote_id]
                    if int(cloud["is_deleted"]) == 1:
                        continue
                    if t.updated_at and to_utc_naive(t.updated_at) > cloud["updated_at"]:
                        _update_task(conn, t.remote_id, user_id, t)
                        changed = True
                elif t.id is not None and t.id in local_by_id:
                    cloud = local_by_id[t.id]
                    if int(cloud["is_deleted"]) == 1:
                        if _insert_task(conn, user_id, t):
                            changed = True
                        continue
                    if t.updated_at and to_utc_naive(t.updated_at) > cloud["updated_at"]:
                        _update_task(conn, int(cloud["id"]), user_id, t)
                        changed = True
                else:
                    if _insert_task(conn, user_id, t):
                        changed = True

            # 2) 本地删除 -> 云端软删除
            #    删除也必须参与 LWW：只有删除时间晚于云端最后修改才生效，
            #    否则一台时钟偏慢/长时间离线的设备上传一条旧删除，会把别的
            #    设备刚编辑过的任务直接抹掉（静默数据丢失）。
            for d in req.deletions:
                if d.remote_id is None:
                    continue
                deleted_at = to_utc_naive(d.deleted_at)
                with conn.cursor() as cur:
                    # 删除前先记下这条任务的循环信息：写进 repeat_skips 之后，
                    # 其它设备同步时就知道"这一期被删了"，不会各自动补生成。
                    cur.execute(
                        "SELECT repeat_group_id, instance_date FROM tasks "
                        "WHERE id=%s AND user_id=%s",
                        (d.remote_id, user_id),
                    )
                    row = cur.fetchone()
                    group_id = None
                    instance_date = None
                    if row:
                        if isinstance(row, dict):
                            group_id = row.get("repeat_group_id")
                            instance_date = row.get("instance_date")
                        else:
                            group_id, instance_date = row[0], row[1]

                    # 软删除时顺手清空 instance_date：uk_repeat 是普通唯一键，
                    # 软删除行不释放槽位的话，同一期永远无法重新落库（会一直补生成）。
                    cur.execute(
                        "UPDATE tasks SET is_deleted=1, updated_at=%s, "
                        "instance_date=NULL "
                        "WHERE id=%s AND user_id=%s AND updated_at < %s",
                        (deleted_at, d.remote_id, user_id, deleted_at),
                    )
                    if cur.rowcount > 0:
                        changed = True
                        # 只有删除真的生效（LWW 通过）才登记跳过，
                        # 否则会把一条"没删掉的任务"误标成跳过。
                        if group_id and instance_date is not None:
                            cur.execute(
                                "INSERT IGNORE INTO repeat_skips "
                                "(user_id, repeat_group_id, instance_date) "
                                "VALUES (%s, %s, %s)",
                                (user_id, group_id, instance_date),
                            )

            # 3) 循环规则：按 updated_at 做 LWW（停止状态也走这里同步）
            if _merge_groups(conn, user_id, req.repeat_groups):
                changed = True

        # 4) 返回云端全部未删除任务 + 已删除的循环实例 + 全部循环规则
        return (
            [_row_to_out(r) for r in _all_remote(conn, user_id)],
            _all_skips(conn, user_id),
            _all_groups(conn, user_id),
            changed,
        )


def _prune_skips(conn, user_id: int) -> None:
    """清理过期的"已删除循环实例"记录。

    这些记录会随每次同步全量下发，日任务用久了能累积上千条，
    不清会让同步响应体持续膨胀。超过保留期的记录已无意义：
    引擎只会补"最近一期"，几个月前的期次不可能再被生成。
    """
    cutoff = (utc_now() - timedelta(days=REPEAT_SKIP_RETENTION_DAYS)).date()
    with conn.cursor() as cur:
        cur.execute(
            "DELETE FROM repeat_skips WHERE user_id=%s AND instance_date < %s",
            (user_id, cutoff),
        )


def _skip_keys(conn, user_id: int) -> set[tuple[str, str]]:
    """(repeat_group_id, YYYY-MM-DD) 集合：用户删过的循环实例。"""
    with conn.cursor() as cur:
        cur.execute(
            "SELECT repeat_group_id, instance_date FROM repeat_skips "
            "WHERE user_id=%s",
            (user_id,),
        )
        rows = cur.fetchall()
    keys: set[tuple[str, str]] = set()
    for row in rows:
        if isinstance(row, dict):
            gid = row.get("repeat_group_id")
            inst = row.get("instance_date")
        else:
            gid, inst = row[0], row[1]
        if gid and inst is not None:
            keys.add((str(gid), str(inst)))
    return keys


def _all_skips(conn, user_id: int) -> list[SkipItem]:
    """本用户所有被删除的循环实例（跨设备共享，客户端据此跳过补生成）。"""
    with conn.cursor() as cur:
        cur.execute(
            "SELECT repeat_group_id, instance_date FROM repeat_skips "
            "WHERE user_id=%s",
            (user_id,),
        )
        rows = cur.fetchall()
    result: list[SkipItem] = []
    for row in rows:
        if isinstance(row, dict):
            gid = row.get("repeat_group_id")
            inst = row.get("instance_date")
        else:
            gid, inst = row[0], row[1]
        if not gid or inst is None:
            continue
        result.append(SkipItem(repeat_group_id=str(gid), instance_date=str(inst)))
    return result


# ---------------- 常规增删改查 ----------------
@router.get("", response_model=list[TaskOut])
def list_tasks(user_id: int = Depends(get_current_user)):
    with get_conn() as conn:
        rows = _all_remote(conn, user_id)
    return [_row_to_out(r) for r in rows]


@router.post("", response_model=TaskOut, status_code=201)
def create_task(req: TaskCreate, user_id: int = Depends(get_current_user)):
    now = utc_now()
    created = req.created_at or now
    with get_conn() as conn:
        with transaction(conn):
            with conn.cursor() as cur:
                cur.execute(
                    "INSERT INTO tasks (user_id, local_id, title, status, urgency, "
                    "created_at, started_at, completed_at, plan_start_at, due_at, "
                    "sort_order, task_type, repeat_type, repeat_week_days, "
                    "repeat_month_day, repeat_group_id, instance_date, "
                    "updated_at, is_deleted) "
                    "VALUES (%s, NULL, %s, %s, %s, %s, NULL, NULL, %s, %s, %s, %s, "
                    "%s, %s, %s, %s, %s, %s, 0)",
                    (user_id, req.title, req.status, req.urgency,
                     to_utc_naive(created),
                     to_utc_naive(req.plan_start_at) if req.plan_start_at else None,
                     to_utc_naive(req.due_at) if req.due_at else None,
                     req.sort_order,
                     req.task_type,
                     req.repeat_type,
                     req.repeat_week_days,
                     req.repeat_month_day,
                     req.repeat_group_id,
                     req.instance_date,
                     now),
                )
                row_id = cur.lastrowid
        with conn.cursor() as cur:
            cur.execute(
                "SELECT * FROM tasks WHERE id = %s AND user_id = %s",
                (row_id, user_id),
            )
            row = cur.fetchone()
    return _row_to_out(row)


@router.patch("/{task_id}", response_model=TaskOut)
def update_task(
    task_id: int, req: TaskUpdate, user_id: int = Depends(get_current_user)
):
    fields: list[str] = []
    values: list = []
    if req.title is not None:
        fields.append("title=%s")
        values.append(req.title)
    if req.status is not None:
        fields.append("status=%s")
        values.append(req.status)
    if req.urgency is not None:
        fields.append("urgency=%s")
        values.append(req.urgency)
    if req.started_at is not None:
        fields.append("started_at=%s")
        values.append(to_utc_naive(req.started_at))
    if req.completed_at is not None:
        fields.append("completed_at=%s")
        values.append(to_utc_naive(req.completed_at))
    if req.plan_start_at is not None:
        fields.append("plan_start_at=%s")
        values.append(to_utc_naive(req.plan_start_at))
    if req.due_at is not None:
        fields.append("due_at=%s")
        values.append(to_utc_naive(req.due_at))
    if req.sort_order is not None:
        fields.append("sort_order=%s")
        values.append(req.sort_order)
    if req.task_type is not None:
        fields.append("task_type=%s")
        values.append(req.task_type)
    if req.repeat_type is not None:
        fields.append("repeat_type=%s")
        values.append(req.repeat_type)
    if req.repeat_week_days is not None:
        fields.append("repeat_week_days=%s")
        values.append(req.repeat_week_days)
    if req.repeat_month_day is not None:
        fields.append("repeat_month_day=%s")
        values.append(req.repeat_month_day)
    if req.repeat_group_id is not None:
        fields.append("repeat_group_id=%s")
        values.append(req.repeat_group_id)
    if req.instance_date is not None:
        fields.append("instance_date=%s")
        values.append(req.instance_date)
    fields.append("updated_at=%s")
    values.append(to_utc_naive(req.updated_at) if req.updated_at else utc_now())

    if not fields:
        raise HTTPException(status_code=400, detail="没有要更新的字段")

    values.extend([task_id, user_id])
    with get_conn() as conn:
        with transaction(conn):
            with conn.cursor() as cur:
                cur.execute(
                    f"UPDATE tasks SET {', '.join(fields)} "
                    "WHERE id=%s AND user_id=%s AND is_deleted=0",
                    values,
                )
                if cur.rowcount == 0:
                    raise HTTPException(status_code=404, detail="任务不存在")
                cur.execute(
                    "SELECT * FROM tasks WHERE id = %s AND user_id = %s",
                    (task_id, user_id),
                )
                row = cur.fetchone()
    return _row_to_out(row)


@router.delete("/{task_id}")
def delete_task(task_id: int, user_id: int = Depends(get_current_user)):
    """直接删除（REST 客户端用）：必须与同步接口的删除语义保持一致。

    只把 is_deleted 置 1 是旧实现，有两个后遗症：
    1) 软删行继续占着 uk_repeat(repeat_group_id, instance_date) 唯一键，
       同一期永远无法重新落库；
    2) 别的设备不知道这一期被删了，同步后还会各自补生成。
    """
    with get_conn() as conn:
        with transaction(conn):
            with conn.cursor() as cur:
                cur.execute(
                    "SELECT repeat_group_id, instance_date FROM tasks "
                    "WHERE id=%s AND user_id=%s AND is_deleted=0",
                    (task_id, user_id),
                )
                row = cur.fetchone()
                if not row:
                    raise HTTPException(status_code=404, detail="任务不存在")
                if isinstance(row, dict):
                    group_id = row.get("repeat_group_id")
                    instance_date = row.get("instance_date")
                else:
                    group_id, instance_date = row[0], row[1]

                cur.execute(
                    "UPDATE tasks SET is_deleted=1, updated_at=%s, "
                    "instance_date=NULL "
                    "WHERE id=%s AND user_id=%s",
                    (utc_now(), task_id, user_id),
                )
                if group_id and instance_date is not None:
                    cur.execute(
                        "INSERT IGNORE INTO repeat_skips "
                        "(user_id, repeat_group_id, instance_date) "
                        "VALUES (%s, %s, %s)",
                        (user_id, group_id, instance_date),
                    )
    return {"success": True}
