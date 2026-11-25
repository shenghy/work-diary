/**
 * 同步响应防覆盖测试（src/utils/sync.js 的写代数 + 逐条 LWW 合并）
 * 跑法 node tests/sync_clobber_test.mjs
 *
 * 背景：/sync 是"上传快照 → 云端全量回信 → 整包盖本地"。请求在飞期间（弱网数秒）
 * 本地又写过的话，回信里没有那条新改动，整包一盖就永久丢失。
 * 这里用可控的假 uni.request 卡住响应，在"飞行期间"写本地缓存，验证：
 * 1) 飞行期间的编辑不被回信滚回（updated_at 新者胜），且自动补推一轮让云端追上；
 * 2) 飞行期间新建的记录不丢；
 * 3) 飞行期间删除的记录不复活（台账响应时重读）；
 * 4) 云端比本地更新时取云端（合并语义与服务端 LWW 一致）；
 * 5) 调用方快照本身就旧（跨页编辑）也走合并，不丢缓存里的新值；
 * 6) 循环实例同族同期本地已有就不收云端的（对齐服务端唯一索引）；
 * 7) 无并发写时行为与旧版完全一致：整包覆盖、不多发请求、云端写不 bump 代数；
 * 8) 快照领先缓存（调用方尚未落盘）不误判为 stale；
 * 9) 备忘同套语义。
 */
import { register } from 'node:module'
register('./esm_ext_hooks.mjs', import.meta.url)

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

const SYNC_URL = 'https://work.jspang.com/api/tasks/sync'
const MEMO_URL = 'https://work.jspang.com/api/memos/sync'

let store = new Map()
let pending = []
let caseNo = 0

global.getCurrentPages = () => [{ route: 'pages/tasks/tasks' }]
global.uni = {
  getStorageSync: (k) => (store.has(k) ? store.get(k) : ''),
  setStorageSync: (k, v) => store.set(k, v),
  removeStorageSync: (k) => store.delete(k),
  request: (opt) => {
    const rec = { url: opt.url, opt, settled: false }
    rec.done = (payload) => {
      if (rec.settled) throw new Error('同一个请求被重复响应')
      rec.settled = true
      setTimeout(() => opt.success(payload), 0)
    }
    pending.push(rec)
  },
  showToast: () => {},
  showLoading: () => {},
  hideLoading: () => {},
  reLaunch: () => {},
  navigateBack: () => {},
  setNavigationBarColor: () => {},
  getSystemInfoSync: () => ({ windowWidth: 375, theme: 'light' })
}

// storage.js 里有模块级状态（写代数 gen），必须和被测的 sync.js 用同一个 case 实例，
// 否则「飞行期间本地写过」的判定读的是另一份计数器，永远测不到合并分支。
let storage = null

async function fresh() {
  store = new Map()
  pending = []
  caseNo += 1
  store.set('wd_token', 'test-token')
  storage = await import('../src/utils/storage.js?case=' + caseNo)
  return await import('../src/utils/sync.js?case=' + caseNo)
}
const tick = () => new Promise((r) => setTimeout(r, 0))
const sent = (url) => pending.filter((p) => p.url === url)
const T0 = '2026-11-16T00:00:00.000Z'
const T1 = '2026-11-16T01:00:00.000Z'
const T2 = '2026-11-16T02:00:00.000Z'
const T3 = '2026-11-16T03:00:00.000Z'

function task(id, title, at, extra) {
  return {
    id,
    remote_id: 'r' + id,
    title,
    status: 0,
    urgency: 0,
    task_type: 1,
    created_at: T0,
    updated_at: at || T0,
    ...extra
  }
}
const cloudOf = (tasks) => ({ statusCode: 200, data: { tasks, skips: [], repeat_groups: [] } })
const titles = (list) => list.map((t) => t.title)

