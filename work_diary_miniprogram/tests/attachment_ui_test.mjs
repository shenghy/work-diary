/**
 * 小程序附件 UI 层测试，跑法：node tests/attachment_ui_test.mjs
 *
 * 覆盖三块：
 * 1) attachment_view 的胶囊状态机——文案必须和桌面端 attachment_strip.dart 一模一样，
 *    两端各说各的话，用户就得记两套"这个文件到底在不在手机上"；
 * 2) attachment_store 的选文件与批量收文件（假 wx）：取消不能报错、数量要夹到微信上限、
 *    一次选 3 个错 1 个时要把那 1 个的原因原话说出来；
 * 3) 页面接线（源码级）：附件同步必须排在任务/备忘之后、卡片点胶囊不能跳编辑页、
 *    删任务/删循环期次要标孤儿、pages.json 里有查看页路由。
 */
import { register } from 'node:module'
import { existsSync, readFileSync } from 'node:fs'
import { dirname, join, resolve } from 'node:path'
import { fileURLToPath } from 'node:url'

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

const ROOT = resolve(dirname(fileURLToPath(import.meta.url)), '..')
function src(rel) {
  return readFileSync(join(ROOT, 'src', rel), 'utf8')
}

// ---------------- 假 uni + 假微信文件系统 ----------------
const KV = new Map()
const FILES = new Map() // path → Uint8Array
const DIRS = new Set(['wxfile://usr'])

function bytesOf(v) {
  if (v instanceof Uint8Array) return v
  if (v instanceof ArrayBuffer) return new Uint8Array(v)
  return new Uint8Array(Buffer.from(String(v)))
}
function parentDir(p) {
  const i = String(p).lastIndexOf('/')
  return i > 0 ? p.slice(0, i) : ''
}

