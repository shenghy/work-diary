/**
 * 增量 SHA-256：小程序没有内置摘要算法，而附件的中转校验（服务端按元数据里的
 * SHA-256 决定收不收这份文件）必须有它。
 *
 * 做成"喂一块、算一块"的流式接口：100MB 的原件绝不能整份读进内存，
 * 一次只处理一片（调用方按 1MB 递），算完即弃。
 *
 * 常量表由前 64 个质数的立方根/平方根小数部分导出，与 FIPS 180-4 一致。
 */

const K = new Uint32Array([
  0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
  0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
  0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
  0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
  0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
  0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
  0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
  0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2
])

const H0 = [
  0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a,
  0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19
]

function rotr(x, n) {
  return ((x >>> n) | (x << (32 - n))) >>> 0
}

/**
 * 创建一个摘要器：
 *   update(bytes) 可反复调用（Uint8Array / ArrayBuffer）；
 *   digestHex() 收尾并返回 64 位小写十六进制，调用后实例作废。
 */
export function createSha256() {
  const h = H0.slice()
  const w = new Uint32Array(64)
  const block = new Uint8Array(64)
  let blockLen = 0
  // 消息长度按 64bit 记：单 32bit 计数在 512MB 以上会溢出
  let lenLow = 0
  let lenHigh = 0

  function processBlock(buf, offset) {
    for (let i = 0; i < 16; i++) {
      const p = offset + i * 4
      w[i] = ((buf[p] << 24) | (buf[p + 1] << 16) | (buf[p + 2] << 8) | buf[p + 3]) >>> 0
    }
    for (let i = 16; i < 64; i++) {
      const s0 = w[i - 15]
      const s1 = w[i - 2]
      const gamma0 = (rotr(s0, 7) ^ rotr(s0, 18) ^ (s0 >>> 3)) >>> 0
      const gamma1 = (rotr(s1, 17) ^ rotr(s1, 19) ^ (s1 >>> 10)) >>> 0
      w[i] = (w[i - 16] + gamma0 + w[i - 7] + gamma1) >>> 0
    }
    let a = h[0]
    let b = h[1]
    let c = h[2]
    let d = h[3]
    let e = h[4]
    let f = h[5]
    let g = h[6]
    let hh = h[7]
    for (let i = 0; i < 64; i++) {
      const S1 = (rotr(e, 6) ^ rotr(e, 11) ^ rotr(e, 25)) >>> 0
      const ch = ((e & f) ^ (~e & g)) >>> 0
      const temp1 = (hh + S1 + ch + K[i] + w[i]) >>> 0
      const S0 = (rotr(a, 2) ^ rotr(a, 13) ^ rotr(a, 22)) >>> 0
      const maj = ((a & b) ^ (a & c) ^ (b & c)) >>> 0
      const temp2 = (S0 + maj) >>> 0
      hh = g
      g = f
      f = e
      e = (d + temp1) >>> 0
      d = c
      c = b
      b = a
      a = (temp1 + temp2) >>> 0
    }
    h[0] = (h[0] + a) >>> 0
    h[1] = (h[1] + b) >>> 0
    h[2] = (h[2] + c) >>> 0
    h[3] = (h[3] + d) >>> 0
    h[4] = (h[4] + e) >>> 0
    h[5] = (h[5] + f) >>> 0
    h[6] = (h[6] + g) >>> 0
    h[7] = (h[7] + hh) >>> 0
  }

  function addLength(n) {
    const bits = n * 8
    const low = bits >>> 0
    const high = Math.floor(bits / 4294967296)
    const sum = (lenLow + low) >>> 0
    // 低 32 位回绕说明进了位
    if (sum < lenLow) lenHigh = (lenHigh + 1) >>> 0
    lenLow = sum
    lenHigh = (lenHigh + high) >>> 0
  }

  return {
    update(data) {
      // ArrayBufferView（含 Node 的 Buffer）可能是共享池里的一段，必须按 offset/length 取，
      // 否则会连带把同池的别的字节一起算进摘要
      const bytes =
        data instanceof ArrayBuffer
          ? new Uint8Array(data)
          : ArrayBuffer.isView(data)
            ? new Uint8Array(data.buffer, data.byteOffset, data.byteLength)
            : new Uint8Array(data)
      addLength(bytes.length)
      let i = 0
      if (blockLen > 0) {
        const fill = Math.min(64 - blockLen, bytes.length)
        block.set(bytes.subarray(0, fill), blockLen)
        blockLen += fill
        i = fill
        if (blockLen === 64) {
          processBlock(block, 0)
          blockLen = 0
        }
      }
      while (bytes.length - i >= 64) {
        processBlock(bytes, i)
        i += 64
      }
      const rest = bytes.length - i
      if (rest > 0) {
        block.set(bytes.subarray(i), 0)
        blockLen = rest
      }
      return this
    },

    digestHex() {
      // 填充：0x80 + 若干 0，最后 8 字节是 64bit 比特长度（大端）
      const pad = new Uint8Array(blockLen < 56 ? 64 : 128)
      pad.set(block.subarray(0, blockLen))
      pad[blockLen] = 0x80
      const total = pad.length
      const dv = new DataView(pad.buffer)
      dv.setUint32(total - 8, lenHigh, false)
      dv.setUint32(total - 4, lenLow, false)
      for (let p = 0; p < total; p += 64) processBlock(pad, p)
      let out = ''
      for (let i = 0; i < 8; i++) out += h[i].toString(16).padStart(8, '0')
      return out
    }
  }
}

export function sha256Hex(data) {
  return createSha256().update(data).digestHex()
}
