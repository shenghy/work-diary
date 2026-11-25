/**
 * 小程序端 AI 能力「彻底移除」验收（源码层）
 * 跑法 node tests/ai_removal_test.mjs
 *
 * 锁住 8 件事：
 * 1) AI 页面与开关文件已删除，pages.json 不再注册这两条路由，其余路由一条不少；
 * 2) src 里没有任何 AI 入口/方法/接口调用/开关引用（注释不算，编译时会被剥掉）；
 * 3) ☰ 功能菜单恰好 4 项，三个 AI 跳转方法已删；
 * 4) 个人中心/设置/关于页的 AI 条目全部消失；
 * 5) 用户协议/隐私政策不再出现 AI、额度、截图识别字样，章节编号连续；
 * 6) 顺带删掉的 dateOffsetStr / todayStr 无残留引用，其余公共函数仍在；
 * 7) markdown-it 仍被任务/备忘渲染使用，没有被误删；
 * 8) src 的接口调用面里不含 /api/ai/*（后端与桌面端的 AI 接口保持不动）。
 */
import fs from 'node:fs'
import path from 'node:path'
import { fileURLToPath } from 'node:url'

const ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..')
const SRC = path.join(ROOT, 'src')

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
const read = (p) => fs.readFileSync(path.join(ROOT, p), 'utf8')
const exists = (p) => fs.existsSync(path.join(ROOT, p))

function walk(dir, out = []) {
  for (const e of fs.readdirSync(dir, { withFileTypes: true })) {
    const p = path.join(dir, e.name)
    if (e.isDirectory()) walk(p, out)
    else out.push(p)
  }
  return out
}

