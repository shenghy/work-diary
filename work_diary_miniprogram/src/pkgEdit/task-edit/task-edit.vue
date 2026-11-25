<template>
  <view class="page" :class="themeClass">
    <aurora-bg />
    <view class="card glass">
      <view class="field">
        <view class="label">任务标题（可多行，子任务自动识别）</view>
        <textarea
          :value="title"
          :cursor="textareaCursor"
          class="input title-input"
          placeholder="要做什么？
提示：输入 1. xxx 或 - xxx 会自动生成勾选子任务"
          placeholder-class="ph"
          :maxlength="2000"
          :adjust-position="true"
          :cursor-spacing="60"
          @input="onTitleInput"
          @blur="onTitleBlur"
        />
      </view>

      <view class="field">
        <view class="label">任务状态</view>
        <view class="options">
          <view
            v-for="s in statuses"
            :key="s.value"
            class="option"
            :class="{ active: status === s.value }"
            @click="status = s.value"
          >
            <view class="dot" :style="{ background: s.color }"></view>
            <text>{{ s.text }}</text>
          </view>
        </view>
      </view>

      <view class="field">
        <view class="label">紧急程度</view>
        <view class="options">
          <view
            v-for="u in urgencies"
            :key="u.value"
            class="option"
            :class="{ active: urgency === u.value }"
            @click="urgency = u.value"
          >
            <view class="dot" :style="{ background: u.color }"></view>
            <text>{{ u.text }}</text>
          </view>
        </view>
      </view>

      <view class="field">
        <view class="label">任务类型</view>
        <view class="options">
          <view
            v-for="t in types"
            :key="t.value"
            class="option"
            :class="{ active: taskType === t.value }"
            @click="taskType = t.value"
          >
            <text>{{ t.text }}</text>
          </view>
        </view>
      </view>

      <view class="field">
        <view class="label">任务类别</view>
        <view class="options">
          <view
            v-for="r in repeatTypes"
            :key="r.value"
            class="option"
            :class="{ active: repeatType === r.value }"
            @click="onRepeatType(r.value)"
          >
            <text>{{ r.text }}</text>
          </view>
        </view>

        <view v-if="repeatType === 2" class="repeat-extra">
          <view class="sub-label">每周重复（可多选）</view>
          <view class="options">
            <view
              v-for="wd in weekDaysArr"
              :key="wd.value"
              class="option small"
              :class="{ active: repeatWeekDays.includes(wd.value) }"
              @click="toggleWeekDay(wd.value)"
            >
              <text>{{ wd.text }}</text>
            </view>
          </view>
        </view>

        <view v-if="repeatType === 3" class="repeat-extra">
          <view class="sub-label">每月</view>
          <picker mode="selector" :range="monthDays" @change="onMonthDay">
            <view class="picker-val">{{ repeatMonthDay }} 号</view>
          </picker>
        </view>

        <view v-if="repeatType === 1" class="repeat-hint">每天自动生成新的一期，时间可自定义</view>
      </view>

      <view class="field">
        <time-field
          label="计划开始时间（可选）"
          :value="startIso"
          :max="dueIso"
          @change="onStartTime"
          @clear="startIso = ''"
        />
      </view>

      <view class="field">
        <time-field
          label="截止时间（可选）"
          :value="dueIso"
          :min="startIso"
          @change="onDueTime"
          @clear="dueIso = ''"
        />
      </view>

      <!-- 附件：原件存本机，其它设备点一下走服务器中转取 -->
      <view class="field">
        <view class="label">附件（{{ attachCount }}/{{ ATTACH_MAX }}，仅图片和文档）</view>
        <attachment-strip
          parent-kind="task"
          :parent-local-id="taskLocalId"
          :pending="pendingFiles"
          @remove-pending="removePending"
        />
        <view class="attach-add" :class="{ disabled: attachRemain <= 0 }" @click="chooseAttachment">
          <text class="attach-add-icon">＋</text>
          <text class="attach-add-text">{{ attachRemain > 0 ? '从微信聊天选择文件' : '附件已满' }}</text>
        </view>
        <view class="attach-hint">原件保存在本机，不占云端空间；在其它设备或手机上点这条附件即可从这里同步过去。</view>
      </view>
    </view>

    <view class="btn primary" @click="save">{{ isEdit ? '保存修改' : '创建任务' }}</view>
    <view class="btn danger" v-if="isEdit" @click="del">删除任务</view>
  </view>
