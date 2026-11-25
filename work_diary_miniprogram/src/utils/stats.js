/**
 * 个人数据看板本地聚合：口径与桌面端 utils/stats_calculator.dart 一致。
 *
 * 纯函数、无依赖，方便 Node 直接跑测试（tests/stats_test.mjs）。
 * 分桶一律用 'YYYY-MM-DD' 字符串比较：ISO 日期串字典序即时间序，
 * 既避开了 Date 跨时区/夏令时的坑，也能直接当热力图和跳过账本的 key。
 */
export const HEATMAP_WEEKS = 12

const FINISH_SAMPLE_MAX_DAYS = 30
const FINISH_MIN_SAMPLES = 3

const DAY_MS = 86400000

function pad(n) {
  return (n < 10 ? '0' : '') + n
}

function keyOf(d) {
  return d.getFullYear() + '-' + pad(d.getMonth() + 1) + '-' + pad(d.getDate())
}

function dayStart(d) {
  return new Date(d.getFullYear(), d.getMonth(), d.getDate())
}

function addDays(d, n) {
  // 用中午起算再加天数，避开某些时区下整天加减落到 23 小时的边界
  return dayStart(new Date(d.getFullYear(), d.getMonth(), d.getDate() + n))
}

function diffDays(a, b) {
  return Math.round((b.getTime() - a.getTime()) / DAY_MS)
}

function mondayOf(d) {
  return addDays(d, -((d.getDay() + 6) % 7))
}

function between(key, startKey, endKey) {
  return key >= startKey && key <= endKey
}

function parseTime(raw) {
  if (!raw) return null
  const d = new Date(raw)
  return isNaN(d.getTime()) ? null : d
}

// instance_date 是纯日期（'YYYY-MM-DD'），补成本地零点，避免被当成 UTC 少一天
function parseDay(raw) {
  if (!raw) return null
  const s = String(raw).slice(0, 10)
  const parts = s.split('-')
  if (parts.length !== 3) return null
  const d = new Date(Number(parts[0]), Number(parts[1]) - 1, Number(parts[2]))
  return isNaN(d.getTime()) ? null : d
}

function toRow(t) {
  return {
    status: Number(t.status) || 0,
    urgency: Number(t.urgency) || 0,
    taskType: t.task_type === null || t.task_type === undefined ? 1 : Number(t.task_type),
    createdAt: parseTime(t.created_at),
    completedAt: parseTime(t.completed_at),
    dueAt: parseTime(t.due_at),
    instanceDate: parseDay(t.instance_date),
    repeatType: Number(t.repeat_type) || 0,
    groupId: t.repeat_group_id || null
  }
}

function round1(v) {
  return Math.round(v * 10) / 10
}

function median(values) {
  if (!values.length) return 0
  const ordered = values.slice().sort((a, b) => a - b)
  const mid = Math.floor(ordered.length / 2)
  return ordered.length % 2 ? ordered[mid] : (ordered[mid - 1] + ordered[mid]) / 2
}

function earliestKey(rows) {
  let earliest = null
  rows.forEach((r) => {
    ;[r.createdAt, r.completedAt, r.dueAt].forEach((d) => {
      if (!d) return
      const key = keyOf(d)
      if (!earliest || key < earliest) earliest = key
    })
  })
  return earliest
}

function streak(days, endKey) {
  let cursor = new Date(endKey + 'T00:00:00')
  if (!days.has(keyOf(cursor))) cursor = addDays(cursor, -1)
  let count = 0
  while (days.has(keyOf(cursor))) {
    count += 1
    cursor = addDays(cursor, -1)
  }
  return count
}

function bestStreak(days) {
  if (!days.size) return 0
  const ordered = Array.from(days).sort()
  let best = 1
  let run = 1
  for (let i = 1; i < ordered.length; i++) {
    const prev = new Date(ordered[i - 1] + 'T00:00:00')
    const cur = new Date(ordered[i] + 'T00:00:00')
    run = diffDays(prev, cur) === 1 ? run + 1 : 1
    if (run > best) best = run
  }
  return best
}

/**
 * 连续 2 小时的峰值窗口，返回 [起始时, 结束时)，结束时是开区间。
 * 同分时取起点更贴近最高峰小时的窗口；不跨越 23 → 0。
 */
