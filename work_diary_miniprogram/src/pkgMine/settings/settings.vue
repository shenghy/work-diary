<template>
  <view class="page" :class="themeClass">
    <aurora-bg />
    <scroll-view class="scroll" scroll-y>
      <!-- 外观 -->
      <view class="group-title">外观</view>
      <view class="group glass">
        <view class="theme-row">
          <view
            v-for="m in modes"
            :key="m.value"
            class="theme-opt"
            :class="{ on: mode === m.value }"
            @click="pickTheme(m.value)"
          >
            <view class="preview" :class="'pv-' + m.value">
              <view class="pv-card"></view>
              <view class="pv-line"></view>
            </view>
            <text class="theme-text">{{ m.text }}</text>
          </view>
        </view>
        <text class="group-hint">深色模式与桌面端配色一致，可选择跟随系统。</text>
        <view class="row motion-row">
          <text class="row-icon motion">✦</text>
          <text class="row-text">动态极光背景</text>
          <switch
            class="row-switch"
            :checked="motion"
            color="#2563eb"
            @change="toggleMotion"
          />
        </view>
      </view>

      <!-- 数据与功能 -->
      <view class="group-title">数据与功能</view>
      <view class="group glass">
        <view class="row" @click="go('/pkgData/stats/stats')">
          <text class="row-icon stats">◎</text>
          <text class="row-text">我的数据</text>
          <text class="row-value">看板</text>
          <text class="row-arrow">›</text>
        </view>
        <view class="row" @click="go('/pkgMine/repeat-manager/repeat-manager')">
          <text class="row-icon repeat">⟳</text>
          <text class="row-text">循环任务</text>
          <text class="row-value">日 / 周 / 月</text>
          <text class="row-arrow">›</text>
        </view>
        <view class="row" @click="syncNow">
          <text class="row-icon sync">↻</text>
          <text class="row-text">立即同步</text>
          <text class="row-value">{{ syncing ? '同步中...' : '任务与备忘' }}</text>
          <text class="row-arrow">›</text>
        </view>
      </view>

      <!-- 其他 -->
      <view class="group-title">其他</view>
      <view class="group glass">
        <view class="row" @click="go('/pkgMine/about/about')">
          <text class="row-icon about">ⓘ</text>
          <text class="row-text">关于我们</text>
          <text class="row-value">v{{ version }}</text>
          <text class="row-arrow">›</text>
        </view>
        <view class="row" @click="go('/pkgMine/about/about?doc=user')">
          <text class="row-icon doc">▤</text>
          <text class="row-text">用户协议</text>
          <text class="row-arrow">›</text>
        </view>
        <view class="row" @click="go('/pkgMine/about/about?doc=privacy')">
          <text class="row-icon doc">▤</text>
          <text class="row-text">隐私政策</text>
          <text class="row-arrow">›</text>
        </view>
      </view>

      <view class="logout" v-if="logged" @click="logout">退出登录</view>
      <view class="version">极简工作日记小程序 v{{ version }}</view>
    </scroll-view>
  </view>
</template>

<script>
import AuroraBg from '../../components/aurora-bg.vue'
import { getThemeMode, setThemeMode, broadcastTheme } from '../../utils/theme'
import { isAuroraMotionEnabled, setAuroraMotionEnabled } from '../../utils/glass'
import { isLoggedIn, clearAuth } from '../../utils/auth'
import { disconnectWS } from '../../utils/ws'
import { fullSyncTasks, fullSyncMemos, syncAttachments } from '../../utils/sync'
import { showToast, showLoading, hideLoading } from '../../utils/util'

export default {
  components: { AuroraBg },
  data() {
    return {
      mode: getThemeMode(),
      modes: [
        { value: 'system', text: '跟随系统' },
        { value: 'light', text: '浅色' },
        { value: 'dark', text: '深色' }
      ],
      motion: isAuroraMotionEnabled(),
      syncing: false,
      logged: false,
      version: '1.0.0'
    }
  },
  onShow() {
    this.mode = getThemeMode()
    this.logged = isLoggedIn()
    this.syncTheme()
  },
  methods: {
    pickTheme(mode) {
      this.mode = setThemeMode(mode)
      broadcastTheme()
      this.syncTheme()
    },
    toggleMotion(e) {
      this.motion = !!(e.detail && e.detail.value)
      setAuroraMotionEnabled(this.motion)
    },
    go(url) {
      uni.navigateTo({ url })
    },
    async syncNow() {
      if (this.syncing) return
      if (!isLoggedIn()) {
        showToast('请先登录')
        return
      }
      this.syncing = true
      showLoading('同步中')
      try {
        await fullSyncTasks()
        await fullSyncMemos()
        // 附件排在最后：服务器按父记录是否已入库决定收不收元数据
        const summary = await syncAttachments()
        hideLoading()
        const rejected = (summary && summary.rejectedNames) || []
        if (rejected.length) {
          showToast('同步完成，但附件未同步：' + rejected.slice(0, 2).join('、'))
        } else {
          showToast('同步完成', 'success')
        }
      } catch (e) {
        hideLoading()
        showToast('同步失败：' + e.message)
      }
      this.syncing = false
    },
    logout() {
      uni.showModal({
        title: '退出登录',
        content: '确定退出当前账号吗？本地数据会保留。',
        success: (res) => {
          if (!res.confirm) return
          clearAuth()
          disconnectWS()
          uni.reLaunch({ url: '/pages/login/login' })
        }
      })
    }
  }
}
</script>

