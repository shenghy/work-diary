"""个人数据看板聚合：GET /api/stats/me。

口径见《个人数据看板-需求文档》5.3，只读 tasks / repeat_skips 两张现有表，
不新增表。库内时间是 naive UTC，所有分桶先换算到请求的 tz 再切日，
否则晚上八点以后完成的任务会被算进前一天。
"""
import time
from collections import defaultdict
from datetime import date, datetime, timedelta, timezone
from zoneinfo import ZoneInfo, ZoneInfoNotFoundError

from fastapi import APIRouter, Depends, HTTPException, Query, Request

from ..database import get_conn
from ..utils import utc_now
from .deps import get_current_user

router = APIRouter(prefix="/api/stats", tags=["stats"])

# 热力图固定近 12 周：范围胶囊切到"全部"也不跟着变，否则格子会被稀释成一片糊。
HEATMAP_WEEKS = 12
# 完成耗时超过 30 天的样本视为异常值（建了没管、后来批量勾掉），不进中位数。
FINISH_SAMPLE_MAX_DAYS = 30
# 中位数样本太少时数字没有意义，返回 null 让前端显示 --。
FINISH_MIN_SAMPLES = 3

_cache: dict[tuple, tuple[float, dict]] = {}
CACHE_TTL_SECONDS = 60

# 限流：与 AI 额度无关的纯读接口，按 IP 每分钟计数（沿用 admin 的 monotonic 写法）。
_rate: dict[str, tuple[int, float]] = {}
RATE_LIMIT_PER_MINUTE = 30


def resolve_tz(name: str):
    """IANA 时区解析，拿不到（精简镜像缺 tzdata）时退回东八区。"""
    try:
        return ZoneInfo(name)
    except (ZoneInfoNotFoundError, ValueError, OSError):
        return timezone(timedelta(hours=8))


def to_local(raw: datetime | None, tz) -> datetime | None:
    if raw is None:
        return None
    return raw.replace(tzinfo=timezone.utc).astimezone(tz)


def _parse_date(raw: str, field: str) -> date:
    try:
        return datetime.strptime(raw, "%Y-%m-%d").date()
    except ValueError:
        raise HTTPException(status_code=400, detail=f"{field} 需为 YYYY-MM-DD")


def _enforce_rate_limit(ip: str) -> None:
    """30 次/分钟/IP：纯读接口不占 AI 额度，只需要挡住轮询。"""
    now = time.monotonic()
    count, window_start = _rate.get(ip, (0, now))
    if now - window_start >= 60:
        count, window_start = 0, now
    count += 1
    _rate[ip] = (count, window_start)
    if count > RATE_LIMIT_PER_MINUTE:
        raise HTTPException(status_code=429, detail="请求过于频繁，请稍后再试")


def _median(values: list[float]) -> float | None:
    if not values:
        return None
    ordered = sorted(values)
    mid = len(ordered) // 2
    if len(ordered) % 2:
        return ordered[mid]
    return (ordered[mid - 1] + ordered[mid]) / 2


def _monday_of(day: date) -> date:
    return day - timedelta(days=day.weekday())


def _completed_rows(rows: list[dict], start: date, end: date) -> list[dict]:
    return [
        r
        for r in rows
        if r["status"] == 2
        and r["completed_date"] is not None
        and start <= r["completed_date"] <= end
    ]


def _due_total(rows: list[dict], start: date, end: date) -> int:
    """应完成数：有到期日的按到期日落窗，无到期日的按创建日落窗。"""
    total = 0
    for r in rows:
        if r["due_date"] is not None:
            if start <= r["due_date"] <= end:
                total += 1
        elif r["created_date"] is not None and start <= r["created_date"] <= end:
            total += 1
    return total


def _streak(dates: set[date], today: date) -> int:
    """从今天往前数连续有完成的天数；今天还没完成就从昨天起算，避免早上打开清零。"""
    cursor = today if today in dates else today - timedelta(days=1)
    days = 0
    while cursor in dates:
        days += 1
        cursor -= timedelta(days=1)
    return days


def _best_streak(dates: set[date]) -> int:
    if not dates:
        return 0
    best = 1
    run = 1
    previous = None
    for day in sorted(dates):
        if previous is not None and day - previous == timedelta(days=1):
            run += 1
        else:
            run = 1
        best = max(best, run)
        previous = day
    return best


def _trend_buckets(start: date, end: date, granularity: str) -> list[date]:
    """每个桶用起始日表示；按周时对齐到周一。"""
    if granularity != "week":
        return [start + timedelta(days=i) for i in range((end - start).days + 1)]
    first = _monday_of(start)
    buckets = []
    cursor = first
    while cursor <= end:
        buckets.append(cursor)
        cursor += timedelta(days=7)
    return buckets


def _bucket_key(day: date, granularity: str) -> date:
    return _monday_of(day) if granularity == "week" else day


