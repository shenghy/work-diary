<template>
  <view class="task-card" @click="onCardTap">
    <!-- 左侧色条：紧急度只在这里和标签上体现，卡片描边保持中性玻璃 -->
    <view class="left-bar" :class="uClass"></view>

    <view class="card-body">
      <!-- 主标题：循环徽章与标题同排（蓝框蓝字徽章效果） -->
      <view class="title-row" v-if="subResult.mainTitle">
        <view class="repeat-badge" v-if="repeatText">↻ {{ repeatText }}</view>
        <view class="instance-chip" v-if="instanceText">{{ instanceText }}</view>
        <text class="title" :class="{ done: task.status === 2 }">
          {{ displayTitle }}
        </text>
      </view>
      <text
        v-if="isLongTitle"
        class="fold-toggle"
        @click.stop="titleExpanded = !titleExpanded"
      >{{ titleExpanded ? '收起' : '展开全文' }}</text>

      <!-- 副标题：状态 · 创建 · 开始 · 完成 -->
      <text class="subtitle">{{ subText }}</text>

      <!-- 子任务进度条 -->
      <view class="progress-wrap" v-if="subResult.items.length > 0">
        <view class="progress-track">
          <view
            class="progress-fill"
            :class="uClass"
            :style="{ width: progressPct + '%' }"
          ></view>
        </view>
      </view>

      <!-- 子任务列表 -->
      <view class="sub-list" v-if="subResult.items.length > 0">
        <view
          v-for="(item, i) in subResult.items"
          :key="i"
          class="sub-row"
          @click.stop="toggleSub(i)"
        >
          <view class="checkbox" :class="{ checked: item.done }">
            <text class="check-mark" v-if="item.done">✓</text>
          </view>
          <!-- 子任务恒为单行：放不下省略号收尾并循环滚动（对齐桌面端 MarqueeText） -->
          <view class="sub-text-clip">
            <view
              class="sub-text-run"
              :class="{ marquee: isMarquee(i) }"
              :style="marqueeStyle(i)"
            >
              <text class="sub-text sub-text-m1" :class="{ done: item.done }">{{ subLabel(item) }}<text
                v-if="isMarquee(i)"
              >…</text></text>
              <text
                class="sub-text"
                :class="{ done: item.done }"
                v-if="isMarquee(i)"
              >{{ subLabel(item) }}<text>…</text></text>
            </view>
          </view>
        </view>
      </view>

      <!-- 附件条：本机可打开 / 在其它主机可一键同步 / 中转进度 -->
      <attachment-strip
        parent-kind="task"
        :parent-local-id="task.id"
        @changed="$emit('attachment-change')"
      />

      <!-- 底部标签 + 操作按钮 -->
      <view class="footer">
        <view class="tags">
          <view class="tag" :class="uClass">{{ urgencyText }}</view>
          <view class="tag" :class="tClass">{{ typeText }}</view>
          <view class="tag plan-tag" v-if="planText">
            <view class="tag-ico ico-calendar"></view>
            <text>{{ planText }}</text>
          </view>
          <view class="tag due-tag" v-if="dueText">
            <view class="tag-ico ico-clock"></view>
            <text>{{ dueText }}</text>
          </view>
        </view>
        <view class="actions">
          <!-- 执行中才能退回计划中：与桌面端「回到计划中」同一个状态流转 -->
          <view v-if="task.status === 1" class="action" @click.stop="onBackToPlanned">
            <view class="act-ico ico-undo"></view>
            <text class="act-label">回到计划</text>
          </view>
          <view class="action go" @click.stop="onStatusAction">
            <view class="act-ico" :class="statusIconClass"></view>
            <text class="act-label">{{ statusActionText }}</text>
          </view>
          <view class="action" @click.stop="onEdit">
            <view class="act-ico ico-edit"></view>
            <text class="act-label">修改</text>
          </view>
          <view class="action danger" @click.stop="onDelete">
            <view class="act-ico ico-delete"></view>
            <text class="act-label">删除</text>
          </view>
        </view>
      </view>
      <!-- 过期图章：右上角半圆形，红色印章 + 白色文字，不断闪烁 -->
      <view class="expired-stamp" v-if="isExpired">已过期</view>
    </view>
  </view>
