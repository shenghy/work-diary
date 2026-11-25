/**
 * API 请求封装：自动附带 Bearer token，401 统一跳登录
 */
import { getToken, clearAuth } from './auth'

const BASE_URL = 'https://work.jspang.com'

function request(method, path, data = {}, options = {}) {
  return new Promise((resolve, reject) => {
    // 认证类接口（登录/注册/找回等）不携带旧 token，且其 401 是业务错误而非 token 过期
    const isAuthApi = path.indexOf('/api/auth/') === 0
    uni.request({
      url: BASE_URL + path,
      method: method,
      data: data,
      timeout: 20000,
      header: {
        'Content-Type': 'application/json',
        ...(getToken() && !isAuthApi ? { Authorization: 'Bearer ' + getToken() } : {}),
        ...(options.headers || {})
      },
      success: (res) => {
        if (res.statusCode === 401) {
          if (!isAuthApi) {
            // 业务接口 401 → token 失效：清理登录态并跳登录
            clearAuth()
            // 避免重复跳转
            const pages = getCurrentPages()
            const current = pages[pages.length - 1]
            if (current && current.route !== 'pages/login/login') {
              uni.reLaunch({ url: '/pages/login/login' })
            }
            reject(new Error('登录已过期，请重新登录'))
            return
          }
          // 认证接口 401（如邮箱或密码错误）→ 透出后端提示
          let msg = '请求失败(401)'
          if (res.data && res.data.detail) {
            msg = typeof res.data.detail === 'string' ? res.data.detail : JSON.stringify(res.data.detail)
          }
          reject(new Error(msg))
          return
        }
        if (res.statusCode >= 200 && res.statusCode < 300) {
          resolve(res.data)
        } else {
          let msg = '请求失败(' + res.statusCode + ')'
          if (res.data && res.data.detail) {
            msg = typeof res.data.detail === 'string' ? res.data.detail : JSON.stringify(res.data.detail)
          }
          reject(new Error(msg))
        }
      },
      fail: (err) => {
        const raw = (err && err.errMsg) || ''
        // 微信把「域名不在白名单 / TLS 校验失败 / 真断网」全塞进 request:fail，
        // 只报“网络错误”会把配置问题伪装成断网，故按原文分类，并留 console 原始值。
        let msg = '网络错误，请检查网络'
        if (raw.indexOf('timeout') >= 0) msg = '请求超时，请稍后重试'
        else if (raw.indexOf('domain list') >= 0) msg = '域名未加入合法域名白名单'
        else if (raw.indexOf('ssl') >= 0 || raw.indexOf('certificate') >= 0) msg = 'HTTPS 证书校验失败'
        console.error('[api] ' + method + ' ' + path + ' fail: ' + raw)
        reject(new Error(msg + (raw ? '（' + raw + '）' : '')))
      }
    })
  })
}

export const api = {
  get: (path, params) => request('GET', path, params),
  post: (path, data, options) => request('POST', path, data, options),
  put: (path, data) => request('PUT', path, data),
  patch: (path, data) => request('PATCH', path, data),
  delete: (path) => request('DELETE', path)
}

export { BASE_URL }