// ---------------- 1. 飞行期间的编辑不被滚回，且补推一轮 ----------------
{
  const m = await fresh()
  storage.saveTasksCache([task(1, '旧标题', T1)])
  const p = m.syncTasks(storage.loadTasksCache(), [])
  await tick()
  eq(sent(SYNC_URL).length, 1, '请求已发出')
  // 飞行期间：编辑页保存了新标题
  storage.saveTasksCache([task(1, '新标题', T2)])
  sent(SYNC_URL)[0].done(cloudOf([task(1, '旧标题', T1)]))
  const r = await p
  eq(titles(r), ['新标题'], '回信整包盖下时本地新编辑仍在（返回值）')
  eq(titles(storage.loadTasksCache()), ['新标题'], '本地缓存保住新编辑')
  await tick()
  eq(sent(SYNC_URL).length, 2, '合并后自动补推一轮')
  const payload = JSON.parse(JSON.stringify(sent(SYNC_URL)[1].opt.data))
  eq(payload.tasks[0].title, '新标题', '补推上传的是合并后的新值')
  sent(SYNC_URL)[1].done(cloudOf([task(1, '新标题', T2)]))
  await tick()
  eq(sent(SYNC_URL).length, 2, '云端追平后不再无限补推')
  eq(titles(storage.loadTasksCache()), ['新标题'], '收敛后缓存仍是新值')
}

// ---------------- 2. 飞行期间新建的记录不丢 ----------------
{
  const m = await fresh()
  storage.saveTasksCache([task(1, 'A', T1)])
  const p = m.syncTasks(storage.loadTasksCache(), [])
  await tick()
  storage.saveTasksCache([task(1, 'A', T1), task(2, '飞行期间新建', T2)])
  sent(SYNC_URL)[0].done(cloudOf([task(1, 'A', T1)]))
  const r = await p
  eq(titles(r).sort(), ['A', '飞行期间新建'], '新建记录保留在合并结果里')
  await tick()
  const payload = JSON.parse(JSON.stringify(sent(SYNC_URL)[1].opt.data))
  eq(payload.tasks.length, 2, '补推把新建记录带上云')
  sent(SYNC_URL)[1].done(cloudOf([task(1, 'A', T1), task(2, '飞行期间新建', T2)]))
  await tick()
}

// ---------------- 3. 飞行期间删除的记录不复活 ----------------
{
  const m = await fresh()
  storage.saveTasksCache([task(1, 'A', T1), task(2, 'B', T1)])
  const p = m.syncTasks(storage.loadTasksCache(), [])
  await tick()
  storage.saveTasksCache([task(1, 'A', T1)])
  storage.saveTasksDeletions([{ local_id: 2, remote_id: 'r2', deleted_at: T2 }])
  sent(SYNC_URL)[0].done(cloudOf([task(1, 'A', T1), task(2, 'B', T1)]))
  const r = await p
  eq(titles(r), ['A'], '飞行期间删掉的记录不被回信复活')
  eq(storage.loadTasksDeletions(), [], '已带 remote_id 的删除记录本轮收尾清除')
  await tick()
  const payload = JSON.parse(JSON.stringify(sent(SYNC_URL)[1].opt.data))
  eq(payload.tasks.length, 1, '补推不再上传已删记录')
  sent(SYNC_URL)[1].done(cloudOf([task(1, 'A', T1)]))
  await tick()
}

// ---------------- 4. 云端更新时取云端（与服务端 LWW 同语义） ----------------
{
  const m = await fresh()
  storage.saveTasksCache([task(1, '本地改', T2)])
  const p = m.syncTasks(storage.loadTasksCache(), [])
  await tick()
  storage.saveTasksCache([task(1, '本地改', T2)]) // 再写一次触发合并路径
  sent(SYNC_URL)[0].done(cloudOf([task(1, '别的设备改得更晚', T3)]))
  const r = await p
  eq(titles(r), ['别的设备改得更晚'], '平局以上云端较新者胜')
  await tick()
  sent(SYNC_URL)[1].done(cloudOf([task(1, '别的设备改得更晚', T3)]))
  await tick()
}

// ---------------- 5. 调用方快照本身就旧（跨页编辑）也走合并 ----------------
{
  const m = await fresh()
  storage.saveTasksCache([task(1, '编辑页已保存', T2)])
  // tasks.vue 内存里还是旧快照
  const p = m.syncTasks([task(1, '旧快照', T1)], [])
  await tick()
  sent(SYNC_URL)[0].done(cloudOf([task(1, '旧快照', T1)]))
  const r = await p
  eq(titles(r), ['编辑页已保存'], '快照旧于缓存时不丢缓存里的新值')
  await tick()
  const payload = JSON.parse(JSON.stringify(sent(SYNC_URL)[1].opt.data))
  eq(payload.tasks[0].title, '编辑页已保存', '补推上传缓存里的新值')
  sent(SYNC_URL)[1].done(cloudOf([task(1, '编辑页已保存', T2)]))
  await tick()
}

