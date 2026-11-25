/**
 * 云同步模块：与桌面端一致，统一走 /sync 全量 LWW 合并
 *
 * 本地缓存是数据源；任何变更先改本地，再全量上报同步，
 * 服务端按 updated_at 较新者胜出合并，返回云端全量覆盖本地。
 */
import { api } from './api'
import { isLoggedIn } from './auth'
import {
  loadTasksCache,
  saveTasksCache,
  loadMemosCache,
  saveMemosCache,
  loadTasksDeletions,
  saveTasksDeletions,
  loadMemosDeletions,
  saveMemosDeletions,
  loadRepeatRules,
  loadRepeatSkips,
  normalizeRepeatRule,
  mergeRepeatRules,
  mergeRepeatSkips,
  getTasksGen,
  getMemosGen
} from './storage'
import { parseWeekDays, sanitizeMonthDay, filterIncomingInstances } from './repeat'
import { getClientId } from './ws'
import { showToast } from './util'
import { syncMetadata } from './attachment_sync'

// ---------------- 同步请求通道 ----------------

// 服务端 tasks.py:356 / memos.py:88 用 X-Client-Id 在 WS 广播里排除发起方。
// 不带这个头，本端每次写都会把自己唤醒（data_changed → pullCloud → 再上传），
// 桌面端 remote_sync_service.dart:31 是带的，这里对齐。
function clientHeaders() {
  return { 'X-Client-Id': getClientId() }
}

/**
 * 单飞通道：同一通道同一时刻只允许一个 /sync 在飞，后来的调用排队。
 *
 * 服务端 /sync 是"全量 LWW + 新记录 INSERT"。两条并发请求带同一条新循环规则时，
 * 后一条的 SELECT 看不到前一条尚未提交的 INSERT（各自独立连接），于是直接 INSERT
 * 撞 repeat_groups.uk_user_group → 1062；_merge_groups 没有捕获（只有 _insert_task
 * 吞 1062），异常冒泡成 HTTP 500，整轮事务回滚，下一轮再撞一次。
 * 表现就是真机上"同步偶发失败，过一会儿自己好了"。
 */
function createChannel() {
  let running = false
  let slot = null

  function drain() {
    if (running || !slot) return
    const job = slot
    slot = null
    running = true
    Promise.resolve()
      .then(() => job.work())
      .then(
        (v) => {
          running = false
          job.resolve(v)
        },
        (e) => {
          running = false
          job.reject(e)
        }
      )
      .then(() => drain())
  }

  return function schedule(work) {
    if (slot) {
      // 排队期间只保留最新快照：全量 LWW 下后一次上传的内容一定更新
      slot.work = work
      return slot.promise
    }
    let resolve
    let reject
    const promise = new Promise((res, rej) => {
      resolve = res
      reject = rej
    })
    slot = { work, promise, resolve, reject }
    drain()
    return promise
  }
}

const taskChannel = createChannel()
const memoChannel = createChannel()
const attachmentChannel = createChannel()

// ---------------- 任务 ----------------

// 本地 local_id 发号器（持久化、只增不减；与桌面端 max+1 递增方案保持兼容）
//
// 为什么不能用随机基址：桌面端/安卓端都用「本地已有最大 id + 1」发号，
// 本端一旦跳到 10 亿段，对端同步后 seed 的水位就正好落进本端号段，反而更容易撞号。
//
// 真正要修的是水位会「原地不动」：旧实现只在 seq 为 0 时 seed 一次，
// 于是新设备（空缓存）从 1 开始发号，而云端早就有 1..N；服务端按 local_id 匹配
// （routers/tasks.py:414），新设备的一条任务就会把另一台设备的同名 id 任务改掉，
// 且两端都看不出异常——属于静默数据损坏。
const SEQ_KEY = 'wd_local_id_seq'
const MAX_LOCAL_ID = 2147483000 // local_id 是 INT，留出安全边界

let seqCache = null
let seqSeeded = false

function seq() {
  if (seqCache === null) {
    const s = Number(uni.getStorageSync(SEQ_KEY))
    seqCache = s > 0 ? s : 0
  }
  return seqCache
}

function setSeq(v) {
  seqCache = v
  uni.setStorageSync(SEQ_KEY, v)
}