// 注释不会进编译产物，扫描前用等长空格遮蔽，保持行号/下标不变
function maskComments(text) {
  return text
    .replace(/<!--[\s\S]*?-->/g, (m) => ' '.repeat(m.length))
    .replace(/\/\*[\s\S]*?\*\//g, (m) => ' '.repeat(m.length))
    .replace(/^\s*\/\/.*$/gm, (m) => ' '.repeat(m.length))
}

// EMAIL / detail / fail 里都含 "ai" 字母，必须用边界排除，只抓真正的 AI 词
const AI_WORD = /(?<![A-Za-z])AI(?![A-Za-z])/
const FORBIDDEN = [
  ['AI_FEATURES', /AI_FEATURES/],
  ['guardAiPage', /guardAiPage/],
  ['aiOn', /\baiOn\b/],
  ['/api/ai/', /\/api\/ai\//],
  ['utils/features', /utils\/features/],
  ['summary 路由', /summary\/summary/],
  ['quota 路由', /quota\/quota/],
  ['menuDaily', /\bmenuDaily\b/],
  ['menuWeekly', /\bmenuWeekly\b/],
  ['menuQuota', /\bmenuQuota\b/],
  ['AI 字样', AI_WORD],
  ['额度', /额度/],
  ['截图识别', /截图识别/],
  ['总结', /总结/]
]

console.log('--- [1] AI 文件已删除 ---')
for (const f of [
  'src/pkgData/summary/summary.vue',
  'src/pkgMine/quota/quota.vue',
  'src/utils/features.js'
]) ok(!exists(f), '已删除 ' + f)
ok(!exists('src/pkgData/summary'), 'pkgData/summary 目录已清空')
ok(!exists('src/pkgMine/quota'), 'pkgMine/quota 目录已清空')

console.log('--- [2] pages.json 路由 ---')
const pj = JSON.parse(read('src/pages.json'))
const routes = [
  ...pj.pages.map((p) => p.path),
  ...pj.subPackages.flatMap((s) => s.pages.map((p) => s.root + '/' + p.path))
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
], '路由恰好 10 条，AI 两条已摘、其余一条不少')
ok(!/summary|quota|AI/.test(JSON.stringify(pj)), 'pages.json 全文无 summary/quota/AI')
const roots = pj.subPackages.map((s) => s.root)
for (const [page, rule] of Object.entries(pj.preloadRule || {})) {
  ok(routes.includes(page), 'preloadRule 入口页仍存在: ' + page)
  for (const pkg of rule.packages) ok(roots.includes(pkg), 'preloadRule 分包仍存在: ' + pkg)
}

console.log('--- [3] src 全量无 AI 残留 ---')
const srcFiles = walk(SRC).filter((f) => /\.(vue|js|json)$/.test(f))
const hits = []
for (const f of srcFiles) {
  const text = maskComments(fs.readFileSync(f, 'utf8'))
  const rel = path.relative(ROOT, f).replace(/\\/g, '/')
  text.split(/\r?\n/).forEach((line, i) => {
    for (const [name, re] of FORBIDDEN) {
      if (re.test(line)) hits.push(rel + ':' + (i + 1) + ' [' + name + '] ' + line.trim())
    }
  })
}
eq(hits, [], 'src ' + srcFiles.length + ' 个文件扫描无 AI 残留')

console.log('--- [4] ☰ 功能菜单 ---')
const tasks = read('src/pages/tasks/tasks.vue')
const sideOptions = tasks.match(/class="menu-option side-option"/g) || []
eq(sideOptions.length, 4, '☰ 菜单恰好 4 项')
for (const h of ['menuCloudSync', 'menuStats', 'menuRepeat', 'menuMine']) {
  ok(new RegExp('@click="' + h + '"').test(tasks), '菜单保留 ' + h)
  ok(new RegExp('\\b' + h + '\\(\\)\\s*\\{').test(tasks), '方法保留 ' + h)
}
for (const t of ['云端同步', '我的数据', '循环任务', '个人中心']) {
  ok(tasks.includes('<view class="opt-title">' + t + '</view>'), '菜单文案保留 ' + t)
}

console.log('--- [5] 个人中心 / 设置 / 关于 ---')
const mine = read('src/pkgMine/mine/mine.vue')
eq((mine.match(/class="menu-item"/g) || []).length, 5, '个人中心 5 个入口（数据/循环/设置/关于/退出）')
const settings = read('src/pkgMine/settings/settings.vue')
const dataGroup = settings.split('数据与功能</view>')[1].split('group-title')[0]
eq((dataGroup.match(/class="row"/g) || []).length, 3, '设置「数据与功能」剩 3 行（数据/循环/立即同步）')
const about = read('src/pkgMine/about/about.vue')
const featBlock = about.split('features: [')[1].split(']')[0]
eq((featBlock.match(/\{ icon:/g) || []).length, 4, '关于页功能介绍 4 条')

console.log('--- [6] 协议文案 ---')
const ag = read('src/utils/agreements.js')
for (const [name, re] of [['AI 字样', AI_WORD], ['额度', /额度/], ['截图识别', /截图识别/], ['总结', /总结/], ['第三方 AI 共享', /发送给/]]) {
  ok(!re.test(maskComments(ag)), '协议文案无「' + name + '」')
}
const userDoc = ag.split('export const USER_AGREEMENT = `')[1].split('`')[0]
const privacyDoc = ag.split('export const PRIVACY_POLICY = `')[1].split('`')[0]
const nums = (doc) => (doc.match(/^\d+\./gm) || []).map((s) => parseInt(s, 10))
eq(nums(userDoc), [1, 2, 3, 4], '用户协议章节 1-4 连续（原「功能限制」节已删）')
eq(nums(privacyDoc), [1, 2, 3, 4, 5], '隐私政策章节 1-5 连续')
ok(!/AI 功能/.test(privacyDoc), '隐私政策不再声明把任务内容交给 AI 服务')
ok(/错误日志（用于服务改进）/.test(privacyDoc), '使用日志只保留错误日志')

console.log('--- [7] 死代码清理与公共函数 ---')
const util = read('src/utils/util.js')
for (const dead of ['dateOffsetStr', 'todayStr']) {
  ok(!new RegExp(dead).test(util), 'util.js 已删 ' + dead)
  eq(
    srcFiles.filter((f) => new RegExp(dead).test(fs.readFileSync(f, 'utf8'))),
    [],
    '全项目无 ' + dead + ' 引用'
  )
}
for (const fn of ['formatDate', 'formatDateLabel', 'formatDateTime', 'showToast', 'showLoading', 'hideLoading']) {
  ok(new RegExp('export function ' + fn + '\\(').test(util), '公共函数仍在 ' + fn)
}

console.log('--- [8] markdown 渲染未被误删 ---')
ok(/import \{ isMarkdown, renderMarkdown \} from '\.\.\/\.\.\/utils\/markdown'/.test(tasks), '任务页仍用 markdown 渲染')
ok(/renderMarkdown/.test(read('src/pkgEdit/memo-edit/memo-edit.vue')), '备忘编辑仍用 markdown 渲染')
ok(/import MarkdownIt from 'markdown-it'/.test(read('src/utils/markdown.js')), 'markdown.js 仍引 markdown-it')
ok(!!JSON.parse(read('package.json')).dependencies['markdown-it'], 'package.json 保留 markdown-it 依赖')

console.log('--- [9] 接口调用面 ---')
const apis = new Set()
for (const f of srcFiles) {
  const text = fs.readFileSync(f, 'utf8')
  for (const m of text.matchAll(/['"`](\/api\/[a-z0-9\-_/]+)['"`]/gi)) apis.add(m[1])
}
const apiList = [...apis].sort()
ok(apiList.length > 0, '扫到接口调用 ' + apiList.length + ' 个')
eq(apiList.filter((a) => a.startsWith('/api/ai')), [], '无任何 /api/ai/* 调用')
console.log('     调用面: ' + apiList.join(', '))

console.log(failed ? '\n' + failed + ' 项失败' : '\n全部通过')
process.exit(failed ? 1 : 0)