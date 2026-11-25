/**
 * 小程序端 AI 能力「彻底移除」验收（编译产物层）
 * 跑法 node tests/dist_ai_absence_test.mjs   （先 npm run build:mp-weixin）
 *
 * 源码干净不等于上传包干净：旧产物目录若没清掉，summary/quota 仍会被一起上传。
 * 这里直接扫 dist/build/mp-weixin 的每一个文件，锁住 7 件事：
 * 1) AI 页面目录与 features.js 不在产物里；
 * 2) app.json 路由恰好 10 条，无 summary/quota；
 * 3) ☰ 菜单编译后恰好 4 项，三个 AI 跳转方法不在 js 里；
 * 4) 全产物文本无 AI 字样 / /api/ai/ / 额度 / 总结 等残留；
 * 5) 协议产物无 AI 条款；util 产物无 dateOffsetStr / todayStr；
 * 6) markdown-it 仍在 vendor 里（任务/备忘渲染依赖，不能被误删）；
 * 7) 9 个编译页面在 Node 里真加载真初始化，删文件没有牵连其余页面。
 * 产物目录不存在时打印 SKIP 并退出 0。
 */
import fs from 'node:fs'
import path from 'node:path'
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
const read = (rel) => fs.readFileSync(path.join(DIST, rel), 'utf8')
const has = (rel) => fs.existsSync(path.join(DIST, rel))

function walk(dir, out = []) {
  for (const e of fs.readdirSync(dir, { withFileTypes: true })) {
    const p = path.join(dir, e.name)
    if (e.isDirectory()) walk(p, out)
    else out.push(p)
  }
  return out
}