</template>

<script>
import {
  STATUS_TEXT,
  STATUS_COLOR,
  URGENCY_TEXT,
  TASK_TYPE_TEXT,
  formatDateTime,
  formatDateLabel
} from '../utils/util'
import { parseSubTasks, setSubTaskDone, subTaskProgress } from '../utils/subtask'
import { repeatRuleLabel } from '../utils/repeat'
import AttachmentStrip from './attachment-strip.vue'

export default {
  name: 'TaskCard',
  components: { AttachmentStrip },
  props: {
    task: {
      type: Object,
      required: true
    }
  },
  data() {
    return {
      titleExpanded: false,
      // 每行子任务的滚动状态：[{ on, dur }]，由渲染后实测宽度得出
      subMarquee: []
    }
  },
  watch: {
    'task.title'() {
      this.measureSubMarquee()
    }
  },
  mounted() {
    this.measureSubMarquee()
  },
  beforeUnmount() {
    this._destroyed = true
  },
  computed: {
    subResult() {
      return parseSubTasks(this.task.title)
    },
    isLongTitle() {
      return (this.subResult.mainTitle || '').length > 180
    },
    displayTitle() {
      const t = this.subResult.mainTitle || ''
      if (this.titleExpanded || t.length <= 180) return t
      return t.slice(0, 180) + '…'
    },
    instanceText() {
      const d = this.task.instance_date
      if (!d || !this.task.repeat_group_id) return ''
      const date = new Date(String(d).slice(0, 10) + 'T00:00:00')
      if (isNaN(date)) return ''
      return '本期 ' + (date.getMonth() + 1) + '/' + date.getDate()
    },
    urgencyText() {
      return URGENCY_TEXT[this.task.urgency] || '一般'
    },
    typeText() {
      return TASK_TYPE_TEXT[this.task.task_type] || '工作'
    },
    // 紧急度与类型都走主题 token：色条/进度/标签同一档色，深色主题下不再有浅色底白块
    uClass() {
      const u = Number(this.task.urgency)
      return u === 1 ? 'u-urgent' : u === 2 ? 'u-important' : 'u-normal'
    },
    tClass() {
      return this.task.task_type === 0 ? 't-personal' : 't-work'
    },
    subText() {
      const parts = []
      parts.push(STATUS_TEXT[this.task.status] || '计划中')
      parts.push('创建 ' + formatDateTime(this.task.created_at))
      if (this.task.started_at) parts.push('开始 ' + formatDateTime(this.task.started_at))
      if (this.task.completed_at) parts.push('完成 ' + formatDateTime(this.task.completed_at))
      return parts.join(' · ')
    },
    progressPct() {
      return Math.round(subTaskProgress(this.task.title) * 100)
    },
    planText() {
      return this.task.plan_start_at ? formatDateLabel(this.task.plan_start_at, '开始') : ''
    },
    dueText() {
      return this.task.due_at ? formatDateLabel(this.task.due_at, '完成') : ''
    },
    isExpired() {
      return (
        this.task.status !== 2 &&
        !!this.task.due_at &&
        new Date(this.task.due_at).getTime() < Date.now()
      )
    },
    // 循环徽章文案：日→每日；周→工作日/每周一、三、五；月→每月15日
    repeatText() {
      if (!this.task.repeat_type) return ''
      return repeatRuleLabel(
        this.task.repeat_type,
        this.task.repeat_week_days,
        this.task.repeat_month_day
      )
    },
    statusActionText() {
      if (this.task.status === 2) return '重开'
      return this.task.status === 0 ? '开始' : '完成'
    },
    statusIconClass() {
      if (this.task.status === 2) return 'ico-replay'
      return this.task.status === 0 ? 'ico-play' : 'ico-check'
    }
  },
  methods: {
    subLabel(item) {
      return item.prefix ? item.prefix + ' ' + item.text : item.text
    },
    isMarquee(i) {
      const m = this.subMarquee[i]
      return !!(m && m.on)
    },
    marqueeStyle(i) {
      const m = this.subMarquee[i]
      return m && m.on ? 'animation-duration:' + m.dur + 'ms;' : ''
    },
    // 文本用 nowrap 撑出自然宽度，与裁剪容器相比即知是否溢出。
    // 桌面端 MarqueeText 只滚「溢出部分」，这里为了无缝循环要滚「整段副本宽」，
    // 位移更大，所以时长按实际位移算：40px/s + 两端各 20% 停顿。
    measureSubMarquee() {
      if (!this.subResult.items.length) {
        if (this.subMarquee.length) this.subMarquee = []
        return
      }
      this.$nextTick(() => {
        uni
          .createSelectorQuery()
          .in(this)
          .selectAll('.sub-text-clip')
          .boundingClientRect()
          .selectAll('.sub-text-m1')
          .boundingClientRect()
          .exec((res) => {
            const clips = res && res[0]
            const texts = res && res[1]
            if (this._destroyed || !clips || !texts || clips.length !== texts.length) return
            const next = texts.map((t, i) => {
              const overflow = t.width - clips[i].width
              const scrollMs = Math.min(18000, Math.max(1600, (t.width / 40) * 1000))
              return { on: overflow > 1, dur: Math.round(scrollMs / 0.6) }
            })
            const same =
              next.length === this.subMarquee.length &&
              next.every((n, i) => {
                const old = this.subMarquee[i]
                return old && old.on === n.on && old.dur === n.dur
              })
            if (!same) this.subMarquee = next
          })
      })
    },
    onCardTap() {
      // 点击卡片主体进入编辑
      this.onEdit()
    },
    onStatusAction() {
      this.$emit('status-action', this.task)
    },
    onBackToPlanned() {
      this.$emit('back-to-planned', this.task)
    },
    onEdit() {
      this.$emit('edit', this.task)
    },
    onDelete() {
      this.$emit('delete', this.task)
    },
    toggleSub(index) {
      const item = this.subResult.items[index]
      const newTitle = setSubTaskDone(this.task.title, index, !item.done)
      if (newTitle === this.task.title) return
      this.$emit('subtask-change', { ...this.task, title: newTitle, updated_at: new Date().toISOString() })
    }
  }
}
</script>

