/**
 * 附件接口的原始 HTTP 调用：元数据同步 + 按需中转的分片上传/下载。
 *
 * 没复用 api.js 的 request 只有两个原因：分片要发二进制（Content-Type 不是 json），
 * 下载要落文件（走 downloadFile 而不是 request）。鉴权头、401 处理与 api.js 一致，
 * 改任何一边记得同步另一边。
 */
import { getToken, clearAuth } from './auth'
import { BASE_URL } from './api'
import { getClientId } from './ws'
import { getDeviceId, getDeviceName } from './device_identity'

const JSON_TIMEOUT = 20000
const BINARY_TIMEOUT = 120000
// 微信对单次请求体积有限制，服务器给的 chunk 再大也截到 2MB（100MB 也就 50 片）
const MAX_CHUNK_BYTES = 2 * 1024 * 1024

/** 带 HTTP 状态码的错误：UI 用 retryable 决定是"再点一次同步"还是"这个文件有问题"。 */
export class AttachmentError extends Error {
  constructor(message, statusCode) {
    super(message)
    this.name = 'AttachmentError'
    this.statusCode = statusCode
  }

  // 410=中转副本已过期/被取走，404=附件已删除，0=网络：都靠重试解决
  get retryable() {
    return this.statusCode === 410 || this.statusCode === 404 || this.statusCode === 0
  }
}

function authHeaders(contentType) {
  const header = { 'X-Client-Id': getClientId(), 'Content-Type': contentType }
  const token = getToken()
  if (token) header.Authorization = 'Bearer ' + token
  return header
}

function handle401(reject) {
  clearAuth()
  try {
    const pages = getCurrentPages()
    const current = pages[pages.length - 1]
    if (current && current.route !== 'pages/login/login') {
      uni.reLaunch({ url: '/pages/login/login' })
    }
  } catch (e) {}
  reject(new AttachmentError('登录已过期，请重新登录', 401))
}

// responseType 是 arraybuffer 时错误体也是二进制，不手工解 UTF-8 就只剩"请求失败(410)"，
// 而服务器这些 detail 都是给用户看的原话（中转已过期 / 请先发起同步请求 / 文件超上限）。
function decodeUtf8(buf) {
  // 网关的 502 页可能是几十 KB 的 HTML，apply 传这么长的参数列表会直接把栈打爆
  const bytes = new Uint8Array(buf.byteLength > 4096 ? buf.slice(0, 4096) : buf)
  let out = ''
  let i = 0
  const part = (from, to) => String.fromCharCode.apply(null, Array.prototype.slice.call(bytes, from, to))
  while (i < bytes.length) {
    const b = bytes[i]
    if (b < 0x80) {
      let j = i
      while (j < bytes.length && bytes[j] < 0x80) j++
      out += part(i, j)
      i = j
    } else {
      const len = b >= 0xf0 ? 4 : b >= 0xe0 ? 3 : 2
      if (i + len > bytes.length) break
      let cp = b & (0xff >> len)
      for (let k = 1; k < len; k++) cp = (cp << 6) | (bytes[i + k] & 0x3f)
      out += String.fromCodePoint(cp)
      i += len
    }
  }
  return out
}

function detailOf(data, statusCode) {
  if (data && typeof data === 'object' && data.detail) {
    return typeof data.detail === 'string' ? data.detail : JSON.stringify(data.detail)
  }
  if (data instanceof ArrayBuffer) return detailOf(decodeUtf8(data), statusCode)
  if (typeof data === 'string' && data) {
    try {
      const parsed = JSON.parse(data)
      if (parsed && parsed.detail) return String(parsed.detail)
    } catch (e) {}
  }
  return '请求失败(' + statusCode + ')'
}

function jsonRequest(method, path, body) {
  return new Promise((resolve, reject) => {
    uni.request({
      url: BASE_URL + path,
      method,
      data: body || {},
      timeout: JSON_TIMEOUT,
      header: authHeaders('application/json'),
      success: (res) => {
        if (res.statusCode === 401) return handle401(reject)
        if (res.statusCode >= 200 && res.statusCode < 300) return resolve(res.data || {})
        reject(new AttachmentError(detailOf(res.data, res.statusCode), res.statusCode))
      },
      fail: (err) => {
        const raw = (err && err.errMsg) || ''
        reject(new AttachmentError('网络错误，请检查网络' + (raw ? '（' + raw + '）' : ''), 0))
      }
    })
  })
}

