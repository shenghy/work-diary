/**
 * WebSocket 实时同步（对齐桌面端 sync_websocket.dart）：
 * - 连接 wss://work.jspang.com/ws?token=&client_id=&device_id=&device_name=
 * - 服务端数据变更时推送 {type:'data_changed'}（已排除触发方），收到后触发回调拉取全量
 * - 附件中转推送 attachment_request / attachment_ready / attachment_taken 交给回调处理
 * - 30s 心跳保活；断线 5s 自动重连（登出/手动关闭除外）
 * 注：微信小程序切后台约 5s 后 WebSocket 会被系统断开，回前台由 App.onShow 重连兜底。
 */
import { getToken, isLoggedIn } from './auth'
import { getDeviceId, getDeviceName } from './device_identity'

const CLIENT_ID_KEY = 'wd_ws_client_id'
const WS_URL = 'wss://work.jspang.com/ws'
const HEARTBEAT_MS = 30000
const RECONNECT_MS = 5000

let socketTask = null
let heartbeatTimer = null
let reconnectTimer = null
let manuallyClosed = false
let onDataChanged = null
let onAttachmentPush = null

// 生成随机 client_id（uuid v4 简化版），服务端用于排除本端自己的推送
function genClientId() {
  let s = ''
  for (let i = 0; i < 32; i++) s += Math.floor(Math.random() * 16).toString(16)
  return s
}

export function getClientId() {
  let id = uni.getStorageSync(CLIENT_ID_KEY)
  if (!id) {
    id = genClientId()
    uni.setStorageSync(CLIENT_ID_KEY, id)
  }
  return id
}

// 注册数据变更回调（收到 data_changed 时执行，如拉取云端全量）
export function setOnDataChanged(fn) {
  onDataChanged = fn
}

// 注册附件中转回调（谁有原件谁上传、谁的请求已备齐谁下载）
export function setOnAttachmentPush(fn) {
  onAttachmentPush = fn
}

function startHeartbeat() {
  stopHeartbeat()
  heartbeatTimer = setInterval(() => {
    if (socketTask) {
      try {
        socketTask.send({ data: 'ping' })
      } catch (e) {}
    }
  }, HEARTBEAT_MS)
}

function stopHeartbeat() {
  if (heartbeatTimer) {
    clearInterval(heartbeatTimer)
    heartbeatTimer = null
  }
}

function scheduleReconnect() {
  if (manuallyClosed || !isLoggedIn()) return
  if (reconnectTimer) return
  reconnectTimer = setTimeout(() => {
    reconnectTimer = null
    connectWS()
  }, RECONNECT_MS)
}

/**
 * 建立连接（幂等：已有连接则跳过）。
 * 调用时机：App 回前台、登录成功、页面 onShow（兜底）。
 */
export function connectWS() {
  if (!isLoggedIn()) return
  const token = getToken()
  if (!token) return
  if (socketTask) return
  manuallyClosed = false

  // device_id/device_name 必须带上：服务器靠它判断"这台机器能不能应答某个拉取请求"，
  // 并在本机上线时把欠着的中转补发一遍（否则用户得再点一次同步）
  const url =
    WS_URL +
    '?token=' +
    encodeURIComponent(token) +
    '&client_id=' +
    encodeURIComponent(getClientId()) +
    '&device_id=' +
    encodeURIComponent(getDeviceId()) +
    '&device_name=' +
    encodeURIComponent(getDeviceName())
  socketTask = uni.connectSocket({
    url: url,
    complete: () => {}
  })
  socketTask.onOpen(() => {
    startHeartbeat()
  })
  socketTask.onMessage((res) => {
    try {
      const msg = JSON.parse(res.data)
      if (msg.type === 'data_changed' && onDataChanged) onDataChanged()
      else if (msg.type && String(msg.type).indexOf('attachment_') === 0 && onAttachmentPush) {
        onAttachmentPush(msg)
      }
    } catch (e) {}
  })
  socketTask.onClose(() => {
    stopHeartbeat()
    socketTask = null
    scheduleReconnect()
  })
  socketTask.onError(() => {
    stopHeartbeat()
    socketTask = null
    scheduleReconnect()
  })
}

/**
 * 断开连接（手动，如登出/切后台），不自动重连
 */
export function disconnectWS() {
  manuallyClosed = true
  if (reconnectTimer) {
    clearTimeout(reconnectTimer)
    reconnectTimer = null
  }
  stopHeartbeat()
  if (socketTask) {
    try {
      socketTask.close({})
    } catch (e) {}
    socketTask = null
  }
}
