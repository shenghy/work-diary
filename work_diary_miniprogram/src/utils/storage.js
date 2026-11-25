/**
 * 任务/备忘本地缓存：离线可用 + 云端数据的本地镜像
 */
const TASKS_KEY = 'wd_tasks_cache'
const MEMOS_KEY = 'wd_memos_cache'

// 本地写代数：每次本地落盘 +1，云端响应落盘（fromCloud）不计。
// 同步模块据此判断"请求在飞期间本地是否又写过"，决定整包覆盖还是逐条合并。
let tasksGen = 0
let memosGen = 0

export function getTasksGen() {
  return tasksGen
}

export function getMemosGen() {
  return memosGen
}

export function loadTasksCache() {
  try {
    return uni.getStorageSync(TASKS_KEY) || []
  } catch (e) {
    return []
  }
}

export function saveTasksCache(tasks, opts) {
  if (!(opts && opts.fromCloud)) tasksGen++
  try {
    uni.setStorageSync(TASKS_KEY, tasks || [])
  } catch (e) {}
}

export function clearTasksCache() {
  try {
    uni.removeStorageSync(TASKS_KEY)
  } catch (e) {}
}

export function loadMemosCache() {
  try {
    return uni.getStorageSync(MEMOS_KEY) || []
  } catch (e) {
    return []
  }
}

export function saveMemosCache(memos, opts) {
  if (!(opts && opts.fromCloud)) memosGen++
  try {
    uni.setStorageSync(MEMOS_KEY, memos || [])
  } catch (e) {}
}

export function clearMemosCache() {
  try {
    uni.removeStorageSync(MEMOS_KEY)
  } catch (e) {}
}

// ---------------- 删除记录（同步时上报） ----------------
const TASKS_DEL_KEY = 'wd_tasks_deletions'
const MEMOS_DEL_KEY = 'wd_memos_deletions'

export function loadTasksDeletions() {
  try {
    return uni.getStorageSync(TASKS_DEL_KEY) || []
  } catch (e) {
    return []
  }
}

export function saveTasksDeletions(list) {
  try {
    uni.setStorageSync(TASKS_DEL_KEY, list || [])
  } catch (e) {}
}

export function loadMemosDeletions() {
  try {
    return uni.getStorageSync(MEMOS_DEL_KEY) || []
  } catch (e) {
    return []
  }
}

export function saveMemosDeletions(list) {
  try {
    uni.setStorageSync(MEMOS_DEL_KEY, list || [])
  } catch (e) {}
}

// ---------------- 附件（云端元数据在本机的镜像 + 删除墓碑） ----------------
// 文件原件存在 wxfile://usr/attachments/<uid>/ 下，这里只存"有哪些附件、
// 各自在哪台机器上"。字段命名与服务端 AttachmentOut 保持一致，少一层翻译。
const ATTACHMENTS_KEY = 'wd_attachments_cache'
const ATTACHMENTS_DEL_KEY = 'wd_attachments_deletions'

function toBool(v) {
  return v === true || v === 1
}

// 容错解析：单条脏数据不能让整批附件丢失（与循环规则同一套做法）
export function normalizeAttachment(raw) {
  if (!raw || typeof raw !== 'object') return null
  const uid = String(raw.uid || '')
  if (!uid) return null
  const created = raw.created_at || new Date().toISOString()
  return {
    uid,
    parent_kind: raw.parent_kind === 'memo' ? 'memo' : 'task',
    parent_local_id: Number.isInteger(raw.parent_local_id) ? raw.parent_local_id : null,
    parent_remote_id: Number.isInteger(raw.parent_remote_id) ? raw.parent_remote_id : null,
    owner_device_id: String(raw.owner_device_id || ''),
    owner_device_name: String(raw.owner_device_name || ''),
    file_name: String(raw.file_name || '附件'),
    file_size: Number(raw.file_size) > 0 ? Number(raw.file_size) : 0,
    sha256: String(raw.sha256 || '').toLowerCase(),
    mime: String(raw.mime || ''),
    is_screenshot: toBool(raw.is_screenshot),
    orphaned: toBool(raw.orphaned),
    // 云端换了内容、本机还是旧原件：本地字段，不上报（与桌面端 staleCopy 同一含义）
    stale_copy: toBool(raw.stale_copy),
    blob_state: String(raw.blob_state || 'none'),
    created_at: created,
    updated_at: raw.updated_at || created
  }
}

