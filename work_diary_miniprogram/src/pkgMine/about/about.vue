<template>
  <view class="page" :class="themeClass">
    <aurora-bg />
    <scroll-view class="scroll" scroll-y>
      <!-- 协议 / 隐私文档 -->
      <template v-if="doc">
        <view class="doc-head">
          <text class="doc-title">{{ doc === 'user' ? '用户协议' : '隐私政策' }}</text>
          <text class="doc-sub">最后更新：2026 年 11 月</text>
        </view>
        <view class="card glass doc-card">
          <text class="doc-text">{{ docText }}</text>
        </view>
        <view class="doc-actions">
          <view class="doc-btn" @click="copyDoc">复制全文</view>
        </view>
      </template>

      <!-- 关于 -->
      <template v-else>
        <view class="hero">
          <view class="logo">极</view>
          <text class="app-name">极简工作日记</text>
          <view class="ver-chip">小程序版 v{{ version }}</view>
          <text class="slogan">极简风格的任务管理工具，本地优先，支持云端多设备同步。</text>
        </view>

        <view class="card glass feature-card">
          <view class="feature" v-for="f in features" :key="f.text">
            <text class="f-icon">{{ f.icon }}</text>
            <text class="f-text">{{ f.text }}</text>
          </view>
        </view>

        <view class="card glass author-card">
          <text class="author-title">有问题反馈或需要新功能？</text>
          <view class="author-row">
            <text class="author-label">作者微信</text>
            <text class="author-value">php100</text>
            <view class="copy-btn" @click="copyWechat">复制</view>
          </view>
        </view>

        <view class="card glass link-card">
          <view class="link-row" @click="openDoc('user')">
            <text class="link-text">用户协议</text>
            <text class="link-arrow">›</text>
          </view>
          <view class="link-row" @click="openDoc('privacy')">
            <text class="link-text">隐私政策</text>
            <text class="link-arrow">›</text>
          </view>
        </view>

        <text class="terms">使用本软件即代表同意《用户协议》与《隐私政策》</text>
        <text class="copyright">© 2026 极简工作日记</text>
      </template>
    </scroll-view>
  </view>
</template>

<script>
import AuroraBg from '../../components/aurora-bg.vue'
import { USER_AGREEMENT, PRIVACY_POLICY } from '../../utils/agreements'
import { showToast } from '../../utils/util'

export default {
  components: { AuroraBg },
  data() {
    return {
      doc: '',
      version: '1.0.0',
      features: [
        { icon: '✓', text: '任务状态流转：计划中 / 执行中 / 已完成' },
        { icon: '⟳', text: '周期任务：每日 / 每周 / 每月，可跳过单期' },
        { icon: '☁', text: '云端多端同步，WebSocket 实时推送' },
        { icon: '◎', text: '个人数据看板与活跃热力图' }
      ]
    }
  },
  computed: {
    docText() {
      if (this.doc === 'user') return USER_AGREEMENT
      if (this.doc === 'privacy') return PRIVACY_POLICY
      return ''
    }
  },
  onLoad(options) {
    if (options && (options.doc === 'user' || options.doc === 'privacy')) {
      this.doc = options.doc
      uni.setNavigationBarTitle({ title: options.doc === 'user' ? '用户协议' : '隐私政策' })
    }
  },
  methods: {
    openDoc(doc) {
      uni.navigateTo({ url: '/pkgMine/about/about?doc=' + doc })
    },
    copyWechat() {
      uni.setClipboardData({
        data: 'php100',
        success: () => showToast('微信号已复制', 'success')
      })
    },
    copyDoc() {
      uni.setClipboardData({
        data: this.docText,
        success: () => showToast('全文已复制', 'success')
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
.hero {
  display: flex;
  flex-direction: column;
  align-items: center;
  padding: 48rpx 30rpx 40rpx;
}
.logo {
  width: 128rpx;
  height: 128rpx;
  border-radius: 34rpx;
  display: flex;
  align-items: center;
  justify-content: center;
  font-size: 64rpx;
  font-weight: 700;
  color: #ffffff;
  background: linear-gradient(145deg, #5b4be0, #2563eb 60%, #12a88e);
  box-shadow: 0 14rpx 36rpx rgba(37, 99, 235, 0.32);
}
.app-name {
  margin-top: 24rpx;
  font-size: 38rpx;
  font-weight: 700;
  color: var(--text-primary);
}
.ver-chip {
  margin-top: 12rpx;
  padding: 4rpx 18rpx;
  border-radius: 999rpx;
  font-size: 21rpx;
  color: var(--accent);
  background: var(--accent-soft);
}
.slogan {
  margin-top: 20rpx;
  text-align: center;
  font-size: 24rpx;
  line-height: 1.7;
  color: var(--text-secondary);
}
.card {
  background: var(--card-bg);
  border: 1rpx solid var(--card-border);
  border-radius: 32rpx;
  box-shadow: var(--shadow-card);
  margin-bottom: 20rpx;
}
.feature-card {
  padding: 10rpx 24rpx;
}
.feature {
  display: flex;
  align-items: center;
  padding: 18rpx 0;
  border-bottom: 1rpx solid var(--card-border);
}
.feature:last-child {
  border-bottom: none;
}
.f-icon {
  width: 48rpx;
  font-size: 26rpx;
  color: var(--accent);
}
.f-text {
  flex: 1;
  font-size: 25rpx;
  line-height: 1.5;
  color: var(--text-secondary);
}
.author-card {
  padding: 26rpx 24rpx;
}
.author-title {
  display: block;
  font-size: 26rpx;
  color: var(--text-secondary);
}
.author-row {
  display: flex;
  align-items: center;
  margin-top: 16rpx;
}
.author-label {
  font-size: 25rpx;
  color: var(--text-tertiary);
}
.author-value {
  flex: 1;
  margin-left: 12rpx;
  font-size: 28rpx;
  font-weight: 600;
  color: var(--accent);
}
.copy-btn {
  padding: 8rpx 24rpx;
  border-radius: 999rpx;
  font-size: 22rpx;
  color: var(--accent);
  background: var(--accent-soft);
}
.link-card {
  overflow: hidden;
}
.link-row {
  display: flex;
  align-items: center;
  padding: 28rpx 24rpx;
  border-bottom: 1rpx solid var(--card-border);
}
.link-row:last-child {
  border-bottom: none;
}
.link-text {
  flex: 1;
  font-size: 27rpx;
  color: var(--text-primary);
}
.link-arrow {
  font-size: 32rpx;
  color: var(--text-tertiary);
}
.terms,
.copyright {
  display: block;
  text-align: center;
  font-size: 21rpx;
  color: var(--text-tertiary);
}
.terms {
  margin-top: 20rpx;
  line-height: 1.6;
}
.copyright {
  margin: 16rpx 0 60rpx;
}
.doc-head {
  padding: 20rpx 8rpx 24rpx;
}
.doc-title {
  display: block;
  font-size: 36rpx;
  font-weight: 700;
  color: var(--text-primary);
}
.doc-sub {
  display: block;
  margin-top: 8rpx;
  font-size: 22rpx;
  color: var(--text-tertiary);
}
.doc-card {
  padding: 28rpx 24rpx;
}
.doc-text {
  display: block;
  font-size: 25rpx;
  line-height: 1.9;
  color: var(--text-secondary);
  white-space: pre-wrap;
}
.doc-actions {
  display: flex;
  justify-content: center;
  margin: 32rpx 0 60rpx;
}
.doc-btn {
  padding: 16rpx 56rpx;
  border-radius: 999rpx;
  font-size: 25rpx;
  color: #ffffff;
  background: var(--accent);
}
</style>
