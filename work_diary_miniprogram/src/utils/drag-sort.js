/**
 * 拖拽排序纯逻辑（与 UI 解耦，可用 Node 独立测试）
 *
 * 约定：视图内列表按下标 0..n-1，卡片等高为 itemHeight（像素）。
 */

// 索引夹取
export function clampIndex(idx, len) {
  if (len <= 0) return 0
  return Math.max(0, Math.min(len - 1, idx))
}

/**
 * 根据手指累计位移计算目标索引
 * @param dragIndex 被拖项原索引
 * @param dy 手指累计位移（像素，向下为正）
 * @param itemHeight 卡片高度（像素）
 * @param len 列表长度
 */
export function computeTargetIndex(dragIndex, dy, itemHeight, len) {
  // 注意 Math.round(-1.5) === -1（向正无穷取整），需用数学四舍五入
  const v = dy / itemHeight
  const delta = v < 0 ? Math.ceil(v - 0.5) : Math.floor(v + 0.5)
  return clampIndex(dragIndex + delta, len)
}

/**
 * 计算其他卡片的让位偏移（像素）
 * @returns Map<index, offsetY>
 */
export function computeOffsets(dragIndex, targetIndex, itemHeight) {
  const offsets = new Map()
  if (dragIndex < targetIndex) {
    // 向下拖：中间卡片上移一位
    for (let i = dragIndex + 1; i <= targetIndex; i++) offsets.set(i, -itemHeight)
  } else if (dragIndex > targetIndex) {
    // 向上拖：中间卡片下移一位
    for (let i = targetIndex; i < dragIndex; i++) offsets.set(i, itemHeight)
  }
  return offsets
}

/**
 * 落位：把 from 位置项移动到 to 位置，返回新数组
 */
export function moveItem(list, from, to) {
  const arr = [...list]
  const [item] = arr.splice(from, 1)
  arr.splice(to, 0, item)
  return arr
}

/**
 * 新任务的 sort_order：同状态组内最小值再往前一格，空组为 0。
 * 对齐桌面端 home_screen.dart `_nextSortOrder()`。
 *
 * 为什么不能写死 0：桌面端新建与循环实例都排在负数区，写死 0 的新任务同步后会被
 * 压到列表底部，用户在手机上刚建的任务“不见了”；两端规则不一致也会让排序来回跳。
 */
export function nextSortOrder(tasks, status) {
  let min = 0
  let found = false
  ;(tasks || []).forEach((t) => {
    if (t.status !== status) return
    const s = Number.isFinite(t.sort_order) ? t.sort_order : 0
    if (!found || s < min) {
      min = s
      found = true
    }
  })
  return found ? min - 1 : 0
}

/**
 * 重建全局 sort_order：
 * - 全部视图：直接按拖拽后顺序整体编号 0..N-1
 * - 状态视图：按状态分组（计划中→执行中→已完成），被拖组替换为拖拽后顺序，再整体编号
 *
 * 注意：必须同时刷新 updated_at 为当前时间——服务端按 LWW（updated_at 较新者胜出）
 * 合并，若沿用旧时间戳，排序更新会被服务端拒绝，云端返回旧顺序覆盖本地导致回弹。
 * @returns 新任务数组（sort_order 与 updated_at 已更新）
 */
export function rebuildSortOrder(tasks, viewKey, viewTasks) {
  const stamp = new Date().toISOString()
  const withStamp = (t, i) => ({ ...t, sort_order: i, updated_at: stamp })
  if (viewKey === 'all') {
    return viewTasks.map(withStamp)
  }
  const groups = [[], [], []]
  tasks.forEach((t) => {
    if (t.status >= 0 && t.status <= 2) groups[t.status].push(t)
  })
  groups[viewKey] = viewTasks
  const ordered = groups.flat()
  return ordered.map(withStamp)
}