</template>

<script>
import AuroraBg from '../../components/aurora-bg.vue'
import TimeField from '../../components/time-field.vue'
import AttachmentStrip from '../../components/attachment-strip.vue'
import {
  loadTasksCache,
  saveTasksCache,
  loadTasksDeletions,
  saveTasksDeletions,
  loadRepeatRules,
  putRepeatRule,
  skipRepeatInstance,
  stopRepeatGroup
} from '../../utils/storage'
import { syncTasks, syncAttachments, genLocalId } from '../../utils/sync'
import * as attachmentStore from '../../utils/attachment_store'
import * as attachmentSync from '../../utils/attachment_sync'
import { MAX_PER_PARENT } from '../../utils/attachment_types'
import { autoConvertNumberedToCheckbox, autoConvertLive } from '../../utils/subtask'
import {
  initialInstanceDate,
  dateKey,
  genGroupId,
  sameSchedule,
  applySchedule
} from '../../utils/repeat'
import { nextSortOrder } from '../../utils/drag-sort'
import {
  showToast,
  showLoading,
  hideLoading,
  URGENCY_TEXT,
  URGENCY_COLOR,
  STATUS_TEXT,
  STATUS_COLOR
} from '../../utils/util'

export default {
  components: { AuroraBg, TimeField, AttachmentStrip },
  data() {
    return {
      isEdit: false,
      editId: null,
      title: '',
      // 附件：taskLocalId 是本机任务 id（新建时保存后才有），pendingFiles 是尚未落库的选中文件
      ATTACH_MAX: MAX_PER_PARENT,
      taskLocalId: null,
      taskRemoteId: null,
      pendingFiles: [],
      attachRev: 0,
      saving: false,
      textareaCursor: -1,
      status: 0,
      urgency: 0,
      taskType: 1,
      repeatType: 0, // 0正常 1日任务 2周任务 3月任务
      repeatWeekDays: [1],
      repeatMonthDay: 1,
      // 编辑循环任务时保留的族信息（新建时为 null）
      editRepeatGroupId: null,
      editInstanceDate: null,
      // 时间值：ISO 字符串（UTC）或空；由 time-field 原生选择器维护
      startIso: '',
      dueIso: '',
      urgencies: [
        { value: 0, text: URGENCY_TEXT[0], color: URGENCY_COLOR[0] },
        { value: 1, text: URGENCY_TEXT[1], color: URGENCY_COLOR[1] },
        { value: 2, text: URGENCY_TEXT[2], color: URGENCY_COLOR[2] }
      ],
      statuses: [
        { value: 0, text: STATUS_TEXT[0], color: STATUS_COLOR[0] },
        { value: 1, text: STATUS_TEXT[1], color: STATUS_COLOR[1] },
        { value: 2, text: STATUS_TEXT[2], color: STATUS_COLOR[2] }
      ],
      types: [
        { value: 0, text: '个人' },
        { value: 1, text: '工作' }
      ],
      repeatTypes: [
        { value: 0, text: '正常' },
        { value: 1, text: '日任务' },
        { value: 2, text: '周任务' },
        { value: 3, text: '月任务' }
      ],
      weekDaysArr: [
        { value: 1, text: '周一' },
        { value: 2, text: '周二' },
        { value: 3, text: '周三' },
        { value: 4, text: '周四' },
        { value: 5, text: '周五' },
        { value: 6, text: '周六' },
        { value: 7, text: '周日' }
      ],
      monthDays: Array.from({ length: 31 }, (_, i) => `${i + 1} 号`)
    }
  },
  onLoad(options) {
    if (options && options.id) {
      this.isEdit = true
      this.editId = options.id
      const task = loadTasksCache().find((t) => (t.remote_id || t.id) == options.id)
      if (task) {
        this.taskLocalId = task.id
        this.taskRemoteId = task.remote_id || null
        this.title = task.title
        this.status = task.status || 0
        this.urgency = task.urgency
        this.taskType = task.task_type
        this.repeatType = task.repeat_type || 0
        if (task.repeat_week_days) {
          this.repeatWeekDays = String(task.repeat_week_days)
            .split(',')
            .map(Number)
        }
        this.repeatMonthDay = task.repeat_month_day || 1
        this.editRepeatGroupId = task.repeat_group_id || null
        this.editInstanceDate = task.instance_date || null
        this.startIso = task.plan_start_at || ''
        this.dueIso = task.due_at || ''
      }
    }
  },
  computed: {
    // 附件记录存在 storage、不是响应式数据，attachRev 是显式的重算触发器
    attachCount() {
      void this.attachRev
      const stored = this.taskLocalId
        ? attachmentStore.countForParent('task', Number(this.taskLocalId))
        : 0
      return stored + this.pendingFiles.length
    },
    attachRemain() {
      return Math.max(0, this.ATTACH_MAX - this.attachCount)
    }
  },
  methods: {
    // ---- 附件 ----
    attachMeta(parentLocalId) {
      return {
        parentKind: 'task',
        parentLocalId: Number(parentLocalId),
        parentRemoteId: this.taskRemoteId || null
      }
    },
    async chooseAttachment() {
      if (this.attachRemain <= 0) {
        showToast(`一个任务最多挂 ${this.ATTACH_MAX} 个附件，请先删除不需要的`)
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
      if (this.isEdit && this.taskLocalId) {
        const res = await attachmentStore.attachPicked(files, this.attachMeta(this.taskLocalId))
        this.attachRev++
        if (res.errors.length) showToast(res.errors[0])
        return
      }
      // 新建：任务还没有 id，先记路径，保存任务后一起收进本机
      this.pendingFiles = this.pendingFiles.concat(
        files.map((f) => ({ path: f.path, name: f.name, size: Number(f.size) || 0 }))
      )
    },
    removePending(index) {
      this.pendingFiles = this.pendingFiles.filter((item, i) => i !== index)
    },
    // 输入实时转义（对齐桌面端 _autoConvertNumbered）：
    // 输入「1.」立即转「[ ] 1.」，输入「- 」立即转「[ ] 」；
    // 光标按「光标前文本单独转换后的长度」重算，多行时每行增量各自计入，不会跳位
    onTitleInput(e) {
      const value = e.detail.value
      const cursor = e.detail.cursor != null ? e.detail.cursor : value.length
      const converted = autoConvertLive(value)
      if (converted === value) {
        this.title = value
        this.textareaCursor = -1
        return
      }
      const nb = autoConvertLive(value.substring(0, cursor)).length
      this.title = converted
      this.textareaCursor = nb
    },
    // 失焦时兜底转义：1. xxx → [ ] 1. xxx，- xxx → [ ] xxx（桌面端输入逻辑）
    onTitleBlur() {
      const converted = autoConvertNumberedToCheckbox(this.title)
      if (converted !== this.title) {
        this.title = converted
      }
    },
    // 任务类别切换：选日/周/月且未设置时间时，自动填入默认时间
    onRepeatType(rt) {
      this.repeatType = rt
      if (rt > 0 && !this.startIso && !this.dueIso) {
        const now = new Date()
        this.startIso = new Date(
          now.getFullYear(),
          now.getMonth(),
          now.getDate(),
          9,
          0,
          0
        ).toISOString()
        this.dueIso =
          rt === 1
            ? new Date(
                now.getFullYear(),
                now.getMonth(),
                now.getDate(),
                23,
                59,
                0
              ).toISOString()
            : new Date(
                now.getFullYear(),
                now.getMonth(),
                now.getDate(),
                18,
                0,
                0
              ).toISOString()
      }
    },
    toggleWeekDay(wd) {
      const arr = [...this.repeatWeekDays]
      if (arr.includes(wd)) {
        if (arr.length > 1) {
          this.repeatWeekDays = arr.filter((x) => x !== wd)
        }
      } else {
        this.repeatWeekDays = [...arr, wd].sort((a, b) => a - b)
      }
    },
    onMonthDay(e) {
      const idx = parseInt(e.detail.value, 10)
      this.repeatMonthDay = isNaN(idx) ? 1 : idx + 1
    },
    // 时间选择完成：先后校验（对齐桌面端 _pickTime：冲突弹窗拒绝，不应用）
    onStartTime(iso) {
      if (this.dueIso && new Date(iso).getTime() >= new Date(this.dueIso).getTime()) {
        this.showTimeConflict('计划开始时间不能晚于截止时间，请重新选择。')
        return
      }
      this.startIso = iso
    },
    onDueTime(iso) {
      if (this.startIso && new Date(iso).getTime() <= new Date(this.startIso).getTime()) {
        this.showTimeConflict('截止时间不能早于计划开始时间，请重新选择。')
        return
      }
      this.dueIso = iso
    },
    showTimeConflict(content) {
      uni.showModal({
        title: '时间冲突',
        content: content,
        showCancel: false,
        confirmText: '确定',
        confirmColor: '#3B82F6'
      })
    },
    async save() {
      // 导入附件要等文件系统，期间禁掉重复提交
      if (this.saving) return
      // 保存前同样转义一次，保证格式统一
      const title = autoConvertNumberedToCheckbox(this.title.trim())
      if (!title) {
        showToast('请输入任务标题')
        return
      }
      // 保存兜底：开始时间必须早于截止时间（双保险，正常流程弹层已拦截）
      if (this.startIso && this.dueIso && new Date(this.startIso).getTime() >= new Date(this.dueIso).getTime()) {
        showToast('开始时间需早于截止时间')
        return
      }
      const tasks = loadTasksCache()
      const now = new Date().toISOString()
      const oldTask = this.isEdit
        ? tasks.find((t) => (t.remote_id || t.id) == this.editId)
        : null
      // 状态时间字段与桌面端一致：计划中清空、执行中补开始、已完成补完成
      let startedAt = oldTask ? oldTask.started_at || null : null
      let completedAt = oldTask ? oldTask.completed_at || null : null
      if (this.status === 0) {
        startedAt = null
        completedAt = null
      } else if (this.status === 1) {
        if (!startedAt) startedAt = now
        if (oldTask && oldTask.status === 2) completedAt = null
      } else if (this.status === 2) {
        if (!completedAt) completedAt = now
      }
      // 循环任务规则：升级/修改/降级
      const repeatType = this.repeatType
      let groupId = this.isEdit && repeatType > 0 ? this.editRepeatGroupId : null
      let instanceDate =
        this.isEdit && repeatType > 0 ? this.editInstanceDate : null
      let startIso = this.startIso
      let dueIso = this.dueIso
      let repeatWeekDaysStr = null
      let repeatMonthDay = null
      if (repeatType > 0) {
        repeatWeekDaysStr = repeatType === 2 ? this.repeatWeekDays.join(',') : null
        repeatMonthDay = repeatType === 3 ? this.repeatMonthDay : null
        if (!groupId) {
          // 新建循环任务 / 普通任务升级为循环：本期作为第一期
          groupId = genGroupId()
          const inst = initialInstanceDate(
            repeatType,
            this.repeatWeekDays,
            this.repeatMonthDay,
            new Date()
          )
          instanceDate = dateKey(inst)
          const relocate = (iso) => {
            if (!iso) return null
            const t = new Date(iso)
            return new Date(
              inst.getFullYear(),
              inst.getMonth(),
              inst.getDate(),
              t.getHours(),
              t.getMinutes(),
              t.getSeconds()
            ).toISOString()
          }
          startIso = relocate(this.startIso)
          dueIso = relocate(this.dueIso)
        }
      }
      if (this.isEdit && oldTask) {
        const idx = tasks.findIndex((t) => (t.remote_id || t.id) == this.editId)
        tasks[idx] = {
          ...tasks[idx],
          title: title,
          status: this.status,
          started_at: startedAt,
          completed_at: completedAt,
          urgency: this.urgency,
          task_type: this.taskType,
          plan_start_at: startIso || null,
          due_at: dueIso || null,
          repeat_type: repeatType,
          repeat_week_days: repeatWeekDaysStr,
          repeat_month_day: repeatMonthDay,
          repeat_group_id: groupId,
          instance_date: instanceDate,
          updated_at: now
        }
        this.taskLocalId = tasks[idx].id
        this.taskRemoteId = tasks[idx].remote_id || null
      } else {
        const newTask = {
          id: genLocalId(),
          remote_id: null,
          title: title,
          status: this.status,
          started_at: startedAt,
          completed_at: completedAt,
          urgency: this.urgency,
          task_type: this.taskType,
          plan_start_at: startIso || null,
          due_at: dueIso || null,
          // 新建排到自己的状态组最前面（与桌面端同一规则，跨端不来回跳）
          sort_order: nextSortOrder(tasks, this.status),
          repeat_type: repeatType,
          repeat_week_days: repeatWeekDaysStr,
          repeat_month_day: repeatMonthDay,
          repeat_group_id: groupId,
          instance_date: instanceDate,
          created_at: now,
          updated_at: now
        }
        tasks.unshift(newTask)
        this.taskLocalId = newTask.id
        this.taskRemoteId = null
      }
      // 规则变更后把新配置同步到同族"未完成"的其它实例，避免徽章一半日一半周
      if (repeatType > 0 && groupId) {
        tasks.forEach((t, i) => {
          if (i === 0 && !this.isEdit) return
          if (t.repeat_group_id !== groupId) return
          if ((t.remote_id || t.id) == this.editId) return
          if (t.status === 2) return
          if (sameSchedule(t, repeatType, this.repeatWeekDays, this.repeatMonthDay)) return
          tasks[i] = applySchedule(t, repeatType, this.repeatWeekDays, this.repeatMonthDay, new Date())
        })
      }
      saveTasksCache(tasks)
      // 同步循环规则库（删除实例不影响循环；改回"正常"才彻底取消）
      if (repeatType > 0 && groupId) {
        putRepeatRule({
          repeat_group_id: groupId,
          title: title,
          urgency: this.urgency,
          task_type: this.taskType,
          repeat_type: repeatType,
          repeat_week_days: repeatWeekDaysStr,
          repeat_month_day: repeatMonthDay,
          plan_start_at: startIso || null,
          due_at: dueIso || null
        })
      } else if (this.isEdit && this.editRepeatGroupId && repeatType === 0) {
        // 循环任务改回正常任务 = 停止循环（规则保留，可在循环任务页恢复）
        stopRepeatGroup(this.editRepeatGroupId)
      }
      // 新建时选的附件到这一步才落库：任务 id 已确定，落完随本轮同步把元数据报上去
      const attachErrors = await this.importPending()
      this.pushSync(attachErrors.length ? '，附件未保存：' + attachErrors[0] : '')
    },
    async importPending() {
      if (!this.pendingFiles.length || !this.taskLocalId) return []
      const picked = this.pendingFiles
      this.pendingFiles = []
      const res = await attachmentStore.attachPicked(picked, this.attachMeta(this.taskLocalId))
      this.attachRev++
      return res.errors
    },
    del() {
      const tasks = loadTasksCache()
      const idx = tasks.findIndex((t) => (t.remote_id || t.id) == this.editId)
      const target = idx >= 0 ? tasks[idx] : null
      const doDelete = (stopRepeat) => {
        if (idx < 0) {
          uni.navigateBack()
          return
        }
        const deletions = loadTasksDeletions()
        deletions.push({
          local_id: target.id,
          remote_id: target.remote_id,
          deleted_at: new Date().toISOString()
        })
        if (target.repeat_type > 0 && target.repeat_group_id) {
          if (stopRepeat) {
            // 停止循环：规则 stopped + STOP 哨兵；同族历史期次保留
            stopRepeatGroup(target.repeat_group_id)
          } else if (target.instance_date) {
            // 仅删除本期：写跳过账本，避免下次补生成复活
            skipRepeatInstance(target)
          }
        }
        tasks.splice(idx, 1)
        saveTasksCache(tasks)
        saveTasksDeletions(deletions)
        // 附件跟着任务走：记录标孤儿、不再上报，原件留着；截图任务的图片当场删掉
        attachmentSync.onParentDeleted('task', target.id)
        this.pushSync()
      }
      if (target && target.repeat_type > 0) {
        uni.showActionSheet({
          itemList: ['仅删除本期', '停止循环并删除'],
          success: (res) => {
            if (res.tapIndex === 0) doDelete(false)
            else if (res.tapIndex === 1) doDelete(true)
          }
        })
        return
      }
      uni.showModal({
        title: '删除任务',
        content: '确定删除该任务吗？删除后不可恢复。',
        confirmColor: '#EF4444',
        success: (res) => {
          if (res.confirm) doDelete(false)
        }
      })
    },
    async pushSync(extraMsg, doneText) {
      if (this.saving) return
      this.saving = true
      const tasks = loadTasksCache()
      const deletions = loadTasksDeletions()
      showLoading('保存中')
      try {
        await syncTasks(tasks, deletions)
        // 附件元数据必须排在任务同步之后：服务器按父记录是否已入库决定收不收，
        // 新建任务这一轮刚拿到 remote_id，早报只会得到一个 rejected。
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
  padding: 32rpx 28rpx;
  border: 1rpx solid var(--card-border);
  margin-bottom: 24rpx;
  box-shadow: var(--shadow-card);
}
.field {
  margin-bottom: 32rpx;
}
.field:last-child {
  margin-bottom: 0;
}
.label {
  font-size: 26rpx;
  color: var(--text-secondary);
  margin-bottom: 14rpx;
}
.title-input {
  min-height: 140rpx;
}
.input {
  width: 100%;
  background: var(--field-bg);
  border: 2rpx solid var(--field-border);
  border-radius: 12rpx;
  padding: 20rpx 24rpx;
  font-size: 28rpx;
  box-sizing: border-box;
  color: var(--text-primary);
}
.ph {
  color: var(--text-tertiary);
}
.options {
  display: flex;
  gap: 16rpx;
  flex-wrap: wrap;
}
.option {
  display: flex;
  align-items: center;
  gap: 10rpx;
  padding: 14rpx 24rpx;
  border-radius: 999rpx;
  background: var(--chip-bg);
  border: 2rpx solid var(--chip-border);
  font-size: 26rpx;
  color: var(--text-secondary);
}
.option.active {
  background: var(--accent-soft);
  border-color: var(--accent);
  color: var(--accent);
  font-weight: 600;
}
.dot {
  width: 20rpx;
  height: 20rpx;
  border-radius: 50%;
}
.option.small {
  padding: 10rpx 18rpx;
  font-size: 24rpx;
}
.repeat-extra {
  margin-top: 20rpx;
}
.sub-label {
  font-size: 24rpx;
  color: var(--text-tertiary);
  margin-bottom: 12rpx;
}
.repeat-hint {
  margin-top: 14rpx;
  font-size: 24rpx;
  color: var(--text-tertiary);
}
.picker-val {
  display: inline-block;
  padding: 10rpx 24rpx;
  border-radius: 999rpx;
  background: var(--chip-bg);
  border: 2rpx solid var(--chip-border);
  font-size: 26rpx;
  color: var(--text-secondary);
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
.attach-hint {
  margin-top: 12rpx;
  font-size: 22rpx;
  line-height: 1.6;
  color: var(--text-tertiary);
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
