/**
 * 子任务解析工具（移植自桌面端 subtask_parser.dart，不改数据库结构）
 *
 * 约定：任务标题中，匹配 `[ ]`（未完成）/ `[x]`（已完成）/ `1. `（数字编号）/ `- `（连字符）开头的行视为子任务。
 * - 数字编号格式（`1. xxx`）渲染时保留编号：`[ ] 1. xxx` / `[x] 1. xxx`
 * - 连字符格式（`- xxx`）渲染时不保留前缀：`[ ] xxx`
 */

// 匹配子任务行：`[ ]`/`[x]`/`[X]`、数字编号、连字符
const SUB_TASK_RE = /^\s*(?:\[([ xX])\]\s*|(\d+)\.\s+|-\s+)(.+?)\s*$/

// 提取文本开头的数字编号前缀
function extractNumberPrefix(text) {
  const m = /^(\d+)\.\s*/.exec(text)
  return m ? m[1] + '.' : null
}

/**
 * 解析任务标题：
 * - 匹配子任务格式的行视为子任务
 * - 其余行原样并入主标题（保留换行）
 * - 若全部行都是子任务，主标题为空
 */
export function parseSubTasks(title) {
  const lines = (title || '').split('\n')
  if (lines.length === 0) {
    return { mainTitle: '', items: [] }
  }
  const mainParts = []
  const items = []
  for (const rawLine of lines) {
    const m = SUB_TASK_RE.exec(rawLine)
    if (m) {
      const mark = m[1]
      const numText = m[2]
      let text = m[3].trimEnd ? m[3].trimEnd() : m[3].replace(/\s+$/, '')
      const done = mark === 'x' || mark === 'X'
      let prefix = null
      if (numText) {
        prefix = numText + '.'
      } else {
        const p = extractNumberPrefix(text)
        if (p) {
          prefix = p
          text = text.replace(/^\d+\.\s*/, '')
        }
      }
      items.push({ text: text.trim(), done: done, prefix: prefix })
    } else {
      mainParts.push(rawLine)
    }
  }
  return {
    mainTitle: mainParts.join('\n').trim(),
    items: items
  }
}

export function hasSubTasks(title) {
  return parseSubTasks(title).items.length > 0
}

/**
 * 将某个子任务的完成状态写入标题字符串（统一转为 `[ ]`/`[x]` 格式）
 */
export function setSubTaskDone(title, index, done) {
  const lines = title.split('\n')
  let subIndex = 0
  const buf = []
  for (const line of lines) {
    const m = SUB_TASK_RE.exec(line)
    if (m) {
      if (subIndex === index) {
        const numText = m[2]
        let text = m[3]
        let prefix = null
        if (numText) {
          prefix = numText + '.'
        } else {
          const p = extractNumberPrefix(text)
          if (p) {
            prefix = p
            text = text.replace(/^\d+\.\s*/, '')
          }
        }
        const mark = done ? '[x]' : '[ ]'
        buf.push(prefix ? mark + ' ' + prefix + ' ' + text.trimEnd() : mark + ' ' + text.trimEnd())
      } else {
        buf.push(line)
      }
      subIndex++
    } else {
      buf.push(line)
    }
  }
  return buf.join('\n')
}

/**
 * 输入自动转义（保存/失焦时用）：
 * - 行首 `数字. ` -> `[ ] 数字. `（保留编号）
 * - 行首 `- ` -> `[ ] `（连字符替换为勾选框）
 */
export function autoConvertNumberedToCheckbox(text) {
  if (!text) return text
  let r = text.replace(/^(\d+)\.\s+/gm, (m, n) => '[ ] ' + n + '. ')
  r = r.replace(/^-\s+/gm, '[ ] ')
  return r
}

/**
 * 输入实时自动转义（输入过程中立即转换，无需离开文本框）：
 * - 行首 `1.` -> `[ ] 1.`（输入到「数字.」立即转换，无需等空格）
 * - 行首 `-` -> `[ ]`（输入连字符立即转换为勾选框，无需等空格）
 */
export function autoConvertLive(text) {
  if (!text) return text
  let r = text.replace(/^(\d+)\./gm, (m, n) => '[ ] ' + n + '.')
  r = r.replace(/^-/gm, '[ ]')
  return r
}

/**
 * 子任务进度（已完成数/总数），无子任务返回 0
 */
export function subTaskProgress(title) {
  const r = parseSubTasks(title)
  if (r.items.length === 0) return 0
  const done = r.items.filter((e) => e.done).length
  return done / r.items.length
}
