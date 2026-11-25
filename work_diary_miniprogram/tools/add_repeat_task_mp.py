# -*- coding: utf-8 -*-
"""小程序 task-edit.vue 加任务类别 + 保存逻辑"""
import io

p = r"E:\Code\WorkDiary\work_diary_miniprogram\src\pages\task-edit\task-edit.vue"
with io.open(p, "r", encoding="utf-8") as f:
    c = f.read()

# ========== 1. import ==========
old = """import { autoConvertNumberedToCheckbox, autoConvertLive } from '../../utils/subtask'"""
new = """import { autoConvertNumberedToCheckbox, autoConvertLive } from '../../utils/subtask'
import {
  initialInstanceDate,
  dateKey,
  genGroupId
} from '../../utils/repeat'"""
assert c.count(old) == 1
c = c.replace(old, new, 1)
print("import ok")

# ========== 2. 模板：任务类型后插入任务类别 ==========
old = """      <view class="field">
        <time-field
          label="计划开始时间（可选）\""""
new = """      <view class="field">
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
          label="计划开始时间（可选）\""""
assert c.count(old) == 1
c = c.replace(old, new, 1)
print("template ok")

# ========== 3. data 加字段 ==========
old = """      taskType: 1,
      // 时间值：ISO 字符串（UTC）或空；由 time-field 原生选择器维护
      startIso: '',
      dueIso: '',"""
new = """      taskType: 1,
      repeatType: 0, // 0正常 1日任务 2周任务 3月任务
      repeatWeekDays: [1],
      repeatMonthDay: 1,
      // 编辑循环任务时保留的族信息（新建时为 null）
      editRepeatGroupId: null,
      editInstanceDate: null,
      // 时间值：ISO 字符串（UTC）或空；由 time-field 原生选择器维护
      startIso: '',
      dueIso: '',"""
assert c.count(old) == 1
c = c.replace(old, new, 1)
print("data ok")

# ========== 4. repeatTypes / weekDaysArr / monthDays 常量 ==========
old = """      types: [
        { value: 0, text: '个人' },
        { value: 1, text: '工作' }
      ]"""
new = """      types: [
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
      monthDays: Array.from({ length: 31 }, (_, i) => `${i + 1} 号`)"""
assert c.count(old) == 1
c = c.replace(old, new, 1)
print("consts ok")

# ========== 5. onLoad 编辑加载循环字段 ==========
old = """        this.title = task.title
        this.urgency = task.urgency
        this.taskType = task.task_type
        this.startIso = task.plan_start_at || ''
        this.dueIso = task.due_at || ''
      }"""
new = """        this.title = task.title
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
      }"""
assert c.count(old) == 1
c = c.replace(old, new, 1)
print("onLoad ok")

# ========== 6. methods：类别交互 + 保存逻辑 ==========
old = """    // 时间选择完成：先后校验（对齐桌面端 _pickTime：冲突弹窗拒绝，不应用）"""
new = """    // 任务类别切换：选日/周/月且未设置时间时，自动填入默认时间
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
    // 时间选择完成：先后校验（对齐桌面端 _pickTime：冲突弹窗拒绝，不应用）"""
assert c.count(old) == 1
c = c.replace(old, new, 1)
print("methods ok")

# ========== 7. save 逻辑 ==========
old = """      const tasks = loadTasksCache()
      const now = new Date().toISOString()
      if (this.isEdit) {
        const idx = tasks.findIndex((t) => (t.remote_id || t.id) == this.editId)
        if (idx >= 0) {
          tasks[idx] = {
            ...tasks[idx],
            title: title,
            urgency: this.urgency,
            task_type: this.taskType,
            plan_start_at: this.startIso || null,
            due_at: this.dueIso || null,
            updated_at: now
          }
        }
      } else {
        tasks.unshift({
          id: genLocalId(),
          remote_id: null,
          title: title,
          status: 0,
          urgency: this.urgency,
          task_type: this.taskType,
          plan_start_at: this.startIso || null,
          due_at: this.dueIso || null,
          sort_order: 0,
          created_at: now,
          updated_at: now
        })
      }"""
new = """      const tasks = loadTasksCache()
      const now = new Date().toISOString()
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
      if (this.isEdit) {
        const idx = tasks.findIndex((t) => (t.remote_id || t.id) == this.editId)
        if (idx >= 0) {
          tasks[idx] = {
            ...tasks[idx],
            title: title,
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
        }
      } else {
        tasks.unshift({
          id: genLocalId(),
          remote_id: null,
          title: title,
          status: 0,
          urgency: this.urgency,
          task_type: this.taskType,
          plan_start_at: startIso || null,
          due_at: dueIso || null,
          sort_order: 0,
          repeat_type: repeatType,
          repeat_week_days: repeatWeekDaysStr,
          repeat_month_day: repeatMonthDay,
          repeat_group_id: groupId,
          instance_date: instanceDate,
          created_at: now,
          updated_at: now
        })
      }"""
assert c.count(old) == 1
c = c.replace(old, new, 1)
print("save ok")

# ========== 8. 样式 ==========
old = """.dot {
  width: 20rpx;
  height: 20rpx;
  border-radius: 50%;
}"""
new = """.dot {
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
  color: #9ca3af;
  margin-bottom: 12rpx;
}
.repeat-hint {
  margin-top: 14rpx;
  font-size: 24rpx;
  color: #9ca3af;
}
.picker-val {
  display: inline-block;
  padding: 10rpx 24rpx;
  border-radius: 999rpx;
  background: #f9fafb;
  border: 2rpx solid #e5e7eb;
  font-size: 26rpx;
  color: #4b5563;
}"""
assert c.count(old) == 1
c = c.replace(old, new, 1)
print("style ok")

with io.open(p, "w", encoding="utf-8", newline="\n") as f:
    f.write(c)
print("task-edit saved")
