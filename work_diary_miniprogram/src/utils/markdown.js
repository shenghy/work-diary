/**
 * Markdown 解析与判断（备忘渲染，对齐桌面端 flutter_markdown 行为）
 */
import MarkdownIt from 'markdown-it'

const md = new MarkdownIt({
  html: false, // 禁止原始 HTML，防注入
  linkify: true, // 自动识别链接
  breaks: true // 单换行 → <br>（备忘记录常用）
})

// 判断文本是否含 Markdown 特征（与桌面端 _isMarkdown 一致）
export function isMarkdown(text) {
  if (!text) return false
  let n = 0
  for (const line of String(text).split('\n')) {
    const t = line.trimLeft()
    if (
      t.startsWith('# ') ||
      t.startsWith('## ') ||
      t.startsWith('### ') ||
      t.startsWith('- ') ||
      t.startsWith('* ') ||
      t.startsWith('> ') ||
      t.startsWith('```') ||
      t.startsWith('---') ||
      t.startsWith('![') ||
      t.indexOf('**') >= 0 ||
      t.indexOf('`') >= 0 ||
      /\[[^\]]+\]\([^)]+\)/.test(t)
    ) {
      n++
    }
  }
  return n >= 1
}

// Markdown → HTML 片段（供 mp-html 组件渲染）
export function renderMarkdown(text) {
  try {
    return md.render(String(text || ''))
  } catch (e) {
    return ''
  }
}
