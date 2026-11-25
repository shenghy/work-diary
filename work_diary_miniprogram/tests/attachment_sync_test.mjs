/**
 * 小程序附件基础层测试（src/utils/attachment_{types,store,api,sync}.js）：
 * 跑法 node tests/attachment_sync_test.mjs
 *
 * 用假 uni + 假 wx FileSystemManager + 一个按服务端契约写的假中转服务器，
 * 覆盖四件真会出事的事：
 * 1) 元数据 LWW 合并与 parent_remote_id 回填（父记录没入库前不能上报）；
 * 2) 分片上传的续传偏移（服务器 offset 不对要按它给的重来）；
 * 3) 下载后先验大小与 SHA-256，不过就整份丢掉，且绝不 ack；
 * 4) 推送只应答"本机确实有原件/确实登记过请求"的情况。
 */
import { register } from 'node:module'
import { createHash } from 'node:crypto'

register('./esm_ext_hooks.mjs', import.meta.url)

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
function ok(cond, msg) {
  if (cond) console.log('ok   ' + msg)
  else {
    failed++
    console.log('FAIL ' + msg)
  }
}

// ---------------- 假存储 + 假文件系统 ----------------
let store = new Map()
let caseNo = 0
const FILES = new Map() // path → Uint8Array
const DIRS = new Set(['wxfile://usr'])

global.getCurrentPages = () => [{ route: 'pages/tasks/tasks' }]

global.uni = {
  getStorageSync: (k) => (store.has(k) ? store.get(k) : ''),
  setStorageSync: (k, v) => store.set(k, v),
  removeStorageSync: (k) => store.delete(k),
  request: () => {},
  showToast: () => {},
  showLoading: () => {},
  hideLoading: () => {},
  reLaunch: () => {},
  navigateBack: () => {},
  navigateTo: (o) => global.__nav.push(o.url),
  setNavigationBarColor: () => {},
  previewImage: (o) => global.__preview.push(o),
  openDocument: (o) => global.__openDoc.push(o),
  getSystemInfoSync: () => ({ windowWidth: 375, theme: 'light' })
}
global.__nav = []
global.__preview = []
global.__openDoc = []

function bytesOf(v) {
  if (v instanceof Uint8Array) return v
  if (v instanceof ArrayBuffer) return new Uint8Array(v)
  return new Uint8Array(Buffer.from(String(v)))
}

function parentDir(p) {
  const i = p.lastIndexOf('/')
  return i > 0 ? p.slice(0, i) : ''
}

global.wx = {
  env: { USER_DATA_PATH: 'wxfile://usr' },
  getDeviceInfo: () => ({ model: 'iPhone 15 Pro', brand: 'Apple' }),
  getFileSystemManager: () => ({
    accessSync(p) {
      if (!FILES.has(p) && !DIRS.has(p)) throw new Error('file not exist')
    },
    mkdirSync(p, recursive) {
      DIRS.add(p)
      if (recursive) {
        const parts = String(p).split('/')
        for (let i = 1; i <= parts.length; i++) {
          const seg = parts.slice(0, i).join('/')
          if (seg.indexOf('://') < 0 && seg) DIRS.add(seg)
        }
      }
    },
    copyFileSync(src, dest) {
      if (!FILES.has(src)) throw new Error('copyFile:fail no such file')
      FILES.set(dest, FILES.get(src).slice())
      DIRS.add(parentDir(dest))
    },
    writeFile({ filePath, data, success, fail }) {
      try {
        FILES.set(filePath, bytesOf(data))
        DIRS.add(parentDir(filePath))
        if (success) success({})
      } catch (e) {
        if (fail) fail({ errMsg: 'writeFile:fail ' + e.message })
      }
    },
    readFile({ filePath, position, length, success, fail }) {
      const all = FILES.get(filePath)
      if (!all) return fail && fail({ errMsg: 'readFile:fail no such file' })
      const from = position || 0
      const to = length == null ? all.length : Math.min(all.length, from + length)
      const slice = all.slice(from, Math.max(from, to))
      const buf = slice.buffer.slice(slice.byteOffset, slice.byteOffset + slice.byteLength)
      if (success) success({ data: buf })
    },
    unlinkSync(p) {
      if (!FILES.delete(p)) throw new Error('unlink:fail no such file')
    },
    rmdirSync(p, recursive) {
      if (!recursive) throw new Error('rmdir:fail not dir')
      DIRS.delete(p)
      Array.from(FILES.keys()).forEach((f) => {
        if (f.startsWith(p + '/')) FILES.delete(f)
      })
    },
    statSync(p) {
      const f = FILES.get(p)
      if (f) return { size: f.length }
      if (DIRS.has(p)) return { size: 0 }
      throw new Error('stat:fail no such file')
    }
  })
}