// ---------------- 6. 循环实例同族同期不重复 ----------------
{
  const m = await fresh()
  storage.saveTasksCache([task(1, 'A', T1)])
  const p = m.syncTasks(storage.loadTasksCache(), [])
  await tick()
  const inst = (id) =>
    task(id, '本期实例', T2, { repeat_group_id: 'g1', instance_date: '2026-11-16', repeat_type: 1 })
  storage.saveTasksCache([task(1, 'A', T1), inst(50)])
  sent(SYNC_URL)[0].done(cloudOf([task(1, 'A', T1), inst(60)]))
  const r = await p
  eq(r.map((t) => t.id).sort((a, b) => a - b), [1, 50], '同族同期本地已有实例时不收云端那条')
  await tick()
  sent(SYNC_URL)[1].done(cloudOf([task(1, 'A', T1), inst(50)]))
  await tick()
}

// ---------------- 7. 无并发写：与旧版行为一致 ----------------
{
  const m = await fresh()
  storage.saveTasksCache([task(1, 'A', T1)])
  const genBefore = storage.getTasksGen()
  const p = m.syncTasks(storage.loadTasksCache(), [])
  await tick()
  sent(SYNC_URL)[0].done(cloudOf([task(1, 'A', T1), task(3, '其它设备新增', T1)]))
  const r = await p
  eq(titles(r), ['A', '其它设备新增'], '干净路径整包采用云端全量（含其它设备新增）')
  eq(titles(storage.loadTasksCache()), ['A', '其它设备新增'], '干净路径缓存整包覆盖')
  eq(storage.getTasksGen(), genBefore, '云端响应落盘不 bump 本地写代数')
  await tick()
  eq(sent(SYNC_URL).length, 1, '干净路径不多发补推请求')
}

// ---------------- 8. 快照领先缓存（调用方未落盘）不算 stale ----------------
{
  const m = await fresh()
  const p = m.syncTasks([task(1, '内存态', T1)], [])
  await tick()
  sent(SYNC_URL)[0].done(cloudOf([task(1, '内存态', T1)]))
  const r = await p
  eq(titles(r), ['内存态'], '快照领先缓存时走干净路径整包覆盖')
  eq(titles(storage.loadTasksCache()), ['内存态'], '云端结果正常落盘')
  await tick()
  eq(sent(SYNC_URL).length, 1, '不误判 stale、不补推')
}

// ---------------- 9. 备忘：飞行期间编辑不丢 + 干净路径回归 ----------------
{
  const m = await fresh()
  const memo = (id, content, at) => ({ id, remote_id: 'm' + id, content, created_at: T0, updated_at: at })
  storage.saveMemosCache([memo(9, '旧内容', T1)])
  const p = m.syncMemos(storage.loadMemosCache(), [])
  await tick()
  storage.saveMemosCache([memo(9, '新内容', T2)])
  sent(MEMO_URL)[0].done({ statusCode: 200, data: { memos: [memo(9, '旧内容', T1)] } })
  const r = await p
  eq(r.map((x) => x.content), ['新内容'], '备忘飞行期间编辑不被滚回')
  await tick()
  eq(sent(MEMO_URL).length, 2, '备忘合并后同样补推一轮')
  sent(MEMO_URL)[1].done({ statusCode: 200, data: { memos: [memo(9, '新内容', T2)] } })
  await tick()
  eq(sent(MEMO_URL).length, 2, '备忘收敛后停止补推')

  const genBefore = storage.getMemosGen()
  const q = m.syncMemos(storage.loadMemosCache(), [])
  await tick()
  sent(MEMO_URL)[2].done({ statusCode: 200, data: { memos: [memo(9, '新内容', T2), memo(10, '别端新增', T2)] } })
  const r2 = await q
  eq(r2.length, 2, '备忘干净路径整包采用云端全量')
  eq(storage.getMemosGen(), genBefore, '备忘云端落盘不 bump 代数')
  await tick()
  eq(sent(MEMO_URL).length, 3, '备忘干净路径不补推')
}

console.log(failed === 0 ? '\n全部通过' : '\n失败 ' + failed + ' 项')
process.exit(failed === 0 ? 0 : 1)