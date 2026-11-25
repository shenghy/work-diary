<template>
  <view class="login-page" :class="themeClass">
    <aurora-bg />
    <view class="login-card glass">
      <view class="app-title">极简工作日记</view>
      <view class="app-subtitle">随手记下每一件事</view>

      <!-- 模式切换 -->
      <view class="mode-tabs">
        <view
          v-for="m in modes"
          :key="m.key"
          class="mode-tab"
          :class="{ active: mode === m.key }"
          @click="switchMode(m.key)"
        >{{ m.text }}</view>
      </view>

      <!-- 邮箱 -->
      <view class="field">
        <input
          v-model="email"
          class="input"
          type="text"
          placeholder="邮箱"
          placeholder-class="ph"
          @blur="onEmailBlur"
          @confirm="onEmailBlur"
        />
      </view>
      <!-- 记住的邮箱：可一键切换账号 -->
      <view class="switch-email" v-if="mode === 'login' && email" @click="switchEmail">不是这个邮箱？切换账号</view>

      <!-- 密码（登录/注册） -->
      <view class="field" v-if="mode === 'login' || mode === 'register'">
        <input
          v-model="password"
          class="input"
          :password="true"
          :placeholder="mode === 'register' ? '设置密码（至少6位）' : '密码'"
          placeholder-class="ph"
        />
      </view>

      <!-- 确认密码（注册） -->
      <view class="field" v-if="mode === 'register'">
        <input
          v-model="confirm"
          class="input"
          :password="true"
          placeholder="确认密码"
          placeholder-class="ph"
        />
      </view>

      <!-- 找回第2步：新密码 + 确认新密码（验证码校验通过后才显示） -->
      <view class="field" v-if="mode === 'recover' && recoverStep === 2">
        <input
          v-model="password"
          class="input"
          :password="true"
          placeholder="新密码（至少6位）"
          placeholder-class="ph"
        />
      </view>
      <view class="field" v-if="mode === 'recover' && recoverStep === 2">
        <input
          v-model="confirm"
          class="input"
          :password="true"
          placeholder="确认新密码"
          placeholder-class="ph"
        />
      </view>

      <!-- 验证码（注册 / 找回第1步）；获取验证码前需通过滑块验证（防机器，对齐 Windows 端） -->
      <view class="field" v-if="mode === 'register' || (mode === 'recover' && recoverStep === 1)">
        <view class="code-row">
          <input
            v-model="code"
            class="input code-input"
            type="text"
            placeholder="邮箱验证码"
            placeholder-class="ph"
          />
          <view class="code-btn" :class="{ disabled: countdown > 0 }" @click="sendCode">
            {{ countdown > 0 ? countdown + 's' : '获取验证码' }}
          </view>
        </view>
        <!-- 滑块人机验证：通过后自动发送验证码 -->
        <slider-captcha v-if="showSlider" :key="sliderKey" @success="onSliderSuccess" />
      </view>

      <view class="hint" v-if="mode !== 'login' && emailHint">{{ emailHint }}</view>
      <view class="hint" v-if="error">{{ error }}</view>

      <view class="submit-btn" @click="submit">{{ submitText }}</view>
      <view class="back-link" v-if="mode === 'recover' && recoverStep === 2" @click="backToStep1">‹ 上一步（返回重新获取验证码）</view>
      <view class="tip">验证码将发送到你的邮箱，5 分钟内有效</view>
    </view>
  </view>
</template>

<script>
import AuroraBg from '../../components/aurora-bg.vue'
import SliderCaptcha from '../../components/slider-captcha.vue'
import { api } from '../../utils/api'
import { setAuth } from '../../utils/auth'
import { connectWS } from '../../utils/ws'
import { showToast } from '../../utils/util'

const EMAIL_RE = /^[\w.-]+@([\w-]+\.)+[\w-]{2,}$/
// 记住邮箱（仅存邮箱，不存密码）：下次登录自动回填，只输密码
const REMEMBER_EMAIL_KEY = 'wd_remember_email'

