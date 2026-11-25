<template>
  <view class="page" :class="themeClass">
    <aurora-bg />
    <!-- 用户信息 -->
    <view class="user-card glass">
      <view class="avatar">{{ emailInitial }}</view>
      <view class="user-info">
        <text class="email">{{ email }}</text>
        <text class="since">注册于 {{ createdText }}</text>
      </view>
    </view>

    <!-- 功能入口 -->
    <view class="menu glass">
      <view class="menu-item" @click="go('/pkgData/stats/stats')">
        <text class="menu-icon">◎</text>
        <text class="menu-text">我的数据</text>
        <text class="menu-arrow">›</text>
      </view>
      <view class="menu-item" @click="go('/pkgMine/repeat-manager/repeat-manager')">
        <text class="menu-icon">⟳</text>
        <text class="menu-text">循环任务</text>
        <text class="menu-arrow">›</text>
      </view>
    </view>

    <view class="menu glass">
      <view class="menu-item" @click="go('/pkgMine/settings/settings')">
        <text class="menu-icon">⚙︎</text>
        <text class="menu-text">设置</text>
        <text class="menu-arrow">›</text>
      </view>
      <view class="menu-item" @click="go('/pkgMine/about/about')">
        <text class="menu-icon">ⓘ</text>
        <text class="menu-text">关于我们</text>
        <text class="menu-arrow">›</text>
      </view>
    </view>

    <view class="menu glass" v-if="isLoggedIn">
      <view class="menu-item" @click="logout">
        <text class="menu-icon danger">⎋</text>
        <text class="menu-text danger">退出登录</text>
      </view>
    </view>

    <view class="version">极简工作日记小程序版 v1.0.0</view>
  </view>
</template>

<script>
import AuroraBg from '../../components/aurora-bg.vue'
import { isLoggedIn, getUser, clearAuth } from '../../utils/auth'
import { disconnectWS } from '../../utils/ws'
import { formatDate } from '../../utils/util'

export default {
  components: { AuroraBg },
  data() {
    return {
      isLoggedIn: false,
      email: '',
      createdText: ''
    }
  },
  computed: {
    emailInitial() {
      return this.email ? this.email[0].toUpperCase() : '?'
    }
  },
  onShow() {
    this.isLoggedIn = isLoggedIn()
    if (!this.isLoggedIn) {
      uni.reLaunch({ url: '/pages/login/login' })
      return
    }
    const user = getUser()
    if (user) {
      this.email = user.email || ''
      this.createdText = user.created_at ? formatDate(user.created_at) : ''
    }
  },
  methods: {
    go(url) {
      uni.navigateTo({ url })
    },
    logout() {
      uni.showModal({
        title: '退出登录',
        content: '确定退出当前账号吗？本地数据会保留。',
        success: (res) => {
          if (res.confirm) {
            clearAuth()
            disconnectWS()
            uni.reLaunch({ url: '/pages/login/login' })
          }
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
  padding: 24rpx;
  box-sizing: border-box;
  color: var(--text-primary);
}
.user-card {
  display: flex;
  align-items: center;
  background: var(--card-bg);
  border-radius: 32rpx;
  padding: 36rpx 28rpx;
  margin-bottom: 24rpx;
  border: 1rpx solid var(--card-border);
  box-shadow: var(--shadow-card);
}
.avatar {
  width: 96rpx;
  height: 96rpx;
  border-radius: 50%;
  background: linear-gradient(145deg, #5b4be0, #2563eb);
  color: #ffffff;
  font-size: 44rpx;
  font-weight: 700;
  display: flex;
  align-items: center;
  justify-content: center;
  margin-right: 24rpx;
  flex-shrink: 0;
}
.user-info {
  flex: 1;
  min-width: 0;
}
.email {
  display: block;
  font-size: 30rpx;
  font-weight: 600;
  color: var(--text-primary);
  word-break: break-all;
}
.since {
  display: block;
  font-size: 24rpx;
  color: var(--text-tertiary);
  margin-top: 8rpx;
}
.menu {
  background: var(--card-bg);
  border-radius: 32rpx;
  margin-bottom: 24rpx;
  border: 1rpx solid var(--card-border);
  overflow: hidden;
  box-shadow: var(--shadow-card);
}
.menu-item {
  display: flex;
  align-items: center;
  padding: 30rpx 28rpx;
  border-bottom: 1rpx solid var(--card-border);
}
.menu-item:last-child {
  border-bottom: none;
}
.menu-icon {
  font-size: 30rpx;
  margin-right: 18rpx;
  color: var(--accent);
}
.menu-icon.danger {
  color: var(--danger);
}
.menu-text {
  flex: 1;
  font-size: 28rpx;
  color: var(--text-primary);
}
.menu-text.danger {
  color: var(--danger);
}
.menu-arrow {
  color: var(--text-tertiary);
  font-size: 32rpx;
}
.version {
  text-align: center;
  color: var(--text-tertiary);
  font-size: 22rpx;
  margin-top: 48rpx;
}
</style>
