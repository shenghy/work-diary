/**
 * 本机设备身份：附件"按需中转"要知道"我是哪台机器"。
 *
 * `getClientId()` 每次启动都是新随机值，只能用来排除自己的推送；附件归属、
 * "此文件在其它主机"的提示、"谁请求了这份文件"必须用一个跨启动稳定的 id，
 * 否则每次重开小程序都会被当成新设备，中转请求永远对不上。
 */
import { genUuid } from './uuid'

const ID_KEY = 'wd_device_id'
const NAME_KEY = 'wd_device_name'

let cachedId = ''
let cachedName = ''

export function getDeviceId() {
  if (cachedId) return cachedId
  let id = ''
  try {
    id = uni.getStorageSync(ID_KEY) || ''
  } catch (e) {
    id = ''
  }
  if (!id) {
    id = genUuid()
    try {
      uni.setStorageSync(ID_KEY, id)
    } catch (e) {
      // 存不下也不能阻塞功能：本次会话内保持稳定即可
    }
  }
  cachedId = String(id)
  return cachedId
}

/** 展示用设备名：机型优先，用户可在"我的"里改名 */
export function getDeviceName() {
  if (cachedName) return cachedName
  let name = ''
  try {
    name = uni.getStorageSync(NAME_KEY) || ''
  } catch (e) {
    name = ''
  }
  if (!name) name = detectModel()
  cachedName = name
  return cachedName
}

function detectModel() {
  try {
    // getDeviceInfo 只给机型不给账号信息，比 getSystemInfoSync 干净
    const info = typeof wx !== 'undefined' && wx.getDeviceInfo ? wx.getDeviceInfo() : null
    if (info) {
      const model = String(info.model || '').trim()
      if (model) return model.slice(0, 64)
      const brand = String(info.brand || '').trim()
      if (brand) return brand.slice(0, 64)
    }
  } catch (e) {}
  try {
    const sys = uni.getSystemInfoSync ? uni.getSystemInfoSync() : null
    const model = sys && (sys.model || sys.brand) ? String(sys.model || sys.brand).trim() : ''
    if (model) return model.slice(0, 64)
  } catch (e) {}
  return '手机'
}

export function setDeviceName(value) {
  const trimmed = String(value == null ? '' : value).trim()
  cachedName = trimmed || detectModel()
  try {
    if (trimmed) uni.setStorageSync(NAME_KEY, trimmed)
    else uni.removeStorageSync(NAME_KEY)
  } catch (e) {}
  return cachedName
}
