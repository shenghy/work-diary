/**
 * 编译产物层：附件条组件真身测试
 * 跑法 node tests/attachment_strip_render_test.mjs   （先 npm run build:mp-weixin）
 *
 * 源码单测证明逻辑对，这个测试证明"上传到微信的那份 js"也对：
 * 直接加载 dist/build/mp-weixin/components/attachment-strip.js，用假 uni/wx 驱动它的方法，
 * 检查卡片上这颗胶囊显示什么、点下去发生什么、长按说什么、× 删的是哪一份。
 * 产物目录不存在时打印 SKIP 并退出 0。
 */
import fs from 'node:fs'
import path from 'node:path'
import { createRequire } from 'node:module'
import { fileURLToPath } from 'node:url'

const ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..')
const DIST = path.join(ROOT, 'dist', 'build', 'mp-weixin')

if (!fs.existsSync(DIST)) {
  console.log('SKIP 未找到 dist/build/mp-weixin，请先 npm run build:mp-weixin')
  process.exit(0)
}

let failed = 0
function eq(actual, expected, msg) {
  const a = JSON.stringify(actual)
  const e = JSON.stringify(expected)
  if (a !== e) {
    failed++
    console.log('FAIL ' + msg + '\n  期望 ' + e + '\n  实际 ' + a)
  } else console.log('ok   ' + msg)
}
function ok(cond, msg) {
  if (cond) console.log('ok   ' + msg)
  else {
    failed++
    console.log('FAIL ' + msg)
  }
}

// ---------------- 假 uni / 假微信文件系统 ----------------
const KV = new Map()
const FILES = new Map()
const DIRS = new Set(['wxfile://usr'])
const toasts = []
const modals = []
const previews = []
const opened = []
const navs = []
const requests = []

function bytesOf(v) {
  if (v instanceof Uint8Array) return v
  if (v instanceof ArrayBuffer) return new Uint8Array(v)
  return new Uint8Array(Buffer.from(String(v)))
}
function parentDir(p) {
  const i = String(p).lastIndexOf('/')
  return i > 0 ? p.slice(0, i) : ''
}

const captured = { def: null }
function anyFn() { return anyFn }
const uniShim = {
  getStorageSync: (k) => (KV.has(k) ? KV.get(k) : ''),
  setStorageSync: (k, v) => KV.set(k, v),
  removeStorageSync: (k) => KV.delete(k),
  getSystemInfoSync: () => ({ statusBarHeight: 20, platform: 'devtools', windowWidth: 375, windowHeight: 667, pixelRatio: 2 }),
  getMenuButtonBoundingClientRect: () => ({ top: 24, bottom: 56, height: 32, left: 280, right: 367, width: 87 }),
  canIUse: () => true,
  showToast: (o) => toasts.push(String(o && o.title)),
  showLoading: () => {},
  hideLoading: () => {},
  showModal: (o) => modals.push(o),
  navigateTo: (o) => navs.push(o.url),
  navigateBack: () => {},
  reLaunch: () => {},
  switchTab: () => {},
  setNavigationBarTitle: () => {},
  previewImage: (o) => previews.push(o),
  openDocument: (o) => opened.push(o),
  nextTick: (fn) => { if (fn) fn() },
  createPage: (def) => { captured.def = def },
  createComponent: (def) => { captured.def = def },
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
    writeFile(o) {
      FILES.set(o.filePath, bytesOf(o.data))
      DIRS.add(parentDir(o.filePath))
      if (o.success) o.success({})
    },
    readFile(o) {
      const all = FILES.get(o.filePath)
      if (!all) return o.fail({ errMsg: 'readFile:fail no such file' })
      const from = o.position || 0
      const to = o.length == null ? all.length : Math.min(all.length, from + o.length)
      const slice = all.slice(from, Math.max(from, to))
      if (o.encoding === 'utf8') return o.success({ data: Buffer.from(slice).toString('utf8') })
      return o.success({ data: slice.buffer.slice(slice.byteOffset, slice.byteOffset + slice.byteLength) })
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
  }),
  // 假服务器：只实现这个测试要走的接口
  request: (o) => {
    const url = String(o.url).replace('https://work.jspang.com', '')
    requests.push(o.method + ' ' + url)
    setTimeout(() => {
      const m = url.match(/^\/api\/attachments\/([^/?]+)\/request$/)
      if (m) {
        if (m[1] === 'ffff0007') {
          return o.success({ statusCode: 404, data: { detail: '附件不存在或已删除' } })
        }
        return o.success({
          statusCode: 200,
          data: { state: 'requested', sources: 1, message: '已通知持有该文件的主机，等待上传' }
        })
      }
      o.success({ statusCode: 404, data: { detail: '没有路由: ' + url } })
    }, 0)
  }
}
globalThis.wx = uniShim
globalThis.uni = uniShim
globalThis.Page = uniShim.createPage
globalThis.Component = uniShim.createComponent
globalThis.getApp = () => ({ globalData: {} })
globalThis.getCurrentPages = () => [{ route: 'pages/tasks/tasks' }]

