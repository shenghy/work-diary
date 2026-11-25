/**
 * 看板聚合口径测试（实现在 src/utils/util.js）：跑法 node tests/stats_test.mjs
 *
 * 夹具时间一律写成不带时区的本地串（'YYYY-MM-DDTHH:mm:ss'，日必须补零，
 * 否则 Date 解析不出来），这样 new Date() 按本地解析，任何机器上跑结果都一致。
 * 2026-11-13 是周五，它所在周的周一是 11-09，用它当"今天"方便验算按周分桶。
 */
import { computeStatsSnapshot } from '../src/utils/stats.js'

const NOW = new Date('2026-11-13T12:00:00')

let failed = 0
function eq(actual, expected, msg) {
  const a = JSON.stringify(actual)
  const e = JSON.stringify(expected)
  if (a !== e) {
    failed++
    console.log('FAIL ' + msg + '\n  期望 ' + e + '\n  实际 ' + a)
  } else {
    console.log('ok   ' + msg)
  }
}

function task(o) {
  return {
    id: o.id,
    title: o.title || '任务',
    status: o.status === undefined ? 0 : o.status,
    urgency: o.urgency || 0,
    task_type: o.task_type === undefined ? 1 : o.task_type,
    created_at: o.created_at,
    completed_at: o.completed_at || null,
    due_at: o.due_at || null,
    repeat_type: o.repeat_type || 0,
    instance_date: o.instance_date || null,
    repeat_group_id: o.repeat_group_id || null
  }
}

function run(tasks, opts = {}) {
  return computeStatsSnapshot({
    tasks,
    skips: opts.skips || {},
    rangeDays: opts.rangeDays === undefined ? 7 : opts.rangeDays,
    now: opts.now || NOW
  })
}

// ---------- A. 窗口 / 上期 / 完成率 / 未完成 ----------
{
  const snap = run([
    task({ id: 1, created_at: '2026-11-07T09:00:00', due_at: '2026-11-08T18:00:00', completed_at: '2026-11-08T10:00:00', status: 2 }),
    task({ id: 2, created_at: '2026-11-09T09:00:00' }),
    task({ id: 3, created_at: '2026-11-01T09:00:00', due_at: '2026-11-05T18:00:00', completed_at: '2026-11-05T12:00:00', status: 2 }),
    task({ id: 4, created_at: '2026-11-12T09:00:00', due_at: '2026-11-12T18:00:00', completed_at: '2026-11-12T11:00:00', status: 2 }),
    task({ id: 5, created_at: '2026-10-01T09:00:00', due_at: '2026-10-02T18:00:00', completed_at: '2026-10-02T10:00:00', status: 2 })
  ])
  eq(snap.range, { from: '2026-11-07', to: '2026-11-13', granularity: 'day', tz: 'local' }, 'A 窗口范围')
  eq(snap.summary.completed, 2, 'A 本期完成数（含无截止日按创建日落窗的任务2不计完成）')
  eq(snap.summary.completed_prev, 1, 'A 上期完成数')
  eq(snap.summary.due_total, 3, 'A 应完成数：有截止按截止日，无截止按创建日')
  eq(snap.summary.completion_rate, 67, 'A 完成率四舍五入')
  eq(snap.summary.undone, 1, 'A 未完成数')
}

