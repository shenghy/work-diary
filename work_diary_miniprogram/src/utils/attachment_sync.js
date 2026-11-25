/**
 * 附件同步：元数据全量 LWW + 文件按需中转。
 *
 * 与桌面端 attachment_sync_service.dart 同一套状态机（谁点同步谁把流程推到底）：
 * 目标端 /request → 服务器推 attachment_request 给源主机 → 源主机分片上传
 * → 服务器校验后推 attachment_ready → 目标端下载校验 → /ack → 服务器删文件。
 *
 * 进度放在模块内存里（uid→job），UI 通过 subscribe/onAttachmentsChanged 重绘；
 * 服务器侧的请求台账保留 TTL，所以小程序被微信挂起、源机稍后上线也能自动续上。
 */
import { isLoggedIn } from './auth'
import { attachmentApi, AttachmentError } from './attachment_api'
import { getDeviceId } from './device_identity'
import {
  loadAttachmentDeletions,
  loadMemosCache,
  loadTasksCache,
  saveAttachmentDeletions
} from './storage'
import * as store from './attachment_store'

export const PHASE = {
  waitingSource: 'waiting_source',
  uploading: 'uploading',
  downloading: 'downloading',
  failed: 'failed'
}

const jobs = new Map()
const busy = new Set()
const listeners = new Set()

/** 数据落地后要刷新附件列表（新下载完、被远端删除…），由页面注册 */
let attachmentsChangedHandler = null

export function setOnAttachmentsChanged(fn) {
  attachmentsChangedHandler = typeof fn === 'function' ? fn : null
}

export function subscribe(fn) {
  listeners.add(fn)
  return () => listeners.delete(fn)
}

function notify() {
  listeners.forEach((fn) => {
    try {
      fn()
    } catch (e) {}
  })
}

function emitAttachmentsChanged() {
  if (attachmentsChangedHandler) {
    try {
      attachmentsChangedHandler()
    } catch (e) {}
  }
  notify()
}

export function jobOf(uid) {
  return uid ? jobs.get(uid) || null : null
}

function setJob(uid, job) {
  jobs.set(uid, job)
  notify()
}

function startJob(uid, phase, message) {
  const previous = jobs.get(uid)
  setJob(uid, {
    phase,
    startedAt: previous && phase === PHASE.waitingSource ? previous.startedAt : Date.now(),
    progress: null,
    message
  })
}

function setProgress(uid, phase, message, ratio) {
  setJob(uid, {
    phase,
    startedAt: (jobs.get(uid) || {}).startedAt || Date.now(),
    progress: ratio,
    message
  })
}

function fail(uid, message) {
  setJob(uid, { phase: PHASE.failed, startedAt: Date.now(), progress: null, message })
}

function clearJob(uid) {
  if (jobs.delete(uid)) notify()
}

// ---------------- 元数据同步 ----------------

/** 本地 id → 云端 id（任务/备忘同步完成后，附件靠它找回自己的父记录） */
function remoteIdMap(list) {
  const map = new Map()
  const localMap = new Map()
  ;(list || []).forEach((item) => {
    if (!item || !item.remote_id || !item.id) return
    map.set(Number(item.id), Number(item.remote_id))
    localMap.set(Number(item.remote_id), Number(item.id))
  })
  return { toRemote: map, toLocal: localMap }
}

/** 上报给服务端的字段子集：本地路径、blob_state 之类不发出去 */
function toServerMeta(record) {
  return {
    uid: record.uid,
    parent_kind: record.parent_kind,
    parent_remote_id: record.parent_remote_id,
    owner_device_id: record.owner_device_id || '',
    owner_device_name: record.owner_device_name || '',
    file_name: record.file_name,
    file_size: record.file_size,
    sha256: record.sha256,
    mime: record.mime || '',
    is_screenshot: !!record.is_screenshot,
    orphaned: !!record.orphaned,
    created_at: record.created_at,
    updated_at: record.updated_at || record.created_at
  }
}

function isNewer(a, b) {
  const ta = Date.parse(a || '')
  const tb = Date.parse(b || '')
  if (isNaN(ta)) return false
  if (isNaN(tb)) return true
  return ta > tb
}