// ---------------- 假中转服务器（按 attachments.py 的契约） ----------------
const srv = {
  meta: new Map(), // uid → 云端元数据
  parts: new Map(), // uid → Uint8Array（上传中）
  blobs: new Map(), // uid → Uint8Array（ready 待取）
  transfers: new Map(), // uid → [{device_id,status}]
  syncPayload: null,
  syncResponse: { attachments: [], deleted_uids: [], rejected_uids: [] },
  pullResult: null,
  stateOverride: null,
  calls: [],
  corruptComplete: false,
  chunkSizeOverride: 0,
  truncateOnce: false,
  lastDeviceId: '',
  lastDeviceName: '',
  blobDeviceId: ''
}

function httpError(statusCode, detail) {
  return { __status: statusCode, __body: { detail } }
}

function respond(opt, handler) {
  setTimeout(() => {
    let out
    try {
      out = handler()
    } catch (e) {
      return opt.fail({ errMsg: String(e && e.message) })
    }
    if (out && out.__status) {
      const body = out.__body
      return opt.success({
        statusCode: out.__status,
        data: opt.responseType === 'arraybuffer' ? Buffer.from(JSON.stringify(body)).buffer : body
      })
    }
    const data =
      opt.responseType === 'arraybuffer' && out instanceof Uint8Array
        ? out.buffer.slice(out.byteOffset, out.byteOffset + out.byteLength)
        : out
    opt.success({ statusCode: 200, data })
  }, 0)
}

global.uni.request = (opt) => {
  const url = String(opt.url).replace('https://work.jspang.com', '')
  const method = String(opt.method || 'GET').toUpperCase()
  const path = url.split('?')[0]
  const query = url.slice(path.length).replace(/^\?/, '')
  srv.calls.push(method + ' ' + url)
  if (opt.data && opt.data.device_id) {
    srv.lastDeviceId = opt.data.device_id
    srv.lastDeviceName = opt.data.device_name
  }
  const qdid = query.match(/device_id=([^&]+)/)
  if (qdid) srv.blobDeviceId = decodeURIComponent(qdid[1])

  if (method === 'POST' && path === '/api/attachments/sync') {
    srv.syncPayload = opt.data
    return respond(opt, () => srv.syncResponse)
  }
  const m = path.match(/^\/api\/attachments\/([^/?]+)\/(request|upload\/init|upload\/complete|ack|state|upload|blob)$/)
  if (!m) return respond(opt, () => httpError(404, '没有路由: ' + url))
  const uid = m[1]
  const verb = m[2]
  const meta = srv.meta.get(uid)

  if (method === 'POST' && verb === 'request') {
    if (!meta) return respond(opt, () => httpError(404, '附件不存在或已删除'))
    const list = srv.transfers.get(uid) || []
    if (!list.some((t) => t.device_id === opt.data.device_id)) {
      list.push({ device_id: opt.data.device_id, device_name: opt.data.device_name, status: 'pending' })
    }
    srv.transfers.set(uid, list)
    if (srv.blobs.has(uid)) {
      return respond(opt, () => srv.pullResult || { state: 'ready', sources: 0, message: '服务器已有文件，可直接下载' })
    }
    return respond(opt, () => srv.pullResult || { state: 'requested', sources: 1, message: '已通知其它主机上传' })
  }

  if (method === 'POST' && verb === 'upload/init') {
    if (!meta) return respond(opt, () => httpError(404, '附件不存在或已删除'))
    if (srv.blobs.has(uid)) {
      return respond(opt, () => ({ state: 'ready', next_offset: 0, chunk_size: 2 * 1024 * 1024, file_size: meta.file_size, sha256: meta.sha256 }))
    }
    const have = srv.parts.has(uid) ? srv.parts.get(uid).length : 0
    return respond(opt, () => ({ state: 'upload', next_offset: have, chunk_size: srv.chunkSizeOverride || 2 * 1024 * 1024, file_size: meta.file_size, sha256: meta.sha256 }))
  }

  if (method === 'PUT' && verb === 'upload') {
    if (!meta) return respond(opt, () => httpError(404, '附件不存在或已删除'))
    const offset = parseInt((query.match(/offset=(\d+)/) || [])[1], 10)
    const chunk = bytesOf(opt.data)
    let have = srv.parts.has(uid) ? srv.parts.get(uid) : new Uint8Array(0)
    if (srv.truncateOnce && have.length > 0) {
      // 模拟服务器侧丢了 5 个字节：客户端必须按服务器给的回退偏移重传，而不是报错
      srv.truncateOnce = false
      have = have.slice(0, have.length - 5)
      srv.parts.set(uid, have)
      return respond(opt, () => ({ state: 'resume', next_offset: have.length }))
    }
    if (have.length !== offset) {
      return respond(opt, () => ({ state: 'resume', next_offset: have.length }))
    }
    if (offset + chunk.length > meta.file_size) {
      return respond(opt, () => httpError(413, '分片超出文件大小'))
    }
    const next = new Uint8Array(offset + chunk.length)
    next.set(have, 0)
    next.set(chunk, offset)
    srv.parts.set(uid, next)
    return respond(opt, () => ({ state: 'ok', next_offset: next.length }))
  }

  if (method === 'POST' && verb === 'upload/complete') {
    if (!meta) return respond(opt, () => httpError(404, '附件不存在或已删除'))
    const part = srv.parts.get(uid) || new Uint8Array(0)
    if (part.length !== meta.file_size) {
      return respond(opt, () => httpError(422, '文件大小与元数据不符，请重新上传'))
    }
    const digest = createHash('sha256').update(part).digest('hex')
    if (srv.corruptComplete || digest !== String(meta.sha256).toLowerCase()) {
      srv.parts.delete(uid)
      return respond(opt, () => httpError(422, '内容校验失败（SHA-256 不匹配）'))
    }
    srv.blobs.set(uid, part)
    srv.parts.delete(uid)
    srv.transfers.set(uid, (srv.transfers.get(uid) || []).map((t) => ({ ...t, status: 'pending' })))
    return respond(opt, () => ({ state: 'requested', sources: 1, message: '已通知请求方下载' }))
  }

  if (method === 'GET' && verb === 'blob') {
    if (!meta) return respond(opt, () => httpError(404, '附件不存在或已删除'))
    if (!srv.blobs.has(uid)) return respond(opt, () => httpError(410, '服务器上没有该文件的中转副本'))
    const deviceId = (query.match(/device_id=([^&]+)/) || [])[1]
    const allowed = (srv.transfers.get(uid) || []).some((t) => t.device_id === deviceId)
    if (!allowed) return respond(opt, () => httpError(403, '请先发起同步请求'))
    return respond(opt, () => srv.blobs.get(uid))
  }

  if (method === 'POST' && verb === 'ack') {
    const list = (srv.transfers.get(uid) || []).map((t) =>
      t.device_id === opt.data.device_id ? { ...t, status: 'downloaded' } : t
    )
    srv.transfers.set(uid, list)
    const remaining = list.filter((t) => t.status === 'pending').length
    if (remaining === 0) srv.blobs.delete(uid)
    return respond(opt, () => ({ remaining, blob_deleted: remaining === 0 }))
  }

  if (method === 'GET' && verb === 'state') {
    if (srv.stateOverride) return respond(opt, () => srv.stateOverride)
    return respond(opt, () => ({
      blob_state: srv.blobs.has(uid) ? 'ready' : 'none',
      transfers: srv.transfers.get(uid) || []
    }))
  }
  return respond(opt, () => httpError(405, '方法不允许'))
}

