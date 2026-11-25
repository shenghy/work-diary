<template>
  <view class="aurora-bg" :class="{ 'is-animated': motion }">
    <view class="aurora-base"></view>
    <view class="blob b1"></view>
    <view class="blob b2"></view>
    <view class="blob b3"></view>
    <view class="blob b4"></view>
    <view class="blob b5"></view>
    <view class="blob b6"></view>
    <view class="blob b7"></view>
    <view class="aurora-scrim"></view>
  </view>
</template>

<script>
import { isAuroraMotionEnabled } from '../utils/glass'

export default {
  name: 'AuroraBg',
  data() {
    return { motion: true }
  },
  mounted() {
    this.motion = isAuroraMotionEnabled()
    uni.$on('aurora-motion', this.onMotionChange)
  },
  beforeUnmount() {
    uni.$off('aurora-motion', this.onMotionChange)
  },
  methods: {
    onMotionChange(on) {
      this.motion = !!on
    }
  }
}
</script>

<style lang="scss" scoped>
.aurora-bg {
  position: fixed;
  left: 0;
  top: 0;
  right: 0;
  bottom: 0;
  z-index: -1;
  overflow: hidden;
  pointer-events: none;
  background: linear-gradient(180deg, var(--bg-page), var(--bg-page-deep));
}
.aurora-base {
  position: absolute;
  left: 0;
  top: 0;
  right: 0;
  bottom: 0;
  background: linear-gradient(180deg, var(--bg-page), var(--bg-page-deep));
}
.blob {
  position: absolute;
  border-radius: 50%;
}
.b1 {
  width: 170vw;
  height: 170vw;
  left: -60vw;
  top: -70vw;
  background: radial-gradient(circle, var(--aurora-1) 0%, transparent 69%);
}
.b2 {
  width: 160vw;
  height: 160vw;
  left: -45vw;
  top: -6vh;
  background: radial-gradient(circle, var(--aurora-2) 0%, transparent 70%);
}
.b3 {
  width: 155vw;
  height: 155vw;
  right: -65vw;
  top: -4vh;
  background: radial-gradient(circle, var(--aurora-3) 0%, transparent 70%);
}
.b4 {
  width: 150vw;
  height: 150vw;
  left: 10vw;
  top: 32vh;
  background: radial-gradient(circle, var(--aurora-4) 0%, transparent 70%);
}
.b5 {
  width: 115vw;
  height: 115vw;
  right: -20vw;
  top: -8vh;
  background: radial-gradient(circle, var(--aurora-5) 0%, transparent 70%);
}
.b6 {
  width: 150vw;
  height: 150vw;
  left: -15vw;
  bottom: -60vw;
  background: radial-gradient(circle, var(--aurora-6) 0%, transparent 70%);
}
.b7 {
  width: 85vw;
  height: 85vw;
  left: 18vw;
  top: 26vh;
  background: radial-gradient(circle, var(--aurora-7) 0%, transparent 70%);
}
.aurora-scrim {
  position: absolute;
  left: 0;
  top: 0;
  right: 0;
  bottom: 0;
  background: var(--aurora-scrim);
}

.is-animated .b1 {
  animation: drift-a 26s ease-in-out infinite;
}
.is-animated .b2 {
  animation: drift-b 32s ease-in-out infinite;
}
.is-animated .b3 {
  animation: drift-c 29s ease-in-out infinite;
}
.is-animated .b4 {
  animation: drift-b 34s ease-in-out infinite reverse;
}
.is-animated .b5 {
  animation: drift-c 24s ease-in-out infinite reverse;
}
.is-animated .b6 {
  animation: drift-a 38s ease-in-out infinite reverse;
}
.is-animated .b7 {
  animation: drift-a 22s ease-in-out infinite;
}
@keyframes drift-a {
  0%,
  100% {
    transform: translate3d(0, 0, 0) scale(1);
  }
  50% {
    transform: translate3d(6vw, 5vh, 0) scale(1.06);
  }
}
@keyframes drift-b {
  0%,
  100% {
    transform: translate3d(0, 0, 0) scale(1);
  }
  50% {
    transform: translate3d(-5vw, 6vh, 0) scale(1.04);
  }
}
@keyframes drift-c {
  0%,
  100% {
    transform: translate3d(0, 0, 0) scale(1.02);
  }
  50% {
    transform: translate3d(4vw, -5vh, 0) scale(0.98);
  }
}
</style>