/**
 * 与云端对账。返回 { incoming, deleted, rejectedNames }。
 * rejectedNames 必须提示给用户：服务器拒收的文件在云端根本不存在，
 * 不说就等于骗用户"已经保存好了"。
 */
export async function syncMetadata() {
  const summary = { incoming: 0, deleted: 0, rejectedNames: [] }
  if (!isLoggedIn()) return summary

  const tasks = remoteIdMap(loadTasksCache())
  const memos = remoteIdMap(loadMemosCache())

  // 1. 回填父记录指向：附件是在任务入库前建的，云端 id 要靠这一轮补上
  const records = store.all()
  records.forEach((record) => {
    const map = record.parent_kind === store.KIND_MEMO ? memos : tasks
    const remote = record.parent_local_id != null ? map.toRemote.get(Number(record.parent_local_id)) : null
    if (remote && remote !== record.parent_remote_id) {
      store.save({ ...record, parent_remote_id: remote, updated_at: record.updated_at })
    }
  })

  // 2. 上报本机全部可入库的附件：父记录还没有云端 id 的、已孤儿的先不报，
  //    服务器按"父记录不存在"拒收，拒收原因会误报成文件本身有问题。
  const uploadable = store.all().filter(
    (a) => !a.orphaned && a.parent_remote_id != null && a.uid && a.sha256
  )
  const tombstones = loadAttachmentDeletions()
  const byUid = new Map(store.all().map((a) => [a.uid, a]))

  const payload = await attachmentApi.sync(
    uploadable.map(toServerMeta),
    tombstones.map((d) => ({ uid: d.uid, deleted_at: d.deleted_at }))
  )

  // 3. 合并云端结果。sha 变了 = 云端换了内容：本机这份标 stale，待会儿自动重取。
  const outOfDate = []
  ;(payload.attachments || []).forEach((remote) => {
    const map = remote.parent_kind === store.KIND_MEMO ? memos : tasks
    const parentLocalId =
      remote.parent_remote_id != null ? map.toLocal.get(Number(remote.parent_remote_id)) : null
    const local = byUid.get(remote.uid) || store.byUid(remote.uid)
    if (!local) {
      // 父记录不在本机（还没同步下来）就跳过，下一轮再挂
      if (parentLocalId == null) return
      store.save({ ...remote, parent_local_id: parentLocalId })
      summary.incoming++
      return
    }
    if (isNewer(remote.updated_at, local.updated_at)) {
      const changed =
        !!remote.sha256 &&
        !!local.sha256 &&
        String(remote.sha256).toLowerCase() !== String(local.sha256).toLowerCase()
      store.save({
        ...remote,
        parent_local_id: parentLocalId != null ? parentLocalId : local.parent_local_id,
        stale_copy: changed
      })
      store.invalidateLocalCache(remote.uid)
      // 文件名也可能跟着变：旧原件留在旧路径，新版校验通过后才替换
      if (changed) outOfDate.push(remote.uid)
      if (parentLocalId == null && local.parent_local_id != null) summary.incoming++
    } else if (local.blob_state !== remote.blob_state) {
      // blob_state 只表示"服务器上有/没有中转副本"，不参与 LWW
      store.save({ ...local, blob_state: remote.blob_state })
    }
  })

  // 4. 云端已删的：本机记录与原件一起清（删任务走的不是这条路，那条要留原件）
  const deletedUids = payload.deleted_uids || []
  deletedUids.forEach((uid) => {
    const local = store.byUid(uid)
    if (!local) return
    store.remove(local, { deleteOriginal: true })
    clearJob(uid)
    summary.deleted++
  })

  // 5. 墓碑只在"本次确实报过"时销账，同步期间新删的留给下一轮
  const sentKeys = new Set(tombstones.map((d) => d.uid + '|' + d.deleted_at))
  saveAttachmentDeletions(
    loadAttachmentDeletions().filter((d) => !sentKeys.has(d.uid + '|' + d.deleted_at))
  )

  // 6. 云端换了内容：自动把新版取回来（桌面端 copy 模式同一口径）。
  //    取失败会在条目上挂"同步失败"，用户点一下就是重试，不用再等下一轮同步。
  outOfDate.forEach((uid) => {
    const rec = store.byUid(uid)
    if (rec) pull(rec).catch(() => {})
  })

  summary.rejectedNames = (payload.rejected_uids || []).map(
    (uid) => (byUid.get(uid) || {}).file_name || '未知文件'
  )
  if (summary.incoming > 0 || summary.deleted > 0) emitAttachmentsChanged()
  else notify()
  return summary
}

