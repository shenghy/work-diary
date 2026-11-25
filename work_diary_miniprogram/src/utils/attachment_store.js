/**
 * 附件原件的本机仓库：`wxfile://usr/attachments/<uid>/<文件名>`。
 *
 * 与桌面端 attachment_store.dart 同一套约定：
 * 1. 只复制、不移动源文件——微信聊天里的临时文件随时会被清，原件必须落到自己的目录；
 * 2. uid 目录隔离同名文件，也让"按 uid 落盘/整份删除"不需要读元数据；
 * 3. 打开前先判类型，判不过就明确说"手机看不了这种格式"，不静默失败。
 *
 * 所有文件系统调用都收在这一个文件里，方便真机排查与测试替换。
 */
import {
  CHOOSE_MAX_COUNT,
  MAX_PER_PARENT,
  PICK_EXTENSIONS,
  checkFile,
  extOf,
  formatSize,
  isImageExt,
  sanitizeFileName,
  sanitizeUid
} from './attachment_types'
import { createSha256 } from './sha256'
import { genUuid } from './uuid'
import { getDeviceId, getDeviceName } from './device_identity'
import {
  loadAttachmentsCache,
  normalizeAttachment,
  saveAttachmentsCache
} from './storage'

const ROOT_DIR_NAME = 'attachments'
const READ_CHUNK_BYTES = 1024 * 1024

// 微信 openDocument 明确支持的办公/文档格式，其余在手机上只提示不硬试
const OPEN_DOCUMENT_EXTS = ['.doc', '.docx', '.xls', '.xlsx', '.ppt', '.pptx', '.pdf']
const TEXT_EXTS = ['.txt', '.md', '.csv']

export const KIND_TASK = 'task'
export const KIND_MEMO = 'memo'

function fs() {
  if (typeof wx === 'undefined' || !wx.getFileSystemManager) return null
  return wx.getFileSystemManager()
}

/** 本机是否具备存放原件的能力（其它平台没有 USER_DATA_PATH 时整体降级） */
export function isSupported() {
  return fs() !== null && typeof wx !== 'undefined' && !!(wx.env && wx.env.USER_DATA_PATH)
}

function userDataPath() {
  return wx.env.USER_DATA_PATH
}

export function attachmentsRoot() {
  return userDataPath() + '/' + ROOT_DIR_NAME
}

export function dirOf(uid) {
  return attachmentsRoot() + '/' + sanitizeUid(String(uid || ''))
}

export function pathOf(record) {
  return dirOf(record.uid) + '/' + sanitizeFileName(record.file_name)
}

function exists(manager, path) {
  try {
    manager.accessSync(path)
    return true
  } catch (e) {
    return false
  }
}

function ensureDir(manager, path) {
  if (exists(manager, path)) return
  try {
    manager.mkdirSync(path, true)
  } catch (e) {
    // 并发下另一路已经建好，accessSync 再确认一次即可
    if (!exists(manager, path)) throw e
  }
}

function removePath(manager, path, recursive) {
  try {
    if (recursive) manager.rmdirSync(path, true)
    else manager.unlinkSync(path)
  } catch (e) {
    // 文件本来就不在：删除目标已达成，不必为此报错
  }
}

function statSize(manager, path) {
  try {
    const stat = manager.statSync(path)
    const size = stat && stat.stats ? stat.stats.size : stat && stat.size
    return Number(size) > 0 ? Number(size) : 0
  } catch (e) {
    return 0
  }
}

// 下载的中转文件先落这里，校验通过才搬进 uid 目录（和桌面端 .incoming 同一思路）
function incomingDir() {
  return attachmentsRoot() + '/.incoming'
}

function writeFileBytes(manager, path, arrayBuffer) {
  return new Promise((resolve, reject) => {
    manager.writeFile({
      filePath: path,
      data: arrayBuffer,
      success: () => resolve(),
      fail: (e) => reject(e)
    })
  })
}

/**
 * 微信的写盘报错是给开发者看的（"exceed maximum size of file"…），
 * 用户需要知道的是"手机本地配额满了，删点附件"。
 */