async function fresh() {
  store = new Map()
  FILES.clear()
  DIRS.clear()
  DIRS.add('wxfile://usr')
  srv.meta.clear()
  srv.parts.clear()
  srv.blobs.clear()
  srv.transfers.clear()
  srv.calls = []
  srv.syncPayload = null
  srv.syncResponse = { attachments: [], deleted_uids: [], rejected_uids: [] }
  srv.pullResult = null
  srv.stateOverride = null
  srv.corruptComplete = false
  srv.chunkSizeOverride = 0
  srv.truncateOnce = false
  srv.lastDeviceId = ''
  srv.lastDeviceName = ''
  srv.blobDeviceId = ''
  global.__nav = []
  global.__preview = []
  global.__openDoc = []
  store.set('wd_token', 'test-token')
  caseNo += 1
  const [types, storeMod, syncMod] = await Promise.all([
    import('../src/utils/attachment_types.js?case=' + caseNo),
    import('../src/utils/attachment_store.js?case=' + caseNo),
    import('../src/utils/attachment_sync.js?case=' + caseNo)
  ])
  await import('../src/utils/storage.js?case=' + caseNo)
  return { types, store: storeMod, sync: syncMod }
}

function putFile(path, content) {
  FILES.set(path, bytesOf(content))
  DIRS.add(parentDir(path))
  return path
}

const TEXT = '附件内容：WorkDiary 小程序中转测试\n'
const TEXT_SHA = createHash('sha256').update(TEXT).digest('hex')

function cloudMeta(uid, over) {
  return {
    uid,
    parent_kind: 'task',
    parent_remote_id: 77,
    owner_device_id: 'desktop-1',
    owner_device_name: 'DESKTOP-ABC',
    file_name: 'notes.txt',
    file_size: bytesOf(TEXT).length,
    sha256: TEXT_SHA,
    mime: 'text/plain',
    is_screenshot: false,
    orphaned: false,
    blob_state: 'none',
    created_at: '2026-11-01T00:00:00.000Z',
    updated_at: '2026-11-01T00:00:00.000Z',
    ...over
  }
}

