/**
 * 启动进度状态机测试（实现在 src/pages/tasks/tasks.vue 的「启动进度」方法段）：
 * 跑法 node tests/boot_progress_test.mjs
 *
 * 直接从源码里把方法体抠出来跑，避免测试和线上代码两套逻辑：
 * 用假时钟推进 setInterval/setTimeout，验证「缓动逼近 / 阶段权重 / 6 秒兜底 / 收尾不留定时器」。
 */
import fs from 'fs'

const vue = fs.readFileSync(new URL('../src/pages/tasks/tasks.vue', import.meta.url), 'utf8')
const START = '    // ---------------- 启动进度 ----------------'
const END = '    // 下拉刷新（各滑页共用）'
const i0 = vue.indexOf(START)
const i1 = vue.indexOf(END)
if (i0 < 0 || i1 < 0 || i1 < i0) {
  console.log('FAIL 找不到「启动进度」方法段（源文件结构变了，请同步改本测试）')
  process.exit(1)
}
const methods = new Function('return {' + vue.slice(i0 + START.length, i1) + '}')()

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

// ---------------- 假时钟 ----------------
let now = 0
let seq = 1
let scheduled = []
globalThis.setTimeout = (fn, ms) => {
  const t = { id: seq++, at: now + (ms || 0), fn, every: 0 }
  scheduled.push(t)
  return t.id
}
globalThis.setInterval = (fn, ms) => {
  const t = { id: seq++, at: now + (ms || 0), fn, every: ms || 1 }
  scheduled.push(t)
  return t.id
}
const drop = (id) => {
  const i = scheduled.findIndex((t) => t.id === id)
  if (i >= 0) scheduled.splice(i, 1)
}
globalThis.clearTimeout = drop
globalThis.clearInterval = drop
function advance(ms) {
  const end = now + ms
  for (;;) {
    const due = scheduled.filter((t) => t.at <= end).sort((a, b) => a.at - b.at)[0]
    if (!due) break
    now = due.at
    due.fn()
    if (due.every) due.at = now + due.every
    else drop(due.id)
  }
  now = end
}

function makeVm() {
  // 每个用例一本独立时钟，免得上一段推进的时间把本段的 6 秒兜底提前引爆
  now = 0
  scheduled = []
  const vm = {
    loading: true,
    bootDone: false,
    bootTickTimer: null,
    bootWatchTimer: null,
    boot: { show: false, full: false, percent: 0, target: 0, label: '' }
  }
  for (const k of Object.keys(methods)) vm[k] = methods[k].bind(vm)
  return vm
}

// ---------------- 1. 起步：先给一个小的前进量 ----------------
{
  const vm = makeVm()
  vm.startBoot()
  eq(vm.boot.show, true, 'startBoot 显示进度')
  eq(vm.boot.full, false, 'startBoot 默认细线态')
  eq(vm.boot.percent, 0, 'startBoot 从 0 开始')
  eq(vm.boot.target, 12, '起步目标 12%')
  eq(vm.boot.label, '正在读取本地数据', '起步文案')
  advance(80)
  ok(vm.boot.percent > 0 && vm.boot.percent <= 12, '一格后进度在 (0,12]：' + vm.boot.percent)
  advance(4000)
  eq(vm.boot.percent, 12, '缓动收敛到目标值后停住')
}

// ---------------- 2. 阶段权重只升不降，文案跟随最新阶段 ----------------
{
  const vm = makeVm()
  vm.startBoot()
  advance(2000)
  vm.bootStep(22, '正在补齐循环任务')
  advance(2000)
  eq(vm.boot.percent, 22, '补齐阶段几秒内追平 22%')
  const p1 = vm.boot.percent
  vm.bootStep(78, '正在同步云端任务')
  vm.bootStep(50, '更靠后的文案')
  eq(vm.boot.target, 78, '阶段权重只取最大值，不会被回退')
  eq(vm.boot.label, '更靠后的文案', '回退的阶段仍能更新文案')
  advance(1500)
  ok(
    vm.boot.percent > p1 && vm.boot.percent <= 78,
    '大跨度阶段持续前进且不越界：' + vm.boot.percent.toFixed(1) + '%'
  )
}

// ---------------- 3. 正常收尾：拉满 100%、关掉骨架屏、稍后隐藏、定时器清空 ----------------
{
  const vm = makeVm()
  vm.startBoot()
  advance(500)
  vm.finishBoot()
  eq(vm.boot.percent, 100, '收尾直接拉满')
  eq(vm.bootDone, true, '收尾后标记完成')
  eq(vm.loading, false, '收尾同时关闭骨架屏')
  eq(vm.boot.show, true, '收尾后进度条仍在（等淡出）')
  advance(400)
  eq(vm.boot.show, false, '淡出后隐藏进度条')
  eq(scheduled.length, 0, '收尾后没有残留定时器')
  vm.bootStep(50, '残留调用')
  eq(vm.boot.show, false, '隐藏后 bootStep 不再改状态')
}