const requireCjs = createRequire(import.meta.url)
const vendorFile = path.join(DIST, 'common', 'vendor.js')
const Module = (await import('node:module')).default
const fakeVendor = new Module(vendorFile)
fakeVendor.filename = vendorFile
fakeVendor.loaded = true
// 产物里的 wx 调用走 vendor 的 wx$1，不是全局 wx：假 vendor 要顶上同一个假 wx
fakeVendor.exports = new Proxy({ index: uniShim, 'wx$1': uniShim, _export_sfc: (sfc) => sfc }, {
  get: (t, k) => (k in t ? t[k] : typeof k === 'string' ? anyFn : undefined),
  has: () => true
})
requireCjs.cache[vendorFile] = fakeVendor

const store = requireCjs(path.join(DIST, 'utils/attachment_store.js'))
const sync = requireCjs(path.join(DIST, 'utils/attachment_sync.js'))

// ---------------- 造数据：本机有原件的、原件在别的电脑的、云端已删的、孤儿、别人的任务 ----------------
KV.set('wd_token', 'fake-token')
KV.set('wd_device_id', 'dev-mine')
KV.set('wd_device_name', '胖子的手机')

function record(uid, name, extra) {
  return {
    uid,
    parent_kind: 'task',
    parent_local_id: 777,
    parent_remote_id: 91,
    owner_device_id: 'dev-pc',
    owner_device_name: '胖子的电脑',
    file_name: name,
    file_size: 2048,
    sha256: 'x',
    mime: 'application/octet-stream',
    is_screenshot: false,
    orphaned: false,
    blob_state: 'none',
    created_at: '2026-11-20T01:00:00.000Z',
    updated_at: '2026-11-20T01:00:00.000Z',
    ...extra
  }
}
const LOCAL_PNG = record('aaaa0001', 'photo.png')
const REMOTE_PDF = record('bbbb0002', '合同.pdf')
const ORPHAN = record('cccc0003', 'gone.png', { orphaned: true })
const OTHER_TASK = record('dddd0004', 'other.png', { parent_local_id: 888 })
// 云端已没有这条附件（假服务器对它返 404），用来验"同步失败"那颗胶囊
const MISSING = record('ffff0007', 'missing.pdf')
KV.set('wd_attachments_cache', [LOCAL_PNG, REMOTE_PDF, MISSING, ORPHAN, OTHER_TASK])
// 本机原件：只有 photo.png 真的在这台手机上
const localPngPath = 'wxfile://usr/attachments/aaaa0001/photo.png'
FILES.set(localPngPath, bytesOf('PNGDATA'))

requireCjs(path.join(DIST, 'components/attachment-strip.js'))
const def = captured.def
ok(!!def && def.name === 'AttachmentStrip', '编译后的组件名仍是 AttachmentStrip')

const emits = []
function makeVm(props) {
  const vm = Object.assign({}, def.methods, def.data(), {
    parentKind: 'task',
    parentLocalId: 777,
    pending: null,
    $emit: (name, payload) => emits.push([name, payload])
  }, props || {})
  if (def.mounted) def.mounted.call(vm)
  return vm
}

console.log('--- [1] 条目渲染 ---')
const vm = makeVm()
eq(vm.rows.length, 3, '任务 777 只画 3 条：孤儿件和别的任务的件都不画')
eq(vm.rows.map((r) => r.name), ['photo.png', '合同.pdf', 'missing.pdf'], '顺序按记录顺序')
eq(
  [vm.rows[0].badgeLabel, vm.rows[0].tone, vm.rows[0].state, vm.rows[0].thumb],
  ['PNG', 'local', '', localPngPath],
  '本机图片件：PNG 角标 + 缩略图走本机原件路径'
)
eq(vm.rows[0].sub, '2.0 KB · 图片', '本机件副行=大小 + 类型')
eq([vm.rows[1].overlay, vm.rows[1].tone, vm.rows[1].state, vm.rows[1].dashed], ['☁', 'remote', '在其它主机', true], '原件在别的电脑：虚线 + ☁ + 在其它主机')
eq(vm.rows[1].thumb, '', '原件不在本机，没有缩略图可画')
eq(vm.rows[1].removable, true, '远端件也能移除')

console.log('--- [2] 新建流程的待收文件 ---')
const vmNew = makeVm({ parentLocalId: null, pending: [{ path: 'wxfile://tmp/x.pdf', name: 'x.pdf', size: 3 }] })
eq(vmNew.rows.length, 1, '还没落库时只画待收文件')
eq([vmNew.rows[0].badgeLabel, vmNew.rows[0].tone, vmNew.rows[0].sub], ['PDF', 'pending', '3 B · PDF'], '待收文件用 PDF 角标 + 大小')
vmNew.onTap(vmNew.rows[0])
eq(toasts.length, 0, '点待收文件不做任何事（保存后才收进本机）')
vmNew.onRemove(vmNew.rows[0])
eq(emits[emits.length - 1], ['remove-pending', 0], '待收文件的 × 交回编辑页移除')