export function loadAttachmentsCache() {
  try {
    const raw = uni.getStorageSync(ATTACHMENTS_KEY) || []
    if (!Array.isArray(raw)) return []
    const out = []
    raw.forEach((item) => {
      const a = normalizeAttachment(item)
      if (a) out.push(a)
    })
    return out
  } catch (e) {
    return []
  }
}

export function saveAttachmentsCache(list) {
  try {
    uni.setStorageSync(ATTACHMENTS_KEY, list || [])
  } catch (e) {}
}

export function clearAttachmentsCache() {
  try {
    uni.removeStorageSync(ATTACHMENTS_KEY)
  } catch (e) {}
}

// 删除墓碑：{ uid, deleted_at }，同步时上报，云端确认后清掉
export function loadAttachmentDeletions() {
  try {
    const raw = uni.getStorageSync(ATTACHMENTS_DEL_KEY) || []
    if (!Array.isArray(raw)) return []
    return raw
      .filter((d) => d && d.uid)
      .map((d) => ({ uid: String(d.uid), deleted_at: d.deleted_at || new Date().toISOString() }))
  } catch (e) {
    return []
  }
}

export function saveAttachmentDeletions(list) {
  try {
    uni.setStorageSync(ATTACHMENTS_DEL_KEY, list || [])
  } catch (e) {}
}

// ---------------- 循环任务规则库（与实例分离持久化） ----------------
// 语义对齐桌面端：
//   - 规则 = 最新配置（日/周/月 + 标题/时间），上云走 repeat_groups
//   - 跳过账本 = 用户"仅删除本期"的日期 + STOP 停止哨兵，独立于规则存在
//   - 永久删除写 deleted 墓碑（终态），并清掉本机同族全部实例
const RULES_KEY = 'wd_repeat_rules'
const SKIPS_KEY = 'wd_repeat_skips'

export const STOPPED_MARKER = 'STOP'
export const SKIP_RETENTION_DAYS = 120

function parseSkipDates(raw) {
  if (Array.isArray(raw)) return raw.map((x) => String(x)).filter(Boolean)
  if (typeof raw === 'string' && raw) {
    return raw
      .split(',')
      .map((x) => x.trim())
      .filter(Boolean)
  }
  return []
}

function nowIso() {
  return new Date().toISOString()
}

// 容错解析：单条损坏不能让整批规则丢失
export function normalizeRepeatRule(raw, gid) {
  if (!raw || typeof raw !== 'object') return null
  const id = String(raw.repeat_group_id || gid || '')
  if (!id) return null
  return {
    repeat_group_id: id,
    title: raw.title || '',
    urgency: Number.isInteger(raw.urgency) ? raw.urgency : 0,
    task_type: Number.isInteger(raw.task_type) ? raw.task_type : 1,
    repeat_type: Number(raw.repeat_type) || 0,
    repeat_week_days: raw.repeat_week_days || null,
    repeat_month_day: raw.repeat_month_day === 0 || raw.repeat_month_day ? Number(raw.repeat_month_day) : null,
    plan_start_at: raw.plan_start_at || null,
    due_at: raw.due_at || null,
    skip_dates: parseSkipDates(raw.skip_dates),
    stopped: raw.stopped === true || raw.stopped === 1,
    deleted: raw.deleted === true || raw.deleted === 1,
    // 老数据没有 updated_at：给一个足够旧的时间，让云端规则能覆盖它
    updated_at: raw.updated_at || '1970-01-01T00:00:00.000Z'
  }
}

export function loadRepeatRules() {
  try {
    const raw = uni.getStorageSync(RULES_KEY) || {}
    const out = {}
    Object.keys(raw).forEach((gid) => {
      const rule = normalizeRepeatRule(raw[gid], gid)
      if (rule) out[gid] = rule
    })
    return out
  } catch (e) {
    return {}
  }
}

export function saveRepeatRules(rules) {
  try {
    const out = {}
    Object.keys(rules || {}).forEach((gid) => {
      const rule = normalizeRepeatRule(rules[gid], gid)
      if (rule) out[gid] = rule
    })
    uni.setStorageSync(RULES_KEY, out)
  } catch (e) {}
}

/**
 * 写入规则（覆盖写一份）。已有规则时，调用方未显式提供的状态字段保持原值，
 * 避免编辑任务时把"仅删除本期/停止循环"的记录放出来。
 */
