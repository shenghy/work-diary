<template>
  <view class="page" :class="themeClass">
    <view class="head">
      <text class="name">{{ name || '附件' }}</text>
      <text class="meta">{{ metaText }}</text>
    </view>
    <scroll-view class="body" scroll-y>
      <!-- 文本内容整段交给 <text>：保留换行与空格，不解析 Markdown（原件是什么就显示什么） -->
      <text class="content" v-if="text">{{ text }}</text>
      <view class="notice" v-else-if="notice">{{ notice }}</view>
      <view class="empty" v-else-if="error">
        <text class="empty-text">{{ error }}</text>
        <view class="btn" v-if="canPull" @click="pull">从其它主机同步</view>
      </view>
      <view class="empty" v-else>
        <text class="empty-text">正在读取…</text>
      </view>
    </scroll-view>
  </view>
</template>

<script>
/**
 * 文本附件查看页：txt / md / csv 这类手机 openDocument 不认的格式在这里读出来。
 *
 * 只读原件，不读云端：本页只在"本机有原件"时由 attachment_store.open 跳进来，
 * 原件不在（比如从别的设备同步失败）就给出"去同步"的出口，而不是空白页。
 */
import * as store from '../../utils/attachment_store'
import * as attachmentSync from '../../utils/attachment_sync'
import { formatSize } from '../../utils/attachment_types'
import { showToast } from '../../utils/util'

// 一次最多读这么多：手机内存紧张，且终端用户看的是内容不是全量转储
const MAX_VIEW_BYTES = 512 * 1024

export default {
  data() {
    return {
      uid: '',
      name: '',
      record: null,
      text: '',
      notice: '',
      error: ''
    }
  },
  computed: {
    metaText() {
      if (!this.record) return ''
      const size = formatSize(this.record.file_size)
      const shown = this.record.file_size > MAX_VIEW_BYTES ? size + '（仅显示前 512KB）' : size
      return this.local ? '本机原件 · ' + shown : '原件在' + (this.record.owner_device_name || '其它主机') + ' · ' + shown
    },
    local() {
      return !!this.record && store.hasLocalCopy(this.record)
    },
    canPull() {
      return !!this.record && !this.local
    }
  },
  onLoad(options) {
    this.uid = decodeURIComponent((options && options.uid) || '')
    this.load()
    // 从本页发起的同步完成后自动重读，不用用户再点一次
    this._unsubscribe = attachmentSync.subscribe(() => this.onJobChange())
  },
  onUnload() {
    if (this._unsubscribe) this._unsubscribe()
    this._unsubscribe = null
  },
  methods: {
    onJobChange() {
      const job = attachmentSync.jobOf(this.uid)
      if (job && job.phase === attachmentSync.PHASE.failed) {
        this.error = job.message || '同步失败'
        this.text = ''
        return
      }
      if (!job && this.record && store.hasLocalCopy(this.record) && !this.text) this.load()
    },
    load() {
      const record = store.byUid(this.uid)
      if (!record) {
        this.error = '附件记录已不存在，请返回后下拉刷新'
        return
      }
      this.record = record
      this.name = record.file_name
      uni.setNavigationBarTitle({ title: record.file_name })
      if (!store.hasLocalCopy(record)) {
        this.error = '本机还没有这个文件的原件'
        this.text = ''
        return
      }
      this.error = ''
      store
        .readText(record, MAX_VIEW_BYTES)
        .then((text) => {
          this.text = text
          this.notice = text ? '' : '文件是空的'
        })
        .catch((e) => {
          this.text = ''
          this.error = '读取失败：' + ((e && e.message) || '未知原因')
        })
    },
    pull() {
      if (!this.record) {
        showToast('附件记录已不存在')
        return
      }
      attachmentSync.pull(this.record)
    }
  }
}
</script>

<style lang="scss" scoped>
.page {
  height: 100vh;
  display: flex;
  flex-direction: column;
  background: var(--card-bg);
  box-sizing: border-box;
}
.head {
  flex-shrink: 0;
  padding: 20rpx 24rpx 16rpx;
  border-bottom: 1rpx solid var(--card-border);
}
.name {
  display: block;
  font-size: 28rpx;
  font-weight: 600;
  color: var(--text-primary);
  word-break: break-all;
}
.meta {
  display: block;
  margin-top: 6rpx;
  font-size: 22rpx;
  color: var(--text-tertiary);
}
.body {
  flex: 1;
  min-height: 0;
  padding: 20rpx 24rpx 40rpx;
  box-sizing: border-box;
}
.content {
  display: block;
  font-family: Menlo, Consolas, 'Courier New', monospace;
  font-size: 26rpx;
  line-height: 1.7;
  color: var(--text-secondary);
  white-space: pre-wrap;
  word-break: break-all;
}
.notice {
  font-size: 26rpx;
  color: var(--text-tertiary);
}
.empty {
  display: flex;
  flex-direction: column;
  align-items: center;
  padding-top: 120rpx;
}
.empty-text {
  font-size: 26rpx;
  color: var(--text-tertiary);
}
.btn {
  margin-top: 28rpx;
  padding: 14rpx 40rpx;
  border-radius: 999rpx;
  background: var(--accent-soft);
  border: 2rpx solid var(--accent);
  color: var(--accent);
  font-size: 26rpx;
}
</style>