function humanWriteError(e) {
  const raw = String((e && (e.errMsg || e.message)) || e || '')
  if (/maximum|exceed|quota|space/i.test(raw)) {
    return '手机本地附件空间已满（小程序上限 200MB），请先删除不需要的附件'
  }
  return '保存到本机失败：' + (raw || '未知原因')
}

// ---------------- 记录读写 ----------------

/** uid 清洗后与原值不一致 = 不可信输入，一律当作"本机没有原件"，
 *  否则可能恰好落到另一个附件的目录里，拿错文件。 */
function hasSafeUid(uid) {
  return !!uid && sanitizeUid(String(uid)) === String(uid)
}

// 附件表每张卡片都要读一遍（几十张卡 × 每次渲染），所以在这里缓存解析结果；
// 写路径全部收在本文件的 writeRecords 里，缓存不会读到旧数据。
// 订阅者（附件条）也挂在这里：谁写了记录，谁的卡片就要重画。
let recordsCache = null
const changeListeners = new Set()

export function subscribeChanges(fn) {
  changeListeners.add(fn)
  return () => changeListeners.delete(fn)
}

export function notifyChanges() {
  changeListeners.forEach((fn) => {
    try {
      fn()
    } catch (e) {}
  })
}

// 一轮元数据合并会连续写十几条记录，逐条重画会把列表卡住：合并到下一个宏任务再通知
let notifyTimer = null
function notifyChangesSoon() {
  if (notifyTimer) return
  notifyTimer = setTimeout(() => {
    notifyTimer = null
    notifyChanges()
  }, 0)
}

function records() {
  if (recordsCache === null) recordsCache = loadAttachmentsCache()
  return recordsCache
}

function writeRecords(list) {
  recordsCache = list
  saveAttachmentsCache(list)
  notifyChangesSoon()
}

export function all() {
  return records()
}

export function byUid(uid) {
  if (!uid) return null
  return records().find((a) => a.uid === uid) || null
}

export function forParent(parentKind, parentLocalId) {
  return records().filter(
    (a) => a.parent_kind === parentKind && a.parent_local_id === parentLocalId && !a.orphaned
  )
}

export function save(record) {
  const normalized = normalizeAttachment(record)
  if (!normalized) return null
  const list = records()
  const idx = list.findIndex((a) => a.uid === normalized.uid)
  if (idx >= 0) list[idx] = normalized
  else list.push(normalized)
  writeRecords(list)
  return normalized
}

export function countForParent(parentKind, parentLocalId) {
  return forParent(parentKind, parentLocalId).length
}

/** 还能再挂几个：编辑页据此决定选择器数量与「添加附件」是否置灰 */
export function remainingForParent(parentKind, parentLocalId) {
  return Math.max(0, MAX_PER_PARENT - countForParent(parentKind, parentLocalId))
}

// hasLocalCopy 会被每张卡片每次渲染调用，accessSync 虽快但架不住几十次重复；
// 缓存 uid→bool，落盘/删除/导入时定点失效。
const localCopyCache = new Map()

export function invalidateLocalCache(uid) {
  if (uid === undefined) localCopyCache.clear()
  else localCopyCache.delete(uid)
}

export function hasLocalCopy(record) {
  if (!record || !hasSafeUid(record.uid) || !record.file_name) return false
  if (!isSupported()) return false
  if (localCopyCache.has(record.uid)) return localCopyCache.get(record.uid)
  const manager = fs()
  let ok = false
  try {
    ok = exists(manager, pathOf(record))
  } catch (e) {
    ok = false
  }
  localCopyCache.set(record.uid, ok)
  return ok
}

// ---------------- 分块读 ----------------

/** 读一片（返回 ArrayBuffer）。100MB 的原件绝不整份进内存。 */
export function readChunk(filePath, position, length) {
  return new Promise((resolve, reject) => {
    const manager = fs()
    if (!manager) return reject(new Error('本机不支持文件读写'))
    try {
      const res = manager.readFile({
        filePath,
        position,
        length,
        success: (r) => resolve(r.data),
        fail: (e) => reject(new Error((e && e.errMsg) || '读取文件失败'))
      })
      // 同步型实现（测试桩）会直接返回数据
      if (res && res.data) resolve(res.data)
    } catch (e) {
      reject(e)
    }
  })
}