export function putRepeatRule(rule) {
  if (!rule || !rule.repeat_group_id) return
  const rules = loadRepeatRules()
  const gid = rule.repeat_group_id
  const old = rules[gid]
  const next = normalizeRepeatRule(
    {
      ...rule,
      skip_dates: rule.skip_dates !== undefined ? rule.skip_dates : old ? old.skip_dates : [],
      stopped: rule.stopped !== undefined ? rule.stopped : old ? old.stopped : false,
      deleted: rule.deleted !== undefined ? rule.deleted : old ? old.deleted : false,
      updated_at: rule.updated_at || nowIso()
    },
    gid
  )
  if (!next) return
  rules[gid] = next
  saveRepeatRules(rules)
}

// ---------------- 跳过账本 ----------------

export function loadRepeatSkips() {
  try {
    const raw = uni.getStorageSync(SKIPS_KEY) || {}
    const out = {}
    Object.keys(raw).forEach((gid) => {
      if (Array.isArray(raw[gid])) out[gid] = raw[gid].map((x) => String(x))
    })
    return out
  } catch (e) {
    return {}
  }
}

export function saveRepeatSkips(skips) {
  try {
    const out = {}
    Object.keys(skips || {}).forEach((gid) => {
      const list = parseSkipDates(skips[gid])
      if (list.length) out[gid] = list
    })
    uni.setStorageSync(SKIPS_KEY, out)
  } catch (e) {}
}

function pruneSkipDates(list) {
  const cutoff = Date.now() - SKIP_RETENTION_DAYS * 24 * 60 * 60 * 1000
  return list.filter((s) => {
    if (s === STOPPED_MARKER) return true
    const t = Date.parse(s)
    return isNaN(t) || t >= cutoff
  })
}

// 用户"仅删除本期"：写独立账本，同时同步一份到规则内（规则可能不存在）
export function skipRepeatInstance(task) {
  const gid = task && task.repeat_group_id
  const date = task && task.instance_date
  if (!gid || !date) return
  const key = String(date).slice(0, 10)
  const skips = loadRepeatSkips()
  const list = skips[gid] || []
  if (!list.includes(key)) {
    list.push(key)
    skips[gid] = list
    saveRepeatSkips(skips)
  }
  const rules = loadRepeatRules()
  const rule = rules[gid]
  if (rule && !rule.skip_dates.includes(key)) {
    // 跳过记录属于数据而非配置：不更新 updated_at，避免无意义的 LWW 竞争
    rule.skip_dates = pruneSkipDates([...rule.skip_dates, key]).sort()
    saveRepeatRules(rules)
  }
}

// 停止循环：规则 stopped（随同步下发）+ 本地 STOP 哨兵兜底
export function stopRepeatGroup(groupId) {
  if (!groupId) return
  const rules = loadRepeatRules()
  const rule = rules[groupId]
  if (rule && !rule.stopped) {
    rule.stopped = true
    rule.updated_at = nowIso()
    saveRepeatRules(rules)
  }
  const skips = loadRepeatSkips()
  const list = skips[groupId] || []
  if (!list.includes(STOPPED_MARKER)) {
    list.push(STOPPED_MARKER)
    skips[groupId] = list
    saveRepeatSkips(skips)
  }
}

// 恢复循环：清掉规则 stopped 与 STOP 哨兵
export function resumeRepeatGroup(groupId) {
  if (!groupId) return
  const rules = loadRepeatRules()
  const rule = rules[groupId]
  if (rule && rule.stopped) {
    rule.stopped = false
    rule.updated_at = nowIso()
    saveRepeatRules(rules)
  }
  const skips = loadRepeatSkips()
  const list = skips[groupId] || []
  if (list.includes(STOPPED_MARKER)) {
    skips[groupId] = list.filter((x) => x !== STOPPED_MARKER)
    saveRepeatSkips(skips)
  }
}