// ---------------- 1. 导入：类型/大小/配额/重复 ----------------
{
  const { store: S } = await fresh()
  const src = putFile('wxfile://chat/notes.txt', TEXT)
  const r = await S.importFile(src, { name: 'notes.txt', size: bytesOf(TEXT).length, parentKind: 'task', parentLocalId: 7 })
  ok(r.ok, 'txt 导入成功：' + (r.error || ''))
  const rec = r.attachment
  eq(S.pathOf(rec), 'wxfile://usr/attachments/' + rec.uid + '/notes.txt', '原件落在 attachments/<uid>/<文件名>')
  ok(FILES.has(S.pathOf(rec)), '原件已写入本机')
  eq(rec.sha256, TEXT_SHA, '导入时算出 SHA-256')
  eq(rec.file_size, bytesOf(TEXT).length, '大小按真实字节记')

  const exe = await S.importFile(putFile('wxfile://chat/a.exe', 'MZ....'), { name: 'a.exe', size: 8, parentKind: 'task', parentLocalId: 7 })
  ok(!exe.ok && /执行/.test(exe.error), '可执行文件被拒：' + exe.error)

  const big = await S.importFile(putFile('wxfile://chat/big.txt', 'x'), { name: 'big.txt', size: 101 * 1024 * 1024, parentKind: 'task', parentLocalId: 7 })
  ok(!big.ok && /100MB/.test(big.error), '超过 100MB 直接提示：' + big.error)

  const dup = await S.importFile(src, { name: 'notes.txt', size: bytesOf(TEXT).length, parentKind: 'task', parentLocalId: 7 })
  ok(!dup.ok && /已经挂/.test(dup.error), '同内容重复挂提示：' + dup.error)

  for (let i = 0; i < 4; i++) {
    await S.importFile(putFile('wxfile://chat/f' + i + '.txt', '内容' + i), { name: 'f' + i + '.txt', parentKind: 'task', parentLocalId: 7 })
  }
  const over = await S.importFile(putFile('wxfile://chat/f9.txt', '内容9'), { name: 'f9.txt', parentKind: 'task', parentLocalId: 7 })
  ok(!over.ok && /最多挂 5 个/.test(over.error), '第 6 个附件被配额拦下：' + over.error)
  eq(S.forParent('task', 7).length, 5, '配额拦下时既不落盘也不建记录')
}

// ---------------- 2. 元数据同步：回填 + 合并 + 墓碑 + 拒收 ----------------
{
  const { store: S, sync } = await fresh()
  const storage = await import('../src/utils/storage.js?case=' + caseNo)
  const src = putFile('wxfile://chat/notes.txt', TEXT)
  const mine = (await S.importFile(src, { name: 'notes.txt', size: bytesOf(TEXT).length, parentKind: 'task', parentLocalId: 7 })).attachment
  const orphan = (await S.importFile(putFile('wxfile://chat/p.png', 'PNGDATA'), { name: 'p.png', size: 7, parentKind: 'task', parentLocalId: 8 })).attachment
  S.save({ ...orphan, orphaned: true, updated_at: new Date().toISOString() })

  storage.saveTasksCache([
    { id: 7, remote_id: 77, title: '带附件的任务', status: 0 },
    { id: 8, remote_id: 78, title: '另一个任务', status: 0 }
  ])
  storage.saveMemosCache([{ id: 21, remote_id: 81, content: '备忘' }])

  const doomed = cloudMeta('bbbbbb000000', { parent_remote_id: 78 })
  S.save(doomed)
  srv.meta.set(mine.uid, cloudMeta(mine.uid, { sha256: mine.sha256, file_size: mine.file_size }))
  srv.meta.set('cccccc000000', cloudMeta('cccccc000000', { parent_kind: 'memo', parent_remote_id: 81, file_name: 'cloud.md' }))
  srv.meta.set(doomed.uid, doomed)
  srv.syncResponse = {
    attachments: [cloudMeta(mine.uid, { sha256: mine.sha256, file_size: mine.file_size }), cloudMeta('cccccc000000', { parent_kind: 'memo', parent_remote_id: 81, file_name: 'cloud.md' })],
    deleted_uids: [doomed.uid],
    rejected_uids: []
  }
  storage.saveAttachmentDeletions([{ uid: doomed.uid, deleted_at: '2026-11-02T00:00:00.000Z' }])
  putFile(S.pathOf(doomed), '要连带删掉的原件')

  const summary = await sync.syncMetadata()
  const sent = srv.syncPayload
  const sentIds = sent.attachments.map((a) => a.uid).sort()
  eq(sentIds, [mine.uid, doomed.uid].sort(), '只上报父记录已入库、未孤儿的附件')
  ok(sentIds.indexOf(orphan.uid) < 0, '孤儿附件不上报')
  eq(sent.attachments.find((a) => a.uid === mine.uid).parent_remote_id, 77, 'parent_remote_id 由任务映射回填后上报')
  ok(
    sent.attachments.every((a) => a.parent_local_id === undefined && a.blob_state === undefined),
    '本地字段不出网（parent_local_id / blob_state 不外泄）'
  )
  eq(sent.deletions, [{ uid: doomed.uid, deleted_at: '2026-11-02T00:00:00.000Z' }], '删除墓碑随同步上报')
  eq(summary.incoming, 1, '云端新增 1 条挂到本机备忘')
  eq(S.byUid('cccccc000000').parent_local_id, 21, '云端附件按 remote→local 挂到本机备忘')
  eq(S.byUid('cccccc000000').file_name, 'cloud.md', '云端文件名落地')
  ok(!S.byUid(doomed.uid), '云端删除的附件本机记录消失')
  ok(!FILES.has(S.pathOf({ ...doomed })), '云端删除的附件原件一并清掉')
  eq(storage.loadAttachmentDeletions(), [], '墓碑已销账')
  eq(S.byUid(mine.uid).parent_remote_id, 77, '本机记录也补上云端父 id')
}