<style lang="scss" scoped>
.page {
  min-height: 100vh;
  background: transparent;
  color: var(--text-primary);
}
.scroll {
  height: 100vh;
  padding: 24rpx;
  box-sizing: border-box;
}
.group-title {
  margin: 24rpx 12rpx 12rpx;
  font-size: 23rpx;
  color: var(--text-tertiary);
}
.group {
  background: var(--card-bg);
  border: 1rpx solid var(--card-border);
  border-radius: 32rpx;
  overflow: hidden;
  box-shadow: var(--shadow-card);
}
.group-hint {
  display: block;
  padding: 16rpx 24rpx 22rpx;
  font-size: 21rpx;
  line-height: 1.6;
  color: var(--text-tertiary);
}
.theme-row {
  display: flex;
  gap: 16rpx;
  padding: 24rpx;
}
.theme-opt {
  flex: 1;
  border-radius: 16rpx;
  padding: 14rpx;
  border: 2rpx solid transparent;
  background: var(--chip-bg);
}
.theme-opt.on {
  border-color: var(--accent);
  background: var(--accent-soft);
}
.preview {
  height: 96rpx;
  border-radius: 12rpx;
  padding: 12rpx;
  box-sizing: border-box;
  display: flex;
  flex-direction: column;
  gap: 8rpx;
}
.pv-light {
  background: #eef2fb;
}
.pv-dark {
  background: #101b36;
}
.pv-system {
  background: linear-gradient(120deg, #eef2fb 0 50%, #101b36 50% 100%);
}
.pv-card {
  height: 40rpx;
  border-radius: 8rpx;
  background: rgba(255, 255, 255, 0.85);
}
.pv-dark .pv-card {
  background: rgba(255, 255, 255, 0.14);
}
.pv-system .pv-card {
  background: linear-gradient(90deg, rgba(255, 255, 255, 0.85) 0 50%, rgba(255, 255, 255, 0.15) 50% 100%);
}
.pv-line {
  width: 60%;
  height: 10rpx;
  border-radius: 5rpx;
  background: rgba(37, 99, 235, 0.55);
}
.theme-text {
  display: block;
  margin-top: 12rpx;
  text-align: center;
  font-size: 23rpx;
  color: var(--text-secondary);
}
.theme-opt.on .theme-text {
  color: var(--accent);
  font-weight: 600;
}
.row {
  display: flex;
  align-items: center;
  padding: 28rpx 24rpx;
  border-bottom: 1rpx solid var(--card-border);
}
.row:last-child {
  border-bottom: none;
}
.row-icon {
  width: 48rpx;
  font-size: 30rpx;
  color: var(--accent);
}
.row-icon.stats {
  color: var(--stats-primary);
}
.row-icon.repeat {
  color: var(--status-executing);
}
.row-text {
  flex: 1;
  font-size: 28rpx;
  color: var(--text-primary);
}
.row-value {
  font-size: 22rpx;
  color: var(--text-tertiary);
  margin-right: 8rpx;
}
.row-arrow {
  font-size: 32rpx;
  color: var(--text-tertiary);
}
.motion-row {
  border-top: 1rpx solid var(--card-border);
  border-bottom: none;
}
.row-icon.motion {
  color: var(--stats-primary-soft);
}
.row-switch {
  margin-left: auto;
  transform: scale(0.82);
  transform-origin: right center;
}
.logout {
  margin-top: 40rpx;
  height: 88rpx;
  line-height: 88rpx;
  text-align: center;
  border-radius: 20rpx;
  font-size: 28rpx;
  color: var(--danger);
  background: var(--danger-bg);
  border: 1rpx solid var(--danger-border);
}
.version {
  margin: 36rpx 0 60rpx;
  text-align: center;
  font-size: 21rpx;
  color: var(--text-tertiary);
}
</style>