/** 流式 SHA-256：一次一片，算完即弃。 */
export function sha256File(filePath, size) {
  return (async () => {
    const hasher = createSha256()
    const total = size > 0 ? size : await fileSizeOf(filePath)
    let offset = 0
    while (offset < total) {
      const n = Math.min(READ_CHUNK_BYTES, total - offset)
      const buf = await readChunk(filePath, offset, n)
      const bytes = new Uint8Array(buf)
      if (bytes.length === 0) break
      hasher.update(bytes)
      offset += bytes.length
    }
    return hasher.digestHex()
  })()
}

export function fileSizeOf(filePath) {
  const manager = fs()
  if (!manager) return Promise.resolve(0)
  return new Promise((resolve) => resolve(statSize(manager, filePath)))
}

// ---------------- 导入（本机新增原件） ----------------

function fail(error) {
  return { ok: false, error, attachment: null }
}

/**
 * 把微信选出来的临时文件收进某任务/备忘。
 *
 * @param {string} tempPath  chooseMessageFile 给的路径
 * @param {object} meta      { name, size, parentKind, parentLocalId, parentRemoteId, isScreenshot }
 */
export async function importFile(tempPath, meta) {
  if (!isSupported()) return fail('本机暂不支持保存附件文件')
  if (!meta || !meta.parentKind || !meta.parentLocalId) return fail('请先保存所属的任务或备忘')
  const manager = fs()
  if (!exists(manager, tempPath)) return fail('文件不存在或已被移动')

  const name = meta.name || String(tempPath).split('/').pop() || '附件'
  const size = Number(meta.size) > 0 ? Number(meta.size) : statSize(manager, tempPath)
  const check = checkFile(name, size)
  if (!check.allowed) return fail(check.reason)

  const parentKind = meta.parentKind === KIND_MEMO ? KIND_MEMO : KIND_TASK
  if (countForParent(parentKind, meta.parentLocalId) >= MAX_PER_PARENT) {
    return fail(
      `一个${parentKind === KIND_MEMO ? '备忘' : '任务'}最多挂 ${MAX_PER_PARENT} 个附件，请先删除不需要的`
    )
  }

  let digest
  try {
    digest = await sha256File(tempPath, size)
  } catch (e) {
    return fail('读取文件失败：' + e.message)
  }
  const dup = forParent(parentKind, meta.parentLocalId).some((a) => a.sha256 === digest)
  if (dup) {
    return fail(`这个文件已经挂在当前${parentKind === KIND_MEMO ? '备忘' : '任务'}上了`)
  }

  const uid = genUuid()
  const safeName = sanitizeFileName(name)
  const target = dirOf(uid) + '/' + safeName
  try {
    ensureDir(manager, dirOf(uid))
    // 先落 .part 再改名：中途失败不会留下"看起来完整"的半个原件
    const part = target + '.part'
    manager.copyFileSync(tempPath, part)
    if (statSize(manager, part) !== size) {
      removePath(manager, part, false)
      return fail('文件复制不完整，请重试')
    }
    manager.copyFileSync(part, target)
    removePath(manager, part, false)
  } catch (e) {
    removePath(manager, dirOf(uid), true)
    return fail(humanWriteError(e))
  }

  const now = new Date().toISOString()
  const record = save({
    uid,
    parent_kind: parentKind,
    parent_local_id: meta.parentLocalId,
    parent_remote_id: meta.parentRemoteId || null,
    owner_device_id: getDeviceId(),
    owner_device_name: getDeviceName(),
    file_name: safeName,
    file_size: size,
    sha256: digest,
    mime: check.mime,
    is_screenshot: !!meta.isScreenshot,
    orphaned: false,
    blob_state: 'none',
    created_at: now,
    updated_at: now
  })
  invalidateLocalCache(uid)
  return { ok: true, error: '', attachment: record }
}

