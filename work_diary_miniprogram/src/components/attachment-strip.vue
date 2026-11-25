<template>
  <view class="att-strip" v-if="rows.length > 0">
    <view
      v-for="row in rows"
      :key="row.key"
      class="att-item"
      :class="['tone-' + row.tone, row.dashed ? 'is-dashed' : '']"
      @click.stop="onTap(row)"
      @longpress.stop="onInfo(row)"
    >
      <view class="att-icon">
        <view class="att-glyph">
          <image v-if="row.thumb" class="att-shot" :src="row.thumb" mode="aspectFill" />
          <view v-else class="att-lines">
            <view class="att-ln"></view>
            <view class="att-ln att-ln-short"></view>
          </view>
          <view class="att-fold"></view>
        </view>
        <text class="att-badge" :style="{ backgroundColor: row.badgeColor }">{{ row.badgeLabel }}</text>
      </view>
      <view class="att-body">
        <text class="att-name">{{ row.name }}</text>
        <text class="att-sub">{{ row.sub }}</text>
      </view>
      <text class="att-x" v-if="row.removable" @click.stop="onRemove(row)">×</text>
      <view class="att-prog" v-if="row.progressWidth">
        <view class="att-prog-in" :style="{ width: row.progressWidth }"></view>
      </view>
      <text class="att-overlay" v-if="row.overlay">{{ row.overlay }}</text>
    </view>
  </view>
</template>

<script>
/**
 * 任务/备忘卡上的附件条：一条 = 一个文件，版式对齐桌面端 AttachmentStrip。
 *
 * 左侧纸片 + 类型角标一眼看出是什么文件，本机图片直接画缩略图；右侧名称一行、
 * 大小与状态一行。点条目：本机有原件 → 打开；原件在别的机器 → 发起按需中转，
 * 进度写在条目顶部。长按：看完整文件名、大小、原件在哪台机器（手机没有 Tooltip）。
 * 卡片本身有「点开进编辑页」的手势，这里所有点击都要 .stop，否则一点附件就跳页。
 */
import * as store from '../utils/attachment_store'
import * as attachmentSync from '../utils/attachment_sync'
import { badgeOf, formatSize, isImageExt, kindLabel } from '../utils/attachment_types'
import { chipDetail, chipOf, progressWidth } from '../utils/attachment_view'
import { showToast } from '../utils/util'

