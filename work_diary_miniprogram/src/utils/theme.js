/**
 * 主题：浅色 / 深色 / 跟随系统（对齐桌面端 GlassPalette 两档）
 */
const MODE_KEY = 'wd_theme_mode'

export function getThemeMode() {
  try {
    const v = uni.getStorageSync(MODE_KEY)
    return v === 'light' || v === 'dark' ? v : 'system'
  } catch (e) {
    return 'system'
  }
}

export function setThemeMode(mode) {
  const m = mode === 'light' || mode === 'dark' ? mode : 'system'
  try {
    uni.setStorageSync(MODE_KEY, m)
  } catch (e) {}
  return m
}

export function systemTheme() {
  try {
    const info =
      typeof wx !== 'undefined' && wx.getAppBaseInfo
        ? wx.getAppBaseInfo()
        : uni.getSystemInfoSync()
    return info && info.theme === 'dark' ? 'dark' : 'light'
  } catch (e) {
    return 'light'
  }
}

export function resolvedTheme() {
  const mode = getThemeMode()
  return mode === 'system' ? systemTheme() : mode
}

export function isDark() {
  return resolvedTheme() === 'dark'
}

export function currentThemeClass() {
  return isDark() ? 'theme-dark' : ''
}

// 导航栏配色跟随主题
export function applyThemeChrome() {
  const dark = isDark()
  try {
    uni.setNavigationBarColor({
      frontColor: dark ? '#ffffff' : '#000000',
      backgroundColor: dark ? '#101B36' : '#EEF2FB'
    })
  } catch (e) {}
  // 窗口底色同步，避免深色下极光未渲染时露出浅色页面底
  try {
    if (typeof uni.setBackgroundColor === 'function') {
      uni.setBackgroundColor({
        backgroundColor: dark ? '#101B36' : '#EEF2FB',
        backgroundColorTop: dark ? '#101B36' : '#EEF2FB',
        backgroundColorBottom: dark ? '#18264D' : '#E2E9F7'
      })
    }
  } catch (e) {}
}

// 通知已打开的页面刷新主题 class（设置页切换后调用）
export function broadcastTheme() {
  const pages = getCurrentPages ? getCurrentPages() : []
  pages.forEach((p) => {
    const vm = p && p.$vm
    if (vm) {
      vm.themeClass = currentThemeClass()
      vm.themeDark = isDark()
    }
  })
  applyThemeChrome()
}

// 全局 mixin：任何页面自动获得 themeClass/themeDark，onShow 时同步
export const themeMixin = {
  data() {
    return {
      themeClass: currentThemeClass(),
      themeDark: isDark()
    }
  },
  onShow() {
    this.themeClass = currentThemeClass()
    this.themeDark = isDark()
    applyThemeChrome()
  },
  methods: {
    syncTheme() {
      this.themeClass = currentThemeClass()
      this.themeDark = isDark()
    }
  }
}