// 抬高水位（只增不减）
export function bumpLocalIdSeq(maxSeen) {
  const v = Number(maxSeen)
  if (!(v > 0)) return seq()
  if (v > seq()) setSeq(Math.min(v, MAX_LOCAL_ID))
  return seq()
}

// 从一批记录里取最大 local_id 抬高水位；删除台账的键是 local_id
function bumpFrom(list, key) {
  const k = key || 'id'
  let max = 0
  ;(list || []).forEach((item) => {
    const v = Number(item && item[k])
    if (v > max) max = v
  })
  bumpLocalIdSeq(max)
}

// 每轮只 seed 一次：发号前把本地缓存/删除台账见过的 id 都并进水位
function ensureSeeded() {
  if (seqSeeded) return
  seqSeeded = true
  bumpFrom(loadTasksCache())
  bumpFrom(loadMemosCache())
  bumpFrom(loadTasksDeletions(), 'local_id')
  bumpFrom(loadMemosDeletions(), 'local_id')
}

function nextLocalId(taken) {
  ensureSeeded()
  let id = seq() + 1
  const busy = taken instanceof Set ? taken : null
  while (busy && busy.has(id)) id += 1
  if (id > MAX_LOCAL_ID) id = MAX_LOCAL_ID
  setSeq(id)
  return id
}

// 生成本地临时 id（正整数递增，与桌面端一致，避免超出数据库 local_id INT 范围）
export function genLocalId() {
  return nextLocalId()
}

/**
 * 清洗存量数据：把本地缓存中 id 为负/null 的任务与备忘重新分配正整数 id。
 * （历史版本用 -Date.now() 生成 id，远超数据库 INT 范围导致同步失败；
 * 此函数幂等，正常数据不受影响，调用后这些任务即可正常上云。）
 */
export function normalizeLocalIds() {
  let changed = false
  const tasks = loadTasksCache()
  const memos = loadMemosCache()
  const busy = new Set()
  ;[tasks, memos].forEach((list) => {
    list.forEach((item) => {
      const id = Number(item.id)
      if (id > 0) busy.add(id)
    })
  })
  ;[tasks, memos].forEach((list) => {
    list.forEach((item) => {
      if (!item.id || item.id <= 0) {
        item.id = nextLocalId(busy)
        busy.add(item.id)
        changed = true
      }
    })
  })
  if (changed) {
    saveTasksCache(tasks)
    saveMemosCache(memos)
  }
}

function toTaskIn(t) {
  return {
    id: t.id || null,
    remote_id: t.remote_id || null,
    title: t.title,
    status: t.status,
    urgency: t.urgency,
    created_at: t.created_at,
    started_at: t.started_at || null,
    completed_at: t.completed_at || null,
    plan_start_at: t.plan_start_at || null,
    due_at: t.due_at || null,
    sort_order: t.sort_order || 0,
    task_type: t.task_type !== undefined ? t.task_type : 1,
    // 循环任务字段必须一起上报：服务端 TaskIn 对缺失字段用默认值 0/null 覆盖，
    // 漏发等于每次同步都把云端的循环规则清空一次。清空后本地实例失去
    // repeat_group_id / instance_date，repeat.js 会认为"本期还没生成"，
    // 于是每次同步后又补一条新任务（无限复制）。
    repeat_type: t.repeat_type || 0,
    repeat_week_days: t.repeat_week_days || null,
    repeat_month_day: t.repeat_month_day || null,
    repeat_group_id: t.repeat_group_id || null,
    instance_date: t.instance_date || null,
    updated_at: t.updated_at || t.created_at
  }
}

// 云端 TaskOut 归一化为本地对象
function fromTaskOut(o) {
  return {
    id: o.id,
    remote_id: o.remote_id,
    title: o.title,
    status: o.status,
    urgency: o.urgency,
    created_at: o.created_at,
    started_at: o.started_at,
    completed_at: o.completed_at,
    plan_start_at: o.plan_start_at,
    due_at: o.due_at,
    sort_order: o.sort_order,
    task_type: o.task_type,
    // 同上：漏掉这几个字段会让每一次同步都把本地循环实例退化成普通任务
    repeat_type: o.repeat_type || 0,
    repeat_week_days: o.repeat_week_days || null,
    repeat_month_day: o.repeat_month_day || null,
    repeat_group_id: o.repeat_group_id || null,
    instance_date: o.instance_date || null,
    updated_at: o.updated_at
  }
}

