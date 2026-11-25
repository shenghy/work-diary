/**
 * UUID v4：附件 uid 与设备 id 都用它。
 *
 * 小程序没有 crypto.getRandomValues（部分基础库有但不可依赖），这里用
 * Math.random 填 128 位并把版本/变体位按 v4 规矩钉好。uid 只需要"跨设备不撞"，
 * 不承担鉴权，随机性够用；服务端另有 UID_RE 做格式校验兜底。
 */
const HEX = '0123456789abcdef'

function hex(n) {
  let s = ''
  for (let i = 0; i < n; i++) s += HEX[Math.floor(Math.random() * 16)]
  return s
}

export function genUuid() {
  return (
    hex(8) +
    '-' +
    hex(4) +
    '-4' +
    hex(3) +
    '-' +
    HEX[(8 + Math.floor(Math.random() * 4)) | 0] +
    hex(3) +
    '-' +
    hex(12)
  )
}
