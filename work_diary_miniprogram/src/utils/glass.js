/**
 * 极光动效开关：低端机默认静止，设置页可覆盖
 */
const MOTION_KEY = 'wd_aurora_motion'

function deviceBenchmarkLevel() {
  try {
    const info =
      typeof wx !== 'undefined' && wx.getDeviceInfo ? wx.getDeviceInfo() : uni.getSystemInfoSync()
    return info && info.benchmarkLevel
  } catch (e) {
    return undefined
  }
}

export function isAuroraMotionEnabled() {
  try {
    const v = uni.getStorageSync(MOTION_KEY)
    if (v === false || v === '0' || v === 0) return false
    if (v === true || v === '1' || v === 1) return true
  } catch (e) {}
  const level = deviceBenchmarkLevel()
  if (typeof level === 'number' && level >= 0 && level < 10) return false
  return true
}

export function setAuroraMotionEnabled(on) {
  try {
    uni.setStorageSync(MOTION_KEY, !!on)
  } catch (e) {}
  try {
    uni.$emit('aurora-motion', !!on)
  } catch (e) {}
}
