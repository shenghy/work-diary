<template>
  <view class="page" :class="themeClass">
    <aurora-bg />
    <view class="card glass">
      <view class="mode-row">
        <view class="mode" :class="{ on: tab === 0 }" @click="tab = 0">编辑</view>
        <view class="mode" :class="{ on: tab === 1 }" @click="tab = 1">预览</view>
      </view>
      <view class="field">
        <textarea
          v-if="tab === 0"
          v-model="content"
          class="input content-input"
          placeholder="输入备忘内容…"
          placeholder-class="ph"
          :maxlength="3000"
          :adjust-position="true"
          :cursor-spacing="60"
          auto-height
        />
        <view class="preview" v-else>
          <mp-html v-if="content.trim()" :content="previewHtml" />
          <text v-else class="preview-empty">输入内容后，点击「预览」查看渲染效果</text>
        </view>
        <view class="counter">{{ content.length }}/3000</view>
        <view class="tip">支持 Markdown：# 标题、**加粗**、- 列表、`代码`、[链接](url)，保存后自动排版</view>
      </view>
    </view>

    <!-- 附件：原件存本机，其它设备点一下走服务器中转取 -->
    <view class="card">
      <view class="label">附件（{{ attachCount }}/{{ ATTACH_MAX }}，仅图片和文档）</view>
      <attachment-strip
        parent-kind="memo"
        :parent-local-id="memoLocalId"
        :pending="pendingFiles"
        @remove-pending="removePending"
      />
      <view class="attach-add" :class="{ disabled: attachRemain <= 0 }" @click="chooseAttachment">
        <text class="attach-add-icon">＋</text>
        <text>{{ attachRemain > 0 ? '从微信聊天选择文件' : '附件已满' }}</text>
      </view>
      <view class="tip">原件保存在本机，不占云端空间；在其它设备或手机上点这条附件即可从这里同步过去。</view>
    </view>

    <view class="btn primary" @click="save">{{ isEdit ? '保存修改' : '保存备忘' }}</view>
    <view class="btn danger" v-if="isEdit" @click="del">删除备忘</view>
  </view>
</template>

<script>
import AuroraBg from '../../components/aurora-bg.vue'
import AttachmentStrip from '../../components/attachment-strip.vue'
import {
  loadMemosCache,
  saveMemosCache,
  loadMemosDeletions,
  saveMemosDeletions
} from '../../utils/storage'
import { syncMemos, syncAttachments, genLocalId } from '../../utils/sync'
import * as attachmentStore from '../../utils/attachment_store'
import * as attachmentSync from '../../utils/attachment_sync'
import { MAX_PER_PARENT } from '../../utils/attachment_types'
import { showToast, showLoading, hideLoading } from '../../utils/util'
import { renderMarkdown } from '../../utils/markdown'
import mpHtml from 'mp-html/dist/uni-app/components/mp-html/mp-html'

