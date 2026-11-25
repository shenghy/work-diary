// 循环任务生成引擎（对齐 Flutter RepeatTaskEngine / RepeatFamily）
// 语义：只补"最近一期已到期但尚未生成"的实例，不预生成未来、不补更早缺失期
import { genLocalId } from './sync'
import { STOPPED_MARKER } from './storage'

const WEEKDAY_NAMES = ['周一', '周二', '周三', '周四', '周五', '周六', '周日']

// 周几归一化：JS getDay() 0=周日 → 7=周日，与 Dart weekday（1=周一..7=周日）对齐
function jsDay(d) {
  return d.getDay() === 0 ? 7 : d.getDay()
}

// 当月 day 号；若当月没有该日（31 号在 2 月），取当月最后一天（month0 为 0-based）
function monthDayOf(year, month0, day) {
  const c = new Date(year, month0, day)
  if (c.getMonth() !== month0) return new Date(year, month0 + 1, 0)
  return new Date(c.getFullYear(), c.getMonth(), c.getDate())
}

export function dateKey(d) {
  return `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, '0')}-${String(d.getDate()).padStart(2, '0')}`
}

export function parseWeekDays(raw) {
  const arr = Array.isArray(raw) ? raw : String(raw || '').split(',')
  const cleaned = [...new Set(arr.map((x) => parseInt(x, 10)).filter((x) => x >= 1 && x <= 7))]
  return cleaned.length ? cleaned.sort((a, b) => a - b) : [1]
}

export function sanitizeMonthDay(raw) {
  const d = parseInt(raw, 10)
  if (isNaN(d) || d < 1) return 1
  return d > 31 ? 31 : d
}

function ruleSkipDates(rule) {
  if (!rule) return []
  const raw = rule.skip_dates
  if (Array.isArray(raw)) return raw.map((x) => String(x))
  if (typeof raw === 'string' && raw) return raw.split(',').map((x) => x.trim()).filter(Boolean)
  return []
}

function isRuleStopped(rule) {
  if (!rule) return false
  return (
    rule.stopped === true ||
    rule.stopped === 1 ||
    rule.deleted === true ||
    rule.deleted === 1 ||
    ruleSkipDates(rule).includes(STOPPED_MARKER)
  )
}

// 创建循环任务时的初始实例日期（第一期）
export function initialInstanceDate(repeatType, weekDays, monthDay, now) {
  const t = new Date(now.getFullYear(), now.getMonth(), now.getDate())
  if (repeatType === 1) return t
  if (repeatType === 2) {
    const days = parseWeekDays(weekDays)
    for (let i = 0; i < 8; i++) {
      const d = new Date(t.getFullYear(), t.getMonth(), t.getDate() + i)
      if (days.includes(jsDay(d))) return d
    }
    return t
  }
  if (repeatType === 3) {
    const day = sanitizeMonthDay(monthDay)
    const thisMonth = monthDayOf(t.getFullYear(), t.getMonth(), day)
    if (thisMonth >= t) return thisMonth
    return monthDayOf(t.getFullYear(), t.getMonth() + 1, day)
  }
  return t
}

// 最近一个 <= today 的命中日
function dueDateFor(repeatType, weekDays, monthDay, today) {
  if (repeatType === 1) return today
  if (repeatType === 2) {
    const days = parseWeekDays(weekDays)
    for (let i = 0; i < 7; i++) {
      const d = new Date(today.getFullYear(), today.getMonth(), today.getDate() - i)
      if (days.includes(jsDay(d))) return d
    }
    return today
  }
  if (repeatType === 3) {
    return monthDayOf(today.getFullYear(), today.getMonth(), sanitizeMonthDay(monthDay))
  }
  return null
}

/**
 * 下一期的实例日期（用于"下次生成"提示）。
 * after 为本族最近一期实例日期：返回严格晚于它的第一个命中日；
 * after 为空时返回引擎下次会生成的那一期。正常任务返回 null。
 */