export default {
  components: { AuroraBg, SliderCaptcha },
  data() {
    return {
      mode: 'login',
      modes: [
        { key: 'login', text: '登录' },
        { key: 'register', text: '注册' },
        { key: 'recover', text: '找回密码' }
      ],
      // 找回密码两步：1=验证身份（邮箱+验证码），2=设置新密码
      recoverStep: 1,
      // 滑块人机验证显示开关；sliderKey 递增强制重建（每次显示都是新目标位置）
      showSlider: false,
      sliderKey: 0,
      email: '',
      password: '',
      confirm: '',
      code: '',
      countdown: 0,
      emailHint: '',
      error: '',
      emailRegistered: false,
      timer: null
    }
  },
  computed: {
    submitText() {
      if (this.mode === 'login') return '登 录'
      if (this.mode === 'register') return '注 册'
      // 找回：第 1 步「下一步」校验验证码；第 2 步「重置密码」
      return this.recoverStep === 1 ? '下一步' : '重置密码'
    }
  },
  onShow() {
    // 记住的邮箱：自动回填邮箱框，用户只需输入密码
    const saved = uni.getStorageSync(REMEMBER_EMAIL_KEY)
    if (saved && !this.email) {
      this.email = saved
    }
  },
  onUnload() {
    if (this.timer) clearInterval(this.timer)
  },
  methods: {
    switchMode(key) {
      this.mode = key
      this.recoverStep = 1
      this.showSlider = false
      this.error = ''
      this.emailHint = ''
      this.code = ''
      this.password = ''
      this.confirm = ''
    },
    // 切换账号：清除记住的邮箱并清空输入框
    switchEmail() {
      uni.removeStorageSync(REMEMBER_EMAIL_KEY)
      this.email = ''
    },
    onEmailBlur() {
      const email = this.email.trim()
      if (!EMAIL_RE.test(email)) {
        this.emailHint = ''
        return
      }
      if (this.mode === 'login') return
      // 注册模式：未注册才能注册；找回模式：需已注册
      api
        .get('/api/auth/email-status', { email: email })
        .then((res) => {
          this.emailRegistered = !!res.registered
          if (this.mode === 'register') {
            if (res.registered) {
              this.emailHint = '该邮箱已被注册，请直接登录'
              // 已注册邮箱不能走注册流程：清空密码/确认/验证码，避免继续误操作
              this.password = ''
              this.confirm = ''
              this.code = ''
            } else {
              this.emailHint = ''
            }
          } else {
            this.emailHint = res.registered ? '' : '该邮箱未注册'
          }
        })
        .catch(() => {})
    },
    sendCode() {
      const email = this.email.trim()
      if (!EMAIL_RE.test(email)) {
        this.error = '请输入正确的邮箱地址'
        return
      }
      this.error = ''
      // 发送前校验注册状态
      api
        .get('/api/auth/email-status', { email: email })
        .then((res) => {
          this.emailRegistered = !!res.registered
          if (this.mode === 'register' && res.registered) {
            this.error = '该邮箱已注册，请直接登录'
            return
          }
          if (this.mode === 'recover' && !res.registered) {
            this.error = '该邮箱未注册'
            return
          }
          // 注册状态检查通过 → 弹出滑块人机验证（对齐 Windows 端：验证通过才真正发码）
          this.sliderKey++
          this.showSlider = true
        })
        .catch((err) => {
          this.error = err.message
        })
    },
    // 滑块验证通过（组件 emit success）→ 隐藏滑块并发送验证码
    onSliderSuccess() {
      this.showSlider = false
      this.doSendCode(this.email.trim())
    },
    // 找回第 2 步返回第 1 步（重新获取/输入验证码）
    backToStep1() {
      this.recoverStep = 1
      this.error = ''
    },
    doSendCode(email) {
      uni.showLoading({ title: '发送中', mask: true })
      api
        .post('/api/auth/send-code', { email: email })
        .then(() => {
          uni.hideLoading()
          this.emailHint = '验证码已发送到邮箱'
          this.startCountdown()
        })
        .catch((err) => {
          uni.hideLoading()
          this.error = err.message
        })
    },
    startCountdown() {
      this.countdown = 60
      if (this.timer) clearInterval(this.timer)
      this.timer = setInterval(() => {
        this.countdown--
        if (this.countdown <= 0 && this.timer) {
          clearInterval(this.timer)
          this.timer = null
        }
      }, 1000)
    },
    submit() {
      const email = this.email.trim()
      if (!EMAIL_RE.test(email)) {
        this.error = '请输入正确的邮箱地址'
        return
      }
      if (this.mode === 'login') {
        if (!this.password) {
          this.error = '请输入密码'
          return
        }
        this.doLogin(email, this.password)
      } else if (this.mode === 'register') {
        if (!this.code) {
          this.error = '请输入验证码'
          return
        }
        if (this.password.length < 6) {
          this.error = '密码至少 6 位'
          return
        }
        if (this.password !== this.confirm) {
          this.error = '两次输入的密码不一致'
          return
        }
        this.doRegister(email)
      } else {
        // 找回密码：第 1 步先校验验证码，通过后进入第 2 步设置新密码
        if (this.recoverStep === 1) {
          if (!this.code) {
            this.error = '请输入验证码'
            return
          }
          this.verifyCodeThenNext(email)
        } else {
          if (this.password.length < 6) {
            this.error = '新密码至少 6 位'
            return
          }
          if (this.password !== this.confirm) {
            this.error = '两次输入的密码不一致'
            return
          }
          this.doReset(email)
        }
      }
    },
    // 找回第 1 步：校验验证码（后端只校验不消费），通过后进入第 2 步
    verifyCodeThenNext(email) {
      uni.showLoading({ title: '验证中', mask: true })
      api
        .post('/api/auth/verify-code', { email: email, code: this.code })
        .then((res) => {
          uni.hideLoading()
          if (res && res.valid) {
            this.error = ''
            this.recoverStep = 2
          } else {
            this.error = (res && res.error) || '验证码错误'
          }
        })
        .catch((err) => {
          uni.hideLoading()
          this.error = err.message
        })
    },
    doLogin(email, password) {
      uni.showLoading({ title: '登录中', mask: true })
      api
        .post('/api/auth/login', { email: email, password: password })
        .then((res) => {
          uni.hideLoading()
          setAuth(res.token, res.user)
          // 记住邮箱：下次登录自动回填，只输密码
          uni.setStorageSync(REMEMBER_EMAIL_KEY, (res.user && res.user.email) || email)
          connectWS()
          showToast('登录成功', 'success')
          setTimeout(() => {
            uni.reLaunch({ url: '/pages/tasks/tasks' })
          }, 400)
        })
        .catch((err) => {
          uni.hideLoading()
          this.error = err.message
        })
    },
    doRegister(email) {
      uni.showLoading({ title: '注册中', mask: true })
      api
        .post('/api/auth/register', {
          email: email,
          code: this.code,
          password: this.password
        })
        .then((res) => {
          uni.hideLoading()
          setAuth(res.token, res.user)
          // 新注册用户也记住邮箱：下次登录自动回填
          uni.setStorageSync(REMEMBER_EMAIL_KEY, (res.user && res.user.email) || email)
          connectWS()
          showToast('注册成功', 'success')
          setTimeout(() => {
            uni.reLaunch({ url: '/pages/tasks/tasks' })
          }, 400)
        })
        .catch((err) => {
          uni.hideLoading()
          this.error = err.message
        })
    },
    doReset(email) {
      uni.showLoading({ title: '提交中', mask: true })
      api
        .post('/api/auth/reset-password', {
          email: email,
          code: this.code,
          password: this.password
        })
        .then(() => {
          uni.hideLoading()
          showToast('密码已重置，请登录', 'success')
          // 记住邮箱：找回后回登录页自动回填
          uni.setStorageSync(REMEMBER_EMAIL_KEY, email)
          this.switchMode('login')
          this.email = email
          this.password = ''
        })
        .catch((err) => {
          uni.hideLoading()
          this.error = err.message
        })
    }
  }
}
</script>

