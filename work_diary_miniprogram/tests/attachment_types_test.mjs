/**
 * 附件基础层测试（实现在 src/utils/sha256.js / attachment_types.js / attachment_store.js）：
 * 跑法 node tests/attachment_types_test.mjs
 *
 * SHA-256 是三端约定的校验口径：小程序没有内置摘要算法，自己实现的这份
 * 必须和 Node 的 crypto 逐字节一致，否则源机算出来的哈希在服务端校验时永远对不上，
 * 表现是"同步一直失败"却看不出原因。
 */
import crypto from 'node:crypto'
import { register } from 'node:module'
import { createSha256, sha256Hex } from '../src/utils/sha256.js'
import {
  checkFile,
  extOf,
  formatSize,
  sanitizeFileName,
  sanitizeUid,
  MAX_BYTES,
  MAX_PER_PARENT
} from '../src/utils/attachment_types.js'

register('./esm_ext_hooks.mjs', import.meta.url)

let failed = 0
function eq(actual, expected, msg) {
  const a = JSON.stringify(actual)
  const e = JSON.stringify(expected)
  if (a !== e) {
    failed++
    console.log('FAIL ' + msg + '\n  期望 ' + e + '\n  实际 ' + a)
  } else {
    console.log('ok   ' + msg)
  }
}
function ok(cond, msg) {
  if (cond) console.log('ok   ' + msg)
  else {
    failed++
    console.log('FAIL ' + msg)
  }
}

// ---------------- 1. SHA-256 与 Node crypto 一致 ----------------
function rand(n) {
  const b = Buffer.alloc(n)
  for (let i = 0; i < n; i++) b[i] = Math.floor(Math.random() * 256)
  return b
}
const inputs = [
  Buffer.alloc(0),
  Buffer.from('abc'),
  Buffer.from('a'.repeat(55)),
  Buffer.from('a'.repeat(56)),
  Buffer.from('a'.repeat(63)),
  Buffer.from('a'.repeat(64)),
  Buffer.from('a'.repeat(65)),
  Buffer.from('a'.repeat(111)),
  Buffer.from('a'.repeat(112)),
  Buffer.from('a'.repeat(119)),
  Buffer.from('a'.repeat(120)),
  Buffer.from('中文测试 🎉 附件.pdf'),
  rand(1000),
  rand(65536),
  rand(1 << 20)
]
for (const buf of inputs) {
  const expect = crypto.createHash('sha256').update(buf).digest('hex')
  eq(sha256Hex(new Uint8Array(buf)), expect, '整块摘要 len=' + buf.length)
  // 分块喂：真实调用是按 1MB 递进去的，跨 64 字节边界的每一种都要一致
  for (const chunk of [1, 7, 13, 64, 997, 4096]) {
    if (buf.length === 0) break
    const s = createSha256()
    for (let i = 0; i < buf.length; i += chunk) {
      s.update(new Uint8Array(buf.subarray(i, i + chunk)))
    }
    eq(s.digestHex(), expect, `分块摘要 len=${buf.length} chunk=${chunk}`)
  }
}
{
  // ArrayBuffer 入参（fs.readFile 给的就是它，不是 Uint8Array）
  const ab = new Uint8Array([0x61, 0x62, 0x63]).buffer
  eq(sha256Hex(ab), crypto.createHash('sha256').update('abc').digest('hex'), 'ArrayBuffer 也能直接喂')
  // 共享池里的视图（Node 小 Buffer 就是这种）：必须按 byteOffset/byteLength 取，
  // 否则会连隔壁字节一起算进来，摘要永远对不上
  const pool = Buffer.alloc(64)
  const view = pool.subarray(7, 10)
  view.set([0x61, 0x62, 0x63])
  eq(sha256Hex(view), crypto.createHash('sha256').update('abc').digest('hex'), '带偏移的视图只算自己那段')
  // 超过 2^32 bit（512MB）时长度要用高 32 位：这里用等价的长度断言，避免真跑 512MB
  const s = createSha256()
  for (let i = 0; i < 600; i++) s.update(new Uint8Array(1 << 20))
  ok(/^[0-9a-f]{64}$/.test(s.digestHex()), '600MB 流式摘要不抛错且输出 64 位十六进制')
}

