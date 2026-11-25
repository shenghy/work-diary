<template>
  <view class="page" :class="themeClass">
    <aurora-bg />
    <scroll-view class="scroll" scroll-y>
      <view class="hint-row">
        <text class="hint">管理所有循环任务族：改规则、停止、恢复或永久删除。</text>
      </view>

      <view class="state" v-if="!families.length">
        <text>还没有循环任务</text>
        <text class="state-sub">新建任务时选择「每日 / 每周 / 每月」即可生成循环。</text>
      </view>

      <view class="family glass" v-for="f in families" :key="f.groupId">
        <view class="f-head">
          <text class="f-title">{{ f.title || '(未命名循环)' }}</text>
          <view class="f-chip" :class="{ stopped: f.stopped }">{{ f.stopped ? '已停止' : '进行中' }}</view>
        </view>

        <view class="f-meta">
          <text class="f-rule">{{ ruleText(f) }}</text>
          <text class="f-dot">·</text>
          <text class="f-count">共 {{ f.total }} 期</text>
          <text class="f-dot" v-if="f.unfinished">·</text>
          <text class="f-count" v-if="f.unfinished">未完成 {{ f.unfinished }}</text>
        </view>

        <view class="f-next" v-if="!f.stopped && f.next">
          下一次 {{ nextText(f) }}
        </view>
        <view class="f-next muted" v-else-if="f.stopped && f.latest">
          最后一期 {{ shortDateWithWeekdayStr(f.latest) }}
        </view>

        <view class="f-actions">
          <view class="f-btn" @click="editRule(f)">编辑规则</view>
          <view class="f-btn" v-if="!f.stopped" @click="stopFamily(f)">停止循环</view>
          <view class="f-btn accent" v-else @click="resumeFamily(f)">恢复循环</view>
          <view class="f-btn danger" @click="deleteFamily(f)">永久删除</view>
        </view>
      </view>
    </scroll-view>
  </view>
</template>

<script>
import AuroraBg from '../../components/aurora-bg.vue'
import {
  loadTasksCache,
  loadTasksDeletions,
  saveTasksDeletions,
  loadRepeatRules,
  loadRepeatSkips,
  putRepeatRule,
  stopRepeatGroup,
  resumeRepeatGroup,
  markRepeatGroupDeleted
} from '../../utils/storage'
import { buildRepeatFamilies, repeatRuleLabel, shortDateWithWeekday } from '../../utils/repeat'
import { syncTasks } from '../../utils/sync'
import { showToast, showLoading, hideLoading } from '../../utils/util'
import * as attachmentSync from '../../utils/attachment_sync'

export default {
  components: { AuroraBg },
  data() {
    return {
      families: []
    }
  },
  onShow() {
    this.reload()
  },
  methods: {
    reload() {
      this.families = buildRepeatFamilies(
        loadTasksCache(),
        loadRepeatRules(),
        new Date(),
        loadRepeatSkips()
      )
    },
    ruleText(f) {
      return repeatRuleLabel(f.repeatType, f.weekDays, f.monthDay)
    },
    nextText(f) {
      return shortDateWithWeekday(f.next)
    },
    shortDateWithWeekdayStr(d) {
      return shortDateWithWeekday(d)
    },
    findInstance(groupId) {
      const list = loadTasksCache().filter((t) => t.repeat_group_id === groupId)
      if (!list.length) return null
      return list.reduce((latest, t) => {
        const key = String(t.instance_date || '').slice(0, 10)
        const bestKey = latest ? String(latest.instance_date || '').slice(0, 10) : ''
        return key > bestKey ? t : latest
      }, null)
    },
    // 老数据可能只有实例没有规则：补一条规则，停止/删除状态才能同步到其它端
    ensureRule(f) {
      const rules = loadRepeatRules()
      if (rules[f.groupId]) return rules[f.groupId]
      const template = this.findInstance(f.groupId) || {}
      putRepeatRule({
        repeat_group_id: f.groupId,
        title: f.title || template.title || '',
        urgency: template.urgency || 0,
        task_type: template.task_type !== undefined ? template.task_type : 1,
        repeat_type: f.repeatType,
        repeat_week_days: f.weekDays || null,
        repeat_month_day: f.monthDay || null,
        plan_start_at: f.planStartAt || template.plan_start_at || null,
        due_at: template.due_at || null
      })
      return loadRepeatRules()[f.groupId]
    },
    editRule(f) {
      const task = this.findInstance(f.groupId)
      if (!task) {
        showToast('该循环暂无实例，无法编辑规则')
        return
      }
      uni.navigateTo({ url: '/pkgEdit/task-edit/task-edit?id=' + encodeURIComponent(task.remote_id || task.id) })
    },
    stopFamily(f) {
      uni.showModal({
        title: '停止循环',
        content: '停止后不再生成新期次，已有期次会保留，可随时恢复。',
        confirmText: '停止',
        success: (res) => {
          if (!res.confirm) return
          this.ensureRule(f)
          stopRepeatGroup(f.groupId)
          this.pushSync('已停止循环')
        }
      })
    },
    resumeFamily(f) {
      this.ensureRule(f)
      resumeRepeatGroup(f.groupId)
      this.pushSync('已恢复循环')
    },
    deleteFamily(f) {
      uni.showModal({
        title: '永久删除循环',
        content: '将删除该循环及其全部期次（含已完成），且其它设备同步后也会删除，无法恢复。',
        confirmText: '永久删除',
        confirmColor: '#EF4444',
        success: (res) => {
          if (!res.confirm) return
          const rule = this.ensureRule(f)
          const removed = markRepeatGroupDeleted(f.groupId, rule)
          const deletions = loadTasksDeletions()
          const now = new Date().toISOString()
          removed.forEach((t) => {
            deletions.push({
              local_id: t.id,
              remote_id: t.remote_id,
              deleted_at: now
            })
            // 期次没了，附件标孤儿：原件留在本机，但不再上报，
            // 否则云端按"父记录不存在"拒收，用户会反复看到假的"附件未同步"
            attachmentSync.onParentDeleted('task', t.id)
          })
          saveTasksDeletions(deletions)
          this.pushSync('已永久删除')
        }
      })
    },
    async pushSync(doneText) {
      showLoading('处理中')
      try {
        await syncTasks(loadTasksCache(), loadTasksDeletions())
        hideLoading()
        showToast(doneText, 'success')
      } catch (e) {
        hideLoading()
        showToast('已保存到本地，同步失败：' + e.message)
      }
      this.reload()
    }
  }
}
</script>