export default {
  name: 'AttachmentStrip',
  props: {
    parentKind: { type: String, default: 'task' },
    parentLocalId: { type: [Number, String], default: null },
    // 新建流程里还没落库的选中文件：[{ path, name, size }]
    pending: { type: Array, default: null }
  },
  data() {
    return { rows: [] }
  },
  watch: {
    parentLocalId() {
      this.refresh()
    },
    pending() {
      this.refresh()
    }
  },
  mounted() {
    this.refresh()
    // 两个来源都要重画：中转进度（attachment_sync 内存态）与记录本身（store 写入）
    this._unsubs = [
      attachmentSync.subscribe(() => this.refresh()),
      store.subscribeChanges(() => this.refresh())
    ]
  },
  beforeUnmount() {
    ;(this._unsubs || []).forEach((off) => off())
    this._unsubs = []
  },
  methods: {
    refresh() {
      const rows = []
      const id = this.parentLocalId === null || this.parentLocalId === '' ? null : Number(this.parentLocalId)
      if (id) {
        store.forParent(this.parentKind, id).forEach((rec) => {
          const local = store.hasLocalCopy(rec)
          const chip = chipOf(rec, attachmentSync.jobOf(rec.uid), local, local ? store.pathOf(rec) : '')
          rows.push({ kind: 'record', key: 'a-' + rec.uid, progressWidth: progressWidth(chip), ...chip })
        })
      }
      ;(this.pending || []).forEach((item, i) => {
        const name = item.name || '附件'
        const badge = badgeOf(name)
        rows.push({
          kind: 'pending',
          key: 'p-' + i,
          index: i,
          uid: '',
          name,
          sizeText: item.size ? formatSize(item.size) : '未知大小',
          badgeLabel: badge.label,
          badgeColor: badge.color,
          // 刚选完的文件还在微信给的临时路径上，图片可以直接当缩略图用
          thumb: item.path && isImageExt(name) ? item.path : '',
          sub: (item.size ? formatSize(item.size) + ' · ' : '') + kindLabel(name),
          progressWidth: '',
          state: '',
          tone: 'pending',
          overlay: '',
          dashed: false,
          fraction: null,
          local: false,
          busy: false,
          removable: true,
          message: ''
        })
      })
      this.rows = rows
    },
    onTap(row) {
      if (row.kind === 'pending') return
      const rec = store.byUid(row.uid)
      if (!rec) {
        showToast('附件已不存在，下拉刷新一下')
        return
      }
      if (row.busy) {
        showToast(row.message || '正在中转，稍等一下')
        return
      }
      // 本机是旧版时先取新版：打开旧文件只会让用户以为云端内容丢了
      if (row.local && !row.stale) {
        const msg = store.open(rec)
        if (msg) showToast(msg)
        return
      }
      attachmentSync.pull(rec)
    },
    onInfo(row) {
      if (row.kind === 'pending') {
        showToast(row.name + '：保存任务后自动存到本机')
        return
      }
      const rec = store.byUid(row.uid)
      if (!rec) return
      uni.showModal({
        title: row.name,
        content: chipDetail(row, rec),
        showCancel: false,
        confirmText: '知道了'
      })
    },
    onRemove(row) {
      if (row.kind === 'pending') {
        this.$emit('remove-pending', row.index)
        return
      }
      const rec = store.byUid(row.uid)
      if (!rec) return
      uni.showModal({
        title: '删除附件',
        content: row.local
          ? `删除附件「${row.name}」？本机原件会一并删除，其它设备同步后也会移除。`
          : `移除附件「${row.name}」？其它设备同步后就看不到它了。`,
        confirmColor: '#EF4444',
        success: (res) => {
          if (!res.confirm) return
          attachmentSync.deleteAttachment(rec)
          this.refresh()
          this.$emit('changed')
        }
      })
    }
  }
}
</script>