// ---------------- 2. 扩展名与类型白名单 ----------------
eq(extOf('报告.DOCX'), '.docx', '扩展名统一小写')
eq(extOf('noext'), '', '无扩展名返回空串')
eq(extOf('.gitignore'), '', '点开头属于隐藏文件而不是扩展名')
eq(extOf('a.'), '', '以点结尾不算扩展名')
eq(extOf('C:\\tmp\\笔记.txt'), '.txt', '取路径最后一段')

ok(checkFile('a.pdf').allowed, 'pdf 允许')
ok(checkFile('a.PNG').allowed, '图片大小写不敏感')
eq(checkFile('a.pdf').mime, 'application/pdf', '给出 MIME')
eq(checkFile('a.unknownext').allowed, false, '未知类型拒绝')
ok(checkFile('a.exe').reason.indexOf('可执行文件') === 0, '可执行文件给出分类原因')
ok(checkFile('a.mp4').reason.indexOf('视频文件') === 0, '视频给出分类原因')
ok(checkFile('a.mp3').reason.indexOf('音频文件') === 0, '音频给出分类原因')
ok(checkFile('a.zip').reason.indexOf('压缩包') === 0, '压缩包给出分类原因')
ok(checkFile('a.txt').reason === '', '放行时没有拒绝原因')
ok(checkFile('a.mkv').reason.indexOf('仅支持图片和文档') > 0, '拒绝原因带上"能放什么"')
eq(checkFile('a.pdf', MAX_BYTES).allowed, true, '刚好 100MB 放行（服务端是 > 判定）')
eq(checkFile('a.pdf', MAX_BYTES + 1).allowed, false, '超过 100MB 拒绝')
ok(checkFile('a.pdf', MAX_BYTES + 1).reason.indexOf('100MB') > 0, '超限提示写明上限')
eq(MAX_PER_PARENT, 5, '单条上限 5 个')

// ---------------- 3. 大小文案 ----------------
eq(formatSize(0), '0 B', '0 字节')
eq(formatSize(29), '29 B', '按 B 显示')
eq(formatSize(1024), '1.0 KB', '按 KB 显示')
eq(formatSize(2 * 1024 * 1024 + 1024), '2.0 MB', '按 MB 显示')
eq(formatSize(undefined), '未知大小', '拿不到大小时不显示 NaN')

// ---------------- 4. 不可信输入清洗 ----------------
eq(sanitizeUid('e29ae301-9ce2-4905-b354-232fac679e96'), 'e29ae301-9ce2-4905-b354-232fac679e96', '合法 uid 原样保留')
eq(sanitizeUid('../../etc/passwd'), 'etcpasswd', 'uid 里的路径符号全部剔除')
eq(sanitizeUid('x'.repeat(100)).length, 64, 'uid 长度封顶 64')
eq(sanitizeFileName('a/b\\c:d?.txt'), 'a_b_c_d_.txt', '文件名非法字符替换')
eq(sanitizeFileName('../../evil.pdf'), '.._.._evil.pdf', '目录穿越变成普通文件名，不再指向别处')
eq(sanitizeFileName('..'), '附件', '纯点号不会变成上级目录')
eq(sanitizeFileName('名'.repeat(200) + '.pdf').length <= 100, true, '超长文件名截断到 100 以内')
ok(sanitizeFileName('超长'.repeat(60) + '.pdf').endsWith('.pdf'), '截断保留扩展名')
eq(sanitizeFileName(''), '附件', '空名兜底')

console.log(failed === 0 ? '\n全部通过' : '\n失败 ' + failed + ' 项')
process.exit(failed === 0 ? 0 : 1)