// ---------- B. 耗时样本过滤与样本不足 ----------
{
  const base = [
    task({ id: 1, created_at: '2026-11-13T09:00:00', completed_at: '2026-11-13T09:10:00', status: 2 }),
    task({ id: 2, created_at: '2026-11-13T09:00:00', completed_at: '2026-11-13T09:30:00', status: 2 }),
    // 跨度 30 天以上：批量勾掉的陈年任务，不进中位数
    task({ id: 3, created_at: '2026-01-01T09:00:00', completed_at: '2026-11-13T09:00:00', status: 2 }),
    // 完成早于创建：时钟漂移，丢弃
    task({ id: 4, created_at: '2026-11-13T12:00:00', completed_at: '2026-11-13T10:00:00', status: 2 })
  ]
  const few = run(base)
  eq(few.summary.finish_samples, 2, 'B 异常样本被剔除后只剩 2 条')
  eq([few.summary.avg_finish_median_hours, few.summary.fastest_minutes, few.summary.slowest_days], [null, null, null], 'B 样本<3 三项一起为 null')

  const enough = run(base.concat([task({ id: 5, created_at: '2026-11-13T08:00:00', completed_at: '2026-11-13T10:00:00', status: 2 })]))
  eq(enough.summary.finish_samples, 3, 'B 满 3 条样本')
  eq(enough.summary.avg_finish_median_hours, 0.5, 'B 中位数 30 分钟 = 0.5 小时')
  eq(enough.summary.fastest_minutes, 10, 'B 最快')
  eq(enough.summary.slowest_days, 0.1, 'B 最慢 120 分钟 = 0.1 天')
}

// ---------- C. 打卡：今天没完成从昨天起算；最长看全历史 ----------
{
  const tasks = []
  for (let d = 8; d <= 12; d++) {
    const day = '2026-11-' + String(d).padStart(2, '0')
    tasks.push(task({ id: 100 + d, created_at: '2026-11-01T09:00:00', completed_at: day + 'T09:00:00', status: 2 }))
  }
  for (let d = 1; d <= 7; d++) {
    tasks.push(task({ id: 200 + d, created_at: '2026-09-01T09:00:00', completed_at: '2026-10-0' + d + 'T09:00:00', status: 2 }))
  }
  const snap = run(tasks)
  eq(snap.summary.streak_days, 5, 'C 今天(13)未完成，从 12 往前数到 8')
  eq(snap.summary.streak_best, 7, 'C 历史最长 7 天')
}

// ---------- D. 按周分桶：首桶周一对齐且能早于 start ----------
{
  const snap = run(
    [
      task({ id: 1, created_at: '2026-08-16T09:00:00' }),
      task({ id: 2, created_at: '2026-11-12T09:00:00', completed_at: '2026-11-13T09:00:00', status: 2 }),
      task({ id: 3, created_at: '2026-08-01T09:00:00', completed_at: '2026-11-02T09:00:00', status: 2 })
    ],
    { rangeDays: 90 }
  )
  eq(snap.range.granularity, 'week', 'D 近90天按周')
  eq(snap.trend.buckets[0], '2026-08-10', 'D 首桶是 8-16 所在周的周一')
  eq(snap.trend.created[0], 1, 'D 落在首个不完整周的创建被计入')
  const w1109 = snap.trend.buckets.indexOf('2026-11-09')
  eq([snap.trend.created[w1109], snap.trend.completed[w1109], snap.trend.completion_rate[w1109]], [1, 1, 100], 'D 11-09 周：新建1 完成1 完成率100')
  const w1102 = snap.trend.buckets.indexOf('2026-11-02')
  eq([snap.trend.created[w1102], snap.trend.completed[w1102], snap.trend.completion_rate[w1102]], [0, 1, null], 'D 只有完成没有新建的周，完成率是 null（断线）而不是 0')
}

// ---------- E. 热力图固定近 12 周 ----------
{
  const tasks = [
    task({ id: 1, created_at: '2026-11-13T09:00:00', completed_at: '2026-11-13T09:30:00', status: 2 }),
    task({ id: 2, created_at: '2026-11-13T09:00:00', completed_at: '2026-11-13T10:30:00', status: 2 }),
    task({ id: 3, created_at: '2026-01-01T09:00:00', completed_at: '2026-02-01T09:00:00', status: 2 })
  ]
  const week = run(tasks, { rangeDays: 7 })
  const all = run(tasks, { rangeDays: 0 })
  eq(week.heatmap.start, '2026-08-24', 'E 起点是今天所在周周一(11-09)往前 11 周')
  eq(week.heatmap.days.length, 84, 'E 84 格')
  eq(week.heatmap.max, 2, 'E 单日最多 2 个')
  eq([all.heatmap.start, all.heatmap.max], [week.heatmap.start, week.heatmap.max], 'E 热力图不跟随范围胶囊')
  eq(week.heatmap.days[83].date, '2026-11-15', 'E 末格是 11-15（含本周末的未来空日）')
}

