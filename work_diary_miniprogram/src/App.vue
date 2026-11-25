<script>
import { isLoggedIn } from './utils/auth'
import { connectWS, disconnectWS } from './utils/ws'
import { applyThemeChrome, broadcastTheme, getThemeMode } from './utils/theme'

export default {
  onLaunch: function () {
    applyThemeChrome()
    // 跟随系统时，系统深浅色变化实时刷新已打开页面
    try {
      if (uni.onThemeChange) {
        uni.onThemeChange(() => {
          if (getThemeMode() === 'system') broadcastTheme()
        })
      }
    } catch (e) {}
  },
  // 回到前台：重连 WebSocket（切后台时微信会断开连接）
  onShow: function () {
    applyThemeChrome()
    if (isLoggedIn()) connectWS()
  },
  // 切后台：主动断开，回前台再重连
  onHide: function () {
    disconnectWS()
  }
}
</script>

<style lang="scss">
@import './styles/tokens.scss';

/* 全局公共样式 */
page {
  background-color: #eef2fb;
  font-family: -apple-system, BlinkMacSystemFont, 'Helvetica Neue', 'PingFang SC',
    'Hiragino Sans GB', 'Microsoft YaHei', sans-serif;
  color: var(--text-primary);
}
view,
text,
input,
textarea,
button {
  box-sizing: border-box;
}
</style>
