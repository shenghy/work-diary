/**
 * 同步并发通道测试（实现在 src/utils/sync.js 的 createChannel / clientHeaders）
 * 跑法 node tests/sync_channel_test.mjs
 *
 * 背景：服务端 /sync 是"全量 LWW + 新记录 INSERT"，两条并发请求带同一条新循环规则时，
 * 后一条看不到前一条未提交的 INSERT，直接 INSERT 撞 repeat_groups.uk_user_group(1062)，
 * _merge_groups 没接这个异常 → HTTP 500，整轮事务回滚。真机上表现为同步偶发失败、
 * 过一会儿又自己好了。这里用可控的假 uni.request 卡住响应，验证：
 * 1) 任意时刻同一接口最多只有 1 个请求在飞；
 * 2) 排队期间只保留最新快照（全量上传，后一次的本地状态一定更新）；
 * 3) 请求失败不会把通道卡死，排队的下一轮照常发出；
 * 4) 每个同步请求都带 X-Client-Id，且与 WebSocket 用的是同一个 id（服务端据此排除本端推送）。
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

// ---------------- 假 uni：请求不自动回，由测试手动 settle ----------------
const SYNC_URL = 'https://work.jspang.com/api/tasks/sync'
const MEMO_URL = 'https://work.jspang.com/api/memos/sync'

let store = new Map()
let pending = [] // { url, opt, settled }
let caseNo = 0
const inflight = {} // url -> 当前在飞数量
const maxInflight = {} // url -> 历史峰值

global.getCurrentPages = () => [{ route: 'pages/tasks/tasks' }]
global.uni = {
  getStorageSync: (k) => (store.has(k) ? store.get(k) : ''),
  setStorageSync: (k, v) => store.set(k, v),
  removeStorageSync: (k) => store.delete(k),
  request: (opt) => {
    const url = opt.url
    inflight[url] = (inflight[url] || 0) + 1
    maxInflight[url] = Math.max(maxInflight[url] || 0, inflight[url])
    const rec = { url, opt, settled: false }
    rec.done = (payload) => {
      if (rec.settled) throw new Error('同一个请求被重复响应')
      rec.settled = true
      inflight[url]--
      setTimeout(() => opt.success(payload), 0)
    }
    rec.fail = (err) => {
      if (rec.settled) throw new Error('同一个请求被重复响应')
      rec.settled = true
      inflight[url]--
      setTimeout(() => opt.fail(err), 0)
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

async function fresh() {
  store = new Map()
  pending = []
  caseNo += 1
  store.set('wd_token', 'test-token')
  return await import('../src/utils/sync.js?case=' + caseNo)
}

// 等 microtask 队列跑完，让通道把请求真正发出去
function tick() {
  return new Promise((r) => setTimeout(r, 0))
}

function sent(url) {
  return pending.filter((p) => p.url === url)
}

function task(id, title) {
  return {
    id,
    remote_id: null,
    title,
    status: 0,
    urgency: 0,
    task_type: 1,
    created_at: '2026-11-16T00:00:00.000Z',
    updated_at: '2026-11-16T00:00:00.000Z'
  }
}

const EMPTY_CLOUD = { tasks: [], skips: [], repeat_groups: [] }

// ---------------- 1. 并发调用不会同时发两个请求 ----------------
{
  const m = await fresh()
  const p1 = m.syncTasks([task(1, 'A')], [])
  await tick()
  eq(sent(SYNC_URL).length, 1, '第一个调用发出请求')

  const p2 = m.syncTasks([task(2, 'B')], [])
  const p3 = m.syncTasks([task(3, 'C')], [])
  await tick()
  eq(sent(SYNC_URL).length, 1, '后两个调用没有插队并发，仍在排队')
  eq(maxInflight[SYNC_URL], 1, '同一接口任意时刻只有 1 个请求在飞')

  sent(SYNC_URL)[0].done({ statusCode: 200, data: EMPTY_CLOUD })
  await p1
  await tick()
  eq(sent(SYNC_URL).length, 2, '前一轮结束后排队的请求才发出')

  sent(SYNC_URL)[1].done({ statusCode: 200, data: EMPTY_CLOUD })
  await Promise.all([p2, p3])
  eq(maxInflight[SYNC_URL], 1, '全程峰值仍是 1')
}

// ---------------- 2. 排队期间只保留最新快照 ----------------
{
  const m = await fresh()
  const p1 = m.syncTasks([task(1, '旧')], [])
  await tick()
  const p2 = m.syncTasks([task(2, '中')], [])
  const p3 = m.syncTasks([task(3, '最新')], [])
  await tick()

  sent(SYNC_URL)[0].done({ statusCode: 200, data: EMPTY_CLOUD })
  await p1
  await tick()
  const second = JSON.parse(JSON.stringify(sent(SYNC_URL)[1].opt.data))
  eq(second.tasks.length, 1, '合并后只补发一轮，不逐条重放')
  eq(second.tasks[0].title, '最新', '排队槽位用最后一次调用的本地状态')
  sent(SYNC_URL)[1].done({ statusCode: 200, data: EMPTY_CLOUD })
  const r2 = await p2
  const r3 = await p3
  eq(r3, r2, '排队的两个调用拿到同一份云端结果')
}

// ---------------- 3. 失败不会把通道卡死 ----------------
{
  const m = await fresh()
  const p1 = m.syncTasks([task(1, 'A')], [])
  await tick()
  const p2 = m.syncTasks([task(2, 'B')], [])

  // 500：服务端未捕获异常时就是这个形状（Starlette 纯文本 Internal Server Error）
  sent(SYNC_URL)[0].done({ statusCode: 500, data: 'Internal Server Error' })
  let e1 = null
  try {
    await p1
  } catch (e) {
    e1 = e.message
  }
  ok(e1 && e1.indexOf('500') >= 0, '500 透出为同步失败：' + e1)

  await tick()
  eq(sent(SYNC_URL).length, 2, '失败后排队的请求照常发出（通道没被卡死）')
  sent(SYNC_URL)[1].done({ statusCode: 200, data: EMPTY_CLOUD })
  const r2 = await p2
  eq(r2.length, 0, '下一轮成功返回，调用方拿到云端数据')

  // 网络层失败（request:fail）同样不能卡死通道
  const p3 = m.syncTasks([task(3, 'C')], [])
  await tick()
  sent(SYNC_URL)[2].fail({ errMsg: 'request:fail timeout' })
  let e3 = null
  try {
    await p3
  } catch (e) {
    e3 = e.message
  }
  ok(e3 && e3.indexOf('超时') >= 0, '超时归类为请求超时：' + e3)
  const p4 = m.syncTasks([task(4, 'D')], [])
  await tick()
  eq(sent(SYNC_URL).length, 4, '超时后通道仍然可用')
  sent(SYNC_URL)[3].done({ statusCode: 200, data: EMPTY_CLOUD })
  await p4
}

// ---------------- 4. 每条同步请求都带设备标识 ----------------
{
  const m = await fresh()
  const p = m.syncTasks([], [])
  await tick()
  const header = sent(SYNC_URL)[0].opt.header
  ok(typeof header['X-Client-Id'] === 'string' && header['X-Client-Id'].length === 32, '任务同步带 32 位 X-Client-Id')
  eq(header['X-Client-Id'], store.get('wd_ws_client_id'), '与 WebSocket 用的是同一个 client_id')
  eq(header['Authorization'], 'Bearer test-token', '原有鉴权头不受影响')
  sent(SYNC_URL)[0].done({ statusCode: 200, data: EMPTY_CLOUD })
  await p

  const q = m.syncMemos([], [])
  await tick()
  eq(sent(MEMO_URL)[0].opt.header['X-Client-Id'], store.get('wd_ws_client_id'), '备忘同步同样带设备标识')
  sent(MEMO_URL)[0].done({ statusCode: 200, data: { memos: [], deletions: [] } })
  await q
}

// ---------------- 5. 任务与备忘是两条独立通道，互不阻塞 ----------------
{
  const m = await fresh()
  const p = m.syncTasks([task(1, 'A')], [])
  const q = m.syncMemos([{ id: 9, content: 'm', created_at: '2026-11-16T00:00:00.000Z' }], [])
  await tick()
  eq(sent(SYNC_URL).length, 1, '任务通道发出 1 条')
  eq(sent(MEMO_URL).length, 1, '备忘通道没被任务通道堵住')
  eq(maxInflight[SYNC_URL], 1, '任务峰值 1')
  eq(maxInflight[MEMO_URL], 1, '备忘峰值 1')
  sent(MEMO_URL)[0].done({ statusCode: 200, data: { memos: [], deletions: [] } })
  sent(SYNC_URL)[0].done({ statusCode: 200, data: EMPTY_CLOUD })
  await Promise.all([p, q])
}

// ---------------- 6. 未登录直接返回 null，不发请求也不留槽位 ----------------
{
  const m = await fresh()
  store.delete('wd_token')
  const r = await m.syncTasks([task(1, 'A')], [])
  eq(r, null, '未登录时任务同步返回 null')
  eq(pending.length, 0, '没有发出任何请求')
  store.set('wd_token', 'test-token')
  const p = m.syncTasks([], [])
  await tick()
  eq(sent(SYNC_URL).length, 1, '重新登录后台通道仍然可用')
  sent(SYNC_URL)[0].done({ statusCode: 200, data: EMPTY_CLOUD })
  await p
}

console.log(failed === 0 ? '\n全部通过' : '\n失败 ' + failed + ' 项')
process.exit(failed === 0 ? 0 : 1)