def _peak_hours(hours: list[int]) -> list[int] | None:
    """完成数最高的连续 2 小时区间，返回 [起始时, 结束时]。

    结束时是开区间：9 点和 10 点两个桶 -> [9, 11]，前端直接念成「上午 9:00–11:00」。
    同分时选起点更贴近峰值小时的那个窗口，否则文案会滑到旁边一个空时段。
    """
    if sum(hours) <= 0:
        return None
    peak = max(range(24), key=lambda h: hours[h])
    best_start, best_score = 0, (-1, -1)
    for start in range(23):
        score = (hours[start] + hours[start + 1], -abs(start - peak))
        if score > best_score:
            best_start, best_score = start, score
    return [best_start, best_start + 2]


def _load_rows(conn, user_id: int, tz) -> list[dict]:
    """一次取回该账号全部未删除任务 + 跳过账本，后续分桶全在 Python 里做。"""
    with conn.cursor() as cur:
        cur.execute(
            "SELECT created_at, completed_at, due_at, status, urgency, "
            "task_type, repeat_type, instance_date, repeat_group_id "
            "FROM tasks WHERE user_id = %s AND is_deleted = 0",
            (user_id,),
        )
        raw = cur.fetchall()
        cur.execute(
            "SELECT repeat_group_id, instance_date FROM repeat_skips "
            "WHERE user_id = %s",
            (user_id,),
        )
        skips = {
            (r["repeat_group_id"], str(r["instance_date"])) for r in cur.fetchall()
        }

    rows = []
    for r in raw:
        created_local = to_local(r["created_at"], tz)
        completed_local = to_local(r["completed_at"], tz)
        due_local = to_local(r["due_at"], tz)
        instance_date = r["instance_date"]
        if isinstance(instance_date, datetime):
            instance_date = instance_date.date()
        elif instance_date is not None:
            instance_date = date.fromisoformat(str(instance_date))
        rows.append(
            {
                "created_at": created_local,
                "completed_at": completed_local,
                "due_at": due_local,
                "created_date": created_local.date() if created_local else None,
                "completed_date": completed_local.date() if completed_local else None,
                "due_date": due_local.date() if due_local else None,
                "status": r["status"],
                "urgency": r["urgency"],
                "task_type": r["task_type"],
                "repeat_type": r["repeat_type"],
                "instance_date": instance_date,
                "group_id": r["repeat_group_id"],
                "skipped": (r["repeat_group_id"], str(instance_date)) in skips
                if r["repeat_group_id"] and instance_date
                else False,
            }
        )
    return rows