global.getCurrentPages = () => [{ route: 'pages/tasks/tasks' }]
global.uni = {
  getStorageSync: (k) => (KV.has(k) ? KV.get(k) : ''),
  setStorageSync: (k, v) => KV.set(k, v),
  removeStorageSync: (k) => KV.delete(k),
  request: () => {},
  showToast: () => {},
  showModal: () => {},
  showLoading: () => {},
  hideLoading: () => {},
  navigateTo: (o) => nav.push(o.url),
  navigateBack: () => {},
  previewImage: (o) => preview.push(o),
  openDocument: (o) => openDoc.push(o),
  setNavigationBarColor: () => {},
  getSystemInfoSync: () => ({ windowWidth: 375, theme: 'light' })
}
const nav = []
const preview = []
const openDoc = []

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
    copyFileSync(from, to) {
      if (!FILES.has(from)) throw new Error('copyFile:fail no such file')
      FILES.set(to, FILES.get(from).slice())
      DIRS.add(parentDir(to))
    },
    writeFile({ filePath, data, success, fail }) {
      FILES.set(filePath, bytesOf(data))
      DIRS.add(parentDir(filePath))
      if (success) success({})
    },
    readFile({ filePath, position, length, success, fail }) {
      const all = FILES.get(filePath)
      if (!all) return fail({ errMsg: 'readFile:fail no such file' })
      const from = position || 0
      const to = length == null ? all.length : Math.min(all.length, from + length)
      const slice = all.slice(from, Math.max(from, to))
      return { data: slice.buffer.slice(slice.byteOffset, slice.byteOffset + slice.byteLength) }
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

const view = await import('../src/utils/attachment_view.js')
const sync = await import('../src/utils/attachment_sync.js')
const store = await import('../src/utils/attachment_store.js')
const types = await import('../src/utils/attachment_types.js')
const PH = sync.PHASE

function rec(extra) {
  return {
    uid: 'uid-' + Math.random().toString(36).slice(2, 8),
    file_name: 'report.pdf',
    file_size: 1024,
    owner_device_name: '胖子的电脑',
    ...extra
  }
}

// ---------------- 1. 条目状态机 ----------------
console.log('\n== attachment_view：条目状态机 ==')

let chip = view.chipOf(rec(), null, true)
eq([chip.badgeLabel, chip.badgeColor], ['PDF', '#D9191E'], '本机文档件：角标写类型，底色对齐桌面端')
eq(chip.sub, '1.0 KB · PDF', '本机件副行=大小 + 类型')
eq(chip.state, '', '本机有原件时不写状态')
eq(chip.tone, 'local', '本机件是本地色')
eq(chip.overlay, '', '本机件不挂右上圆标')
eq(chip.thumb, '', '没给原件路径就不画缩略图')
eq(chip.removable, true, '本机件可以删')
eq(chip.busy, false, '本机件不忙')

eq(
  view.chipOf(rec({ file_name: 'a.png' }), null, true, 'wxfile://usr/a.png').thumb,
  'wxfile://usr/a.png',
  '本机图片挂真缩略图'
)
eq(view.chipOf(rec({ file_name: 'a.png' }), null, false, 'wxfile://usr/a.png').thumb, '', '原件不在本机不画缩略图')
eq(view.chipOf(rec({ file_name: 'report.pdf' }), null, true, 'wxfile://usr/a.png').thumb, '', '非图片不画缩略图')
eq(view.chipOf(rec({ file_name: 'a.png' }), null, true).badgeColor, '#0E7C86', '图片角标用青绿')
eq(view.chipOf(rec({ file_name: '无扩展名' }), null, true).badgeLabel, '文件', '认不出类型时角标写"文件"')

const remote = view.chipOf(rec(), null, false)
eq([remote.overlay, remote.state, remote.tone, remote.dashed], ['☁', '在其它主机', 'remote', true], '没原件=虚线 + ☁ + 在其它主机')
eq(remote.sub, '在其它主机', '远端件副行只说状态：半张卡片宽，大小留给长按详情')
eq(remote.removable, true, '远端件也能删（只打墓碑，不动别人机器上的原件）')

const stale = view.chipOf(rec({ stale_copy: true }), null, true)
eq([stale.overlay, stale.state, stale.tone, stale.dashed], ['↻', '云端有新版', 'stale', false], '旧版：↻ + 云端有新版 + 强调色（实线）')
eq(stale.sub, '云端有新版 · 点取回', '旧版副行直接告诉用户怎么拿新版')
eq([stale.local, stale.stale], [true, true], '旧版仍算本机有文件，但点击先取新版')
eq(view.chipOf(rec({ stale_copy: true }), null, false).state, '在其它主机', '标了旧版但本机没文件时仍按"在其它主机"说')

const up = view.chipOf(rec(), { phase: PH.uploading, progress: 0.45, message: '正在上传' }, true)
eq([up.overlay, up.state, up.tone, up.fraction], ['', '上传中 45%', 'busy', 0.45], '上传中：百分比 + 忙色 + 进度比例')
eq(view.progressWidth(up), '45%', '进度带宽度按百分比')
eq(up.removable, false, '中转进行中不给删（否则另一边拿到半截件）')
eq(up.busy, true, '上传中算忙')

const dl = view.chipOf(rec(), { phase: PH.downloading, progress: null, message: '' }, false)
eq([dl.state, dl.fraction], ['下载中 …', null], '进度未知写 …，不画进度带')
eq(view.progressWidth(dl), '', '进度未知时宽度为空')
eq(view.chipOf(rec(), { phase: PH.downloading, progress: 1.6, message: '' }, false).state, '下载中 100%', '进度夹到 100%')
eq(view.chipOf(rec(), { phase: PH.downloading, progress: -0.2, message: '' }, false).state, '下载中 0%', '进度夹到 0%')

const wait = view.chipOf(rec(), { phase: PH.waitingSource, progress: null, message: '' }, false)
eq([wait.overlay, wait.state, wait.tone], ['⏳', '等待主机上传', 'waiting'], '等源主机上传：⏳ + 兜底文案')
eq(
  view.chipOf(rec(), { phase: PH.waitingSource, message: '已通知 2 台主机，等待上传', progress: null }, false).state,
  '等待主机上传',
  '条目上只放一句状态，服务器原话留给长按详情'
)
eq(
  view.chipOf(rec(), { phase: PH.waitingSource, message: '已通知 2 台主机，等待上传', progress: null }, false).message,
  '已通知 2 台主机，等待上传',
  '服务器原话带回去给详情用'
)

const bad = view.chipOf(rec(), { phase: PH.failed, progress: null, message: '服务器上没有这份文件了' }, false)
eq([bad.overlay, bad.state, bad.tone], ['!', '同步失败', 'failed'], '失败：! + 同步失败 + 危险色')
eq(bad.sub, '同步失败 · 点重试', '失败副行直接告诉用户怎么补救')
eq(bad.busy, false, '失败不算忙——点了还能重试')
eq(bad.removable, true, '失败件要能删，否则卡上永远挂着点不动的条目')
eq(bad.message, '服务器上没有这份文件了', '失败原话带回去给长按详情用')

eq(view.progressText(null), '…', '没有任务时进度写 …')
eq(view.ownerLabel(rec()), '胖子的电脑', '归属显示设备名')
eq(view.ownerLabel({ owner_device_name: '   ' }), '其它主机', '设备名空白兜底"其它主机"')
eq(view.chipOf(rec({ file_size: 0 }), null, true).sizeText, '0 B', '大小走同一个格式化口径')

// ---------------- 2. 长按详情 ----------------
console.log('\n== attachment_view：长按详情 ==')

const localChip = view.chipOf(rec(), null, true)
eq(
  view.chipDetail(localChip, rec()),
  '1.0 KB · 在本机\n点击打开，点 × 从这条记录上移除',
  '本机件详情：大小+位置+怎么操作'
)
eq(
  view.chipDetail(remote, rec()),
  '1.0 KB · 原件在「胖子的电脑」\n点击从其它主机同步过来',
  '远端件详情：说清原件在哪台机器'
)
eq(
  view.chipDetail(view.chipOf(rec({ owner_device_name: '' }), null, false), rec({ owner_device_name: '' })),
  '1.0 KB · 原件在「其它主机」\n点击从其它主机同步过来',
  '不知道是哪台机器时写"其它主机"'
)
eq(
  view.chipDetail(bad, rec()),
  '1.0 KB · 原件在「胖子的电脑」\n服务器上没有这份文件了\n点击从其它主机同步过来',
  '失败详情带上失败原因'
)
const busyChip = view.chipOf(rec(), { phase: PH.uploading, progress: 0.2, message: '正在上传' }, true)
ok(
  view.chipDetail(busyChip, rec()).indexOf('同步进行中，传完前请勿删除') > 0,
  '中转中提示别删除，避免另一边拿到半截件'
)
eq(
  view.chipDetail(stale, rec({ stale_copy: true })),
  '1.0 KB · 在本机\n云端有更新的版本，点一下取回新版（下载完成前本机还是旧内容）',
  '旧版详情说清点击会取新版、旧内容不会直接打开'
)
ok(
  view
    .chipDetail(view.chipOf(rec({ stale_copy: true }), { phase: PH.downloading, progress: 0.3, message: '' }, true), rec())
    .indexOf('同步进行中') > 0,
  '旧版正在下载时，详情优先说同步中'
)

// ---------------- 3. 从微信聊天选文件 ----------------
console.log('\n== attachment_store.chooseFromChat ==')

const noPicker = await store.chooseFromChat(2).then(() => null, (e) => e)
eq(noPicker && noPicker.message, '请在微信聊天里选择文件', '没有选择器时给明确指引')
eq(noPicker && noPicker.cancelled, undefined, ' API 缺失不算用户取消')

let lastOptions = null
global.wx.chooseMessageFile = (opt) => {
  lastOptions = opt
  opt.success({ tempFiles: [{ path: 'wxfile://tmp/a.png', name: 'a.png', size: 3 }] })
}
const picked = await store.chooseFromChat(3)
eq(picked.length, 1, '把 tempFiles 原样交回')
eq(lastOptions.count, 3, '数量按还剩几个坑来')
eq(lastOptions.type, 'file', 'type 必须是 file，否则 extension 不生效')
eq(lastOptions.extension, types.PICK_EXTENSIONS, '扩展名白名单和服务端同一份')
ok(lastOptions.extension.indexOf('pdf') >= 0 && lastOptions.extension.indexOf('exe') < 0, '白名单收 pdf、挡 exe')

await store.chooseFromChat(0)
eq(lastOptions.count, 1, '剩余 0 个时也至少开 1 个坑（微信不允许 count=0）')
await store.chooseFromChat(99)
eq(lastOptions.count, types.CHOOSE_MAX_COUNT, '数量夹到微信单次上限')
await store.chooseFromChat('4')
eq(lastOptions.count, 4, '字符串数量也能用')

global.wx.chooseMessageFile = (opt) => opt.fail({ errMsg: 'chooseMessageFile:fail cancel' })
const cancelErr = await store.chooseFromChat(2).then(() => null, (e) => e)
eq([cancelErr.message, cancelErr.cancelled], ['已取消选择', true], '取消标成 cancelled，调用方别弹错误')
global.wx.chooseMessageFile = (opt) => opt.fail({ errMsg: 'chooseMessageFile:fail auth deny' })
const denyErr = await store.chooseFromChat(2).then(() => null, (e) => e)
eq([denyErr.cancelled, /选择文件失败/.test(denyErr.message)], [false, true], '真失败要报出来')
global.wx.chooseMessageFile = (opt) => opt.success({})
eq(await store.chooseFromChat(2), [], '返回体缺 tempFiles 当空列表')

// ---------------- 4. 批量收文件 ----------------
console.log('\n== attachment_store.attachPicked ==')

FILES.set('wxfile://tmp/doc.png', bytesOf('PNGPNG'))
FILES.set('wxfile://tmp/tool.exe', bytesOf('MZ'))
FILES.set('wxfile://tmp/movie.mp4', bytesOf('FAKE'))
const meta = { parentKind: 'task', parentLocalId: 777, parentRemoteId: null }
const mix = await store.attachPicked(
  [
    { path: 'wxfile://tmp/doc.png', name: 'doc.png', size: 6 },
    { path: 'wxfile://tmp/tool.exe', name: 'tool.exe', size: 2 },
    { path: 'wxfile://tmp/movie.mp4', name: 'movie.mp4', size: 4 }
  ],
  meta
)
eq(mix.attached.length, 1, '一次选 3 个，能存的存下来')
eq(mix.errors.length, 2, '两个不行的都要报')
ok(/可执行文件（\.exe）/.test(mix.errors[0]), 'exe 的错误说清是"可执行文件"')
ok(/视频文件（\.mp4）/.test(mix.errors[1]), 'mp4 的错误说清是"视频"')
ok(mix.errors[0].indexOf('仅支持图片和文档') > 0, '顺手告诉用户能放什么')
const saved = store.forParent('task', 777)
eq(saved.length, 1, '只落了那 1 个合法文件')
eq(saved[0].file_size, 6, '大小按微信给的实际字节记')
eq(saved[0].orphaned, false, '导入的附件不背孤儿标')
ok(FILES.has(store.pathOf(saved[0])), '原件真的复制到本机目录')
eq(store.hasLocalCopy(saved[0]), true, 'hasLocalCopy 认出刚落盘的原件')

const dup = await store.attachPicked([{ path: 'wxfile://tmp/doc.png', name: 'doc.png', size: 6 }], meta)
eq(dup.attached.length, 0, '同一个任务不重复挂同一份内容')
ok(/已经挂在当前任务上/.test(dup.errors[0]), '重复件的原因要说清')
eq((await store.attachPicked([{ path: 'wxfile://tmp/doc.png', name: 'doc.png', size: 6 }], { ...meta, parentKind: 'memo', parentLocalId: 888 })).attached.length, 1, '同样的文件挂到别的备忘是另一回事')

eq((await store.attachPicked([], meta)).errors, [], '空列表不报错')
const noParent = await store.attachPicked([{ path: 'wxfile://tmp/doc.png', name: 'doc.png', size: 6 }], { parentKind: 'task' })
eq(noParent.attached.length, 0, '没有父记录时不收文件')
ok(/先保存所属/.test(noParent.errors[0]), '提示先保存任务/备忘')
const missing = await store.attachPicked([{ path: 'wxfile://tmp/gone.png', name: 'gone.png', size: 6 }], meta)
ok(/不存在或已被移动/.test(missing.errors[0]), '微信临时件被清掉时如实说')
const over = await store.attachPicked(
  [{ path: 'wxfile://tmp/doc.png', name: 'doc.png', size: types.MAX_BYTES + 1 }],
  meta
)
ok(/超过 100MB 上限/.test(over.errors[0]), '超上限直接拦，不白读一遍大文件')

for (let i = 0; i < 10; i++) {
  const name = 'fill' + i + '.txt'
  FILES.set('wxfile://tmp/' + name, bytesOf('x' + i))
}
let filled = 0
let fillErrors = []
for (let i = 0; i < 10; i++) {
  const r = await store.attachPicked(
    [{ path: 'wxfile://tmp/fill' + i + '.txt', name: 'fill' + i + '.txt', size: 2 }],
    { parentKind: 'memo', parentLocalId: 555 }
  )
  if (r.attached.length) filled++
  else fillErrors.push(r.errors[0])
}
eq(fillErrors, new Array(types.MAX_PER_PARENT).fill('一个备忘最多挂 5 个附件，请先删除不需要的'), '超出的每个都收到"挂满"原话')
eq(filled, types.MAX_PER_PARENT, '一个备忘最多挂 ' + types.MAX_PER_PARENT + ' 个附件')
eq(store.remainingForParent('memo', 555), 0, '挂满后剩余坑位为 0')
eq(store.remainingForParent('task', 4242), types.MAX_PER_PARENT, '没附件的父记录坑位是全量')

// ---------------- 5. 记录缓存与订阅 ----------------
console.log('\n== attachment_store：记录缓存与变更订阅 ==')

let notifies = 0
let secondNotifies = 0
const offFirst = store.subscribeChanges(() => notifies++)
store.subscribeChanges(() => secondNotifies++)
FILES.set('wxfile://tmp/n1.txt', bytesOf('n1'))
FILES.set('wxfile://tmp/n2.txt', bytesOf('n2'))
await store.attachPicked([{ path: 'wxfile://tmp/n1.txt', name: 'n1.txt', size: 2 }], { parentKind: 'task', parentLocalId: 9001 })
eq(notifies, 0, '同一次写不立刻重画（合并到下一个宏任务）')
await new Promise((r) => setTimeout(r, 5))
eq([notifies, secondNotifies], [1, 1], '写记录后订阅者收到一次通知')
await store.attachPicked(
  [
    { path: 'wxfile://tmp/n1.txt', name: 'n1.txt', size: 2 },
    { path: 'wxfile://tmp/n2.txt', name: 'n2.txt', size: 2 }
  ],
  { parentKind: 'task', parentLocalId: 9002 }
)
const before = notifies
store.save(rec({ uid: 'xxxx-1', parent_kind: 'task', parent_local_id: 9003 }))
store.save(rec({ uid: 'xxxx-2', parent_kind: 'task', parent_local_id: 9003 }))
store.save(rec({ uid: 'xxxx-3', parent_kind: 'task', parent_local_id: 9003 }))
await new Promise((r) => setTimeout(r, 5))
eq(notifies, before + 1, '连续三次写只重画一次（元数据合并别把列表卡住）')
offFirst()
store.save(rec({ uid: 'xxxx-4', parent_kind: 'task', parent_local_id: 9003 }))
const afterOff = notifies
const tickSecond = secondNotifies
await new Promise((r) => setTimeout(r, 5))
eq(notifies, afterOff, '退订后不再收到通知')
ok(secondNotifies > tickSecond, '另一个订阅者还在')

// 记录表只有 writeRecords 一个写入口：同步层合并进来的每条立刻可读，
// 卡片读到的和落到 storage 的必须是同一份
store.save(rec({ uid: 'from-sync-1', parent_kind: 'memo', parent_local_id: 61, file_name: 'sync.txt', file_size: 5 }))
eq(store.byUid('from-sync-1').file_name, 'sync.txt', '刚写入的记录立刻能读到')
eq(store.forParent('memo', 61).length, 1, '按父记录过滤')
eq(KV.get('wd_attachments_cache').filter((a) => a.uid === 'from-sync-1').length, 1, '同一份也写进了存储')
eq(store.forParent('task', 9001).length, 1, '本机的老记录没被挤掉')
store.remove(store.byUid('from-sync-1'))
eq(store.byUid('from-sync-1'), null, '删除后缓存里也没有')
eq(KV.get('wd_attachments_cache').some((a) => a.uid === 'from-sync-1'), false, '存储里也一起删掉')

// 删父记录：截图件连原件一起清，普通件只标孤儿（需求里的第 7 条）
const shot = store.forParent('task', 9001)[0]
store.save({ ...shot, is_screenshot: true })
const keepRec = store.forParent('task', 9002)[0]
eq(store.onParentDeleted('task', 9001).length, 1, '删任务时处理它挂的附件')
eq(store.byUid(shot.uid), null, '截图附件的记录一并删掉')
eq(FILES.has(store.pathOf(shot)), false, '截图原件跟着任务一起删')
eq(store.onParentDeleted('task', 9001).length, 0, '再删一次不重复处理')
store.onParentDeleted('task', 9002)
eq(store.byUid(keepRec.uid).orphaned, true, '非截图附件只标孤儿，不动原件')
ok(FILES.has(store.pathOf(keepRec)), '非截图原件仍在本机')
eq(store.forParent('task', 9002).length, 0, '孤儿件不再出现在卡上')

// ---------------- 6. 打开方式分流 ----------------
console.log('\n== attachment_store.open：按类型分流 ==')

const img = store.forParent('memo', 888)[0]
preview.length = 0
eq(store.open(img), null, '图片交给微信大图预览')
eq(preview.length, 1, 'previewImage 调了一次')
eq(nav.length, 0, '还没走过页面跳转')
const txtRecord = await store.importFile('wxfile://tmp/n1.txt', { parentKind: 'task', parentLocalId: 9100, name: 'n1.txt', size: 2 })
nav.length = 0
eq(store.open(txtRecord.attachment), null, 'txt 走内置查看页')
ok(String(nav[0] || '').indexOf('/pkgData/attachment-view/attachment-view?uid=' + txtRecord.attachment.uid) === 0, '查看页带 uid')
FILES.set('wxfile://tmp/doc.pdf', bytesOf('%PDF'))
const docRecord = await store.importFile('wxfile://tmp/doc.pdf', { parentKind: 'task', parentLocalId: 9102, name: 'doc.pdf', size: 4 })
openDoc.length = 0
eq(store.open(docRecord.attachment), null, 'pdf 交给系统文档组件')
eq(openDoc[0].fileType, 'pdf', 'fileType 用不带点的扩展名')
eq(store.open({ uid: 'ghost-uid', file_name: 'g.png', owner_device_name: '办公室的电脑' }), '此文件在办公室的电脑上，先同步到本机再打开', '没原件先说清在哪台机器')
eq(store.open({ uid: 'ghost-uid', file_name: 'g.png', owner_device_name: '' }), '此文件在其它主机上，先同步到本机再打开', '不知道哪台机器就说其它主机')

// ---------------- 7. 页面接线（源码级回归） ----------------
console.log('\n== 页面接线 ==')

const tasks = src('pages/tasks/tasks.vue')
const s = tasks.indexOf('await syncMemos')
const a = tasks.indexOf('await this.doAttachmentSync')
ok(s > 0 && a > s, '附件元数据排在任务/备忘之后（否则父记录没上云只会拿到 rejected）')
ok(tasks.includes('import { syncTasks, syncMemos, syncAttachments'), 'tasks.vue 引了 syncAttachments')
ok(tasks.includes('setOnAttachmentPush'), 'tasks.vue 接了附件推送')
ok(/attachmentSync\.handlePush\(msg\)/.test(tasks), '推送交给状态机')
ok(tasks.includes('createSyncer(() => this.doAttachmentSync())'), '本地改动会触发附件同步')
ok(/attachmentSync\.onParentDeleted\('task', task\.id\)/.test(tasks), '删任务把附件标孤儿')
ok(/<attachment-strip\s+parent-kind="task"/.test(src('components/task-card.vue')), '任务卡挂附件条')
ok(/<attachment-strip\s+parent-kind="memo"/.test(tasks), '备忘行挂附件条')
ok(/parentLocalId === null \|\| this\.parentLocalId === ''/.test(src('components/attachment-strip.vue')), '父 id 为空时不误查')

const strip = src('components/attachment-strip.vue')
ok(/@click\.stop="onTap\(row\)"/.test(strip) && /@click\.stop="onRemove\(row\)"/.test(strip), '胶囊点击带 .stop，否则一点附件就跳进编辑页')
ok(strip.includes('store.subscribeChanges') && strip.includes('attachmentSync.subscribe'), '记录和中转进度都能驱动重画')
ok(strip.includes('beforeUnmount'), '卸载时取消订阅，别留野回调')

const edit = src('pkgEdit/task-edit/task-edit.vue')
const memoEdit = src('pkgEdit/memo-edit/memo-edit.vue')
;[
  [edit, 'task'],
  [memoEdit, 'memo']
].forEach(([page, kind]) => {
  ok(page.includes('chooseFromChat'), kind + ' 编辑页能从微信聊天选文件')
  ok(page.includes('attachPicked'), kind + ' 编辑页批量收文件')
  ok(page.includes('importPending'), kind + ' 编辑页新建时先记后收')
  ok(new RegExp("attachMeta\\(this\\." + kind + "LocalId\\)").test(page), kind + ' 编辑页按本机 id 归属附件')
  ok(page.includes('syncAttachments'), kind + ' 编辑页保存后推附件元数据')
  ok(page.includes("onParentDeleted('" + kind + "'"), kind + ' 编辑页删除时处理附件')
  ok(/this\.saving/.test(page), kind + ' 编辑页有防重复保存闸门')
})
ok(/await syncTasks\([\s\S]{0,160}?await syncAttachments\(\)/.test(edit), '任务编辑页：任务先上云，附件元数据排在后面')
ok(/await syncMemos\([\s\S]{0,160}?await syncAttachments\(\)/.test(memoEdit), '备忘编辑页：备忘先上云，附件元数据排在后面')

ok(src('pkgMine/repeat-manager/repeat-manager.vue').includes("import * as attachmentSync from '../../utils/attachment_sync'"), '循环任务管理页引了附件状态机')
ok(/attachmentSync\.onParentDeleted\('task', t\.id\)/.test(src('pkgMine/repeat-manager/repeat-manager.vue')), '永久删除循环期次时标孤儿')

const settings = src('pkgMine/settings/settings.vue')
ok(/await fullSyncMemos[\s\S]*await syncAttachments\(\)/.test(settings), '手动全量同步包含附件且排在最后')

const pagesJson = JSON.parse(src('pages.json').replace(/\/\/[^\n]*/g, ''))
const pkgData = (pagesJson.subPackages || []).find((p) => p.root === 'pkgData')
ok(!!pkgData && pkgData.pages.some((p) => p.path === 'attachment-view/attachment-view'), 'pages.json 注册了附件查看页')
const storeSrc = src('utils/attachment_store.js')
ok(storeSrc.includes("'/pkgData/attachment-view/attachment-view?uid='"), '打开文本件跳的就是注册的路由')

const viewer = src('pkgData/attachment-view/attachment-view.vue')
ok(viewer.includes('readText') && viewer.includes('从其它主机同步'), '查看页能读文本也能发起中转')
ok(/attachmentSync\.subscribe/.test(viewer), '查看页等中转完成后自动刷新内容')

// 构建产物里必须真的带上这些页面（漏分包是最常见的"本地好、线上白屏"）
const dist = join(ROOT, 'dist/build/mp-weixin')
if (existsSync(dist)) {
  ok(existsSync(join(dist, 'components/attachment-strip.js')), '产物含 attachment-strip 组件')
  ok(existsSync(join(dist, 'pkgData/attachment-view/attachment-view.js')), '产物含附件查看页')
  const distApp = JSON.parse(readFileSync(join(dist, 'app.json'), 'utf8'))
  const distPkg = (distApp.subPackages || []).find((p) => p.root === 'pkgData')
  // 产物里的 pages 是纯路径字符串（源码 pages.json 才是对象）
  const distPaths = distPkg ? distPkg.pages.map((p) => (typeof p === 'string' ? p : p.path)) : []
  ok(distPaths.indexOf('attachment-view/attachment-view') >= 0, '产物 app.json 带上附件查看页')
} else {
  console.log('skip 构建产物检查（先跑 npm run build:mp-weixin）')
}

console.log(failed ? '\n有 ' + failed + ' 项未通过' : '\n全部通过')
process.exit(failed ? 1 : 0)
