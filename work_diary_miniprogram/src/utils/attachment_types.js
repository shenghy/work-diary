/**
 * 附件类型白名单：与桌面端 attachment_types.dart、服务端 attachment_types.py 同一份口径。
 *
 * 三端必须一起改：客户端拦一道是为了让用户选错文件时立刻知道原因，
 * 服务端再拦一道是因为客户端的校验用户可以绕过（改扩展名、直接调接口），
 * 而中转文件最终会在另一台机器上一键打开——那才是真正的安全边界。
 */

export const IMAGE_EXTS = ['.jpg', '.jpeg', '.png', '.gif', '.webp', '.bmp']

export const DOC_EXTS = [
  '.pdf', '.doc', '.docx', '.xls', '.xlsx', '.ppt', '.pptx',
  '.txt', '.md', '.csv', '.rtf', '.ofd', '.wps', '.et', '.dps'
]

export const EXECUTABLE_EXTS = [
  '.exe', '.msi', '.msp', '.bat', '.cmd', '.com', '.scr', '.ps1', '.psm1',
  '.vbs', '.vbe', '.js', '.jse', '.wsf', '.wsh', '.dll', '.sys', '.drv',
  '.reg', '.lnk', '.apk', '.jar', '.sh', '.msu', '.cpl', '.msiexec'
]

export const VIDEO_EXTS = [
  '.mp4', '.mov', '.avi', '.mkv', '.flv', '.wmv', '.webm', '.m4v', '.mpg',
  '.mpeg', '.3gp', '.ts', '.vob', '.rmvb', '.asf'
]

export const AUDIO_EXTS = ['.mp3', '.wav', '.m4a', '.flac', '.aac', '.ogg', '.wma', '.amr', '.opus', '.mid', '.midi']

export const ARCHIVE_EXTS = ['.zip', '.rar', '.7z', '.tar', '.gz', '.tgz', '.bz2', '.xz', '.iso']

const MIME_BY_EXT = {
  '.jpg': 'image/jpeg',
  '.jpeg': 'image/jpeg',
  '.png': 'image/png',
  '.gif': 'image/gif',
  '.webp': 'image/webp',
  '.bmp': 'image/bmp',
  '.pdf': 'application/pdf',
  '.doc': 'application/msword',
  '.docx': 'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
  '.xls': 'application/vnd.ms-excel',
  '.xlsx': 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
  '.ppt': 'application/vnd.ms-powerpoint',
  '.pptx': 'application/vnd.openxmlformats-officedocument.presentationml.presentation',
  '.txt': 'text/plain',
  '.md': 'text/markdown',
  '.csv': 'text/csv',
  '.rtf': 'application/rtf',
  '.ofd': 'application/ofd',
  '.wps': 'application/wps-office.doc',
  '.et': 'application/wps-office.xlsx',
  '.dps': 'application/wps-office.pptx'
}

export const ALLOWED_HINT = '仅支持图片和文档（jpg/png/gif/webp/bmp、pdf/word/excel/ppt/txt/md/csv 等）'

// 与服务端 ATTACHMENT_MAX_MB / ATTACHMENT_MAX_PER_PARENT 一致
export const MAX_BYTES = 100 * 1024 * 1024
export const MAX_PER_PARENT = 5

// 微信一次最多能选几个文件；上限 5 个时用不上多选的余量
export const CHOOSE_MAX_COUNT = 5

// wx.chooseMessageFile 的 extension 参数不带点，且只在 type:'file' 时生效
export const PICK_EXTENSIONS = [...IMAGE_EXTS, ...DOC_EXTS].map((e) => e.slice(1))

function contains(list, ext) {
  return list.indexOf(ext) >= 0
}

/** 取小写扩展名（含点）。无扩展名、以点结尾、隐藏文件都返回空串。 */
export function extOf(fileName) {
  const name = String(fileName == null ? '' : fileName).trim()
  const base = name.replace(/\\/g, '/').split('/').pop()
  const dot = base.lastIndexOf('.')
  if (dot <= 0 || dot === base.length - 1) return ''
  return base.slice(dot).toLowerCase()
}

/**
 * 能不能当附件保存：返回 { allowed, mime, reason }。
 * reason 是给用户看的一句话，必须说清"为什么不行"和"能放什么"。
 */