// ---------------- 4. 6 秒兜底：先落到本地数据，真实同步稍后到达也不反悔 ----------------
{
  const vm = makeVm()
  vm.startBoot()
  advance(3000)
  eq(vm.bootDone, false, '3 秒内不提前收尾')
  eq(vm.loading, true, '3 秒内仍显示骨架/进度')
  advance(3100)
  eq(vm.bootDone, true, '6 秒兜底触发')
  eq(vm.loading, false, '兜底后列表可见')
  eq(vm.boot.label, '网络较慢，已先用本地数据', '兜底文案')
  eq(vm.boot.percent, 100, '兜底拉满')
  advance(400)
  eq(vm.boot.show, false, '兜底后也会隐藏进度条')
  vm.finishBoot()
  eq(vm.boot.label, '网络较慢，已先用本地数据', '迟到的同步不再改写兜底文案')
  vm.bootStep(50, '迟到的阶段')
  eq(vm.boot.percent, 100, '迟到的阶段不再回退进度')
  eq(scheduled.length, 0, '兜底路径也不留定时器')
}

// ---------------- 5. onHide / onUnload：clearBootTimers 幂等且彻底 ----------------
{
  const vm = makeVm()
  vm.startBoot()
  vm.clearBootTimers()
  eq([vm.bootTickTimer, vm.bootWatchTimer], [null, null], '清理后句柄置空')
  vm.clearBootTimers()
  eq(scheduled.length, 0, '重复清理不报错、无残留定时器')
  const p = vm.boot.percent
  advance(2000)
  eq(vm.boot.percent, p, '清理后进度冻结')
}

// ---------------- 6. 未完成前 boot.show=false 时 bootStep 空转（非首启的静默同步） ----------------
{
  const vm = makeVm()
  vm.bootStep(78, '不该生效')
  eq(vm.boot.target, 0, '未 startBoot 时 bootStep 空转')
  eq(vm.boot.label, '', '未 startBoot 时不改文案')
  vm.finishBoot()
  eq(vm.loading, false, '未 startBoot 时 finishBoot 仍能关掉骨架屏')
  eq(vm.boot.show, false, '未 startBoot 时不会冒出进度条')
}

// ---------------- 7. 源码接线：阶段检查点确实埋在 onShow / pullCloud 里 ----------------
{
  const body = vue.slice(vue.indexOf('async pullCloud(silent)'))
  const order = [
    body.indexOf("this.bootStep(78, '正在同步云端任务')"),
    body.indexOf('await syncTasks('),
    body.indexOf("this.bootStep(92, '正在同步备忘')"),
    body.indexOf('await syncMemos('),
    body.indexOf('this.finishBoot()')
  ]
  ok(order.every((n) => n >= 0), 'pullCloud 里 5 个进度接线都在')
  ok(
    order[0] < order[1] && order[1] < order[2] && order[2] < order[3] && order[3] < order[4],
    '接线顺序：任务前 → 任务后 → 备忘前 → 备忘后 → 收尾'
  )
  const show = vue.slice(vue.indexOf('onShow() {'), vue.indexOf('onHide() {'))
  ok(show.indexOf('const firstBoot = !this.bootDone') >= 0, 'onShow 只在首启启动进度')
  ok(show.indexOf("this.bootStep(22, '正在补齐循环任务')") >= 0, 'onShow 缓存读取后推进')
  ok(show.indexOf("this.bootStep(35, '正在同步云端任务')") >= 0, 'onShow 循环补齐后推进')
  ok(
    show.indexOf('this.boot.full = this.tasks.length === 0 && this.memos.length === 0') >= 0,
    '无本地缓存才升级整屏进度卡'
  )
  const hide = vue.slice(vue.indexOf('onHide() {'), vue.indexOf('mounted()'))
  eq((hide.match(/this\.clearBootTimers\(\)/g) || []).length, 2, 'onHide/onUnload 都清定时器')
}

// ---------------- 8. 只用设计令牌，深浅色都靠 CSS 变量翻转 ----------------
{
  const css = vue.slice(vue.indexOf('.boot-line {'), vue.indexOf('.skeleton-list {'))
  ok(css.length > 400, '取到启动进度样式段')
  eq((css.match(/#[0-9a-fA-F]{3,8}/g) || []).length, 0, '启动进度样式无硬编码色值')
  eq((css.match(/rgba?\(/g) || []).length, 0, '启动进度样式无硬编码颜色函数')
  ok(css.indexOf('var(--track-bg)') >= 0 && css.indexOf('var(--accent)') >= 0, '进度条底色/前景走令牌')
}

console.log(failed === 0 ? '\n全部通过' : '\n失败 ' + failed + ' 项')
process.exit(failed === 0 ? 0 : 1)