// ---------- F. 循环任务按期率 ----------
{
  const tasks = [
    task({ id: 1, repeat_type: 1, repeat_group_id: 'g1', instance_date: '2026-11-10', due_at: '2026-11-10T18:00:00', completed_at: '2026-11-10T17:00:00', status: 2 }),
    task({ id: 2, repeat_type: 1, repeat_group_id: 'g1', instance_date: '2026-11-11', due_at: '2026-11-11T18:00:00', completed_at: '2026-11-11T19:00:00', status: 2 }),
    // 跳过的期次不进分母
    task({ id: 3, repeat_type: 1, repeat_group_id: 'g1', instance_date: '2026-11-12', due_at: '2026-11-12T18:00:00', status: 0 }),
    // 没有到期日：谈不上按期，不进分母
    task({ id: 4, repeat_type: 1, repeat_group_id: 'g2', instance_date: '2026-11-13', status: 0 })
  ]
  const snap = run(tasks, { skips: { g1: ['2026-11-12'] } })
  eq(snap.repeat_rate[0], { kind: 'day', done: 1, total: 2, rate: 50 }, 'F 日任务：完成时刻<=到期时刻才算按期')
  eq(snap.repeat_rate[1], { kind: 'week', done: 0, total: 0, rate: null }, 'F 本周无排期 rate 为 null')
}

// ---------- G. 峰值时段与紧急占比 ----------
{
  const snap = run([
    task({ id: 1, created_at: '2026-11-13T08:00:00', completed_at: '2026-11-13T09:00:00', status: 2, urgency: 1 }),
    task({ id: 2, created_at: '2026-11-13T09:00:00', completed_at: '2026-11-13T10:00:00', status: 2 })
  ])
  eq(snap.peak_hours, [9, 11], 'G 连续两小时窗口，右端开区间')
  eq(snap.peak_urgent_share, 50, 'G 峰值时段紧急占比')
  eq(snap.hours.length, 24, 'G 小时桶恒为 24')
  const empty = run([task({ id: 3, created_at: '2026-11-13T08:00:00' })])
  eq([empty.peak_hours, empty.peak_urgent_share], [null, null], 'G 无完成记录时峰值为空')
}

// ---------- H. 全部范围取最早日期 ----------
{
  const snap = run(
    [task({ id: 1, created_at: '2026-11-01T09:00:00', due_at: '2025-05-05T18:00:00', completed_at: '2026-11-02T09:00:00', status: 2 })],
    { rangeDays: 0 }
  )
  eq(snap.range.from, '2025-05-05', 'H 起点取 created/completed/due 三者最早')
  eq(snap.range.granularity, 'week', 'H 全部按周')
}

// ---------- I. 空数据 ----------
{
  const snap = run([])
  eq(snap.is_blank, true, 'I 空态')
  eq(snap.summary.completion_rate, null, 'I 应完成为 0 时完成率 null')
  eq([snap.summary.streak_days, snap.summary.streak_best, snap.summary.undone], [0, 0, 0], 'I 零值')
  eq(snap.trend.buckets.length, 7, 'I 近 7 天恒为 7 个日桶')
  eq(run([], { rangeDays: 0 }).trend.buckets.length, 1, 'I 无任务时"全部"塌成今天一天')
}

console.log(failed ? '\n' + failed + ' 条失败' : '\n全部通过')
process.exit(failed ? 1 : 0)