export function checkFile(fileName, sizeBytes) {
  const ext = extOf(fileName)
  if (contains(IMAGE_EXTS, ext) || contains(DOC_EXTS, ext)) {
    if (typeof sizeBytes === 'number' && sizeBytes > MAX_BYTES) {
      return { allowed: false, mime: '', reason: `${fileName} 超过 ${MAX_BYTES / 1024 / 1024}MB 上限` }
    }
    return { allowed: true, mime: MIME_BY_EXT[ext] || 'application/octet-stream', reason: '' }
  }
  if (contains(EXECUTABLE_EXTS, ext)) {
    return { allowed: false, mime: '', reason: `可执行文件（${ext}）不支持保存，${ALLOWED_HINT}` }
  }
  if (contains(VIDEO_EXTS, ext)) {
    return { allowed: false, mime: '', reason: `视频文件（${ext}）不支持保存，${ALLOWED_HINT}` }
  }
  if (contains(AUDIO_EXTS, ext)) {
    return { allowed: false, mime: '', reason: `音频文件（${ext}）不支持保存，${ALLOWED_HINT}` }
  }
  if (contains(ARCHIVE_EXTS, ext)) {
    return { allowed: false, mime: '', reason: `压缩包（${ext}）不支持保存，${ALLOWED_HINT}` }
  }
  return { allowed: false, mime: '', reason: `该类型（${ext || '无扩展名'}）不支持保存，${ALLOWED_HINT}` }
}

export function isImageExt(fileName) {
  return contains(IMAGE_EXTS, extOf(fileName))
}

// 纸片角标的底色沿用 Windows 资源管理器里各类文件的习惯色，
// 与桌面端 widgets/attachment_strip.dart 的 _badgeColor 必须取同一组值。
const BADGE_COLORS = [
  [['.doc', '.docx', '.rtf'], '#2B579A'],
  [['.xls', '.xlsx', '.et', '.csv'], '#217346'],
  [['.ppt', '.pptx', '.dps'], '#D24726'],
  [['.pdf'], '#D9191E'],
  [['.ofd'], '#8B5E34'],
  [['.wps'], '#E8632B'],
  [IMAGE_EXTS, '#0E7C86']
]
const BADGE_FALLBACK = '#5B6B86'

/** 纸片角标：一眼看出类型的短标签与底色。 */
export function badgeOf(fileName) {
  const ext = extOf(fileName)
  const hit = BADGE_COLORS.find((pair) => contains(pair[0], ext))
  return { label: ext ? ext.slice(1).toUpperCase() : '文件', color: hit ? hit[1] : BADGE_FALLBACK }
}

// 副行里的类型词，与桌面端 _kindOf 一一对应
export function kindLabel(fileName) {
  const ext = extOf(fileName)
  if (contains(IMAGE_EXTS, ext)) return '图片'
  if (ext === '.pdf') return 'PDF'
  if (contains(['.doc', '.docx', '.wps', '.rtf', '.ofd'], ext)) return '文档'
  if (contains(['.xls', '.xlsx', '.et', '.csv'], ext)) return '表格'
  if (contains(['.ppt', '.pptx', '.dps'], ext)) return '演示'
  return '文本'
}

// 卡片上的"2.3 MB"
export function formatSize(bytes) {
  const n = Number(bytes)
  if (!isFinite(n) || n < 0) return '未知大小'
  if (n < 1024) return n + ' B'
  if (n < 1024 * 1024) return (n / 1024).toFixed(1) + ' KB'
  return (n / 1024 / 1024).toFixed(1) + ' MB'
}

/**
 * uid 只允许 UUID 用到的字符。云端上报的 uid 是不可信输入，
 * 否则 `../` 形式的 uid 能把原件写到本目录之外。
 */
export function sanitizeUid(raw) {
  const cleaned = String(raw == null ? '' : raw).replace(/[^0-9A-Za-z_-]/g, '')
  return cleaned.length <= 64 ? cleaned : cleaned.slice(0, 64)
}

/**
 * 文件名清洗：去掉路径分隔符与非法字符，保留扩展名。
 *
 * 其它设备上报的 file_name 同样不可信，带 `../` 就能把"打开附件"
 * 变成"打开任意路径"。uid 目录已经隔离了同名冲突，这里只保证名字能落盘。
 */
export function sanitizeFileName(raw) {
  let name = String(raw == null ? '' : raw).replace(/\\/g, '_').replace(/\//g, '_')
  name = name.replace(/[<>:"|?*\u0000-\u001F]/g, '_').trim()
  // 结尾的点/空格会被文件系统静默吃掉，留下会以为文件不见了
  name = name.replace(/[. ]+$/, '')
  const keep = 100
  if (name.length > keep) {
    const dot = name.lastIndexOf('.')
    const ext = dot > 0 ? name.slice(dot) : ''
    const base = name.slice(0, name.length - ext.length)
    const cut = base.length > keep - ext.length ? keep - ext.length : base.length
    name = base.slice(0, cut) + ext
  }
  return name || '附件'
}
