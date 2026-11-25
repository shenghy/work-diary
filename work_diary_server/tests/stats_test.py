"""/api/stats/me 口径测试：用假连接喂数据，逐条断言需求文档 5.3 的公式。

跑法：.venv/Scripts/python.exe tests/stats_test.py
不连数据库，所以和 smoke_test.py 分开——这个文件只关心聚合口径。
"""
import sys
from contextlib import contextmanager
from datetime import date, datetime, timedelta, timezone

sys.path.insert(0, ".")

from fastapi.testclient import TestClient

from app.main import app
from app.routers import stats
from app.security import create_token

PASS = 0
FAIL = 0

# 固定窗口，避免"今天"跟着真实日期漂移
WINDOW_FROM = "2026-11-04"
WINDOW_TO = "2026-11-10"
# 库内是 naive UTC；+8 换算到北京时间
CST = timezone(timedelta(hours=8))


def check(name: str, ok: bool, detail: str = "") -> None:
    global PASS, FAIL
    if ok:
        PASS += 1
        print(f"  [OK]   {name}")
    else:
        FAIL += 1
        print(f"  [FAIL] {name} {detail}")


def cst(text: str) -> datetime:
    """北京时间字符串 -> 库里存的 naive UTC。"""
    local = datetime.strptime(text, "%Y-%m-%d %H:%M").replace(tzinfo=CST)
    return local.astimezone(timezone.utc).replace(tzinfo=None)


def task(
    created,
    *,
    status=0,
    completed=None,
    due=None,
    urgency=0,
    task_type=1,
    repeat_type=0,
    instance_date=None,
    group_id=None,
):
    return {
        "created_at": cst(created),
        "completed_at": cst(completed) if completed else None,
        "due_at": cst(due) if due else None,
        "status": status,
        "urgency": urgency,
        "task_type": task_type,
        "repeat_type": repeat_type,
        "instance_date": instance_date,
        "repeat_group_id": group_id,
    }


TASKS: list[dict] = []
SKIPS: list[tuple[str, str]] = []


class FakeCursor:
    def __init__(self, log):
        self._rows = []
        self._log = log

    def execute(self, sql, params=None):
        self._log.append(sql.split()[0:4])
        if "FROM tasks" in sql:
            self._rows = list(TASKS)
        elif "FROM repeat_skips" in sql:
            self._rows = [
                {"repeat_group_id": g, "instance_date": d} for g, d in SKIPS
            ]
        else:
            self._rows = []

    def fetchall(self):
        return self._rows

    def __enter__(self):
        return self

    def __exit__(self, *exc):
        return False


class FakeConn:
    def __init__(self):
        self.log = []

    def cursor(self):
        return FakeCursor(self.log)

    def __enter__(self):
        return self

    def __exit__(self, *exc):
        return False


@contextmanager
def fake_conn():
    conn = FakeConn()
    try:
        yield conn
    finally:
        pass


stats.get_conn = fake_conn
client = TestClient(app, follow_redirects=False)
# 本地签一个 token 即可：这条链路只走 deps.get_current_user 的解码，不查 users 表
AUTH = {"Authorization": f"Bearer {create_token(1, 'stats@example.com')}"}


def reset() -> None:
    """每个用例都要清一次：60 秒缓存和按 IP 的限流计数会污染下一个断言。"""
    stats._cache.clear()
    stats._rate.clear()


def fetch(**params) -> dict:
    reset()
    query = {"from": WINDOW_FROM, "to": WINDOW_TO, **params}
    resp = client.get("/api/stats/me", headers=AUTH, params=query)
    assert resp.status_code == 200, resp.text
    return resp.json()


def raw(**params):
    reset()
    return client.get("/api/stats/me", params=params or {"from": "2026-13-99"})