<style lang="scss" scoped>
.page {
  min-height: 100vh;
  background: transparent;
  color: var(--text-primary);
}
.scroll {
  height: 100vh;
  padding: 24rpx;
  box-sizing: border-box;
}
.hint-row {
  margin-bottom: 20rpx;
}
.hint {
  font-size: 23rpx;
  line-height: 1.6;
  color: var(--text-tertiary);
}
.state {
  padding: 160rpx 40rpx;
  display: flex;
  flex-direction: column;
  align-items: center;
  gap: 12rpx;
  color: var(--text-secondary);
  font-size: 28rpx;
}
.state-sub {
  font-size: 23rpx;
  color: var(--text-tertiary);
  text-align: center;
  line-height: 1.6;
}
.family {
  background: var(--card-bg);
  border: 1rpx solid var(--card-border);
  border-radius: 32rpx;
  padding: 26rpx 24rpx;
  margin-bottom: 20rpx;
  box-shadow: var(--shadow-card);
}
.f-head {
  display: flex;
  align-items: flex-start;
  justify-content: space-between;
  gap: 16rpx;
}
.f-title {
  flex: 1;
  min-width: 0;
  font-size: 30rpx;
  font-weight: 600;
  line-height: 1.4;
  color: var(--text-primary);
  word-break: break-all;
}
.f-chip {
  flex-shrink: 0;
  padding: 4rpx 14rpx;
  border-radius: 999rpx;
  font-size: 21rpx;
  color: var(--status-executing);
  background: var(--status-executing-bg);
}
.f-chip.stopped {
  color: var(--text-tertiary);
  background: var(--chip-bg);
}
.f-meta {
  display: flex;
  align-items: center;
  flex-wrap: wrap;
  gap: 8rpx;
  margin-top: 12rpx;
  font-size: 23rpx;
  color: var(--text-tertiary);
}
.f-rule {
  color: var(--accent);
}
.f-dot {
  color: var(--text-tertiary);
}
.f-next {
  margin-top: 12rpx;
  font-size: 23rpx;
  color: var(--text-secondary);
}
.f-next.muted {
  color: var(--text-tertiary);
}
.f-actions {
  display: flex;
  gap: 14rpx;
  margin-top: 22rpx;
}
.f-btn {
  flex: 1;
  height: 64rpx;
  line-height: 64rpx;
  text-align: center;
  border-radius: 14rpx;
  font-size: 24rpx;
  color: var(--text-secondary);
  background: var(--chip-bg);
  border: 1rpx solid var(--chip-border);
}
.f-btn.accent {
  color: #ffffff;
  background: var(--accent);
  border-color: var(--accent);
}
.f-btn.danger {
  color: var(--danger);
  border-color: var(--danger-border);
  background: var(--danger-bg);
}
</style>