// ---------------- 删除墓碑 ----------------

export function recordDeletion(uid) {
  if (!uid) return
  const list = loadAttachmentDeletions()
  if (list.some((d) => d.uid === uid)) return
  list.push({ uid, deleted_at: new Date().toISOString() })
  saveAttachmentDeletions(list)
}

/** 用户从卡片上删掉一个附件：本机记录与原件删掉，云端等下次同步打墓碑。 */
export function deleteAttachment(record) {
  store.remove(record, { deleteOriginal: true })
  recordDeletion(record.uid)
  clearJob(record.uid)
  emitAttachmentsChanged()
}

/**
 * 父任务/备忘被删：附件按孤儿处理（原件留着，截图原件删掉），
 * 云端那边靠任务墓碑，不需要额外上报。
 */
export function onParentDeleted(parentKind, parentLocalId) {
  store
    .forParent(parentKind, parentLocalId)
    .forEach((a) => clearJob(a.uid))
  const affected = store.onParentDeleted(parentKind, parentLocalId)
  if (affected.length) emitAttachmentsChanged()
  return affected
}

// ---------------- 按需中转 ----------------

async function guard(uid, body) {
  if (busy.has(uid)) return
  busy.add(uid)
  try {
    await body()
  } catch (e) {
    if (e instanceof AttachmentError) fail(uid, e.message)
    else fail(uid, '同步失败，请稍后重试')
  } finally {
    busy.delete(uid)
  }
}

/** 目标端一键同步。 */
export async function pull(uidOrRecord) {
  const record = typeof uidOrRecord === 'object' ? uidOrRecord : store.byUid(uidOrRecord)
  if (!record) return
  const uid = record.uid
  if (!isLoggedIn()) {
    fail(uid, '登录后才能从其它主机同步文件')
    return
  }
  // 本机有原件、且不是旧版，才没什么可取
  if (store.hasLocalCopy(record) && !record.stale_copy) {
    clearJob(uid)
    return
  }
  await guard(uid, async () => {
    startJob(uid, PHASE.waitingSource, '正在通知其它主机…')
    const result = await attachmentApi.requestPull(uid)
    switch (result.state) {
      case 'ready':
        await download(record)
        break
      case 'done':
        clearJob(uid)
        break
      case 'waiting':
        startJob(uid, PHASE.waitingSource, result.message || '等待持有该文件的主机上线')
        break
      case 'requested':
        startJob(
          uid,
          PHASE.waitingSource,
          Number(result.sources) > 1
            ? `已通知 ${result.sources} 台主机，等待对方上传`
            : '已通知持有该文件的主机，等待上传'
        )
        break
      default:
        fail(uid, result.message || '服务器未接受同步请求')
    }
  })
}

/** 处理服务器推送：attachment_request / attachment_ready / attachment_taken。 */
export async function handlePush(msg) {
  const type = String((msg && msg.type) || '')
  const uid = String((msg && msg.uid) || '')
  if (!uid || !isLoggedIn()) return
  const record = store.byUid(uid)
  if (!record) return // 本机没有这条记录，推给它也没意义

  if (type === 'attachment_request') {
    // 本机这份是旧版：应答只会把旧内容推出去，顺手把新版取回来
    if (record.stale_copy) {
      const job = jobs.get(uid)
      if (!job || job.phase === PHASE.failed) pull(record).catch(() => {})
      return
    }
    // 服务器把请求广播给该账号的其它设备：谁本机有原件谁应答
    if (!store.hasLocalCopy(record)) return
    const job = jobs.get(uid)
    if (job && job.phase === PHASE.uploading) return
    await guard(uid, () => upload(record))
    return
  }

  if (type === 'attachment_ready') {
    // 旧版也要下：云端刚传上来的正是本机缺的那一版
    if (store.hasLocalCopy(record) && !record.stale_copy) {
      clearJob(uid)
      return
    }
    // 上传完成是全站广播，别的主机自己传给自己用不着下：
    // 只有服务器确认"这台设备登记过拉取请求"才下载
    let st
    try {
      st = await attachmentApi.state(uid)
    } catch (e) {
      if (e instanceof AttachmentError && !e.retryable) clearJob(uid)
      return
    }
    const mine = getDeviceId()
    const requested = (st.transfers || []).some(
      (t) => String(t.device_id) === mine && String(t.status) === 'pending'
    )
    if (!requested) {
      clearJob(uid)
      return
    }
    await guard(uid, () => download(record))
    return
  }

  if (type === 'attachment_taken') {
    // 文件已被取走并从服务器删除：本机这边的等待/上传都可以收了
    const job = jobs.get(uid)
    if (job && job.phase !== PHASE.failed) clearJob(uid)
  }
}