// ---------------- 3. 父记录还没同步上来：不上报，等下一轮 ----------------
{
  const { store: S, sync } = await fresh()
  const storage = await import('../src/utils/storage.js?case=' + caseNo)
  storage.saveTasksCache([{ id: 9, title: '刚新建，还没有 remote_id', status: 0 }])
  const rec = (await S.importFile(putFile('wxfile://chat/x.txt', 'x'), { name: 'x.txt', size: 1, parentKind: 'task', parentLocalId: 9 })).attachment
  await sync.syncMetadata()
  eq(srv.syncPayload.attachments.length, 0, '父记录没云端 id 时不报，避免被误判成文件有问题')
  ok(!S.byUid(rec.uid).parent_remote_id, 'parent_remote_id 仍为空')
}

// ---------------- 4. 服务器拒收要把文件名报给用户 ----------------
{
  const { store: S, sync } = await fresh()
  const storage = await import('../src/utils/storage.js?case=' + caseNo)
  storage.saveTasksCache([{ id: 7, remote_id: 77, title: '任务', status: 0 }])
  const rec = (await S.importFile(putFile('wxfile://chat/v.txt', TEXT), { name: 'v.txt', size: bytesOf(TEXT).length, parentKind: 'task', parentLocalId: 7 })).attachment
  srv.syncResponse = { attachments: [], deleted_uids: [], rejected_uids: [rec.uid, 'ffffffffffff'] }
  const summary = await sync.syncMetadata()
  eq(summary.rejectedNames, ['v.txt', '未知文件'], '拒收附件按本地文件名提示，查不到的说"未知文件"')
  ok(S.byUid(rec.uid), '被拒收的附件本机仍留着原件，下一轮继续报')
}

// ---------------- 5. 一键同步：服务器已有中转件 → 下载校验 → ack 删件 ----------------
{
  const { store: S, sync } = await fresh()
  const storage = await import('../src/utils/storage.js?case=' + caseNo)
  const { getDeviceId } = await import('../src/utils/device_identity.js?case=' + caseNo)
  storage.saveTasksCache([{ id: 7, remote_id: 77, title: '任务', status: 0 }])
  srv.meta.set('aaaaaa000000', cloudMeta('aaaaaa000000'))
  srv.syncResponse = { attachments: [cloudMeta('aaaaaa000000')], deleted_uids: [], rejected_uids: [] }
  await sync.syncMetadata()
  const rec = S.byUid('aaaaaa000000')
  eq(rec.parent_local_id, 7, '云端附件挂到本机任务 7')
  ok(!S.hasLocalCopy(rec), '下载前本机没有原件')

  srv.blobs.set('aaaaaa000000', bytesOf(TEXT))
  const seen = []
  sync.setOnAttachmentsChanged(() => seen.push('changed'))
  await sync.pull('aaaaaa000000')
  const finalPath = S.pathOf(rec)
  ok(FILES.has(finalPath), '原件落到 attachments/<uid>/<文件名>')
  eq(new TextDecoder().decode(FILES.get(finalPath)), TEXT, '内容与服务器中转件一致')
  eq(S.byUid('aaaaaa000000').sha256, TEXT_SHA, '校验通过后摘要写回记录')
  ok(sync.jobOf('aaaaaa000000') === null, '完成后进度收掉')
  eq(seen, ['changed'], '下载完成通知 UI 刷新')
  ok(srv.calls.some((c) => c.indexOf('POST /api/attachments/aaaaaa000000/ack') === 0), '确认后服务器才删中转件')
  ok(!srv.blobs.has('aaaaaa000000'), '服务器侧中转副本已消失')
  eq((srv.transfers.get('aaaaaa000000') || []).map((t) => t.status), ['downloaded'], '请求台账标记已取走')
  const blobCall = srv.calls.find((c) => c.indexOf('GET /api/attachments/aaaaaa000000/blob?') === 0) || ''
  eq(
    (blobCall.match(/device_id=([^&]+)/) || [])[1],
    srv.lastDeviceId,
    '下载带的 device_id 与 /request 登记的同一个（对不上服务器会 403）'
  )
  ok(srv.lastDeviceName.length > 0, '设备名一并上报：' + srv.lastDeviceName)
}

// ---------------- 6. 校验不过：不 ack、不留半个原件、说清原因 ----------------
{
  const { store: S, sync } = await fresh()
  const storage = await import('../src/utils/storage.js?case=' + caseNo)
  storage.saveTasksCache([{ id: 7, remote_id: 77, title: '任务', status: 0 }])
  srv.meta.set('dddddd000000', cloudMeta('dddddd000000'))
  srv.syncResponse = { attachments: [cloudMeta('dddddd000000')], deleted_uids: [], rejected_uids: [] }
  await sync.syncMetadata()
  const rec = S.byUid('dddddd000000')

  // 同长度但内容不同 → 大小过、SHA 不过
  const bad = bytesOf(TEXT).slice()
  bad[bad.length - 2] ^= 0x01 // 只改内容不改长度：大小能过、SHA 过不了
  srv.blobs.set('dddddd000000', bad)
  await sync.pull(rec)
  const job = sync.jobOf('dddddd000000')
  eq(job.phase, sync.PHASE.failed, '摘要不符时进入失败态')
  eq(job.message, '文件校验失败，请重新同步', '失败原因就是校验失败')
  ok(!FILES.has(S.pathOf(rec)), '校验不过的原件绝不落进附件目录')
  ok(!srv.calls.some((c) => c.indexOf('/ack') > 0), '没校验过就不确认，服务器保留中转件给别人')

  // 长度也不对 → 大小不符
  srv.calls = []
  srv.blobs.set('dddddd000000', bytesOf('短了'))
  await sync.pull(rec)
  ok(/文件大小不符/.test(sync.jobOf('dddddd000000').message), '大小不符也报错：' + sync.jobOf('dddddd000000').message)
}