// 规则 → RepeatGroupIn（skip_dates 不走规则通道，服务端以 skip 表为准）
function toRepeatGroupIn(rule) {
  return {
    group_id: rule.repeat_group_id,
    title: rule.title || '',
    urgency: rule.urgency || 0,
    task_type: rule.task_type !== undefined ? rule.task_type : 1,
    repeat_type: rule.repeat_type,
    repeat_week_days: rule.repeat_type === 2 ? parseWeekDays(rule.repeat_week_days).join(',') : null,
    repeat_month_day: rule.repeat_type === 3 ? sanitizeMonthDay(rule.repeat_month_day) : null,
    plan_start_at: rule.plan_start_at || null,
    due_at: rule.due_at || null,
    stopped: !!rule.stopped,
    deleted: !!rule.deleted,
    updated_at: rule.updated_at || null
  }
}

function fromRepeatGroupOut(o) {
  return normalizeRepeatRule({ ...o, repeat_group_id: o.group_id }, o.group_id)
}

function mergeDeletionRecords(passed, stored) {
  const map = new Map()
  ;[...(stored || []), ...(passed || [])].forEach((d) => {
    if (!d || d.local_id === undefined || d.local_id === null) return
    map.set(d.local_id, { ...d })
  })
  return [...map.values()]
}

function isNewer(a, b) {
  return (Date.parse(a) || 0) > (Date.parse(b) || 0)
}

function sortTasks(list) {
  return [...list].sort((a, b) => {
    const d = (a.sort_order ?? 0) - (b.sort_order ?? 0)
    if (d !== 0) return d
    return (b.created_at || '').localeCompare(a.created_at || '')
  })
}

// 缓存是否比上传快照更新/多出记录：是则说明"调用方取快照"之后本地又写过
// （只看这个方向：快照领先缓存属于调用方尚未落盘的内存态，上传它正是本意）
function cacheAhead(snapshot, cache) {
  const map = new Map((snapshot || []).map((t) => [t.id, t.updated_at || t.created_at]))
  return (cache || []).some((t) => {
    if (!map.has(t.id)) return true
    return isNewer(t.updated_at || t.created_at, map.get(t.id))
  })
}

/**
 * 请求在飞期间本地又写过：不能整包覆盖，逐条按 updated_at 合并（新者胜、平局取本地）。
 * 本地独有记录（飞行期间新建/编辑）保留；云端独有记录（其它设备新增）并入；
 * 循环实例对齐服务端唯一索引：同族同期本地已有就不再收云端的，避免一期两条。
 */
function mergeTasksWithLocal(cloud, current, pendingIds, skips) {
  const byId = new Map(cloud.map((t) => [t.id, t]))
  const instanceKeys = new Set()
  ;(current || []).forEach((t) => {
    if (t.repeat_group_id && t.instance_date) {
      instanceKeys.add(t.repeat_group_id + '|' + String(t.instance_date).slice(0, 10))
    }
  })
  const merged = []
  ;(current || []).forEach((cur) => {
    if (pendingIds.has(cur.id)) return
    const c = byId.get(cur.id)
    if (c) byId.delete(cur.id)
    merged.push(c && isNewer(c.updated_at, cur.updated_at) ? c : cur)
  })
  filterIncomingInstances([...byId.values()], current, skips).forEach((t) => {
    const key = t.repeat_group_id + '|' + String(t.instance_date).slice(0, 10)
    if (t.repeat_group_id && t.instance_date && instanceKeys.has(key)) return
    merged.push(t)
  })
  return sortTasks(merged)
}

/**
 * 同步任务：上报本地全量 + 删除记录，返回云端全量
 * @param {Array} localTasks 本地任务列表
 * @param {Array} deletions  删除记录 [{local_id, remote_id, deleted_at}]
 */
export async function syncTasks(localTasks, deletions) {
  if (!isLoggedIn()) return null
  return taskChannel(() => pushTasksSync(localTasks, deletions))
}