@router.get("/me")
def my_stats(
    request: Request,
    date_from: str | None = Query(default=None, alias="from"),
    date_to: str | None = Query(default=None, alias="to"),
    granularity: str = Query(default="day", pattern="^(day|week)$"),
    tz_name: str = Query(default="Asia/Shanghai", alias="tz"),
    user_id: int = Depends(get_current_user),
):
    _enforce_rate_limit(request.client.host if request.client else "unknown")

    now_local = datetime.now(resolve_tz(tz_name))
    end = now_local.date()
    start = end - timedelta(days=6)
    if date_to:
        end = _parse_date(date_to, "to")
    if date_from:
        start = _parse_date(date_from, "from")
    if start > end:
        raise HTTPException(status_code=400, detail="from 不能晚于 to")

    cache_key = (user_id, start, end, granularity, tz_name)
    cached = _cache.get(cache_key)
    if cached and time.monotonic() - cached[0] < CACHE_TTL_SECONDS:
        return cached[1]

    tz = resolve_tz(tz_name)
    length = (end - start).days + 1
    prev_end = start - timedelta(days=1)
    prev_start = prev_end - timedelta(days=length - 1)
    heat_start = _monday_of(end) - timedelta(weeks=HEATMAP_WEEKS - 1)
    scan_from = min(prev_start, start, heat_start)

    with get_conn() as conn:
        all_rows = _load_rows(conn, user_id, tz)

    # 打卡天数要看全历史，其余口径只在扫描窗口内比较。
    completed_dates = {
        r["completed_date"]
        for r in all_rows
        if r["status"] == 2 and r["completed_date"]
    }
    rows = [r for r in all_rows if _touches_window(r, scan_from, end)]

    completed = _completed_rows(rows, start, end)
    completed_prev = _completed_rows(rows, prev_start, prev_end)
    due_total = _due_total(rows, start, end)

    durations = []
    for r in completed:
        span = r["completed_at"] - r["created_at"]
        minutes = span.total_seconds() / 60
        if minutes < 0 or minutes > FINISH_SAMPLE_MAX_DAYS * 24 * 60:
            continue
        durations.append(minutes)

    fastest = round(min(durations)) if len(durations) >= FINISH_MIN_SAMPLES else None
    slowest_days = (
        round(max(durations) / 60 / 24, 1)
        if len(durations) >= FINISH_MIN_SAMPLES
        else None
    )
    median_hours = (
        round(_median(durations) / 60, 1) if len(durations) >= FINISH_MIN_SAMPLES else None
    )
    mean_hours = (
        round(sum(durations) / len(durations) / 60, 1)
        if len(durations) >= FINISH_MIN_SAMPLES
        else None
    )

    buckets = _trend_buckets(start, end, granularity)
    created_by_bucket: dict[date, int] = defaultdict(int)
    completed_by_bucket: dict[date, int] = defaultdict(int)
    for r in rows:
        if r["created_date"] and start <= r["created_date"] <= end:
            created_by_bucket[_bucket_key(r["created_date"], granularity)] += 1
        if r["status"] == 2 and r["completed_date"] and start <= r["completed_date"] <= end:
            completed_by_bucket[_bucket_key(r["completed_date"], granularity)] += 1

    trend_created = [created_by_bucket[b] for b in buckets]
    trend_completed = [completed_by_bucket[b] for b in buckets]
    trend_rate = [
        round(completed_by_bucket[b] / created_by_bucket[b] * 100)
        if created_by_bucket[b]
        else None
        for b in buckets
    ]

    heat_days = [heat_start + timedelta(days=i) for i in range(HEATMAP_WEEKS * 7)]
    # 热力图固定近 12 周，不能跟着范围胶囊走：切到"近 7 天"时只剩 7 个格子有值，
    # 整张图会被稀释成一片空。
    per_day_count: dict[date, int] = defaultdict(int)
    for r in rows:
        if r["status"] == 2 and r["completed_date"]:
            per_day_count[r["completed_date"]] += 1
    heat_counts = [per_day_count[d] for d in heat_days]

    by_type = [
        {"type": "work", "count": sum(1 for r in completed if r["task_type"] == 1)},
        {"type": "personal", "count": sum(1 for r in completed if r["task_type"] == 0)},
    ]
    by_urgency = [
        {"urgency": level, "count": sum(1 for r in completed if r["urgency"] == level)}
        for level in (0, 1, 2)
    ]

    repeat_rate = []
    for kind, repeat_type in (("day", 1), ("week", 2), ("month", 3)):
        members = [
            r
            for r in rows
            if r["repeat_type"] == repeat_type
            and r["instance_date"]
            and start <= r["instance_date"] <= end
            and not r["skipped"]
            and r["due_date"] is not None
        ]
        done = [
            r
            for r in members
            if r["status"] == 2 and r["completed_at"] and r["completed_at"] <= r["due_at"]
        ]
        repeat_rate.append(
            {
                "kind": kind,
                "done": len(done),
                "total": len(members),
                "rate": round(len(done) / len(members) * 100) if members else None,
            }
        )

    hours = [0] * 24
    for r in completed:
        hours[r["completed_at"].hour] += 1

    peak = _peak_hours(hours)
    # 需求 4.7 的追加文案：峰值时段里「紧急 + 重要」占该时段完成数的比例。
    peak_urgent_share = None
    if peak:
        in_peak = [
            r
            for r in completed
            if peak[0] <= r["completed_at"].hour < peak[1]
        ]
        if in_peak:
            urgent = [r for r in in_peak if r["urgency"] in (1, 2)]
            peak_urgent_share = round(len(urgent) / len(in_peak) * 100)

    payload = {
        "range": {
            "from": start.isoformat(),
            "to": end.isoformat(),
            "granularity": granularity,
            "tz": tz_name,
        },
        "summary": {
            "completed": len(completed),
            "completed_prev": len(completed_prev),
            "completion_rate": round(len(completed) / due_total * 100)
            if due_total
            else None,
            "due_total": due_total,
            "undone": max(due_total - len(completed), 0),
            "streak_days": _streak(completed_dates, end),
            "streak_best": _best_streak(completed_dates),
            "avg_finish_hours": mean_hours,
            "avg_finish_median_hours": median_hours,
            "fastest_minutes": fastest,
            "slowest_days": slowest_days,
            "finish_samples": len(durations),
        },
        "trend": {
            "buckets": [b.isoformat() for b in buckets],
            "created": trend_created,
            "completed": trend_completed,
            "completion_rate": trend_rate,
        },
        "heatmap": {
            "start": heat_start.isoformat(),
            "days": [
                {"date": d.isoformat(), "count": c} for d, c in zip(heat_days, heat_counts)
            ],
            "max": max(heat_counts) if heat_counts else 0,
        },
        "by_type": by_type,
        "by_urgency": by_urgency,
        "repeat_rate": repeat_rate,
        "hours": hours,
        "peak_hours": peak,
        "peak_urgent_share": peak_urgent_share,
        "generated_at": utc_now().isoformat(),
    }
    _cache[cache_key] = (time.monotonic(), payload)
    return payload


def _touches_window(row: dict, start: date, end: date) -> bool:
    """与统计窗口无关的行直接丢掉，省掉后面几万次比较。"""
    for key in ("created_date", "completed_date", "due_date", "instance_date"):
        value = row[key]
        if value is not None and start <= value <= end:
            return True
    return False