const AI_WORD = /(?<![A-Za-z])AI(?![A-Za-z])/
const FORBIDDEN = [
  ['AI_FEATURES', /AI_FEATURES/],
  ['guardAiPage', /guardAiPage/],
  ['aiOn', /\baiOn\b/],
  ['/api/ai/', /\/api\/ai\//],
  ['summary 路由', /summary\/summary/],
  ['quota 路由', /quota\/quota/],
  ['menuDaily', /menuDaily/],
  ['menuWeekly', /menuWeekly/],
  ['menuQuota', /menuQuota/],
  ['AI 字样', AI_WORD],
  ['额度', /额度/],
  ['截图识别', /截图识别/],
  ['总结', /总结/],
  ['dateOffsetStr', /dateOffsetStr/],
  ['todayStr', /todayStr/]
]

console.log('--- [1] AI 产物已不存在 ---')
for (const p of ['pkgData/summary', 'pkgMine/quota', 'utils/features.js']) {
  ok(!has(p), '产物无 ' + p)
}

console.log('--- [2] app.json 路由 ---')
const app = JSON.parse(read('app.json'))
const routes = [
  ...app.pages,
  ...app.subPackages.flatMap((s) => s.pages.map((p) => s.root + '/' + p))
]
eq(routes.sort(), [
  'pages/login/login',
  'pages/tasks/tasks',
  'pkgData/attachment-view/attachment-view',
  'pkgData/stats/stats',
  'pkgEdit/memo-edit/memo-edit',
  'pkgEdit/task-edit/task-edit',
  'pkgMine/about/about',
  'pkgMine/mine/mine',
  'pkgMine/repeat-manager/repeat-manager',
  'pkgMine/settings/settings'
], 'app.json 路由恰好 10 条')
ok(!/summary|quota|AI/.test(read('app.json')), 'app.json 全文无 summary/quota/AI')
for (const r of routes) ok(has(r + '.js') && has(r + '.wxml'), '路由产物齐全 ' + r)

console.log('--- [3] ☰ 菜单编译结果 ---')
const twxml = read('pages/tasks/tasks.wxml')
eq((twxml.match(/menu-option side-option/g) || []).length, 4, '编译后 ☰ 菜单恰好 4 项')
for (const t of ['云端同步', '我的数据', '循环任务', '个人中心']) {
  ok(twxml.includes('>' + t + '<'), '菜单文案保留 ' + t)
}
const tjs = read('pages/tasks/tasks.js')
for (const h of ['menuDaily', 'menuWeekly', 'menuQuota', 'aiOn']) {
  ok(!tjs.includes(h), 'tasks.js 无 ' + h)
}
for (const h of ['menuCloudSync', 'menuStats', 'menuRepeat', 'menuMine']) {
  ok(tjs.includes(h), 'tasks.js 保留 ' + h)
}

console.log('--- [4] 全产物文本扫描 ---')
const files = walk(DIST)
const hits = []
for (const f of files) {
  if (!/\.(js|json|wxml|wxss|txt)$/.test(f)) continue
  const rel = path.relative(DIST, f).replace(/\\/g, '/')
  const text = fs.readFileSync(f, 'utf8')
  text.split(/\r?\n/).forEach((line, i) => {
    for (const [name, re] of FORBIDDEN) {
      if (re.test(line)) hits.push(rel + ':' + (i + 1) + ' [' + name + '] ' + line.trim().slice(0, 120))
    }
  })
}
eq(hits, [], '产物 ' + files.length + ' 个文件扫描无 AI 残留')

console.log('--- [5] 协议与 util 产物 ---')
const ag = read('utils/agreements.js')
ok(!AI_WORD.test(ag) && !/额度|截图识别|总结|发送给/.test(ag), '协议产物无 AI 条款')
ok(/错误日志/.test(ag), '协议产物保留错误日志条款')
const utilJs = read('utils/util.js')
for (const dead of ['dateOffsetStr', 'todayStr']) {
  ok(!new RegExp(dead).test(utilJs), 'util 产物无 ' + dead)
}
ok(/formatDate/.test(utilJs), 'util 产物保留 formatDate')

console.log('--- [6] markdown-it 未被误删 ---')
const vendor = read('common/vendor.js')
ok(/MarkdownIt|markdown-it/.test(vendor), 'vendor 仍含 markdown-it')
ok(/renderMarkdown/.test(read('utils/markdown.js')), 'markdown 工具仍在产物里')

console.log('--- [7] 编译页面运行时冒烟（删文件后其余页面仍能初始化） ---')
const Module = (await import('node:module')).default
const { createRequire } = await import('node:module')
const requireCjs = createRequire(import.meta.url)

const store = new Map()
const captured = { def: null }
function anyFn() { return anyFn }
const uniShim = {
  getStorageSync: (k) => (store.has(k) ? store.get(k) : ''),
  setStorageSync: (k, v) => store.set(k, v),
  removeStorageSync: (k) => store.delete(k),
  getSystemInfoSync: () => ({ statusBarHeight: 20, platform: 'devtools', windowWidth: 375, windowHeight: 667, pixelRatio: 2 }),
  getMenuButtonBoundingClientRect: () => ({ top: 24, bottom: 56, height: 32, left: 280, right: 367, width: 87 }),
  canIUse: () => true,
  showToast: () => {}, showLoading: () => {}, hideLoading: () => {},
  navigateTo: () => {}, navigateBack: () => {}, reLaunch: () => {}, switchTab: () => {},
  setNavigationBarTitle: () => {},
  nextTick: (fn) => { if (fn) fn() },
  request: () => {},
  createPage: (def) => { captured.def = def; return def },
  createComponent: (def) => { captured.def = def; return def },
  env: { USER_DATA_PATH: '' },
  getFileSystemManager: () => ({ writeFileSync: () => {} })
}
const vendorFile = path.join(DIST, 'common', 'vendor.js')
const fakeVendor = new Module(vendorFile)
fakeVendor.filename = vendorFile
fakeVendor.loaded = true
fakeVendor.exports = new Proxy({ index: uniShim, _export_sfc: (sfc) => sfc }, {
  get: (t, k) => (k in t ? t[k] : typeof k === 'string' ? anyFn : undefined),
  has: () => true
})
requireCjs.cache[vendorFile] = fakeVendor
globalThis.wx = uniShim
globalThis.Page = (def) => { captured.def = def }
globalThis.Component = (def) => { captured.def = def }
globalThis.getApp = () => ({ globalData: {} })
globalThis.getCurrentPages = () => [{ route: 'pages/tasks/tasks' }]

const PAGES = [
  'pages/tasks/tasks.js',
  'pages/login/login.js',
  'pkgData/stats/stats.js',
  'pkgData/attachment-view/attachment-view.js',
  'pkgEdit/task-edit/task-edit.js',
  'pkgEdit/memo-edit/memo-edit.js',
  'pkgMine/mine/mine.js',
  'pkgMine/settings/settings.js',
  'pkgMine/about/about.js',
  'pkgMine/repeat-manager/repeat-manager.js'
]
const defs = {}
for (const rel of PAGES) {
  captured.def = null
  let err = null
  try { requireCjs(path.join(DIST, rel)) } catch (e) { err = e }
  ok(!err, '页面模块可加载 ' + rel + (err ? ' -> ' + err.message : ''))
  ok(!!captured.def, '页面已注册 ' + rel)
  defs[rel] = captured.def
}
const tasksDef = defs['pages/tasks/tasks.js']
if (tasksDef && typeof tasksDef.data === 'function') {
  const d = tasksDef.data()
  ok(!('aiOn' in d), 'tasks data() 无 aiOn')
  for (const h of ['menuCloudSync', 'menuStats', 'menuRepeat', 'menuMine']) {
    ok(typeof tasksDef.methods[h] === 'function', 'tasks 方法仍在 ' + h)
  }
  for (const h of ['menuDaily', 'menuWeekly', 'menuQuota']) {
    ok(!tasksDef.methods[h], 'tasks 方法已删 ' + h)
  }
}
const aboutDef = defs['pkgMine/about/about.js']
if (aboutDef && typeof aboutDef.data === 'function') {
  const f = aboutDef.data().features
  eq(f.length, 4, '关于页运行时功能介绍 4 条')
  ok(!f.some((x) => AI_WORD.test(x.text)), '关于页功能介绍无 AI')
}
for (const rel of ['pkgMine/mine/mine.js', 'pkgMine/settings/settings.js']) {
  const def = defs[rel]
  if (def && typeof def.data === 'function') ok(!('aiOn' in def.data()), rel + ' data() 无 aiOn')
}

console.log('--- 体积 ---')
const sizeOf = (dir) => walk(dir).reduce((n, f) => n + fs.statSync(f).size, 0)
const kb = (n) => (n / 1024).toFixed(1) + 'KB'
const total = sizeOf(DIST)
console.log('     总计 ' + kb(total))
for (const d of ['pages', 'pkgEdit', 'pkgData', 'pkgMine', 'common', 'components', 'utils', 'node-modules', 'static']) {
  const p = path.join(DIST, d)
  if (fs.existsSync(p)) console.log('     ' + d.padEnd(14) + kb(sizeOf(p)))
}

console.log(failed ? '\n' + failed + ' 项失败' : '\n全部通过')
process.exit(failed ? 1 : 0)