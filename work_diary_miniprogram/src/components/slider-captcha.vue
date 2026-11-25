<template>
  <view class="slider-captcha" v-if="!hidden">
    <view class="slider-track">
      <!-- 目标高亮区：位置随机 20%~80%，宽度=容差(±7%) -->
      <view
        class="slider-target"
        :class="{ ok: verified }"
        :style="{ left: targetLeft + 'px', width: targetWidth + 'px' }"
      ></view>
      <!-- 滑块块：拖动后按比例定位 -->
      <view
        class="slider-handle"
        :class="{ ok: verified }"
        :style="handleStyle"
        @touchstart="onStart"
        @touchmove="onMove"
        @touchend="onEnd"
        @touchcancel="onEnd"
      >
        <text class="handle-icon" v-if="!verified">›</text>
        <text class="handle-icon" v-else>✓</text>
      </view>
    </view>
    <view class="slider-hint" :class="{ ok: verified, fail: failed }">{{ hint }}</view>
  </view>
</template>

<script>
// 滑块人机验证组件：对齐 Windows 客户端 login_screen.dart
// 目标位置 0.2 + random*0.6（20%~80%），容差 ±0.07；松手判定，通过后 emit('success')
export default {
  name: 'SliderCaptcha',
  data() {
    return {
      trackWidth: 0, // 轨道实际宽度(px)
      handleWidth: 0, // 滑块块宽度(px)
      maxDrag: 0, // 最大拖动距离 = trackWidth - handleWidth
      value: 0, // 当前拖动比例 0~1
      target: 0.2 + Math.random() * 0.6, // 目标位置
      range: 0.07, // 判定容差（对齐 Windows 端 _targetRange）
      startX: 0,
      dragging: false,
      verified: false,
      failed: false,
      hidden: false,
      hint: '拖动滑块到高亮区域'
    }
  },
  computed: {
    // 目标区：以滑块块中心对齐 target，宽度 = 2*range*maxDrag
    targetLeft() {
      return this.target * this.maxDrag + this.handleWidth / 2 - this.range * this.maxDrag
    },
    targetWidth() {
      return this.range * 2 * this.maxDrag
    },
    handleStyle() {
      return {
        left: this.value * this.maxDrag + 'px',
        transition: this.dragging || this.verified ? 'none' : 'left 0.3s ease'
      }
    }
  },
  mounted() {
    this.measure()
  },
  methods: {
    measure() {
      const win =
        typeof wx !== 'undefined' && wx.getWindowInfo
          ? wx.getWindowInfo()
          : uni.getSystemInfoSync()
      this.handleWidth = (72 * win.windowWidth) / 750
      const q = uni.createSelectorQuery().in(this)
      q.select('.slider-track')
        .boundingClientRect((rect) => {
          if (rect && rect.width > 0) {
            this.trackWidth = rect.width
            this.maxDrag = rect.width - this.handleWidth
          }
        })
        .exec()
    },
    onStart(e) {
      if (this.verified) return
      // 若轨道宽度尚未测量成功，先重新测量（防止 maxDrag=0 导致无法拖动）
      if (!this.maxDrag) this.measure()
      const touch = e.touches[0]
      if (!touch || !this.maxDrag) return
      this.dragging = true
      this.failed = false
      this.startX = touch.clientX - this.value * this.maxDrag
    },
    onMove(e) {
      if (!this.dragging || this.verified || !this.maxDrag) return
      const touch = e.touches[0]
      if (!touch) return
      let v = (touch.clientX - this.startX) / this.maxDrag
      v = Math.max(0, Math.min(1, v))
      this.value = v
    },
    onEnd() {
      if (!this.dragging || this.verified) return
      this.dragging = false
      const diff = Math.abs(this.value - this.target)
      if (diff <= this.range) {
        // 通过：目标区变绿，1.2s 后隐藏
        this.verified = true
        this.hint = '验证通过，正在发送...'
        this.$emit('success')
        setTimeout(() => {
          this.hidden = true
        }, 1200)
      } else {
        // 失败：滑块回弹到起点，提示重试
        this.failed = true
        this.hint = '位置不对，重试'
        this.value = 0
      }
    }
  }
}
</script>

<style lang="scss" scoped>
.slider-captcha {
  margin-top: 20rpx;
}
.slider-track {
  position: relative;
  height: 80rpx;
  background: var(--chip-bg);
  border: 2rpx solid var(--chip-border);
  border-radius: 40rpx;
  box-sizing: border-box;
  overflow: hidden;
}
.slider-target {
  position: absolute;
  top: 0;
  height: 100%;
  background: var(--accent);
  opacity: 0.24;
  border-radius: 40rpx;
  transition: background 0.2s ease;
}
.slider-target.ok {
  background: var(--status-completed);
}
.slider-handle {
  position: absolute;
  top: 0;
  width: 72rpx;
  height: 80rpx;
  background: #ffffff;
  border-radius: 40rpx;
  box-shadow: 0 2rpx 8rpx rgba(0, 0, 0, 0.18);
  display: flex;
  align-items: center;
  justify-content: center;
  z-index: 2;
}
.slider-handle.ok {
  background: var(--status-completed);
  box-shadow: 0 2rpx 8rpx rgba(16, 185, 129, 0.4);
}
.handle-icon {
  font-size: 36rpx;
  color: var(--accent);
  font-weight: 700;
  line-height: 1;
}
.slider-handle.ok .handle-icon {
  color: #ffffff;
}
.slider-hint {
  margin-top: 10rpx;
  font-size: 22rpx;
  color: var(--text-tertiary);
}
.slider-hint.ok {
  color: var(--status-completed);
}
.slider-hint.fail {
  color: var(--danger);
}
</style>
