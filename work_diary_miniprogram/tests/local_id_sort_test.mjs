/**
 * local_id 水位 + 新建任务排序测试（实现在 src/utils/sync.js / src/utils/drag-sort.js）：
 * 跑法 node tests/local_id_sort_test.mjs
 *
 * 用假 uni 走真实的 api.js → sync.js 路径，验证两件事：
 * 1) 跨设备撞号：水位必须随云端返回的 local_id 只增不减，新设备不会从 1 重新发号；
 * 2) 新建任务排序：与桌面端 _nextSortOrder 同规则（同状态组内 min-1）。
 * 每段用 `?case=n` 动态 import 拿到全新的 sync 模块实例，模块内水位互不污染。
 */
import { register } from 'node:module'
// uni-app 源码里的 import 不带扩展名，Node 需要补 .js 才能直接加载被测模块
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

// ---------------- 假 uni（必须在 import 被测模块之前装好） ----------------
let store = new Map()
let caseNo = 0
global.getCurrentPages = () => [{ route: 'pages/tasks/tasks' }]
global.uni = {
  getStorageSync: (k) => (store.has(k) ? store.get(k) : ''),
  setStorageSync: (k, v) => store.set(k, v),
  removeStorageSync: (k) => store.delete(k),
  request: (opt) => {
    const fn = global.__routes[opt.url]
    setTimeout(() => {
      if (!fn) return opt.fail({ errMsg: '没有路由: ' + opt.url })
      opt.success({ statusCode: 200, data: fn(opt) })
    }, 0)
  },
  showToast: () => {},
  showLoading: () => {},
  hideLoading: () => {},
  reLaunch: () => {},
  navigateBack: () => {},
  setNavigationBarColor: () => {},
  getSystemInfoSync: () => ({ windowWidth: 375, theme: 'light' })
}
global.__routes = {}

// 每个用例一套干净的存储 + 全新的 sync 模块实例
async function fresh() {
  store = new Map()
  global.__routes = {}
  store.set('wd_token', 'test-token')
  caseNo += 1
  return await import('../src/utils/sync.js?case=' + caseNo)
}

function cloudTasks(n, base) {
  const out = []
  for (let i = 0; i < n; i++) {
    out.push({
      id: base + i,
      remote_id: 9000 + base + i,
      title: '云端任务' + (base + i),
      status: 0,
      urgency: 0,
      task_type: 1,
      created_at: '2026-01-01T00:00:00',
      updated_at: '2026-06-01T00:00:00',
      sort_order: i
    })
  }
  return out
}

const SYNC_URL = 'https://work.jspang.com/api/tasks/sync'
const MEMO_URL = 'https://work.jspang.com/api/memos/sync'

// ---------------- 1. 云端已有 1..50：同步后发号必须接着往上走 ----------------
{
  const m = await fresh()
  global.__routes[SYNC_URL] = () => ({ tasks: cloudTasks(50, 1), skips: [], repeat_groups: [] })
  const list = await m.syncTasks([], [])
  eq(list.length, 50, '同步拿到云端 50 条任务')
  eq(m.genLocalId(), 51, '新设备同步后从 51 开始发号（旧实现会发 1，直接覆盖别人第 1 条）')
}

// ---------------- 2. 连续发号严格递增、互不重复 ----------------
{
  const m = await fresh()
  global.__routes[SYNC_URL] = () => ({ tasks: cloudTasks(50, 1), skips: [], repeat_groups: [] })
  await m.syncTasks([], [])
  const ids = [m.genLocalId(), m.genLocalId(), m.genLocalId(), m.genLocalId()]
  eq(ids, [51, 52, 53, 54], '连续发号严格递增')
  eq(new Set(ids).size, ids.length, '发号无重复')
}

// ---------------- 3. 水位只增不减：本地删空后也不会退回小号 ----------------
{
  const m = await fresh()
  global.__routes[SYNC_URL] = () => ({ tasks: cloudTasks(50, 1), skips: [], repeat_groups: [] })
  await m.syncTasks([], [])
  const { saveTasksCache, saveMemosCache } = await import('../src/utils/storage.js?case=' + caseNo)
  saveTasksCache([])
  saveMemosCache([])
  const id = m.genLocalId()
  ok(id > 50, '缓存清空后水位不回退：' + id + ' > 50')
}

// ---------------- 4. 存量脏 id 清洗：负数/0/null 换成正整数且不与已有 id 撞 ----------------
{
  const m = await fresh()
  const { saveTasksCache, saveMemosCache, loadTasksCache, loadMemosCache } = await import(
    '../src/utils/storage.js?case=' + caseNo
  )
  saveTasksCache([
    { id: -1731234567890, title: '脏1' },
    { id: 7, title: '好' },
    { id: 0, title: '脏2' },
    { id: null, title: '脏3' }
  ])
  saveMemosCache([{ id: -42, content: '脏备忘' }])
  m.normalizeLocalIds()
  const t = loadTasksCache()
  const mm = loadMemosCache()
  const ids = [...t.map((x) => x.id), ...mm.map((x) => x.id)]
  ok(ids.every((id) => Number.isInteger(id) && id > 0), '清洗后全部是正整数：' + JSON.stringify(ids))
  eq(new Set(ids).size, ids.length, '清洗后无重复 id')
  eq(t[1].id, 7, '原本正常的 id 不动')
  m.normalizeLocalIds()
  eq(loadTasksCache()[1].id, 7, '再次调用幂等')
}