async function pushTasksSync(localTasks, deletions) {
  const records = mergeDeletionRecords(deletions, loadTasksDeletions())
  const localRules = loadRepeatRules()
  const genAtStart = getTasksGen()
  const staleAtStart = cacheAhead(localTasks, loadTasksCache())

  const res = await api.post(
    '/api/tasks/sync',
    {
      tasks: (localTasks || []).map(toTaskIn),
      // remote_id 必填：新建后未完成同步即删除的记录暂不上报，收尾时从云端补 remote_id
      deletions: records
        .filter((d) => d.remote_id !== undefined && d.remote_id !== null)
        .map((d) => ({
          local_id: d.local_id,
          remote_id: d.remote_id,
          deleted_at: d.deleted_at || new Date().toISOString()
        })),
      repeat_groups: Object.values(localRules)
        .filter((r) => r && r.repeat_type > 0 && r.repeat_group_id)
        .map(toRepeatGroupIn)
    },
    { headers: clientHeaders() }
  )

  // 1) 先合并云端跳过账本（其它设备"仅删除本期"的记录）
  const cloudSkips = {}
  ;(res.skips || []).forEach((s) => {
    if (!s || !s.repeat_group_id || !s.instance_date) return
    if (!cloudSkips[s.repeat_group_id]) cloudSkips[s.repeat_group_id] = []
    cloudSkips[s.repeat_group_id].push(String(s.instance_date).slice(0, 10))
  })
  mergeRepeatSkips(cloudSkips)

  // 2) 合并云端规则（含停止状态/永久删除墓碑）
  const incomingRules = {}
  ;(res.repeat_groups || []).forEach((o) => {
    const rule = fromRepeatGroupOut(o)
    if (rule && rule.repeat_type > 0) incomingRules[rule.repeat_group_id] = rule
  })
  const deletedGroups = new Set(mergeRepeatRules(incomingRules))

  // 3) 过滤下发实例：本机删过的期次不复活；已停止的族只认本机已有期次
  const mergedSkips = loadRepeatSkips()
  let cloud = (res.tasks || [])
    .map(fromTaskOut)
    .filter((t) => !(t.repeat_group_id && deletedGroups.has(t.repeat_group_id)))
  cloud = filterIncomingInstances(cloud, localTasks || [], mergedSkips)

  // 4) 待同步删除记录收尾（响应时重读台账：飞行期间发生的删除也算 pending，不复活）
  const liveRecords = mergeDeletionRecords(deletions, loadTasksDeletions())
  const pendingIds = new Set()
  const nextRecords = []
  liveRecords.forEach((entry) => {
    pendingIds.add(entry.local_id)
    if (entry.remote_id !== undefined && entry.remote_id !== null) return
    const matched = cloud.find((t) => t.id === entry.local_id)
    if (matched) nextRecords.push({ ...entry, remote_id: matched.remote_id })
  })
  saveTasksDeletions(nextRecords)
  cloud = cloud.filter((t) => !pendingIds.has(t.id))

  // 云端返回顺序以 sort_order 为准（防御性排序）
  const sorted = sortTasks(cloud)
  // 见过的云端 local_id 全部并进水位：新设备/清缓存后也不会从 1 重新发号
  bumpFrom(sorted)
  if (!staleAtStart && getTasksGen() === genAtStart) {
    saveTasksCache(sorted, { fromCloud: true })
    return sorted
  }
  // 本地在飞期间写过：逐条合并保住未上报的新改动，再补推一轮让云端追上
  const merged = mergeTasksWithLocal(sorted, loadTasksCache(), pendingIds, loadRepeatSkips())
  bumpFrom(merged)
  saveTasksCache(merged, { fromCloud: true })
  taskChannel(() => pushTasksSync(loadTasksCache(), loadTasksDeletions())).catch(() => {})
  return merged
}

/**
 * 全量同步任务（供登录后/下拉刷新调用），返回云端全量
 */
export async function fullSyncTasks() {
  const local = loadTasksCache()
  return syncTasks(local, loadTasksDeletions())
}

// ---------------- 备忘 ----------------

function toMemoIn(m) {
  return {
    id: m.id || null,
    remote_id: m.remote_id || null,
    content: m.content,
    created_at: m.created_at,
    updated_at: m.updated_at || m.created_at
  }
}