// ---------------- 从微信聊天选文件 ----------------

/**
 * 打开微信的会话文件选择器，返回 [{ path, name, size }]。
 *
 * extension 过滤只在 type:'file' 下生效，且用户仍可能选到别的类型，
 * 真正的把关在 importFile 的 checkFile（与服务端同一份白名单）。
 * 取消不算错误：调用方按 cancelled 静默返回，别弹「选择文件失败」。
 */
export function chooseFromChat(count) {
  return new Promise((resolve, reject) => {
    if (typeof wx === 'undefined' || !wx.chooseMessageFile) {
      reject(new Error('请在微信聊天里选择文件'))
      return
    }
    const n = Math.max(1, Math.min(Number(count) || 1, CHOOSE_MAX_COUNT))
    wx.chooseMessageFile({
      count: n,
      type: 'file',
      extension: PICK_EXTENSIONS,
      success: (res) => resolve((res && res.tempFiles) || []),
      fail: (e) => {
        const raw = String((e && (e.errMsg || e.message)) || e || '')
        const err = /cancel/i.test(raw)
          ? new Error('已取消选择')
          : new Error('选择文件失败：' + (raw || '未知原因'))
        err.cancelled = /cancel/i.test(raw)
        reject(err)
      }
    })
  })
}

/**
 * 批量收进某任务/备忘：逐个走 importFile，把每个文件的失败原因原样带回去。
 * 一次选 3 个、其中 1 个是 .exe 时，只说「失败」等于没说。
 */
export async function attachPicked(files, meta) {
  const attached = []
  const errors = []
  const list = files || []
  for (let i = 0; i < list.length; i++) {
    const f = list[i] || {}
    const res = await importFile(f.path, {
      ...meta,
      name: f.name,
      size: Number(f.size) > 0 ? Number(f.size) : 0
    })
    if (res.ok && res.attachment) attached.push(res.attachment)
    else errors.push(res.error || '保存失败')
  }
  return { attached, errors }
}

/**
 * 收下一个已下载好的中转文件（整份 ArrayBuffer）：先写临时件，再按元数据校验
 * 大小与摘要，不过就整份丢掉——绝不留下"名字对、内容不对"的原件。
 */
export async function saveIncoming({ attachment, buffer, parentLocalId }) {
  if (!attachment) return fail('附件记录不存在')
  if (!hasSafeUid(attachment.uid)) return fail('附件标识不合法，无法保存到本机')
  if (!isSupported()) return fail('本机暂不支持保存附件文件')
  const bytes = buffer instanceof ArrayBuffer ? buffer : null
  if (!bytes || bytes.byteLength === 0) return fail('下载内容为空，请重新发起同步')

  const manager = fs()
  const part = incomingDir() + '/' + sanitizeUid(attachment.uid) + '.part'
  try {
    ensureDir(manager, incomingDir())
    await writeFileBytes(manager, part, bytes)
  } catch (e) {
    removePath(manager, part, false)
    return fail(humanWriteError(e))
  }

  const size = statSize(manager, part)
  if (attachment.file_size > 0 && size !== attachment.file_size) {
    removePath(manager, part, false)
    return fail(
      `文件大小不符（期望 ${formatSize(attachment.file_size)}，实际 ${formatSize(size)}）`
    )
  }
  let digest
  try {
    digest = await sha256File(part, size)
  } catch (e) {
    removePath(manager, part, false)
    return fail('读取下载文件失败：' + e.message)
  }
  if (attachment.sha256 && digest.toLowerCase() !== attachment.sha256.toLowerCase()) {
    removePath(manager, part, false)
    return fail('文件校验失败，请重新同步')
  }

  const target = pathOf(attachment)
  try {
    ensureDir(manager, dirOf(attachment.uid))
    if (exists(manager, target)) removePath(manager, target, false)
    manager.copyFileSync(part, target)
  } catch (e) {
    return fail(humanWriteError(e))
  } finally {
    removePath(manager, part, false)
  }
  const saved = save({
    ...attachment,
    parent_local_id: parentLocalId || attachment.parent_local_id,
    file_size: size,
    sha256: digest,
    // 刚校验通过的就是云端当前版本，旧版标记到此为止
    stale_copy: false,
    updated_at: new Date().toISOString()
  })
  invalidateLocalCache(attachment.uid)
  return { ok: true, error: '', attachment: saved }
}