// ---------------- 7. 本机是源：分片上传，服务器偏移不对就按它的重来 ----------------
{
  const { store: S, sync } = await fresh()
  const storage = await import('../src/utils/storage.js?case=' + caseNo)
  storage.saveTasksCache([{ id: 7, remote_id: 77, title: '任务', status: 0 }])
  const content = new Uint8Array(200000)
  for (let i = 0; i < content.length; i++) content[i] = (i * 31 + 7) & 0xff
  const localPath = putFile('wxfile://chat/big.bin', content)
  const rec = (await S.importFile(localPath, { name: 'big.pdf', size: content.length, parentKind: 'task', parentLocalId: 7 })).attachment
  const digest = createHash('sha256').update(content).digest('hex')
  eq(rec.sha256, digest, '纯 JS SHA-256 与 Node crypto 对 200KB 二进制结果一致')
  srv.meta.set(rec.uid, cloudMeta(rec.uid, { file_name: 'big.pdf', file_size: content.length, sha256: digest, mime: 'application/pdf' }))

  // 服务器只收下 3 字节就说"我这儿有 3 字节"，客户端要按服务器偏移续传
  srv.parts.set(rec.uid, content.slice(0, 3))
  srv.chunkSizeOverride = 65536
  const seenPhases = []
  sync.subscribe(() => {
    const j = sync.jobOf(rec.uid)
    if (j) seenPhases.push(j.phase + ':' + Math.round((j.progress || 0) * 100))
  })
  await sync.handlePush({ type: 'attachment_request', uid: rec.uid })
  ok(srv.blobs.has(rec.uid), '上传完成后服务器有完整中转件')
  eq(Array.from(srv.blobs.get(rec.uid)), Array.from(content), '分片拼接后字节与本机原件完全一致')
  ok(!srv.parts.has(rec.uid), '中转件转正后 .part 已收掉')
  ok(seenPhases.some((p) => p.indexOf('uploading:') === 0), '上传过程有进度：' + seenPhases.slice(0, 3).join(' '))
  ok(sync.jobOf(rec.uid) === null, '传完清进度')

  // 服务器要的是别台机器推上去的另一版：本机这份不是它要的内容，别硬传
  srv.blobs.delete(rec.uid)
  srv.calls = []
  srv.meta.set(rec.uid, cloudMeta(rec.uid, { file_name: 'big.pdf', file_size: content.length, sha256: 'f'.repeat(64) }))
  await sync.handlePush({ type: 'attachment_request', uid: rec.uid })
  ok(
    !srv.calls.some((c) => c.indexOf('/api/attachments/' + rec.uid + '/upload?') > 0),
    'init 返回的 sha256 与记录不符时不上传（硬传只会被当成坏文件）'
  )
  ok(sync.jobOf(rec.uid) === null, '对不上就收掉进度，让持有新版的主机应答')

  // 原件已被改动：拒绝上传，别把坏文件传上去
  srv.blobs.delete(rec.uid)
  S.save({ ...rec, file_size: content.length + 1 })
  await sync.handlePush({ type: 'attachment_request', uid: rec.uid })
  ok(/已被修改/.test(sync.jobOf(rec.uid).message), '本机文件与记录大小不符时提示重新添加：' + sync.jobOf(rec.uid).message)
}

// ---------------- 8. 推送只应答与自己相关的部分 ----------------
{
  const { store: S, sync } = await fresh()
  const storage = await import('../src/utils/storage.js?case=' + caseNo)
  storage.saveTasksCache([{ id: 7, remote_id: 77, title: '任务', status: 0 }])
  srv.meta.set('eeeeee000000', cloudMeta('eeeeee000000'))
  srv.syncResponse = { attachments: [cloudMeta('eeeeee000000')], deleted_uids: [], rejected_uids: [] }
  await sync.syncMetadata()
  const rec = S.byUid('eeeeee000000')

  // attachment_ready 是全站广播：本机没登记过请求就不该下
  srv.stateOverride = { blob_state: 'ready', transfers: [{ device_id: 'some-other-machine', device_name: '', status: 'pending', expires_at: '' }] }
  srv.calls = []
  await sync.handlePush({ type: 'attachment_ready', uid: rec.uid })
  ok(!srv.calls.some((c) => c.indexOf('/blob') > 0), '别的设备登记的请求，本机不代下载')

  // 本机有原件才应答 attachment_request
  srv.stateOverride = null
  S.remove(rec, { deleteOriginal: false })
  srv.calls = []
  await sync.handlePush({ type: 'attachment_request', uid: rec.uid })
  ok(!srv.calls.some((c) => c.indexOf('/upload/init') > 0), '本机没有原件时不接上传的活')

  // attachment_taken：等待收掉
  sync.pull(rec)
  await new Promise((r) => setTimeout(r, 5))
  srv.calls = []
  await sync.handlePush({ type: 'attachment_taken', uid: rec.uid })
}