// ---------------- 5. 删除台账里的历史 local_id 也要抬水位 ----------------
{
  const m = await fresh()
  const { saveTasksDeletions } = await import('../src/utils/storage.js?case=' + caseNo)
  saveTasksDeletions([{ local_id: 400, remote_id: 1, deleted_at: '2026-01-01T00:00:00' }])
  ok(m.genLocalId() > 400, '避开删除台账用过的号：' + (m.genLocalId() - 1) + ' > 400')
}

// ---------------- 6. 备忘同步同样抬水位 ----------------
{
  const m = await fresh()
  global.__routes[MEMO_URL] = () => ({
    memos: Array.from({ length: 10 }, (_, i) => ({
      id: 200 + i,
      remote_id: 8000 + i,
      content: 'm' + i,
      created_at: '2026-01-01T00:00:00',
      updated_at: '2026-06-01T00:00:00'
    })),
    deletions: []
  })
  const list = await m.syncMemos([], [])
  eq(list.length, 10, '同步拿到云端 10 条备忘')
  ok(m.genLocalId() > 209, '备忘云端 id 也进水位：' + (m.genLocalId() - 1))
}

// ---------------- 7. 不许越过 local_id 的 INT 上限（桌面端按 max+1 续号，随机基址会互相踩） ----------------
{
  const m = await fresh()
  m.bumpLocalIdSeq(99999999999)
  const id = m.genLocalId()
  ok(id <= 2147483647, '异常水位下仍不超过 INT 上限：' + id)
  m.bumpLocalIdSeq(0)
  m.bumpLocalIdSeq('abc')
  ok(m.genLocalId() >= id, '非法水位不会把号码往回拽')
}

// ---------------- 8. 源码接线：syncTasks / syncMemos 里都有水位上报 ----------------
{
  const fs = await import('fs')
  const src = fs.readFileSync(new URL('../src/utils/sync.js', import.meta.url), 'utf8')
  ok(src.indexOf('bumpFrom(sorted)') > 0, 'syncTasks 把云端任务 id 并进水位')
  ok(src.indexOf('bumpFrom(kept)') > 0, 'syncMemos 把云端备忘 id 并进水位')
  ok(src.indexOf('ensureSeq') < 0, '旧的“只 seed 一次”发号逻辑已移除')
  ok(src.indexOf('wd_local_id_base') < 0, '没有引入随机基址（会与桌面端 max+1 互相踩号）')
  const edit = fs.readFileSync(new URL('../src/pkgEdit/task-edit/task-edit.vue', import.meta.url), 'utf8')
  ok(edit.indexOf('sort_order: 0,') < 0, 'task-edit 不再硬编码 sort_order: 0')
  ok(edit.indexOf('nextSortOrder(tasks, this.status)') > 0, 'task-edit 改用与桌面端同规则的发号')
  const man = JSON.parse(
    fs
     .readFileSync(new URL('../src/manifest.json', import.meta.url), 'utf8')
      .replace(/\/\*[\s\S]*?\*\//g, '')
  )
  // 服务器域名（request: https://work.jspang.com / socket: wss://work.jspang.com）
  // 尚未在微信公众平台「开发设置-服务器域名」里登记前，DevTools 必须关掉合法域名校验，
  // 否则所有 uni.request 在出设备前就被拦掉，登录/同步只会报“网络错误”。
  eq(man['mp-weixin'].setting.urlCheck, false, '域名未登记白名单前保持不校验')
}

// ---------------- 9. 新建任务排序：对齐桌面端 _nextSortOrder ----------------
const { nextSortOrder } = await import('../src/utils/drag-sort.js')
{
  eq(nextSortOrder([], 0), 0, '空组为 0（与桌面端 group.isEmpty 一致）')
  eq(nextSortOrder([{ status: 0, sort_order: 0 }], 0), -1, '组内最小值再往前一格')
  eq(
    nextSortOrder(
      [
        { status: 0, sort_order: 5 },
        { status: 0, sort_order: 100 }
      ],
      0
    ),
    4,
    '取组内最小值而非最后一条'
  )
  eq(
    nextSortOrder(
      [
        { status: 2, sort_order: -99 },
        { status: 0, sort_order: 3 }
      ],
      0
    ),
    2,
    '只看同状态组，已完成组的负数不牵连计划中'
  )
  eq(nextSortOrder([{ status: 1 }], 1), -1, '缺失 sort_order 按 0 处理')
  eq(nextSortOrder([{ status: 1, sort_order: null }], 1), -1, 'null 排序按 0 处理')
  // 连续新建三条，位置依次排在最前，和桌面端行为逐格一致
  const list = [{ status: 0, sort_order: 0, title: '旧任务' }]
  for (let i = 0; i < 3; i++) {
    const s = nextSortOrder(list, 0)
    list.unshift({ status: 0, sort_order: s, title: '新' + i })
  }
  eq(list.map((t) => t.sort_order), [-3, -2, -1, 0], '连续新建依次排到最前')
  const sorted = [...list].sort((a, b) => a.sort_order - b.sort_order)
  eq(sorted[0].title, '新2', '排序后最新建的在最前')
}

console.log(failed === 0 ? '\n全部通过' : '\n失败 ' + failed + ' 项')
process.exit(failed === 0 ? 0 : 1)