def main() -> None:
    # 1) 未登录 -> 401
    TASKS.clear()
    resp = client.get("/api/stats/me")
    check("未登录返回 401", resp.status_code == 401, resp.text)

    # 2) 空账号：不出现 0/0，完成率给 null 而不是 0%
    data = fetch()
    check("空账号完成率为 null", data["summary"]["completion_rate"] is None)
    check("空账号耗时为 null", data["summary"]["avg_finish_median_hours"] is None)
    check("空账号趋势仍是 7 个桶", len(data["trend"]["buckets"]) == 7)
    check("空账号热力图 84 格", len(data["heatmap"]["days"]) == 84)
    check("空账号热力图 max=0", data["heatmap"]["max"] == 0)

    # 3) 验收项 3：1 完成 + 1 过期未完成 + 1 无到期日 -> 应完成 3、完成率 33%
    TASKS.extend(
        [
            task("2026-11-04 09:00", status=2, completed="2026-11-05 14:30",
                 due="2026-11-05 18:00", urgency=1, task_type=1),
            task("2026-11-03 10:00", due="2026-11-06 18:00"),
            task("2026-11-05 10:00"),  # 无到期日，按创建日计入应完成
        ]
    )
    data = fetch()
    s = data["summary"]
    check("已完成数 = 1", s["completed"] == 1, str(s))
    check("应完成数 = 3", s["due_total"] == 3, str(s))
    check("完成率 = 33", s["completion_rate"] == 33, str(s))
    check("未完成 = 2", s["undone"] == 2, str(s))

    # 4) 时区：北京时间 11-10 00:30 完成的任务要落在 11-10，而不是 11-09
    TASKS.append(
        task("2026-11-09 20:00", status=2, completed="2026-11-10 01:00",
             due="2026-11-10 12:00")
    )
    data = fetch()
    check("跨 UTC 日期的完成计入北京 11-10", data["summary"]["completed"] == 2,
          str(data["summary"]))
    check("时段按北京时间分桶（01:00 -> 1 点）", data["hours"][1] == 1,
          str(data["hours"]))
    check("UTC 17 点桶没有被误用", data["hours"][17] == 0, str(data["hours"]))

    # 5) 完成耗时：中位数、异常值剔除、样本不足
    TASKS.clear()
    TASKS.extend(
        [
            # 耗时 10 分钟 / 2 小时 / 1 天 / 40 天（异常值，剔除）
            task("2026-11-04 09:00", status=2, completed="2026-11-04 09:10"),
            task("2026-11-05 09:00", status=2, completed="2026-11-05 11:00"),
            task("2026-11-06 09:00", status=2, completed="2026-11-07 09:00"),
            task("2026-11-07 09:00", status=2, completed="2026-12-07 09:00"),
        ]
    )
    data = fetch()
    s = data["summary"]
    check("异常值不进样本（4 条完成只有 3 个样本）", s["finish_samples"] == 3, str(s))
    check("中位数 = 2 小时", s["avg_finish_median_hours"] == 2.0, str(s))
    check("最快 = 10 分钟", s["fastest_minutes"] == 10, str(s))
    check("最慢 = 1 天", s["slowest_days"] == 1.0, str(s))

    TASKS.clear()
    TASKS.append(task("2026-11-04 09:00", status=2, completed="2026-11-04 09:10"))
    s = fetch()["summary"]
    check("样本不足 3 条时耗时为 null", s["avg_finish_median_hours"] is None, str(s))
    check("样本不足 3 条时最快/最慢为 null",
          s["fastest_minutes"] is None and s["slowest_days"] is None, str(s))

    # 6) 环比：上一个等长窗口
    TASKS.clear()
    TASKS.extend(
        [
            task("2026-10-28 09:00", status=2, completed="2026-10-29 09:00"),
            task("2026-10-30 09:00", status=2, completed="2026-10-31 09:00"),
            task("2026-11-04 09:00", status=2, completed="2026-11-04 10:00"),
            task("2026-11-05 09:00", status=2, completed="2026-11-05 10:00"),
            task("2026-11-06 09:00", status=2, completed="2026-11-06 10:00"),
            task("2026-11-07 09:00", status=2, completed="2026-11-07 10:00"),
        ]
    )
    data = fetch()
    check("本窗口完成 4", data["summary"]["completed"] == 4, str(data["summary"]))
    check("上一窗口完成 2", data["summary"]["completed_prev"] == 2,
          str(data["summary"]))

    # 7) 连续打卡：今天没完成也从昨天起算
    TASKS.clear()
    TASKS.extend(
        [
            task("2026-11-07 09:00", status=2, completed="2026-11-07 10:00"),
            task("2026-11-08 09:00", status=2, completed="2026-11-08 10:00"),
            task("2026-11-09 09:00", status=2, completed="2026-11-09 10:00"),
            task("2026-11-01 09:00", status=2, completed="2026-11-01 10:00"),
        ]
    )
    data = fetch()
    check("连续打卡 3 天", data["summary"]["streak_days"] == 3, str(data["summary"]))
    check("历史最长 3 天", data["summary"]["streak_best"] == 3, str(data["summary"]))

    # 8) 热力图固定 12 周，不随范围胶囊变化
    TASKS.clear()
    TASKS.extend(
        [
            task("2026-11-01 09:00", status=2, completed="2026-11-04 09:00"),
            task("2026-11-04 09:00", status=2, completed="2026-11-04 10:00"),
            task("2026-11-05 09:00", status=2, completed="2026-11-05 10:00"),
        ]
    )
    wide = fetch(**{"from": "2026-11-09", "to": "2026-11-10"})
    check("范围切窄后热力图仍是 84 格", len(wide["heatmap"]["days"]) == 84)
    check("热力图起点是周一",
          date.fromisoformat(wide["heatmap"]["start"]).weekday() == 0)
    by_day = {d["date"]: d["count"] for d in wide["heatmap"]["days"]}
    check("窗口外的完成仍计入热力图", by_day.get("2026-11-04") == 2, str(by_day))
    check("热力图峰值 = 2", wide["heatmap"]["max"] == 2, str(wide["heatmap"]["max"]))
    check("热力图不随范围胶囊变化", fetch()["heatmap"] == wide["heatmap"])

    # 9) 任务构成与指标 1 同集合
    TASKS.clear()
    TASKS.extend(
        [
            task("2026-11-04 09:00", status=2, completed="2026-11-04 10:00",
                 task_type=1, urgency=0),
            task("2026-11-04 09:00", status=2, completed="2026-11-04 11:00",
                 task_type=0, urgency=1),
            task("2026-11-04 09:00", status=2, completed="2026-11-04 12:00",
                 task_type=1, urgency=2),
            task("2026-11-04 09:00", status=1),  # 未完成不进构成
        ]
    )
    data = fetch()
    total_by_type = sum(i["count"] for i in data["by_type"])
    check("类型合计 = 已完成数", total_by_type == data["summary"]["completed"],
          str(data["by_type"]))
    check("工作 2 / 个人 1",
          {i["type"]: i["count"] for i in data["by_type"]} == {"work": 2, "personal": 1},
          str(data["by_type"]))
    check("紧急度合计 = 已完成数",
          sum(i["count"] for i in data["by_urgency"]) == data["summary"]["completed"])

    # 10) 循环按期率：跳过不计分母、无到期日不计分母、迟完成不算按期
    TASKS.clear()
    TASKS.extend(
        [
            task("2026-11-04 09:00", status=2, completed="2026-11-04 10:00",
                 due="2026-11-04 18:00", repeat_type=1, instance_date=date(2026, 11, 4),
                 group_id="g1"),
            task("2026-11-05 09:00", status=2, completed="2026-11-05 20:00",
                 due="2026-11-05 18:00", repeat_type=1, instance_date=date(2026, 11, 5),
                 group_id="g1"),  # 超期完成
            task("2026-11-06 09:00", status=0, due="2026-11-06 18:00",
                 repeat_type=1, instance_date=date(2026, 11, 6), group_id="g1"),  # 没做
            task("2026-11-07 09:00", status=2, completed="2026-11-07 10:00",
                 repeat_type=1, instance_date=date(2026, 11, 7), group_id="g1"),  # 无到期日
            task("2026-11-08 09:00", status=2, completed="2026-11-08 10:00",
                 due="2026-11-08 18:00", repeat_type=1, instance_date=date(2026, 11, 8),
                 group_id="g1"),  # 该期被跳过
            task("2026-11-09 09:00", status=2, completed="2026-11-09 10:00",
                 due="2026-11-09 18:00", repeat_type=2, instance_date=date(2026, 11, 9),
                 group_id="g2"),
        ]
    )
    SKIPS.clear()
    SKIPS.append(("g1", "2026-11-08"))
    data = fetch()
    day = next(i for i in data["repeat_rate"] if i["kind"] == "day")
    check("日任务分母排除跳过/无到期日 = 3", day["total"] == 3, str(day))
    check("日任务按期 = 1（超期与未完成都不算）", day["done"] == 1, str(day))
    check("日任务按期率 33", day["rate"] == 33, str(day))
    week = next(i for i in data["repeat_rate"] if i["kind"] == "week")
    check("周任务 1/1 期 100%", (week["done"], week["total"], week["rate"]) == (1, 1, 100),
          str(week))
    month = next(i for i in data["repeat_rate"] if i["kind"] == "month")
    check("月任务空分母返回 null", (month["total"], month["rate"]) == (0, None), str(month))

    # 11) 趋势：近 90 天按周聚合
    TASKS.clear()
    TASKS.extend(
        [
            task("2026-11-04 09:00", status=2, completed="2026-11-05 09:00"),
            task("2026-11-05 09:00", status=2, completed="2026-11-05 10:00"),
        ]
    )
    data = fetch(**{"from": "2026-11-04", "to": "2026-11-10"}, granularity="week")
    check("按周聚合对齐到周一",
          data["trend"]["buckets"] == ["2026-11-02", "2026-11-09"], str(data["trend"]))
    check("按周新建 2 / 完成 2",
          data["trend"]["created"] == [2, 0] and data["trend"]["completed"] == [2, 0],
          str(data["trend"]))
    check("按周完成率 100 / 空桶 null",
          data["trend"]["completion_rate"] == [100, None], str(data["trend"]))

    data = fetch()
    check("按天完成率 = 完成/新建", data["trend"]["completion_rate"][1] == 200,
          str(data["trend"]))
    check("无新建的桶完成率为 null（不是 0）",
          data["trend"]["completion_rate"][2] is None, str(data["trend"]))

    # 12) 峰值时段
    TASKS.clear()
    TASKS.append(task("2026-11-04 09:00", status=2, completed="2026-11-04 10:00"))
    data = fetch()
    check("峰值时段取包含峰值小时的窗口", data["peak_hours"] == [10, 12],
          str(data["peak_hours"]))
    TASKS.clear()
    data = fetch()
    check("无数据时峰值时段为 null", data["peak_hours"] is None)

    # 13) 参数校验
    resp = client.get("/api/stats/me", headers=AUTH, params={"from": "2026-13-99"})
    check("非法日期 400", resp.status_code == 400, resp.text)
    resp = client.get("/api/stats/me", headers=AUTH, params={"granularity": "month"})
    check("非法粒度 422", resp.status_code == 422, resp.text)
    resp = client.get("/api/stats/me", headers=AUTH,
                      params={"from": "2026-11-10", "to": "2026-11-01"})
    check("from 晚于 to 返回 400", resp.status_code == 400, resp.text)
    reset()
    for _ in range(stats.RATE_LIMIT_PER_MINUTE + 1):
        resp = client.get("/api/stats/me", headers=AUTH)
    check("超过限流返回 429", resp.status_code == 429, resp.text)

    print(f"\n{PASS} passed, {FAIL} failed")
    sys.exit(1 if FAIL else 0)


if __name__ == "__main__":
    main()