export function nextInstanceDate({ repeatType, weekDays, monthDay, now, after }) {
  const today = new Date(now.getFullYear(), now.getMonth(), now.getDate())
  if (!after) return dueDateFor(repeatType, weekDays, monthDay, today)
  const base = new Date(after.getFullYear(), after.getMonth(), after.getDate())
  if (repeatType === 1) return new Date(base.getFullYear(), base.getMonth(), base.getDate() + 1)
  if (repeatType === 2) {
    const days = parseWeekDays(weekDays)
    let d = new Date(base.getFullYear(), base.getMonth(), base.getDate() + 1)
    for (let i = 0; i < 15; i++) {
      if (days.includes(jsDay(d))) return d
      d = new Date(d.getFullYear(), d.getMonth(), d.getDate() + 1)
    }
    return null
  }
  if (repeatType === 3) {
    const day = sanitizeMonthDay(monthDay)
    let y = base.getFullYear()
    let m = base.getMonth()
    for (let i = 0; i < 24; i++) {
      const d = monthDayOf(y, m, day)
      if (d > base) return d
      m++
      if (m > 11) {
        m = 0
        y++
      }
    }
    return null
  }
  return null
}

// 把 ISO 时间的时分秒套用到目标日期
function applyDate(iso, date) {
  if (!iso) return null
  const t = new Date(iso)
  if (isNaN(t)) return null
  return new Date(date.getFullYear(), date.getMonth(), date.getDate(), t.getHours(), t.getMinutes(), t.getSeconds())
}

function buildInstance(template, date, now, sortOrder) {
  const plan = applyDate(template.plan_start_at, date)
  const due = applyDate(template.due_at, date)
  return {
    id: genLocalId(),
    remote_id: null,
    title: template.title,
    status: 0,
    urgency: Number.isInteger(template.urgency) ? template.urgency : 0,
    task_type: Number.isInteger(template.task_type) ? template.task_type : 1,
    plan_start_at: plan ? plan.toISOString() : null,
    due_at: due ? due.toISOString() : null,
    sort_order: sortOrder,
    repeat_type: template.repeat_type,
    // 生成时顺手规范配置，云端脏数据（越界星期/每月几号）不会一代代传染
    repeat_week_days: template.repeat_type === 2 ? parseWeekDays(template.repeat_week_days).join(',') : null,
    repeat_month_day: template.repeat_type === 3 ? sanitizeMonthDay(template.repeat_month_day) : null,
    repeat_group_id: template.repeat_group_id,
    instance_date: dateKey(date),
    started_at: null,
    completed_at: null,
    created_at: now.toISOString(),
    updated_at: now.toISOString()
  }
}

// 生成缺失实例；返回新增任务数组（幂等：已存在/未到期/已处理/已停止的期跳过）
// rules：循环任务规则库（键=repeat_group_id）。族模板来源 = 规则优先（规则即最新配置），
// 规则缺失的族再回退到现存实例中最早创建的一条——删除族内全部实例后仍能照常补生成。
// skips：跳过账本（键=族 ID，值=日期数组，可能含 STOP 哨兵）
export function generateMissing(tasks, rules, now, skips) {
  const today = new Date(now.getFullYear(), now.getMonth(), now.getDate())
  const ledger = skips || {}
  const groups = {}
  for (const gid of Object.keys(rules || {})) {
    const r = rules[gid]
    if (r && r.repeat_type > 0 && gid && !r.deleted) groups[gid] = r
  }
  for (const t of tasks) {
    if (t.repeat_type > 0 && t.repeat_group_id) {
      const old = groups[t.repeat_group_id]
      if (!old || new Date(t.created_at) < new Date(old.created_at)) {
        groups[t.repeat_group_id] = t
      }
    }
  }
  const latest = {}
  for (const t of tasks) {
    if (t.repeat_group_id && t.instance_date) {
      const d = new Date(String(t.instance_date).slice(0, 10) + 'T00:00:00')
      const old = latest[t.repeat_group_id]
      if (!old || d > old) latest[t.repeat_group_id] = d
    }
  }
  let minSort = 0
  for (const t of tasks) {
    if ((t.sort_order || 0) < minSort) minSort = t.sort_order
  }
  const out = []
  for (const gid of Object.keys(groups)) {
    const template = groups[gid]
    const rule = (rules || {})[gid]
    // 已停止循环：规则/旧实例都还在也不再生成新一期
    if ((ledger[gid] || []).includes(STOPPED_MARKER)) continue
    if (isRuleStopped(rule)) continue
    const due = dueDateFor(template.repeat_type, template.repeat_week_days, template.repeat_month_day, today)
    if (!due || due > today) continue
    // 用户主动删掉了这一期（仅删除本期）：不要再补回来
    const dueKey = dateKey(due)
    if ((ledger[gid] || []).includes(dueKey)) continue
    if (ruleSkipDates(rule).includes(dueKey)) continue
    const lt = latest[gid]
    if (lt && due <= lt) continue
    out.push(buildInstance(template, due, now, --minSort))
  }
  return out
}