// ---------------- 删除 ----------------

/**
 * 删附件。deleteOriginal 只在用户明确删这个附件、或删截图任务时为真。
 */
export function remove(record, opts) {
  if (!record) return
  const list = records().filter((a) => a.uid !== record.uid)
  writeRecords(list)
  localCopyCache.delete(record.uid)
  if (!(opts && opts.deleteOriginal)) return
  if (!isSupported() || !hasSafeUid(record.uid)) return
  const manager = fs()
  removePath(manager, dirOf(record.uid), true)
}

/** 父任务/备忘被删：非截图附件标孤儿（原件留着），截图附件连原件一起清。 */
export function onParentDeleted(parentKind, parentLocalId) {
  const kind = parentKind === KIND_MEMO ? KIND_MEMO : KIND_TASK
  const list = records()
  const affected = []
  list.forEach((a) => {
    if (a.orphaned || a.parent_kind !== kind || a.parent_local_id !== parentLocalId) return
    a.orphaned = true
    // 抬高 updated_at：否则下一轮云端那份未孤儿的记录会在 LWW 里赢回来，附件又出现在卡上
    a.updated_at = new Date().toISOString()
    affected.push(a)
  })
  if (!affected.length) return affected
  writeRecords(list)
  affected.forEach((a) => {
    localCopyCache.delete(a.uid)
    if (a.is_screenshot) remove(a, { deleteOriginal: true })
  })
  return affected
}

// ---------------- 打开 ----------------

/** 文本类附件读成字符串（给附件查看页）。 */
export function readText(record, maxBytes = 512 * 1024) {
  return new Promise((resolve, reject) => {
    if (!hasLocalCopy(record)) return reject(new Error('本机还没有这个文件的原件'))
    const manager = fs()
    try {
      const res = manager.readFile({
        filePath: pathOf(record),
        encoding: 'utf8',
        length: maxBytes,
        success: (r) => resolve(String(r.data || '')),
        fail: (e) => reject(new Error((e && e.errMsg) || '读取失败'))
      })
      if (res && typeof res.data === 'string') resolve(res.data)
    } catch (e) {
      reject(e)
    }
  })
}

/**
 * 一键打开：图片走大图预览，office/pdf 走系统文档组件，txt/md/csv 走内置查看页。
 * 返回 null 表示已交给微信/我们的页面，返回字符串表示要提示用户的原话。
 */
export function open(record) {
  if (!record) return '附件已不存在'
  if (!hasLocalCopy(record)) {
    const owner = String(record.owner_device_name || '').trim()
    return `此文件在${owner || '其它主机'}上，先同步到本机再打开`
  }
  const ext = extOf(record.file_name)
  const path = pathOf(record)
  if (isImageExt(record.file_name)) {
    uni.previewImage({ urls: [path], current: path, fail: () => showToast('图片打开失败') })
    return null
  }
  if (OPEN_DOCUMENT_EXTS.indexOf(ext) >= 0) {
    uni.openDocument({
      filePath: path,
      fileType: ext.slice(1),
      showMenu: true,
      fail: () => showToast('该格式手机暂时打不开，可在电脑端打开')
    })
    return null
  }
  if (TEXT_EXTS.indexOf(ext) >= 0) {
    uni.navigateTo({
      url: '/pkgData/attachment-view/attachment-view?uid=' + encodeURIComponent(record.uid)
    })
    return null
  }
  return `${record.file_name} 在手机上没有可用的打开方式，可在电脑端打开`
}

function showToast(title) {
  try {
    uni.showToast({ title, icon: 'none' })
  } catch (e) {}
}