// 永久删除：写终态墓碑（deleted + stopped），清本机同族实例。
// 返回被删掉的任务列表，调用方据此登记删除记录上云。
export function markRepeatGroupDeleted(groupId, baseRule) {
  if (!groupId) return []
  const rules = loadRepeatRules()
  const old = rules[groupId]
  const source = baseRule || old || { repeat_group_id: groupId }
  const tombstone = normalizeRepeatRule(
    {
      ...source,
      repeat_group_id: groupId,
      deleted: true,
      stopped: true,
      skip_dates: [...new Set([...(source.skip_dates || []), ...((old && old.skip_dates) || [])])].sort(),
      updated_at: nowIso()
    },
    groupId
  )
  rules[groupId] = tombstone
  saveRepeatRules(rules)

  const skips = loadRepeatSkips()
  const list = skips[groupId] || []
  if (!list.includes(STOPPED_MARKER)) {
    list.push(STOPPED_MARKER)
    skips[groupId] = list
    saveRepeatSkips(skips)
  }
  return deleteTasksOfGroup(groupId)
}

// 从本地缓存移除某族全部实例（含已完成），返回被移除的任务
export function deleteTasksOfGroup(groupId) {
  if (!groupId) return []
  const tasks = loadTasksCache()
  const kept = []
  const removed = []
  tasks.forEach((t) => {
    if (t.repeat_group_id === groupId) removed.push(t)
    else kept.push(t)
  })
  if (removed.length) saveTasksCache(kept)
  return removed
}

// ---------------- 云端下发合并 ----------------

function sameIsoNewer(a, b) {
  const ta = Date.parse(a) || 0
  const tb = Date.parse(b) || 0
  return ta > tb
}

/**
 * 合并云端跳过账本：并集 + 只保留最近 N 天（STOP 哨兵永久保留）
 */
export function mergeRepeatSkips(skips) {
  if (!skips || !Object.keys(skips).length) return
  const local = loadRepeatSkips()
  Object.keys(skips).forEach((gid) => {
    if (!gid) return
    const merged = [...new Set([...(local[gid] || []), ...parseSkipDates(skips[gid])])]
    const kept = pruneSkipDates(merged).sort()
    if (kept.length) local[gid] = kept
    else delete local[gid]
  })
  saveRepeatSkips(local)
}

/**
 * 合并云端规则：deleted 为终态；其余按 updated_at LWW。
 * 返回本次被墓碑确认永久删除的族 ID 列表（调用方用它过滤下发实例）。
 */
export function mergeRepeatRules(incomingRules) {
  const deletedGroups = []
  if (!incomingRules || !Object.keys(incomingRules).length) return deletedGroups
  const rules = loadRepeatRules()
  Object.keys(incomingRules).forEach((gid) => {
    if (!gid) return
    const incoming = normalizeRepeatRule(incomingRules[gid], gid)
    if (!incoming) return
    const existing = rules[gid]

    // 永久删除是终态：云端墓碑优先，本地再新的编辑也不能复活
    if (incoming.deleted) {
      deletedGroups.push(gid)
      rules[gid] = normalizeRepeatRule(
        {
          ...incoming,
          stopped: true,
          deleted: true,
          skip_dates: [...new Set([...incoming.skip_dates, ...((existing && existing.skip_dates) || [])])].sort()
        },
        gid
      )
      const skips = loadRepeatSkips()
      const list = skips[gid] || []
      if (!list.includes(STOPPED_MARKER)) {
        list.push(STOPPED_MARKER)
        skips[gid] = list
        saveRepeatSkips(skips)
      }
      deleteTasksOfGroup(gid)
      return
    }
    if (existing && existing.deleted) return

    // 本地更新（刚改过还没上传）保留本地，等下一轮同步；时间相同也以本地为准
    if (existing && !sameIsoNewer(incoming.updated_at, existing.updated_at)) return

    const merged = normalizeRepeatRule(
      {
        ...incoming,
        skip_dates: [...new Set([...incoming.skip_dates, ...((existing && existing.skip_dates) || [])])].sort()
      },
      gid
    )
    rules[gid] = merged
    saveRepeatRules(rules)

    // 云端停止状态落到本地哨兵（规则丢失时引擎只认哨兵）
    const skips = loadRepeatSkips()
    const list = skips[gid] || []
    if (merged.stopped || merged.deleted) {
      if (!list.includes(STOPPED_MARKER)) {
        list.push(STOPPED_MARKER)
        skips[gid] = list
        saveRepeatSkips(skips)
      }
    } else if (list.includes(STOPPED_MARKER)) {
      skips[gid] = list.filter((x) => x !== STOPPED_MARKER)
      saveRepeatSkips(skips)
    }
  })
  saveRepeatRules(rules)
  return deletedGroups
}