/**
 * 同步下发实例过滤：只保留本机该收的期次。
 * 1) 本机账本标记已删除的期次：云端下发说明别的设备补生成后上传，丢弃；
 * 2) 已停止循环的族：只认本机已存在的期次，新补出来的一律丢弃。
 */
export function filterIncomingInstances(incoming, local, skips) {
  const ledger = skips || {}
  if (!Object.keys(ledger).length) return incoming
  const localKeys = new Set()
  ;(local || []).forEach((t) => {
    if (!t.repeat_group_id || !t.instance_date) return
    localKeys.add(t.repeat_group_id + '|' + String(t.instance_date).slice(0, 10))
  })
  return (incoming || []).filter((t) => {
    const gid = t.repeat_group_id
    const date = t.instance_date
    if (!gid || !date) return true
    const ledgerForGroup = ledger[gid]
    if (!ledgerForGroup || !ledgerForGroup.length) return true
    const key = gid + '|' + String(date).slice(0, 10)
    if (ledgerForGroup.includes(STOPPED_MARKER)) return localKeys.has(key)
    return !ledgerForGroup.includes(String(date).slice(0, 10))
  })
}

// 该实例的循环配置是否已经是目标配置
export function sameSchedule(task, repeatType, weekDays, monthDay) {
  if ((task.repeat_type || 0) !== repeatType) return false
  if (repeatType === 2) {
    const a = parseWeekDays(task.repeat_week_days)
    const b = parseWeekDays(weekDays)
    return a.length === b.length && a.every((x, i) => x === b[i])
  }
  if (repeatType === 3) return sanitizeMonthDay(task.repeat_month_day) === sanitizeMonthDay(monthDay)
  return true
}

// 把新的循环配置套到某条实例（只改 schedule 字段，不动标题/时间/状态）
export function applySchedule(task, repeatType, weekDays, monthDay, now) {
  return {
    ...task,
    repeat_type: repeatType,
    repeat_week_days: repeatType === 2 ? parseWeekDays(weekDays).join(',') : null,
    repeat_month_day: repeatType === 3 ? sanitizeMonthDay(monthDay) : null,
    updated_at: (now || new Date()).toISOString()
  }
}

// 循环任务族 ID：时间戳 + 随机数
export function genGroupId() {
  const now = Date.now().toString(16)
  let r = ''
  for (let i = 0; i < 8; i++) r += Math.floor(Math.random() * 16).toString(16)
  return now + r
}

// ---------------- 展示文案（对齐 repeat_format.dart） ----------------

export function weekdayLabel(day) {
  return day >= 1 && day <= 7 ? WEEKDAY_NAMES[day - 1] : ''
}

function weekdayShort(day) {
  return day >= 1 && day <= 7 ? WEEKDAY_NAMES[day - 1].slice(1) : ''
}