function fromMemoOut(o) {
  return {
    id: o.id,
    remote_id: o.remote_id,
    content: o.content,
    created_at: o.created_at,
    updated_at: o.updated_at
  }
}

/**
 * 同步备忘：上报本地全量 + 删除记录，返回云端全量
 */
export async function syncMemos(localMemos, deletions) {
  if (!isLoggedIn()) return null
  return memoChannel(() => pushMemosSync(localMemos, deletions))
}

async function pushMemosSync(localMemos, deletions) {
  const records = mergeDeletionRecords(deletions, loadMemosDeletions())
  const genAtStart = getMemosGen()
  const staleAtStart = cacheAhead(localMemos, loadMemosCache())
  const res = await api.post(
    '/api/memos/sync',
    {
      memos: (localMemos || []).map(toMemoIn),
      deletions: records
        .filter((d) => d.remote_id !== undefined && d.remote_id !== null)
        .map((d) => ({
          local_id: d.local_id,
          remote_id: d.remote_id,
          deleted_at: d.deleted_at || new Date().toISOString()
        }))
    },
    { headers: clientHeaders() }
  )
  const cloud = (res.memos || []).map(fromMemoOut)

  // 新建后未同步即删除的记录：云端若返回同 local_id 的备忘就补上 remote_id 下轮删
  // （响应时重读台账：飞行期间发生的删除也算 pending，不复活）
  const liveRecords = mergeDeletionRecords(deletions, loadMemosDeletions())
  const nextRecords = []
  liveRecords.forEach((entry) => {
    if (entry.remote_id !== undefined && entry.remote_id !== null) return
    const matched = cloud.find((m) => m.id === entry.local_id)
    if (matched) nextRecords.push({ ...entry, remote_id: matched.remote_id })
  })
  saveMemosDeletions(nextRecords)

  // 别把刚删掉的备忘又从云端响应里放回来
  const pendingIds = new Set(liveRecords.map((d) => d.local_id))
  const kept = cloud.filter((m) => !pendingIds.has(m.id))
  bumpFrom(kept)
  if (!staleAtStart && getMemosGen() === genAtStart) {
    saveMemosCache(kept, { fromCloud: true })
    return kept
  }
  const byId = new Map(kept.map((m) => [m.id, m]))
  const merged = []
  loadMemosCache().forEach((cur) => {
    if (pendingIds.has(cur.id)) return
    const c = byId.get(cur.id)
    if (c) byId.delete(cur.id)
    merged.push(c && isNewer(c.updated_at, cur.updated_at) ? c : cur)
  })
  byId.forEach((m) => merged.push(m))
  bumpFrom(merged)
  saveMemosCache(merged, { fromCloud: true })
  memoChannel(() => pushMemosSync(loadMemosCache(), loadMemosDeletions())).catch(() => {})
  return merged
}

export async function fullSyncMemos() {
  const local = loadMemosCache()
  return syncMemos(local, loadMemosDeletions())
}

// ---------------- 附件 ----------------

/**
 * 附件元数据对账：必须在任务/备忘同步之后调用。
 *
 * 服务端按"父记录是否已入库"决定收不收这条附件元数据，先报附件只会拿到
 * 一个 rejected，然后被当成文件本身有问题提示用户——顺序错了就是假错误。
 * 本轮没报上去的下一轮自然补上（父 id 已经回填在本地记录里）。
 */
export function syncAttachments() {
  if (!isLoggedIn()) return Promise.resolve(null)
  return attachmentChannel(() => syncMetadata())
}

// ---------------- 通用 ----------------

/**
 * 带防抖的同步执行器：合并短时间内的连续变更
 */
export function createSyncer(syncFn, debounceMs = 800) {
  let timer = null
  let pending = false
  let running = false

  async function flush() {
    if (running) {
      pending = true
      return
    }
    running = true
    try {
      await syncFn()
    } catch (e) {
      showToast('同步失败：' + e.message)
    } finally {
      running = false
      if (pending) {
        pending = false
        timer = setTimeout(flush, 200)
      }
    }
  }

  return function schedule() {
    if (timer) clearTimeout(timer)
    timer = setTimeout(flush, debounceMs)
  }
}