<style lang="scss" scoped>
/* 条目高 84rpx = 桌面端 42px，纸片 52×64rpx = 26×32px */
.att-strip {
  display: flex;
  flex-wrap: wrap;
  gap: 16rpx;
  margin-top: 16rpx;
}
.att-item {
  position: relative;
  display: flex;
  align-items: center;
  box-sizing: border-box;
  /* 一行两条、每条一模一样宽：名字短的也拉长到整格，卡片右侧不留参差的尾巴 */
  flex: none;
  width: calc((100% - 16rpx) / 2);
  min-width: 0;
  height: 84rpx;
  padding: 0 12rpx;
  border-radius: 18rpx;
  border: 2rpx solid var(--chip-border);
  background: var(--chip-bg);
}
.att-icon {
  position: relative;
  flex-shrink: 0;
  width: 52rpx;
  height: 64rpx;
  margin-right: 18rpx;
}
/* 纸片：外层是描边色，内层缩 2rpx 是纸面，clip-path 切出右上角的折角 */
.att-glyph {
  position: absolute;
  left: 0;
  top: 0;
  right: 0;
  bottom: 0;
  padding: 2rpx;
  background: var(--att-paper-edge);
  clip-path: polygon(0 0, 38rpx 0, 52rpx 14rpx, 52rpx 100%, 0 100%);
}
.att-glyph::after {
  content: '';
  position: absolute;
  left: 2rpx;
  top: 2rpx;
  right: 2rpx;
  bottom: 2rpx;
  background: var(--att-paper);
  clip-path: polygon(0 0, 36rpx 0, 48rpx 12rpx, 48rpx 100%, 0 100%);
}
.att-lines,
.att-shot {
  position: absolute;
  left: 2rpx;
  top: 2rpx;
  right: 2rpx;
  bottom: 2rpx;
  z-index: 1;
}
.att-shot {
  width: 48rpx;
  height: 60rpx;
  border-radius: 0;
}
.att-lines {
  padding: 22rpx 6rpx 0;
  box-sizing: border-box;
}
.att-ln {
  height: 3rpx;
  width: 100%;
  border-radius: 2rpx;
  background: var(--att-fold);
}
.att-ln-short {
  width: 70%;
  margin-top: 5rpx;
}
/* 折角：切掉的那块纸翻过来，压在斜边上 */
.att-fold {
  position: absolute;
  right: 0;
  top: 0;
  z-index: 2;
  width: 14rpx;
  height: 14rpx;
  background: var(--att-fold);
  clip-path: polygon(0 0, 100% 100%, 0 100%);
}
.att-badge {
  position: absolute;
  left: -4rpx;
  bottom: -2rpx;
  z-index: 3;
  min-width: 26rpx;
  padding: 0 4rpx;
  height: 18rpx;
  line-height: 18rpx;
  border-radius: 4rpx;
  font-size: 14rpx;
  font-weight: 700;
  color: #ffffff;
  text-align: center;
}
.att-body {
  display: flex;
  flex-direction: column;
  min-width: 0;
  flex: 1;
}
.att-name {
  font-size: 22rpx;
  line-height: 1.35;
  font-weight: 600;
  color: var(--text-primary);
  overflow: hidden;
  white-space: nowrap;
  text-overflow: ellipsis;
}
.att-sub {
  font-size: 20rpx;
  line-height: 1.3;
  color: var(--text-tertiary);
  overflow: hidden;
  white-space: nowrap;
  text-overflow: ellipsis;
}
.att-x {
  flex-shrink: 0;
  margin-left: 8rpx;
  padding: 0 4rpx;
  font-size: 28rpx;
  line-height: 1.2;
  color: var(--text-tertiary);
}
/* 顶部进度带：中转进行中，× 已经收起，这里只留一条进度 */
.att-prog {
  position: absolute;
  left: 16rpx;
  right: 16rpx;
  top: 4rpx;
  height: 6rpx;
  border-radius: 4rpx;
  background: var(--track-bg);
  overflow: hidden;
}
.att-prog-in {
  height: 100%;
  border-radius: 4rpx;
  background: var(--accent);
}
/* 右上角圆形角标：☁ 远端、⏳ 等待、! 失败 */
.att-overlay {
  position: absolute;
  right: -10rpx;
  top: -10rpx;
  z-index: 4;
  width: 36rpx;
  height: 36rpx;
  line-height: 32rpx;
  border-radius: 50%;
  border: 2rpx solid var(--chip-border);
  background: var(--att-overlay-bg);
  font-size: 18rpx;
  text-align: center;
  color: var(--text-tertiary);
}
/* 状态色：远端可同步/旧版待取=强调色，进行中=强调，等待=中性，失败=危险 */
.att-item.tone-remote,
.att-item.tone-stale,
.att-item.tone-busy {
  border-color: var(--accent);
}
.att-item.tone-remote .att-sub,
.att-item.tone-stale .att-sub,
.att-item.tone-busy .att-sub,
.att-item.tone-remote .att-overlay,
.att-item.tone-stale .att-overlay,
.att-item.tone-busy .att-overlay {
  color: var(--accent);
}
.att-item.tone-remote .att-overlay,
.att-item.tone-stale .att-overlay,
.att-item.tone-busy .att-overlay {
  border-color: var(--accent);
}
.att-item.tone-waiting .att-sub {
  color: var(--text-tertiary);
}
.att-item.tone-failed {
  border-color: var(--danger);
}
.att-item.tone-failed .att-sub,
.att-item.tone-failed .att-overlay {
  color: var(--danger);
}
.att-item.tone-failed .att-overlay {
  border-color: var(--danger);
}
.att-item.tone-pending .att-sub {
  color: var(--text-tertiary);
}
</style>