// ---------------- 9. 删任务：附件转孤儿，截图原件才跟着删 ----------------
{
  const { store: S, sync } = await fresh()
  const storage = await import('../src/utils/storage.js?case=' + caseNo)
  storage.saveTasksCache([{ id: 7, remote_id: 77, title: '任务', status: 0 }])
  const doc = (await S.importFile(putFile('wxfile://chat/d.docx', 'DOC'), { name: 'd.docx', size: 3, parentKind: 'task', parentLocalId: 7 })).attachment
  const shot = (await S.importFile(putFile('wxfile://chat/s.png', 'PNG'), { name: 's.png', size: 3, parentKind: 'task', parentLocalId: 7, isScreenshot: true })).attachment
  const docPath = S.pathOf(doc)
  const shotPath = S.pathOf(shot)
  ok(FILES.has(docPath) && FILES.has(shotPath), '两份原件都在本机')
  sync.onParentDeleted('task', 7)
  eq(S.forParent('task', 7).length, 0, '孤儿附件不再挂在卡上')
  ok(S.byUid(doc.uid).orphaned, '文档附件标孤儿')
  ok(FILES.has(docPath), '删除任务不动文档原件')
  ok(!S.byUid(shot.uid), '截图任务的图片直接删掉')
  ok(!FILES.has(shotPath), '截图原件一并删除')
  await sync.syncMetadata()
  eq(srv.syncPayload.attachments.length, 0, '孤儿附件不再上报云端')
}

// ---------------- 10. 一键打开的四种分流 ----------------
{
  const { store: S, sync } = await fresh()
  void sync
  const png = (await S.importFile(putFile('wxfile://chat/a.png', 'PNG'), { name: 'a.png', size: 3, parentKind: 'task', parentLocalId: 7 })).attachment
  eq(S.open(png), null, '图片走大图预览')
  eq(global.__preview.length, 1, '调用 uni.previewImage')
  eq(global.__preview[0].urls, [S.pathOf(png)], '预览路径是本机原件')

  const docx = (await S.importFile(putFile('wxfile://chat/a.docx', 'DOC'), { name: 'a.docx', size: 3, parentKind: 'task', parentLocalId: 7 })).attachment
  eq(S.open(docx), null, 'office 走系统文档组件')
  eq(global.__openDoc.length, 1, '调用 uni.openDocument')
  eq(global.__openDoc[0].fileType, 'docx', 'openDocument 带上扩展名')

  const md = (await S.importFile(putFile('wxfile://chat/a.md', '# 标题'), { name: 'a.md', parentKind: 'task', parentLocalId: 7 })).attachment
  eq(S.open(md), null, 'markdown 走内置查看页')
  eq(global.__nav, ['/pkgData/attachment-view/attachment-view?uid=' + md.uid], '查看页按 uid 传参')

  // .rtf 在白名单内但手机没有对应组件，要说清"能在电脑端打开"
  const rtf = (await S.importFile(putFile('wxfile://chat/a.rtf', 'RTF'), { name: 'a.rtf', size: 3, parentKind: 'task', parentLocalId: 7 })).attachment
  ok(/没有可用的打开方式/.test(String(S.open(rtf))), '白名单里但手机打开的格式也给出明确指引')

  const zip = await S.importFile(putFile('wxfile://chat/a.zip', 'PK'), { name: 'a.zip', size: 2, parentKind: 'task', parentLocalId: 7 })
  ok(!zip.ok && /压缩包/.test(zip.error), '压缩包在选择阶段就拒掉：' + zip.error)

  const remote = S.save({ uid: 'ffffffff0001', parent_kind: 'task', parent_local_id: 7, file_name: 'r.txt', file_size: 12, sha256: '0'.repeat(64), owner_device_name: 'DESKTOP-X', created_at: '2026-11-01T00:00:00.000Z' })
  ok(/此文件在DESKTOP-X上/.test(String(S.open(remote))), '没原件时提示先同步')
}

// ---------------- 11. 路径派生：脏 uid/脏文件名不能越狱 ----------------
{
  const { store: S } = await fresh()
  eq(
    S.pathOf({ uid: 'aaaaaaaa0001', file_name: '../../evil.pdf' }),
    'wxfile://usr/attachments/aaaaaaaa0001/.._.._evil.pdf',
    '文件名里的穿越被改名，仍留在自己的 uid 目录内'
  )
  eq(S.dirOf('aaaaaaaa0002<script>'), 'wxfile://usr/attachments/aaaaaaaa0002script', '目录名只留安全字符')
  const foreign = { uid: '../../../Windows', file_name: 'a.txt' }
  ok(!S.hasLocalCopy(foreign), '清洗后会改变 uid 的记录一律视为"本机无原件"')
  eq(S.pathOf(foreign), 'wxfile://usr/attachments/Windows/a.txt', '脏 uid 清洗后仍落在自己的目录里')
}