<style lang="scss" scoped>
/* 过期印章：右上角方章（红框红字、轻微倾斜），闪烁节奏与客户端一致（1.15s） */
.expired-stamp {
  position: absolute;
  top: 24rpx;
  right: 24rpx;
  padding: 6rpx 13rpx 6rpx 11rpx;
  border: 3rpx solid var(--danger);
  border-radius: 4rpx;
  color: var(--danger);
  font-size: 17rpx;
  font-weight: 800;
  letter-spacing: 3rpx;
  text-indent: 3rpx;
  background: var(--danger-bg);
  transform: rotate(-6deg);
  animation: blink-expired 1.15s ease-in-out infinite;
}
@keyframes blink-expired {
  0%, 100% { opacity: 1; }
  50% { opacity: 0.62; }
}
.task-card {
  position: relative;
  display: flex;
  background: var(--card-bg);
  border-radius: 32rpx;
  border: 1rpx solid var(--card-border);
  box-shadow: var(--shadow-card);
  margin-bottom: 18rpx;
  overflow: hidden;
}
/* 玻璃反光已并入 --card-bg 背景层，避免伪元素盖住内容 */
.left-bar {
  position: absolute;
  left: 12rpx;
  top: 22rpx;
  bottom: 22rpx;
  width: 6rpx;
  border-radius: 3rpx;
  z-index: 2;
}
/* 竖向渐变到同色 32%：对齐桌面端 rim 色条，紧急色不外扩到卡片描边 */
.left-bar.u-normal {
  background: linear-gradient(180deg, var(--urgency-normal), var(--urgency-normal-line));
}
.left-bar.u-urgent {
  background: linear-gradient(180deg, var(--urgency-urgent), var(--urgency-urgent-line));
}
.left-bar.u-important {
  background: linear-gradient(180deg, var(--urgency-important), var(--urgency-important-line));
}
.card-body {
  flex: 1;
  min-width: 0;
  padding: 22rpx 20rpx 18rpx 34rpx;
}
/* 标题行：循环徽章与标题同排 */
.title-row {
  display: flex;
  align-items: center;
}
.repeat-badge {
  flex-shrink: 0;
  margin-right: 8rpx;
  padding: 1rpx 8rpx;
  border: 2rpx solid var(--accent);
  border-radius: 6rpx;
  background: var(--accent-soft);
  color: var(--accent);
  font-size: 22rpx;
  font-weight: 500;
  line-height: 1.5;
}
.instance-chip {
  flex-shrink: 0;
  margin-right: 8rpx;
  padding: 1rpx 10rpx;
  border-radius: 6rpx;
  background: var(--chip-bg);
  color: var(--text-secondary);
  font-size: 22rpx;
  line-height: 1.5;
}
.fold-toggle {
  display: block;
  margin-top: 6rpx;
  font-size: 24rpx;
  color: var(--accent);
}
.title {
  flex: 1;
  min-width: 0;
  display: block;
  font-size: 30rpx;
  color: var(--text-primary);
  font-weight: 500;
  line-height: 1.5;
  word-break: break-all;
  white-space: pre-wrap;
}
.title.done {
  color: var(--text-tertiary);
  text-decoration: line-through;
}
.subtitle {
  display: block;
  font-size: 22rpx;
  color: var(--text-tertiary);
  margin-top: 6rpx;
}
.progress-wrap {
  margin-top: 12rpx;
}
.progress-track {
  height: 8rpx;
  border-radius: 4rpx;
  background: var(--track-bg);
  overflow: hidden;
}
.progress-fill {
  height: 100%;
  border-radius: 4rpx;
  transition: width 0.3s ease;
}
.progress-fill.u-normal {
  background: linear-gradient(90deg, var(--urgency-normal-line), var(--urgency-normal));
}
.progress-fill.u-urgent {
  background: linear-gradient(90deg, var(--urgency-urgent-line), var(--urgency-urgent));
}
.progress-fill.u-important {
  background: linear-gradient(90deg, var(--urgency-important-line), var(--urgency-important));
}
.sub-list {
  margin-top: 10rpx;
}
.sub-row {
  display: flex;
  align-items: flex-start;
  padding: 6rpx 0;
}
.checkbox {
  width: 30rpx;
  height: 30rpx;
  border-radius: 6rpx;
  border: 2rpx solid var(--text-tertiary);
  margin-right: 12rpx;
  margin-top: 2rpx;
  flex-shrink: 0;
  display: flex;
  align-items: center;
  justify-content: center;
  box-sizing: border-box;
}
.checkbox.checked {
  background: var(--status-completed);
  border-color: var(--status-completed);
}
.check-mark {
  color: #ffffff;
  font-size: 20rpx;
  line-height: 1;
}
.sub-text-clip {
  flex: 1;
  min-width: 0;
  display: flex;
  overflow: hidden;
}
/* 两段等宽文本拼成 2 倍长，滚到 -50% 时画面与起点完全一致，循环无缝 */
.sub-text-run {
  flex-shrink: 0;
  display: flex;
  animation-duration: 9000ms;
}
.sub-text-run.marquee {
  animation-name: sub-marquee;
  animation-timing-function: linear;
  animation-iteration-count: infinite;
}
/* 两端各停 20%：起点看清开头，终点看清结尾 */
@keyframes sub-marquee {
  0%,
  20% {
    transform: translate3d(0, 0, 0);
  }
  80%,
  100% {
    transform: translate3d(-50%, 0, 0);
  }
}
.sub-text {
  flex-shrink: 0;
  font-size: 28rpx;
  color: var(--text-secondary);
  line-height: 1.5;
  white-space: nowrap;
}
.sub-text.done {
  color: var(--text-tertiary);
  text-decoration: line-through;
}
.footer {
  margin-top: 16rpx;
}
.tags {
  display: flex;
  align-items: center;
  flex-wrap: wrap;
  gap: 6rpx;
}
.tag {
  display: flex;
  align-items: center;
  gap: 3rpx;
  font-size: 22rpx;
  font-weight: 500;
  border: 1rpx solid var(--chip-border);
  border-radius: 19rpx;
  /* 紧凑内边距：手机一行要放下四个标签，16rpx 会把标签挤到第二行 */
  padding: 4rpx 12rpx;
  line-height: 1.4;
  /* 质感来自光影不是描边：顶部受光压语义淡染底，外面再勾一层软投影 */
  background: linear-gradient(180deg, var(--tag-gloss), rgba(255, 255, 255, 0) 34%), var(--chip-bg);
  box-shadow: var(--tag-shadow);
  color: var(--text-secondary);
}
.tag.u-normal {
  color: var(--urgency-normal);
  background: linear-gradient(180deg, var(--tag-gloss), rgba(255, 255, 255, 0) 34%),
    var(--urgency-normal-bg);
  border-color: var(--urgency-normal-line);
}
.tag.u-urgent {
  color: var(--urgency-urgent);
  background: linear-gradient(180deg, var(--tag-gloss), rgba(255, 255, 255, 0) 34%),
    var(--urgency-urgent-bg);
  border-color: var(--urgency-urgent-line);
}
.tag.u-important {
  color: var(--urgency-important);
  background: linear-gradient(180deg, var(--tag-gloss), rgba(255, 255, 255, 0) 34%),
    var(--urgency-important-bg);
  border-color: var(--urgency-important-line);
}
.tag.t-personal {
  color: var(--type-personal);
  background: linear-gradient(180deg, var(--tag-gloss), rgba(255, 255, 255, 0) 34%),
    var(--type-personal-bg);
  border-color: var(--type-personal-line);
}
.tag.t-work {
  color: var(--type-work);
  background: linear-gradient(180deg, var(--tag-gloss), rgba(255, 255, 255, 0) 34%),
    var(--type-work-bg);
  border-color: var(--type-work-line);
}
.tag.plan-tag {
  color: var(--date-start);
  background: linear-gradient(180deg, var(--tag-gloss), rgba(255, 255, 255, 0) 34%),
    var(--date-start-bg);
  border-color: var(--date-start-line);
}
.tag.due-tag {
  color: var(--date-done);
  background: linear-gradient(180deg, var(--tag-gloss), rgba(255, 255, 255, 0) 34%),
    var(--date-done-bg);
  border-color: var(--date-done-line);
}
/* 带图标的左边收 2rpx：图标自带视觉留白，这一档留给 390pt 手机的一行余量 */
.tag.plan-tag,
.tag.due-tag {
  padding-left: 8rpx;
}
/* 小程序没有图标字体，日历/时钟用纯 CSS 画，尺寸对齐桌面端 10px */
.tag-ico {
  flex: none;
  position: relative;
}
.ico-calendar {
  width: 18rpx;
  height: 16rpx;
  border: 2rpx solid currentColor;
  border-radius: 4rpx;
}
.ico-calendar::before {
  content: '';
  position: absolute;
  left: -2rpx;
  right: -2rpx;
  top: 4rpx;
  height: 2rpx;
  background: currentColor;
}
.ico-calendar::after {
  content: '';
  position: absolute;
  top: 1rpx;
  left: 3rpx;
  width: 2rpx;
  height: 3rpx;
  background: currentColor;
  box-shadow: 7rpx 0 0 currentColor;
}
.ico-clock {
  width: 18rpx;
  height: 18rpx;
  border: 2rpx solid currentColor;
  border-radius: 50%;
}
.ico-clock::before {
  content: '';
  position: absolute;
  left: 7rpx;
  top: 3rpx;
  width: 2rpx;
  height: 6rpx;
  background: currentColor;
}
.ico-clock::after {
  content: '';
  position: absolute;
  left: 7rpx;
  top: 8rpx;
  width: 5rpx;
  height: 2rpx;
  background: currentColor;
}
.actions {
  display: flex;
  align-items: center;
  gap: 14rpx;
  margin-top: 16rpx;
}
/* 手机点按友好：整行等宽按钮，高 64rpx（32px），图标和文字都在热区里 */
.action {
  flex: 1;
  display: flex;
  align-items: center;
  justify-content: center;
  gap: 4rpx;
  height: 64rpx;
  border-radius: 20rpx;
  border: 1rpx solid var(--chip-border);
  font-size: 22.4rpx;
  font-weight: 500;
  color: var(--text-secondary);
  background: linear-gradient(180deg, var(--tag-gloss), rgba(255, 255, 255, 0) 40%), var(--chip-bg);
  box-shadow: var(--tag-shadow);
}
.act-label {
  white-space: nowrap;
}
/* 图标用 mask 取形状、背景色跟随按钮文字色，深浅主题自动一致 */
.act-ico {
  flex: none;
  width: 20.8rpx;
  height: 20.8rpx;
  background-color: currentColor;
  -webkit-mask-repeat: no-repeat;
  -webkit-mask-position: center;
  -webkit-mask-size: 100% 100%;
  mask-repeat: no-repeat;
  mask-position: center;
  mask-size: 100% 100%;
}
.ico-play {
  -webkit-mask: url("data:image/svg+xml;base64,PHN2ZyB4bWxucz0iaHR0cDovL3d3dy53My5vcmcvMjAwMC9zdmciIHZpZXdCb3g9IjAgMCAyNCAyNCI+PHBhdGggZD0iTTggNXYxNGwxMS03eiIvPjwvc3ZnPg==") no-repeat center / 100% 100%;
  mask: url("data:image/svg+xml;base64,PHN2ZyB4bWxucz0iaHR0cDovL3d3dy53My5vcmcvMjAwMC9zdmciIHZpZXdCb3g9IjAgMCAyNCAyNCI+PHBhdGggZD0iTTggNXYxNGwxMS03eiIvPjwvc3ZnPg==") no-repeat center / 100% 100%;
}
.ico-check {
  -webkit-mask: url("data:image/svg+xml;base64,PHN2ZyB4bWxucz0iaHR0cDovL3d3dy53My5vcmcvMjAwMC9zdmciIHZpZXdCb3g9IjAgMCAyNCAyNCI+PGNpcmNsZSBjeD0iMTIiIGN5PSIxMiIgcj0iOC45IiBmaWxsPSJub25lIiBzdHJva2U9IiMwMDAiIHN0cm9rZS13aWR0aD0iMS43Ii8+PHBhdGggZD0iTTcuOSAxMi4zbDIuNyAyLjcgNS41LTYiIGZpbGw9Im5vbmUiIHN0cm9rZT0iIzAwMCIgc3Ryb2tlLXdpZHRoPSIxLjciIHN0cm9rZS1saW5lY2FwPSJyb3VuZCIgc3Ryb2tlLWxpbmVqb2luPSJyb3VuZCIvPjwvc3ZnPg==") no-repeat center / 100% 100%;
  mask: url("data:image/svg+xml;base64,PHN2ZyB4bWxucz0iaHR0cDovL3d3dy53My5vcmcvMjAwMC9zdmciIHZpZXdCb3g9IjAgMCAyNCAyNCI+PGNpcmNsZSBjeD0iMTIiIGN5PSIxMiIgcj0iOC45IiBmaWxsPSJub25lIiBzdHJva2U9IiMwMDAiIHN0cm9rZS13aWR0aD0iMS43Ii8+PHBhdGggZD0iTTcuOSAxMi4zbDIuNyAyLjcgNS41LTYiIGZpbGw9Im5vbmUiIHN0cm9rZT0iIzAwMCIgc3Ryb2tlLXdpZHRoPSIxLjciIHN0cm9rZS1saW5lY2FwPSJyb3VuZCIgc3Ryb2tlLWxpbmVqb2luPSJyb3VuZCIvPjwvc3ZnPg==") no-repeat center / 100% 100%;
}
.ico-replay {
  -webkit-mask: url("data:image/svg+xml;base64,PHN2ZyB4bWxucz0iaHR0cDovL3d3dy53My5vcmcvMjAwMC9zdmciIHZpZXdCb3g9IjAgMCAyNCAyNCI+PHBhdGggZD0iTTEyIDVWMUw3IDZsNSA1VjdjMy4zMSAwIDYgMi42OSA2IDZzLTIuNjkgNi02IDYtNi0yLjY5LTYtNkg0YzAgNC40MiAzLjU4IDggOCA4czgtMy41OCA4LTgtMy41OC04LTgtOHoiLz48L3N2Zz4=") no-repeat center / 100% 100%;
  mask: url("data:image/svg+xml;base64,PHN2ZyB4bWxucz0iaHR0cDovL3d3dy53My5vcmcvMjAwMC9zdmciIHZpZXdCb3g9IjAgMCAyNCAyNCI+PHBhdGggZD0iTTEyIDVWMUw3IDZsNSA1VjdjMy4zMSAwIDYgMi42OSA2IDZzLTIuNjkgNi02IDYtNi0yLjY5LTYtNkg0YzAgNC40MiAzLjU4IDggOCA4czgtMy41OCA4LTgtMy41OC04LTgtOHoiLz48L3N2Zz4=") no-repeat center / 100% 100%;
}
.ico-undo {
  -webkit-mask: url("data:image/svg+xml;base64,PHN2ZyB4bWxucz0iaHR0cDovL3d3dy53My5vcmcvMjAwMC9zdmciIHZpZXdCb3g9IjAgMCAyNCAyNCI+PHBhdGggZD0iTTEyLjUgOGMtMi42NSAwLTUuMDUuOTktNi45IDIuNkwyIDd2OWg5bC0zLjYyLTMuNjJjMS4zOS0xLjE2IDMuMTYtMS44OCA1LjEyLTEuODggMy41NCAwIDYuNTUgMi4zMSA3LjYgNS41bDIuMzctLjc4QzIxLjA4IDExLjAzIDE3LjE1IDggMTIuNSA4eiIvPjwvc3ZnPg==") no-repeat center / 100% 100%;
  mask: url("data:image/svg+xml;base64,PHN2ZyB4bWxucz0iaHR0cDovL3d3dy53My5vcmcvMjAwMC9zdmciIHZpZXdCb3g9IjAgMCAyNCAyNCI+PHBhdGggZD0iTTEyLjUgOGMtMi42NSAwLTUuMDUuOTktNi45IDIuNkwyIDd2OWg5bC0zLjYyLTMuNjJjMS4zOS0xLjE2IDMuMTYtMS44OCA1LjEyLTEuODggMy41NCAwIDYuNTUgMi4zMSA3LjYgNS41bDIuMzctLjc4QzIxLjA4IDExLjAzIDE3LjE1IDggMTIuNSA4eiIvPjwvc3ZnPg==") no-repeat center / 100% 100%;
}
.ico-edit {
  -webkit-mask: url("data:image/svg+xml;base64,PHN2ZyB4bWxucz0iaHR0cDovL3d3dy53My5vcmcvMjAwMC9zdmciIHZpZXdCb3g9IjAgMCAyNCAyNCI+PHBhdGggZD0iTTMgMTcuMjVWMjFoMy43NUwxNy44MSA5Ljk0bC0zLjc1LTMuNzVMMyAxNy4yNXpNMjAuNzEgNy4wNGMuMzktLjM5LjM5LTEuMDIgMC0xLjQxbC0yLjM0LTIuMzRjLS4zOS0uMzktMS4wMi0uMzktMS40MSAwbC0xLjgzIDEuODMgMy43NSAzLjc1IDEuODMtMS44M3oiLz48L3N2Zz4=") no-repeat center / 100% 100%;
  mask: url("data:image/svg+xml;base64,PHN2ZyB4bWxucz0iaHR0cDovL3d3dy53My5vcmcvMjAwMC9zdmciIHZpZXdCb3g9IjAgMCAyNCAyNCI+PHBhdGggZD0iTTMgMTcuMjVWMjFoMy43NUwxNy44MSA5Ljk0bC0zLjc1LTMuNzVMMyAxNy4yNXpNMjAuNzEgNy4wNGMuMzktLjM5LjM5LTEuMDIgMC0xLjQxbC0yLjM0LTIuMzRjLS4zOS0uMzktMS4wMi0uMzktMS40MSAwbC0xLjgzIDEuODMgMy43NSAzLjc1IDEuODMtMS44M3oiLz48L3N2Zz4=") no-repeat center / 100% 100%;
}
.ico-delete {
  -webkit-mask: url("data:image/svg+xml;base64,PHN2ZyB4bWxucz0iaHR0cDovL3d3dy53My5vcmcvMjAwMC9zdmciIHZpZXdCb3g9IjAgMCAyNCAyNCI+PHBhdGggZmlsbC1ydWxlPSJldmVub2RkIiBjbGlwLXJ1bGU9ImV2ZW5vZGQiIGQ9Ik0xNiA5djEwSDhWOWg4bS0xLjUtNmgtNWwtMSAxSDV2MmgxNFY0aC0zLjVsLTEtMXpNMTggN0g2djEyYzAgMS4xLjkgMiAyIDJoOGMxLjEgMCAyLS45IDItMlY3eiIvPjwvc3ZnPg==") no-repeat center / 100% 100%;
  mask: url("data:image/svg+xml;base64,PHN2ZyB4bWxucz0iaHR0cDovL3d3dy53My5vcmcvMjAwMC9zdmciIHZpZXdCb3g9IjAgMCAyNCAyNCI+PHBhdGggZmlsbC1ydWxlPSJldmVub2RkIiBjbGlwLXJ1bGU9ImV2ZW5vZGQiIGQ9Ik0xNiA5djEwSDhWOWg4bS0xLjUtNmgtNWwtMSAxSDV2MmgxNFY0aC0zLjVsLTEtMXpNMTggN0g2djEyYzAgMS4xLjkgMiAyIDJoOGMxLjEgMCAyLS45IDItMlY3eiIvPjwvc3ZnPg==") no-repeat center / 100% 100%;
}
.action.go {
  color: var(--accent);
  border-color: var(--accent-border);
  background: linear-gradient(180deg, var(--tag-gloss), rgba(255, 255, 255, 0) 40%),
    var(--accent-soft);
}
.action.danger {
  color: var(--danger);
  border-color: var(--danger-border);
  background: linear-gradient(180deg, var(--tag-gloss), rgba(255, 255, 255, 0) 40%),
    var(--danger-bg);
}
</style>
