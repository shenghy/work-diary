/**
 * 通用工具：时间格式化、状态/紧急度文案（配色与桌面端 task_card.dart 一致）
 */

// 时间 → "M/D HH:mm"（桌面端风格：月日不补零，时分补零）
export function formatDateTime(iso) {
  if (!iso) return ''
  const d = new Date(iso)
  if (isNaN(d.getTime())) return ''
  const p = (n) => (n < 10 ? '0' + n : '' + n)
  return d.getMonth() + 1 + '/' + d.getDate() + ' ' + p(d.getHours()) + ':' + p(d.getMinutes())
}

// 时间 → "YYYY-MM-DD"
export function formatDate(iso) {
  if (!iso) return ''
  const d = new Date(iso)
  if (isNaN(d.getTime())) return ''
  const p = (n) => (n < 10 ? '0' + n : '' + n)
  return d.getFullYear() + '-' + p(d.getMonth() + 1) + '-' + p(d.getDate())
}

// 日期标签（桌面端 _dateLabel 风格）：今天/明天/后天/x月x日
export function formatDateLabel(iso, suffix) {
  if (!iso) return ''
  const d = new Date(iso)
  if (isNaN(d.getTime())) return ''
  const now = new Date()
  const today = new Date(now.getFullYear(), now.getMonth(), now.getDate())
  const target = new Date(d.getFullYear(), d.getMonth(), d.getDate())
  const diff = Math.round((target - today) / 86400000)
  const s = suffix || ''
  if (diff === 0) return '今天' + s
  if (diff === 1) return '明天' + s
  if (diff === 2) return '后天' + s
  return d.getMonth() + 1 + '月' + d.getDate() + '日' + s
}

// ISO → 本地 "YYYY-MM-DD" 与 "HH:mm"（供编辑页回填时间选择器）
export function isoLocalDateTime(iso) {
  if (!iso) return { date: '', time: '' }
  const d = new Date(iso)
  if (isNaN(d.getTime())) return { date: '', time: '' }
  const p = (n) => (n < 10 ? '0' + n : '' + n)
  return {
    date: d.getFullYear() + '-' + p(d.getMonth() + 1) + '-' + p(d.getDate()),
    time: p(d.getHours()) + ':' + p(d.getMinutes())
  }
}

// 任务状态：0 计划中 1 执行中 2 已完成
export const STATUS_TEXT = ['计划中', '执行中', '已完成']
export const STATUS_COLOR = ['#64748B', '#3B82F6', '#22C55E']

// 紧急程度：0 一般(绿) 1 紧急(黄) 2 重要(红) —— 与桌面端 TaskCard.urgencyColors 一致
export const URGENCY_TEXT = ['一般', '紧急', '重要']
export const URGENCY_COLOR = ['#10B981', '#FAAD14', '#EA6668']

// 任务类型：0 个人(绿) 1 工作(蓝)
export const TASK_TYPE_TEXT = ['个人', '工作']

export function showToast(title, icon = 'none') {
  uni.showToast({ title: title, icon: icon })
}

export function showLoading(title = '加载中') {
  uni.showLoading({ title: title, mask: true })
}

export function hideLoading() {
  uni.hideLoading()
}