export default {
  components: { AuroraBg, AttachmentStrip, mpHtml },
  data() {
    return {
      isEdit: false,
      editId: null,
      content: '',
      tab: 0,
      // 附件：memoLocalId 在本机备忘 id（新建时保存后才有）
      ATTACH_MAX: MAX_PER_PARENT,
      memoLocalId: null,
      memoRemoteId: null,
      pendingFiles: [],
      attachRev: 0,
      saving: false
    }
  },
  computed: {
    previewHtml() {
      return renderMarkdown(this.content)
    },
    // 附件记录存在 storage、不是响应式数据，attachRev 是显式的重算触发器
    attachCount() {
      void this.attachRev
      const stored = this.memoLocalId
        ? attachmentStore.countForParent('memo', Number(this.memoLocalId))
        : 0
      return stored + this.pendingFiles.length
    },
    attachRemain() {
      return Math.max(0, this.ATTACH_MAX - this.attachCount)
    }
  },
  onLoad(options) {
    if (options && options.id) {
      this.isEdit = true
      this.editId = options.id
      const memo = loadMemosCache().find((m) => (m.remote_id || m.id) == options.id)
      if (memo) {
        this.memoLocalId = memo.id
        this.memoRemoteId = memo.remote_id || null
        this.content = memo.content
      }
    }
  },
  methods: {
    // ---- 附件 ----
    attachMeta(parentLocalId) {
      return {
        parentKind: 'memo',
        parentLocalId: Number(parentLocalId),
        parentRemoteId: this.memoRemoteId || null
      }
    },
    async chooseAttachment() {
      if (this.attachRemain <= 0) {
        showToast(`一条备忘最多挂 ${this.ATTACH_MAX} 个附件，请先删除不需要的`)
        return
      }
      let files
      try {
        files = await attachmentStore.chooseFromChat(this.attachRemain)
      } catch (e) {
        // 用户点了取消不算失败，别弹错误提示
        if (!e || !e.cancelled) showToast((e && e.message) || '选择文件失败')
        return
      }
      if (!files.length) return
      if (this.isEdit && this.memoLocalId) {
        const res = await attachmentStore.attachPicked(files, this.attachMeta(this.memoLocalId))
        this.attachRev++
        if (res.errors.length) showToast(res.errors[0])
        return
      }
      // 新建：备忘还没有 id，先记路径，保存时一起收进本机
      this.pendingFiles = this.pendingFiles.concat(
        files.map((f) => ({ path: f.path, name: f.name, size: Number(f.size) || 0 }))
      )
    },
    removePending(index) {
      this.pendingFiles = this.pendingFiles.filter((item, i) => i !== index)
    },
    async importPending() {
      if (!this.pendingFiles.length || !this.memoLocalId) return []
      const picked = this.pendingFiles
      this.pendingFiles = []
      const res = await attachmentStore.attachPicked(picked, this.attachMeta(this.memoLocalId))
      this.attachRev++
      return res.errors
    },
    async save() {
      if (this.saving) return
      const content = this.content.trim()
      if (!content) {
        showToast('请输入备忘内容')
        return
      }
      const memos = loadMemosCache()
      const now = new Date().toISOString()
      if (this.isEdit) {
        const idx = memos.findIndex((m) => (m.remote_id || m.id) == this.editId)
        if (idx >= 0) {
          memos[idx] = {
            ...memos[idx],
            content: content,
            updated_at: now
          }
          this.memoLocalId = memos[idx].id
          this.memoRemoteId = memos[idx].remote_id || null
        }
      } else {
        const newMemo = {
          id: genLocalId(),
          remote_id: null,
          content: content,
          created_at: now,
          updated_at: now
        }
        memos.unshift(newMemo)
        this.memoLocalId = newMemo.id
        this.memoRemoteId = null
      }
      saveMemosCache(memos)
      const attachErrors = await this.importPending()
      this.pushSync(attachErrors.length ? '，附件未保存：' + attachErrors[0] : '')
    },
    del() {
      uni.showModal({
        title: '删除备忘',
        content: '确定删除该备忘吗？删除后不可恢复。',
        confirmColor: '#EF4444',
        success: (res) => {
          if (!res.confirm) return
          const memos = loadMemosCache()
          const idx = memos.findIndex((m) => (m.remote_id || m.id) == this.editId)
          if (idx < 0) {
            uni.navigateBack()
            return
          }
          const target = memos[idx]
          const deletions = loadMemosDeletions()
          deletions.push({
            local_id: target.id,
            remote_id: target.remote_id,
            deleted_at: new Date().toISOString()
          })
          memos.splice(idx, 1)
          saveMemosCache(memos)
          saveMemosDeletions(deletions)
          // 附件跟着备忘走：记录标孤儿、不再上报，原件留着
          attachmentSync.onParentDeleted('memo', target.id)
          this.pushSync('', '已删除')
        }
      })
    },
    async pushSync(extraMsg, doneText) {
      if (this.saving) return
      this.saving = true
      const memos = loadMemosCache()
      const deletions = loadMemosDeletions()
      showLoading('保存中')
      try {
        await syncMemos(memos, deletions)
        // 附件元数据必须排在备忘同步之后：服务器按父记录是否已入库决定收不收
        const summary = await syncAttachments()
        hideLoading()
        const rejected = (summary && summary.rejectedNames) || []
        const tail = (extraMsg || '') + (rejected.length ? '，附件未同步：' + rejected[0] : '')
        const base = doneText || (this.isEdit ? '已保存' : '已创建')
        showToast(base + tail, tail ? 'none' : 'success')
        setTimeout(() => uni.navigateBack(), tail ? 2600 : 400)
      } catch (e) {
        hideLoading()
        showToast('已保存到本地，同步失败：' + e.message)
        setTimeout(() => uni.navigateBack(), 800)
      } finally {
        this.saving = false
      }
    }
  }
}
</script>