function uidPath(uid, suffix) {
  return '/api/attachments/' + encodeURIComponent(String(uid)) + suffix
}

function who() {
  return { device_id: getDeviceId(), device_name: getDeviceName() }
}

export const attachmentApi = {
  /** 元数据全量对账：attachments 用服务端 AttachmentIn 的蛇形字段（不含本地字段）。 */
  sync(attachments, deletions) {
    return jsonRequest('POST', '/api/attachments/sync', { attachments, deletions })
  },

  requestPull(uid) {
    return jsonRequest('POST', uidPath(uid, '/request'), who())
  },

  uploadInit(uid) {
    return jsonRequest('POST', uidPath(uid, '/upload/init'), who())
  },

  /** 偏移由调用方带上，body 是 ArrayBuffer；服务端按 offset 顺序写进 .part。 */
  uploadChunk(uid, offset, bytes) {
    return new Promise((resolve, reject) => {
      uni.request({
        url: BASE_URL + uidPath(uid, '/upload?offset=' + encodeURIComponent(offset)),
        method: 'PUT',
        data: bytes,
        timeout: BINARY_TIMEOUT,
        header: authHeaders('application/octet-stream'),
        success: (res) => {
          if (res.statusCode === 401) return handle401(reject)
          if (res.statusCode >= 200 && res.statusCode < 300) return resolve(res.data || {})
          reject(new AttachmentError(detailOf(res.data, res.statusCode), res.statusCode))
        },
        fail: (err) => {
          const raw = (err && err.errMsg) || ''
          reject(new AttachmentError('网络中断，分片上传失败' + (raw ? '（' + raw + '）' : ''), 0))
        }
      })
    })
  },

  uploadComplete(uid) {
    return jsonRequest('POST', uidPath(uid, '/upload/complete'), who())
  },

  ack(uid) {
    return jsonRequest('POST', uidPath(uid, '/ack'), who())
  },

  state(uid) {
    return jsonRequest('GET', uidPath(uid, '/state'))
  },

  /**
   * 下载中转文件，读出整份 ArrayBuffer 交给 attachment_store 校验落盘。
   *
   * 不用 wx.downloadFile：它的 tempFilePath 与 FileSystemManager 的可用域不是一回事，
   * 且非 2xx 时错误体落在临时文件里还得再读一次。这里文件上限 100MB，
   * 下载完成后由 saveIncoming 校验大小与 SHA-256，不对就整份丢掉。
   */
  download(uid) {
    return new Promise((resolve, reject) => {
      uni.request({
        url: BASE_URL + uidPath(uid, '/blob') + '?device_id=' + encodeURIComponent(getDeviceId()),
        method: 'GET',
        responseType: 'arraybuffer',
        timeout: BINARY_TIMEOUT,
        header: authHeaders('application/octet-stream'),
        success: (res) => {
          if (res.statusCode === 401) return handle401(reject)
          if (res.statusCode >= 200 && res.statusCode < 300) {
            const body = res.data
            if (!body || !(body.byteLength > 0)) {
              return reject(new AttachmentError('下载内容为空，请重新发起同步', res.statusCode))
            }
            return resolve(body instanceof ArrayBuffer ? body : new Uint8Array(body).buffer)
          }
          reject(new AttachmentError(detailOf(res.data, res.statusCode), res.statusCode))
        },
        fail: (err) => {
          const raw = (err && err.errMsg) || ''
          reject(new AttachmentError('下载失败，请检查网络' + (raw ? '（' + raw + '）' : ''), 0))
        }
      })
    })
  },

  maxChunkBytes(chunkSize) {
    const n = Number(chunkSize) > 0 ? Number(chunkSize) : MAX_CHUNK_BYTES
    return Math.max(64 * 1024, Math.min(n, MAX_CHUNK_BYTES))
  }
}

export default attachmentApi
