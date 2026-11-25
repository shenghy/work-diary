/**
 * 附件条目的展示口径：一条 = 一个文件，"这个文件在哪、点了会怎样"全部在这里算。
 *
 * 版式与文案对齐桌面端 widgets/attachment_strip.dart：左侧纸片（本机图片用真缩略图）
 * + 类型角标，右侧名称一行、副行一行。一行里每条等宽，副行只放一句状态：
 * 本机 = 大小 + 类型，其余 = 状态词；大小、主机名、服务器原话都在长按详情里。
 * 纯函数，卡片与编辑页共用，也方便单测直接断言文案。
 */
import { badgeOf, formatSize, isImageExt, kindLabel } from './attachment_types'
import { PHASE } from './attachment_sync'

// 右上角圆形角标：桌面端用图标字体，小程序只有这几个字符能一眼认出
const OVERLAY = {
  remote: '☁',
  waiting: '⏳',
  stale: '↻',
  failed: '!'
}

export function ownerLabel(record) {
  const owner = String((record && record.owner_device_name) || '').trim()
  return owner || '其它主机'
}

export function progressText(job) {
  if (!job || job.progress === null || job.progress === undefined) return '…'
  const pct = Math.max(0, Math.min(100, Math.round(Number(job.progress) * 100)))
  return pct + '%'
}

/** 顶部进度带的宽度比例，进度未知返回 null（只写字，不画带） */
export function progressFraction(job) {
  if (!job || job.progress === null || job.progress === undefined) return null
  return Math.max(0, Math.min(1, Number(job.progress)))
}

/** 模板里不能调全局函数，宽度在这里算好带出去：'' 表示不画进度带 */
export function progressWidth(chip) {
  return chip.fraction === null || chip.fraction === undefined ? '' : Math.round(chip.fraction * 100) + '%'
}

/**
 * @param {object} record 附件元数据
 * @param {object|null} job attachment_sync.jobOf(uid)
 * @param {boolean} local 本机是否有原件
 * @param {string} thumb 本机图片原件路径，没有原件时传空串
 */
export function chipOf(record, job, local, thumb) {
  const name = (record && record.file_name) || '附件'
  const sizeText = formatSize(record.file_size)
  const badge = badgeOf(name)
  const phase = job ? job.phase : ''
  let state = ''
  let sub = sizeText + ' · ' + kindLabel(name)
  let tone = 'local'
  let overlay = ''
  let dashed = false
  let fraction = null
  if (phase === PHASE.failed) {
    state = '同步失败'
    // 副行只有半张卡片宽，状态和动作要留得下；大小在长按详情里
    sub = '同步失败 · 点重试'
    tone = 'failed'
    overlay = OVERLAY.failed
  } else if (phase === PHASE.uploading) {
    state = '上传中 ' + progressText(job)
    sub = state
    tone = 'busy'
    fraction = progressFraction(job)
  } else if (phase === PHASE.downloading) {
    state = '下载中 ' + progressText(job)
    sub = state
    tone = 'busy'
    fraction = progressFraction(job)
  } else if (phase === PHASE.waitingSource) {
    // 服务器原话留给长按详情：条目上只放一句状态，长消息会把窄卡片挤爆
    state = '等待主机上传'
    sub = state
    tone = 'waiting'
    overlay = OVERLAY.waiting
  } else if (record && record.stale_copy && local) {
    // 云端换了内容，本机这份是旧版：点一下取新版，不打开旧文件
    state = '云端有新版'
    sub = '云端有新版 · 点取回'
    tone = 'stale'
    overlay = OVERLAY.stale
  } else if (!local) {
    state = '在其它主机'
    sub = state
    tone = 'remote'
    overlay = OVERLAY.remote
    dashed = true
  }
  return {
    uid: record.uid,
    name,
    sizeText,
    badgeLabel: badge.label,
    badgeColor: badge.color,
    // 本机图片才有缩略图可画，其余一律纸片
    thumb: local && thumb && isImageExt(name) ? thumb : '',
    sub,
    state,
    tone,
    overlay,
    dashed,
    fraction,
    local: !!local,
    stale: !!(record && record.stale_copy),
    // 中转进行中不给删：文件还在管道里，删了另一边拿到的就是半截件。
    // 失败件要能删：不然卡上永远挂着一颗点不动的胶囊。
    removable: !job || phase === PHASE.failed,
    busy: !!job && phase !== PHASE.failed,
    message: job ? job.message || '' : ''
  }
}

/** 长按条目看到的详情（桌面端 Tooltip 的手机版） */
export function chipDetail(chip, record) {
  const downloaded = chip.state.indexOf('下载') === 0
  const where = chip.local || downloaded ? '在本机' : '原件在「' + ownerLabel(record) + '」'
  const lines = [chip.sizeText + ' · ' + where]
  if (chip.message) lines.push(chip.message)
  if (chip.busy) lines.push('同步进行中，传完前请勿删除')
  else if (chip.stale) lines.push('云端有更新的版本，点一下取回新版（下载完成前本机还是旧内容）')
  else if (chip.local) lines.push('点击打开，点 × 从这条记录上移除')
  else lines.push('点击从其它主机同步过来')
  return lines.join('\n')
}