console.log('--- [3] 点胶囊 ---')
previews.length = 0
vm.onTap(vm.rows[0])
eq(previews.length, 1, '本机件点开：走大图预览')
eq(previews[0].urls[0], localPngPath, '预览的就是本机原件路径')
toasts.length = 0
vm.onTap({ kind: 'record', uid: 'zzz', local: false })
eq(toasts[0], '附件已不存在，下拉刷新一下', '记录被别端删掉后点胶囊给准话')

requests.length = 0
vm.onTap(vm.rows[1])
await new Promise((r) => setTimeout(r, 10))
eq(requests, ['POST /api/attachments/bbbb0002/request'], '远端件点一下就是发起按需中转')
eq([vm.rows[1].overlay, vm.rows[1].state, vm.rows[1].message, vm.rows[1].removable], ['⏳', '等待主机上传', '已通知持有该文件的主机，等待上传', false], '中转等待中：⏳ + 条目只写状态，服务器原话留给详情 + 不给删')
toasts.length = 0
vm.onTap(vm.rows[1])
eq(toasts[0], '已通知持有该文件的主机，等待上传', '等待中再点只报进度，不重复发起')
eq(vm.rows[1].busy, true, '等待中仍算忙：胶囊上的点法跟着状态机走')

requests.length = 0
toasts.length = 0
vm.onTap(vm.rows[2])
await new Promise((r) => setTimeout(r, 10))
eq(requests, ['POST /api/attachments/ffff0007/request'], '第三颗也发起中转')
eq([vm.rows[2].overlay, vm.rows[2].state, vm.rows[2].tone], ['!', '同步失败', 'failed'], '服务器说没这条附件：! + 同步失败')
eq(vm.rows[2].removable, true, '失败件可以删，不会永远挂在卡上')
eq(vm.rows[2].busy, false, '失败件不算忙，再点就是重试')
requests.length = 0
vm.onTap(vm.rows[2])
await new Promise((r) => setTimeout(r, 10))
eq(requests.length, 1, '失败后再点一次是真重试，不是弹一句"稍后再试"')

console.log('--- [4] 长按详情 ---')
modals.length = 0
vm.onInfo(vm.rows[1])
ok(modals[0].content.indexOf('原件在「胖子的电脑」') > 0, '长按说清原件在哪台机器')
eq(modals[0].showCancel, false, '详情只有一个"知道了"')
modals.length = 0
vm.onInfo(vm.rows[0])
ok(modals[0].content.indexOf('在本机') > 0, '本机件详情写在本机')

console.log('--- [5] × 删除 ---')
modals.length = 0
vm.onRemove(vm.rows[0])
ok(modals[0].content.indexOf('本机原件会一并删除') > 0, '删本机件先说清原件一起删')
modals[0].success({ confirm: true })
eq(store.byUid('aaaa0001'), null, '确认后本机记录删掉')
eq(FILES.has(localPngPath), false, '原件也从本机删除')
eq(emits[emits.length - 1], ['changed', undefined], '删完通知页面去推墓碑')
eq(vm.rows.map((r) => r.uid), ['bbbb0002', 'ffff0007'], '胶囊立刻少一颗')
modals.length = 0
vm.onRemove(vm.rows[0])
ok(modals[0].content.indexOf('其它设备同步后就看不到它了') > 0, '删远端件只说"移除"，不说删原件')
modals[0].success({ confirm: false })
eq(vm.rows.length, 2, '取消就不动')

console.log('--- [5b] 云端有新版 ---')
const STALE = record('gggg0008', 'old.pdf', { stale_copy: true })
store.save(STALE)
const stalePath = 'wxfile://usr/attachments/gggg0008/old.pdf'
FILES.set(stalePath, bytesOf('OLDPDF'))
await new Promise((r) => setTimeout(r, 5))
const vmStale = makeVm()
const staleRow = vmStale.rows.find((r) => r.uid === 'gggg0008')
ok(!!staleRow, '旧版附件照常画出来')
eq(
  [staleRow.overlay, staleRow.state, staleRow.tone, staleRow.dashed],
  ['↻', '云端有新版', 'stale', false],
  '旧版：↻ + 云端有新版 + 实线强调色'
)
eq(staleRow.sub, '云端有新版 · 点取回', '副行告诉用户点一下取新版')
requests.length = 0
previews.length = 0
vmStale.onTap(staleRow)
await new Promise((r) => setTimeout(r, 10))
eq(requests, ['POST /api/attachments/gggg0008/request'], '旧版点一下先取新版（对齐桌面端），不是打开旧文件')
eq(previews.length, 0, '不会打开旧内容')
def.beforeUnmount.call(vmStale)

console.log('--- [6] 订阅与退订 ---')
const rowsBefore = vm.rows.length
store.save(record('eeee0005', 'new.docx'))
await new Promise((r) => setTimeout(r, 5))
eq(vm.rows.length, rowsBefore + 1, '同步层合进来一条新记录，胶囊自己长出来')
def.beforeUnmount.call(vm)
store.save(record('ffff0006', 'after.png'))
await new Promise((r) => setTimeout(r, 5))
eq(vm.rows.length, rowsBefore + 1, '退订后不再重画，页面销毁不留野回调')

console.log(failed ? '\n有 ' + failed + ' 项未通过' : '\n全部通过')
process.exit(failed ? 1 : 0)