<style lang="scss">
.login-page {
  min-height: 100vh;
  background: transparent;
  padding: 60rpx 40rpx;
  box-sizing: border-box;
}
.login-card {
  width: 100%;
  max-width: 640rpx;
  margin: 0 auto;
  background: var(--card-bg);
  border: 1rpx solid var(--card-border);
  border-radius: 32rpx;
  padding: 60rpx 48rpx 48rpx;
  box-sizing: border-box;
  box-shadow: var(--shadow-card);
}
.app-title {
  font-size: 44rpx;
  font-weight: 700;
  text-align: center;
  color: var(--text-primary);
}
.app-subtitle {
  font-size: 26rpx;
  color: var(--text-tertiary);
  text-align: center;
  margin-top: 10rpx;
  margin-bottom: 48rpx;
}
.mode-tabs {
  display: flex;
  margin-bottom: 36rpx;
  border-bottom: 2rpx solid var(--card-border);
}
.mode-tab {
  flex: 1;
  text-align: center;
  font-size: 28rpx;
  color: var(--text-secondary);
  padding-bottom: 16rpx;
  position: relative;
  cursor: pointer;
}
.mode-tab.active {
  color: var(--accent);
  font-weight: 600;
}
.mode-tab.active::after {
  content: '';
  position: absolute;
  bottom: -2rpx;
  left: 25%;
  width: 50%;
  height: 4rpx;
  border-radius: 2rpx;
  background: var(--accent);
}
.field {
  margin-bottom: 24rpx;
}
.input {
  height: 88rpx;
  background: var(--field-bg);
  border: 2rpx solid var(--field-border);
  border-radius: 12rpx;
  padding: 0 24rpx;
  font-size: 28rpx;
  box-sizing: border-box;
  color: var(--text-primary);
}
.ph {
  color: var(--text-tertiary);
}
.switch-email {
  text-align: right;
  font-size: 24rpx;
  color: var(--accent);
  margin: -8rpx 0 16rpx;
}
.code-row {
  display: flex;
  gap: 16rpx;
}
.code-input {
  flex: 1;
}
.code-btn {
  width: 200rpx;
  height: 88rpx;
  line-height: 88rpx;
  text-align: center;
  border-radius: 12rpx;
  background: var(--accent-soft);
  color: var(--accent);
  font-size: 26rpx;
  flex-shrink: 0;
}
.code-btn.disabled {
  background: var(--chip-bg);
  color: var(--text-tertiary);
}
.hint {
  font-size: 24rpx;
  color: #f59e0b;
  margin: -8rpx 0 16rpx;
}
.error-hint {
  color: var(--danger);
}
.submit-btn {
  margin-top: 16rpx;
  height: 92rpx;
  line-height: 92rpx;
  text-align: center;
  background: var(--accent);
  color: #ffffff;
  font-size: 32rpx;
  font-weight: 600;
  border-radius: 14rpx;
}
.tip {
  font-size: 22rpx;
  color: var(--text-tertiary);
  text-align: center;
  margin-top: 24rpx;
}
.back-link {
  text-align: center;
  font-size: 24rpx;
  color: var(--text-secondary);
  margin-top: 20rpx;
  padding: 8rpx 0;
}
</style>