// ---------------- 12. 换版：云端 sha 变了 → 标旧版 + 自动重取 ----------------
{
  const { store: S, sync } = await fresh()
  const storage = await import('../src/utils/storage.js?case=' + caseNo)
  storage.saveTasksCache([{ id: 7, remote_id: 77, title: '任务', status: 0 }])
  const OLD = '第一版内容\n'
  const NEW = '第二版内容：桌面端改过\n'
  const NEW_SHA = createHash('sha256').update(NEW).digest('hex')
  const rec = (
    await S.importFile(putFile('wxfile://chat/notes.txt', OLD), {
      name: 'notes.txt',
      size: bytesOf(OLD).length,
      parentKind: 'task',
      parentLocalId: 7
    })
  ).attachment
  eq(rec.stale_copy, false, '刚导入的附件不是旧版')
  eq(storage.normalizeAttachment({ uid: 'x1', stale_copy: 1 }).stale_copy, true, 'stale_copy 能落盘（本地字段）')

  const newer = cloudMeta(rec.uid, {
    sha256: NEW_SHA,
    file_size: bytesOf(NEW).length,
    updated_at: '2026-12-01T00:00:00.000Z'
  })
  srv.meta.set(rec.uid, newer)
  srv.syncResponse = { attachments: [newer], deleted_uids: [], rejected_uids: [] }
  srv.blobs.set(rec.uid, bytesOf(NEW))

  await sync.syncMetadata()
  eq(S.byUid(rec.uid).stale_copy, true, '云端 sha 变了：本机这份立刻标旧版')
  eq(S.byUid(rec.uid).sha256, NEW_SHA, '元数据以云端为准')
  ok(srv.syncPayload.attachments.every((a) => a.stale_copy === undefined), '旧版标记是本机私有字段，不上报')

  for (let i = 0; i < 200 && S.byUid(rec.uid).stale_copy; i++) {
    await new Promise((r) => setTimeout(r, 5))
  }
  eq(S.byUid(rec.uid).stale_copy, false, '自动取回新版后旧版标记清掉')
  eq(new TextDecoder().decode(FILES.get(S.pathOf(S.byUid(rec.uid)))), NEW, '本机原件换成了新版内容')
  ok(
    srv.calls.some((c) => c.indexOf('POST /api/attachments/' + rec.uid + '/request') === 0),
    '旧版会自己发起一次取回，不用用户点'
  )
  ok(srv.calls.some((c) => c.indexOf('/ack') > 0), '校验通过后才 ack 删中转件')
}

// ---------------- 13. 旧版不当源；ready 推过来照下 ----------------
{
  const { store: S, sync } = await fresh()
  const storage = await import('../src/utils/storage.js?case=' + caseNo)
  storage.saveTasksCache([{ id: 7, remote_id: 77, title: '任务', status: 0 }])
  const OLD = '本机旧版\n'
  const NEW = '云端新版，内容长一点\n'
  const NEW_SHA = createHash('sha256').update(NEW).digest('hex')
  const rec = (
    await S.importFile(putFile('wxfile://chat/a.txt', OLD), {
      name: 'a.txt',
      size: bytesOf(OLD).length,
      parentKind: 'task',
      parentLocalId: 7
    })
  ).attachment
  S.save({
    ...rec,
    sha256: NEW_SHA,
    file_size: bytesOf(NEW).length,
    stale_copy: true,
    updated_at: '2026-12-01T00:00:00.000Z'
  })
  srv.meta.set(rec.uid, cloudMeta(rec.uid, { file_name: 'a.txt', sha256: NEW_SHA, file_size: bytesOf(NEW).length }))

  srv.calls = []
  await sync.handlePush({ type: 'attachment_request', uid: rec.uid })
  ok(!srv.calls.some((c) => c.indexOf('/upload/init') > 0), '本机是旧版：不应答上传，别把旧内容当新版传出去')
  ok(srv.calls.some((c) => c.indexOf('/request') > 0), '顺手发起一次取回新版')
  await new Promise((r) => setTimeout(r, 20))

  // 另一台已把新版传上服务器并广播 ready：本机登记过请求，旧版也照下
  srv.blobs.set(rec.uid, bytesOf(NEW))
  await sync.handlePush({ type: 'attachment_ready', uid: rec.uid })
  eq(S.byUid(rec.uid).stale_copy, false, 'ready 推过来：旧版也下载（不再因有本机文件就跳过）')
  eq(new TextDecoder().decode(FILES.get(S.pathOf(S.byUid(rec.uid)))), NEW, '本机原件换成新版内容')
}

console.log(failed === 0 ? '\n全部通过' : '\n失败 ' + failed + ' 项')
process.exit(failed === 0 ? 0 : 1)