/** 源主机：把本机原件分片传到服务器（偏移以服务器为准，可断点续传）。 */
async function upload(record) {
  const uid = record.uid
  const path = store.pathOf(record)
  const size = await store.fileSizeOf(path)
  if (size === 0) {
    // 原件不在了就别再占着请求：服务器等 TTL 到期自己清
    clearJob(uid)
    return
  }
  if (record.file_size > 0 && size !== record.file_size) {
    fail(uid, '本机文件已被修改（大小与记录不符），请重新添加该附件')
    return
  }
  const init = await attachmentApi.uploadInit(uid)
  if (init.state === 'ready') {
    // 另一台持有者已经传完了，本机不用再出一份
    clearJob(uid)
    return
  }
  // 服务器认的是别台机器推上去的那一版：本机这份不是它要的内容，
  // 硬传也只会被当成坏文件，让持有新版的主机应答
  const expected = String(init.sha256 || '').toLowerCase()
  if (expected && expected !== String(record.sha256 || '').toLowerCase()) {
    clearJob(uid)
    return
  }
  const chunkSize = attachmentApi.maxChunkBytes(init.chunk_size)
  const declared = record.file_size
  let offset = Math.max(0, Math.min(Number(init.next_offset) || 0, declared))
  let lastPercent = -1
  let stalled = 0

  startJob(uid, PHASE.uploading, '正在上传到服务器 0%')
  while (offset < declared) {
    const buffer = await store.readChunk(path, offset, Math.min(chunkSize, declared - offset))
    const bytes = new Uint8Array(buffer)
    if (bytes.length === 0) {
      fail(uid, '本机文件读取失败，请重新添加该附件')
      return
    }
    const res = await attachmentApi.uploadChunk(uid, offset, buffer)
    const next = Number(res.next_offset)
    if (!Number.isFinite(next) || next < 0) {
      fail(uid, '上传没有进展，请检查网络后重试')
      return
    }
    if (next === offset) {
      // 服务端一次都没收下：连续两次没进展就别空转
      if (++stalled >= 2) {
        fail(uid, '上传没有进展，请检查网络后重试')
        return
      }
    } else {
      stalled = 0
      // state=resume 时服务器给的是它真实已收字节数，可能比本地小（回退重传）
      offset = Math.min(next, declared)
    }
    const percent = Math.floor((offset * 100) / Math.max(1, declared))
    // 只在整数百分比变化时刷新，避免大文件把渲染拖垮
    if (percent !== lastPercent) {
      lastPercent = percent
      setProgress(uid, PHASE.uploading, `正在上传到服务器 ${percent}%`, offset / Math.max(1, declared))
    }
  }
  await attachmentApi.uploadComplete(uid)
  clearJob(uid)
}

/** 目标端：下载、校验、落进本机，然后确认让服务器删文件。 */
async function download(record) {
  const uid = record.uid
  startJob(uid, PHASE.downloading, '正在下载到本机…')
  const buffer = await attachmentApi.download(uid)
  const saved = await store.saveIncoming({ attachment: record, buffer, parentLocalId: record.parent_local_id })
  if (!saved.ok) {
    fail(uid, saved.error)
    return
  }
  await attachmentApi.ack(uid)
  clearJob(uid)
  emitAttachmentsChanged()
}