export function repeatRuleLabel(repeatType, weekDays, monthDay) {
  if (repeatType === 1) return '每日'
  if (repeatType === 2) {
    const days = [...new Set(parseWeekDays(weekDays))].sort((a, b) => a - b)
    if (!days.length) return '每周'
    if (days.length === 5 && days.every((d) => d <= 5)) return '工作日'
    return '每周' + days.map(weekdayShort).join('、')
  }
  if (repeatType === 3) return '每月' + sanitizeMonthDay(monthDay) + '日'
  return '不循环'
}

export function shortDate(d) {
  return d.getMonth() + 1 + '/' + d.getDate()
}

export function shortDateWithWeekday(d) {
  return shortDate(d) + ' ' + weekdayLabel(jsDay(d))
}

export function clockLabel(iso) {
  if (!iso) return ''
  const t = new Date(iso)
  if (isNaN(t)) return ''
  return String(t.getHours()).padStart(2, '0') + ':' + String(t.getMinutes()).padStart(2, '0')
}

export function formatDueDate(date, planStartAt) {
  const time = clockLabel(planStartAt)
  const base = shortDateWithWeekday(date)
  return time ? base + ' ' + time : base
}

// ---------------- 族汇总（对齐 RepeatFamily.build） ----------------

export function buildRepeatFamilies(tasks, rules, now, skips) {
  const ledger = skips || {}
  const ruleByGroup = {}
  const deletedGroups = new Set()
  Object.keys(rules || {}).forEach((gid) => {
    const r = rules[gid]
    if (!gid || !r || r.repeat_type <= 0) return
    if (r.deleted) {
      deletedGroups.add(gid)
      return
    }
    ruleByGroup[gid] = r
  })

  const instances = {}
  ;(tasks || []).forEach((t) => {
    const gid = t.repeat_group_id
    if (!gid || t.repeat_type <= 0) return
    if (!instances[gid]) instances[gid] = []
    instances[gid].push(t)
  })

  const groupIds = [...new Set([...Object.keys(ruleByGroup), ...Object.keys(instances)])]
  const result = []
  groupIds.forEach((gid) => {
    if (deletedGroups.has(gid)) return
    const rule = ruleByGroup[gid]
    const list = instances[gid] || []
    let template = null
    list.forEach((t) => {
      if (!template || new Date(t.created_at) < new Date(template.created_at)) template = t
    })
    if (!rule && !template) return

    const repeatType = rule ? rule.repeat_type : template.repeat_type
    const weekDays = rule ? rule.repeat_week_days : template.repeat_week_days
    const monthDay = rule ? rule.repeat_month_day : template.repeat_month_day
    const planStartAt = rule ? rule.plan_start_at : template.plan_start_at
    const title = rule ? rule.title : template.title

    let latest = null
    let unfinished = 0
    list.forEach((t) => {
      if (t.status !== 2) unfinished++
      if (!t.instance_date) return
      const day = new Date(String(t.instance_date).slice(0, 10) + 'T00:00:00')
      if (!latest || day > latest) latest = day
    })

    const stopped = isRuleStopped(rule) || (ledger[gid] || []).includes(STOPPED_MARKER)
    const next = stopped ? null : nextInstanceDate({ repeatType, weekDays, monthDay, now, after: latest })

    result.push({
      groupId: gid,
      title,
      repeatType,
      weekDays,
      monthDay,
      planStartAt,
      stopped,
      hasRule: !!rule,
      total: list.length,
      unfinished,
      latest,
      next,
      rule: rule || null
    })
  })

  // 进行中的排在前面；同组内按下一次生成时间升序
  result.sort((a, b) => {
    if (a.stopped !== b.stopped) return a.stopped ? 1 : -1
    if (a.next && b.next && a.next.getTime() !== b.next.getTime()) return a.next - b.next
    if (!a.next && b.next) return 1
    if (a.next && !b.next) return -1
    return String(a.title).localeCompare(String(b.title))
  })
  return result
}