<style lang="scss" scoped>
.page {
  min-height: 100vh;
  background: transparent;
  padding: 24rpx;
  box-sizing: border-box;
}
.card {
  background: var(--card-bg);
  border-radius: 32rpx;
  padding: 28rpx;
  border: 1rpx solid var(--card-border);
  margin-bottom: 24rpx;
  box-shadow: var(--shadow-card);
}
.mode-row {
  display: flex;
  gap: 12rpx;
  margin-bottom: 20rpx;
}
.mode {
  flex: 1;
  height: 64rpx;
  line-height: 64rpx;
  text-align: center;
  border-radius: 12rpx;
  font-size: 26rpx;
  color: var(--text-secondary);
  background: var(--chip-bg);
  border: 1rpx solid var(--chip-border);
}
.mode.on {
  color: var(--accent);
  border-color: var(--accent);
  background: var(--accent-soft);
  font-weight: 600;
}
.field {
  margin-bottom: 0;
}
.label {
  font-size: 26rpx;
  color: var(--text-secondary);
  margin-bottom: 14rpx;
}
.content-input {
  /* 初始高度加一倍（原 200rpx），内容变多时 auto-height 继续自动撑高 */
  min-height: 400rpx;
}
.input {
  width: 100%;
  background: var(--field-bg);
  border: 2rpx solid var(--field-border);
  border-radius: 12rpx;
  padding: 20rpx 24rpx;
  font-size: 28rpx;
  box-sizing: border-box;
  line-height: 1.6;
  color: var(--text-primary);
}
.ph {
  color: var(--text-tertiary);
}
.preview {
  min-height: 400rpx;
  padding: 20rpx 24rpx;
  border-radius: 12rpx;
  background: var(--field-bg);
  border: 2rpx solid var(--field-border);
  box-sizing: border-box;
}
.preview-empty {
  font-size: 26rpx;
  color: var(--text-tertiary);
}
.counter {
  margin-top: 8rpx;
  text-align: right;
  font-size: 21rpx;
  color: var(--text-tertiary);
}
.tip {
  font-size: 22rpx;
  color: var(--text-tertiary);
  margin-top: 4rpx;
  line-height: 1.6;
}
.attach-add {
  display: flex;
  align-items: center;
  justify-content: center;
  gap: 8rpx;
  margin-top: 14rpx;
  height: 76rpx;
  border-radius: 12rpx;
  border: 2rpx dashed var(--field-border);
  background: var(--field-bg);
  font-size: 26rpx;
  color: var(--text-secondary);
}
.attach-add:active {
  border-color: var(--accent);
  color: var(--accent);
}
.attach-add.disabled {
  opacity: 0.55;
}
.attach-add-icon {
  font-size: 30rpx;
  line-height: 1;
}
.btn {
  height: 92rpx;
  line-height: 92rpx;
  text-align: center;
  border-radius: 14rpx;
  font-size: 30rpx;
  font-weight: 600;
  margin-bottom: 20rpx;
}
.btn.primary {
  background: var(--accent);
  color: #ffffff;
}
.btn.danger {
  background: var(--danger-bg);
  color: var(--danger);
  border: 2rpx solid var(--danger-border);
}
</style>