function peakHours(hours) {
  const total = hours.reduce((a, b) => a + b, 0)
  if (total <= 0) return null
  let peak = 0
  for (let h = 1; h < hours.length; h++) {
    if (hours[h] > hours[peak]) peak = h
  }
  let bestStart = 0
  let bestSum = -1
  let bestGap = -1
  for (let start = 0; start < 23; start++) {
    const sum = hours[start] + hours[start + 1]
    const gap = -Math.abs(start - peak)
    if (sum > bestSum || (sum === bestSum && gap > bestGap)) {
      bestStart = start
      bestSum = sum
      bestGap = gap
    }
  }
  return [bestStart, bestStart + 2]
}

/**
 * @param tasks   loadTasksCache() 的全量任务（含已完成，未删除）
 * @param skips   { groupId: ['YYYY-MM-DD', ...] }，跳过账本 ∪ 规则里的 skip_dates
 * @param rangeDays 7 / 30 / 90 / 0（0 = 全部）
 * @param now     可注入的当前时间，便于测试
 */
export function computeStatsSnapshot({ tasks = [], skips = {}, rangeDays = 7, now = new Date() } = {}) {
  const rows = (tasks || []).map(toRow)
  const reference = now instanceof Date ? now : new Date(now)

  const byWeek = !rangeDays || rangeDays > 30
  const end = dayStart(reference)
  let start
  if (!rangeDays) {
    const earliest = earliestKey(rows)
    start = earliest ? new Date(earliest + 'T00:00:00') : end
  } else {
    start = addDays(end, -(rangeDays - 1))
  }
  const startKey = keyOf(start)
  const endKey = keyOf(end)
  const length = diffDays(start, end) + 1
  const prevEnd = addDays(start, -1)
  const prevStart = addDays(prevEnd, -(length - 1))
  const prevStartKey = keyOf(prevStart)
  const prevEndKey = keyOf(prevEnd)
  const heatStart = addDays(mondayOf(end), -7 * (HEATMAP_WEEKS - 1))

  const completed = rows.filter(
    (r) => r.status === 2 && r.completedAt && between(keyOf(r.completedAt), startKey, endKey)
  )
  const completedPrev = rows.filter(
    (r) => r.status === 2 && r.completedAt && between(keyOf(r.completedAt), prevStartKey, prevEndKey)
  )

  let dueTotal = 0
  rows.forEach((r) => {
    const day = r.dueAt ? keyOf(r.dueAt) : r.createdAt ? keyOf(r.createdAt) : null
    if (day && between(day, startKey, endKey)) dueTotal += 1
  })

  // inMinutes 取整，与桌面端 Duration.inMinutes 一致；负值和超过 30 天的样本都不进统计
  const durations = []
  completed.forEach((r) => {
    if (!r.createdAt) return
    const minutes = Math.trunc((r.completedAt.getTime() - r.createdAt.getTime()) / 60000)
    if (minutes < 0 || minutes > FINISH_SAMPLE_MAX_DAYS * 24 * 60) return
    durations.push(minutes)
  })
  const enough = durations.length >= FINISH_MIN_SAMPLES
  const medianHours = enough ? round1(median(durations) / 60) : null
  const fastestMinutes = enough ? Math.round(Math.min.apply(null, durations)) : null
  const slowestDays = enough ? round1(Math.max.apply(null, durations) / 60 / 24) : null

  // 打卡天数看全历史，不受范围胶囊影响
  const completedDays = new Set()
  rows.forEach((r) => {
    if (r.status === 2 && r.completedAt) completedDays.add(keyOf(r.completedAt))
  })

  const buckets = []
  if (!byWeek) {
    for (let i = 0; i <= diffDays(start, end); i++) buckets.push(addDays(start, i))
  } else {
    let cursor = mondayOf(start)
    while (cursor.getTime() <= end.getTime()) {
      buckets.push(cursor)
      cursor = addDays(cursor, 7)
    }
  }
  const bucketKeyOf = (dayKey) => {
    if (!byWeek) return dayKey
    return keyOf(mondayOf(new Date(dayKey + 'T00:00:00')))
  }
  const createdCount = {}
  const doneCount = {}
  buckets.forEach((b) => {
    createdCount[keyOf(b)] = 0
    doneCount[keyOf(b)] = 0
  })
  rows.forEach((r) => {
    // 先按任务自己的日子判断是否落窗，再归到桶（按周时首个桶可能早于 start）
    if (r.createdAt && between(keyOf(r.createdAt), startKey, endKey)) {
      const key = bucketKeyOf(keyOf(r.createdAt))
      if (createdCount[key] !== undefined) createdCount[key] += 1
    }
    if (r.status === 2 && r.completedAt && between(keyOf(r.completedAt), startKey, endKey)) {
      const key = bucketKeyOf(keyOf(r.completedAt))
      if (doneCount[key] !== undefined) doneCount[key] += 1
    }
  })
  const trendCreated = buckets.map((b) => createdCount[keyOf(b)])
  const trendCompleted = buckets.map((b) => doneCount[keyOf(b)])
  const trendRate = buckets.map((b, i) =>
    trendCreated[i] ? Math.round((trendCompleted[i] / trendCreated[i]) * 100) : null
  )

  // 热力图固定近 12 周：跟着范围胶囊走会被稀释成一片空
  const perDayCount = {}
  rows.forEach((r) => {
    if (r.status === 2 && r.completedAt) {
      const key = keyOf(r.completedAt)
      perDayCount[key] = (perDayCount[key] || 0) + 1
    }
  })
  const heatDays = []
  for (let i = 0; i < HEATMAP_WEEKS * 7; i++) {
    const d = addDays(heatStart, i)
    heatDays.push({ date: keyOf(d), count: perDayCount[keyOf(d)] || 0 })
  }
  const heatCounts = heatDays.map((d) => d.count)
  const heatMax = heatCounts.length ? Math.max.apply(null, heatCounts) : 0

  const hours = new Array(24).fill(0)
  completed.forEach((r) => {
    hours[r.completedAt.getHours()] += 1
  })
  const peak = peakHours(hours)
  let peakUrgentShare = null
  if (peak) {
    let inRange = 0
    let urgent = 0
    completed.forEach((r) => {
      const h = r.completedAt.getHours()
      if (h < peak[0] || h >= peak[1]) return
      inRange += 1
      if (r.urgency !== 0) urgent += 1
    })
    peakUrgentShare = inRange ? Math.round((urgent / inRange) * 100) : null
  }

  const skipSets = {}
  Object.keys(skips || {}).forEach((gid) => {
    skipSets[String(gid)] = new Set((skips[gid] || []).map((d) => String(d).slice(0, 10)))
  })

  const repeatRate = [['day', 1], ['week', 2], ['month', 3]].map(([kind, repeatType]) => {
    let total = 0
    let done = 0
    rows.forEach((r) => {
      if (r.repeatType !== repeatType || !r.instanceDate) return
      const key = keyOf(r.instanceDate)
      if (!between(key, startKey, endKey)) return
      if (r.groupId && skipSets[String(r.groupId)] && skipSets[String(r.groupId)].has(key)) return
      // 没有到期日就谈不上"按期"，分母里也不要它
      if (!r.dueAt) return
      total += 1
      if (r.status === 2 && r.completedAt && r.completedAt.getTime() <= r.dueAt.getTime()) done += 1
    })
    return { kind, done, total, rate: total ? Math.round((done / total) * 100) : null }
  })

  const completionRate = dueTotal ? Math.round((completed.length / dueTotal) * 100) : null
  const undone = Math.min(Math.max(dueTotal - completed.length, 0), dueTotal)

  const snapshot = {
    range: {
      from: startKey,
      to: endKey,
      granularity: byWeek ? 'week' : 'day',
      tz: 'local'
    },
    summary: {
      completed: completed.length,
      completed_prev: completedPrev.length,
      completion_rate: completionRate,
      due_total: dueTotal,
      undone,
      streak_days: streak(completedDays, endKey),
      streak_best: bestStreak(completedDays),
      avg_finish_median_hours: medianHours,
      fastest_minutes: fastestMinutes,
      slowest_days: slowestDays,
      finish_samples: durations.length
    },
    trend: {
      buckets: buckets.map(keyOf),
      created: trendCreated,
      completed: trendCompleted,
      completion_rate: trendRate
    },
    heatmap: { start: keyOf(heatStart), days: heatDays, max: heatMax },
    by_type: [
      { type: 'work', count: completed.filter((r) => r.taskType === 1).length },
      { type: 'personal', count: completed.filter((r) => r.taskType === 0).length }
    ],
    by_urgency: [0, 1, 2].map((level) => ({
      urgency: level,
      count: completed.filter((r) => r.urgency === level).length
    })),
    repeat_rate: repeatRate,
    hours,
    peak_hours: peak,
    peak_urgent_share: peakUrgentShare,
    generated_at: reference.toISOString()
  }

  snapshot.is_blank =
    completed.length === 0 &&
    dueTotal === 0 &&
    trendCreated.every((v) => !v) &&
    trendCompleted.every((v) => !v) &&
    heatMax === 0 &&
    hours.every((v) => !v)

  return snapshot
}
