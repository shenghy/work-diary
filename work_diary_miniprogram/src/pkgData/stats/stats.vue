<template>
  <view class="page" :class="themeClass">
    <aurora-bg />
    <scroll-view class="scroll" scroll-y>
      <!-- 范围切换 -->
      <view class="range-row">
        <view
          v-for="r in ranges"
          :key="r.days"
          class="range-chip"
          :class="{ on: rangeDays === r.days }"
          @click="pickRange(r.days)"
        >{{ r.text }}</view>
      </view>

      <view class="state" v-if="loading">数据加载中...</view>
      <view class="state error" v-else-if="error">
        <text>{{ error }}</text>
        <view class="retry" @click="load">重试</view>
      </view>

      <view class="state" v-else-if="blank">
        <text>还没有足够数据，先完成几个任务吧</text>
      </view>

      <template v-else-if="data">
        <!-- 核心指标 -->
        <view class="metric-grid">
          <view class="metric-card glass">
            <text class="m-label">已完成任务</text>
            <text class="m-value">{{ summary.completed }}</text>
            <text class="m-hint" :class="compareClass">{{ compareText }}</text>
          </view>
          <view class="metric-card glass">
            <text class="m-label">完成率</text>
            <text class="m-value">{{ rateText(summary.completion_rate) }}</text>
            <text class="m-hint">应完成 {{ summary.due_total }} · 未完成 {{ summary.undone }}</text>
            <text class="m-hint sparse" v-if="sparseHint">{{ sparseHint }}</text>
          </view>
          <view class="metric-card glass">
            <text class="m-label">连续打卡</text>
            <text class="m-value">{{ summary.streak_days }}<text class="m-unit">天</text></text>
            <text class="m-hint">历史最长 {{ summary.streak_best }} 天</text>
          </view>
          <view class="metric-card glass">
            <text class="m-label">平均完成耗时</text>
            <text class="m-value">{{ finishText }}</text>
            <text class="m-hint" v-if="finishHint">{{ finishHint }}</text>
            <text class="m-hint" v-else>样本不足 3 条</text>
          </view>
        </view>

        <!-- 任务趋势 -->
        <view class="card glass">
          <view class="card-head">
            <view class="head-left">
              <text class="card-title">任务趋势</text>
              <text class="grain-badge">{{ grainText }}</text>
            </view>
            <text class="head-rate">{{ trendRateText }}</text>
          </view>
          <view class="trend-body" v-if="!trendEmpty">
            <view class="trend-yaxis">
              <text class="y-tick t0">{{ trendPeak }}</text>
              <text class="y-tick t50">{{ trendMid }}</text>
              <text class="y-tick t100">0</text>
            </view>
            <view class="trend-plot">
              <view class="trend-plot-inner">
                <view class="grid-line top"></view>
                <view class="grid-line mid"></view>
                <view class="trend-bars">
                  <view class="trend-col" v-for="(b, i) in trendBuckets" :key="i">
                    <view class="empty-band" v-if="b.empty"></view>
                    <view class="trend-pair">
                      <text class="bar-cap" v-if="b.cap">{{ b.cap }}</text>
                      <view class="bar created" :style="{ height: b.createdH + '%', width: barW + 'rpx' }"></view>
                      <view class="bar done" :style="{ height: b.doneH + '%', width: barW + 'rpx' }"></view>
                    </view>
                  </view>
                </view>
              </view>
              <view class="trend-axis">
                <text
                  class="axis-tick"
                  v-for="t in axisTicks"
                  :key="t.i"
                  :style="{ left: t.pct + '%', transform: 'translateX(' + t.shift + ')' }"
                >{{ t.label }}</text>
              </view>
            </view>
          </view>
          <view class="trend-empty" v-else>这段时间还没有记录</view>
          <view class="trend-foot">
            <view class="legend">
              <view class="dot created"></view><text>新建</text>
              <view class="dot done"></view><text>完成</text>
            </view>
            <text class="foot-hint">斜纹段 = 完全没有记录的{{ grainText }}</text>
          </view>
        </view>

        <!-- 任务构成 -->
        <view class="card glass">
          <view class="card-head"><text class="card-title">任务构成</text></view>
          <view class="compose">
            <view class="donut" :style="{ background: donutBg }">
              <view class="donut-hole">
                <text class="donut-num">{{ summary.completed }}</text>
                <text class="donut-cap">已完成</text>
              </view>
            </view>
            <view class="compose-bars">
              <view class="compose-row">
                <text class="c-label">工作</text>
                <view class="c-track"><view class="c-fill work" :style="{ width: typePct(1) + '%' }"></view></view>
                <text class="c-val">{{ typeCount(1) }}</text>
              </view>
              <view class="compose-row">
                <text class="c-label">个人</text>
                <view class="c-track"><view class="c-fill personal" :style="{ width: typePct(0) + '%' }"></view></view>
                <text class="c-val">{{ typeCount(0) }}</text>
              </view>
              <view class="compose-row" v-for="u in urgencyRows" :key="'u' + u.urgency">
                <text class="c-label">{{ u.label }}</text>
                <view class="c-track"><view class="c-fill" :style="{ width: u.pct + '%', background: u.color }"></view></view>
                <text class="c-val">{{ u.count }}</text>
              </view>
            </view>
          </view>
        </view>

        <!-- 活跃热力图 -->
        <view class="card glass">
          <view class="card-head">
            <text class="card-title">活跃热力图</text>
            <text class="card-hint">近 12 周</text>
          </view>
          <view class="heat-body">
            <view class="heat-days">
              <text class="d-tick on">一</text>
              <text class="d-tick"></text>
              <text class="d-tick on">三</text>
              <text class="d-tick"></text>
              <text class="d-tick on">五</text>
              <text class="d-tick"></text>
              <text class="d-tick"></text>
            </view>
            <view class="heat-main">
              <view class="heat-months">
                <text
                  class="m-tick"
                  v-for="m in monthTicks"
                  :key="m.i"
                  :style="{ left: m.pct + '%' }"
                >{{ m.label }}</text>
              </view>
              <view class="heat-wrap">
                <view class="heat-week" v-for="(week, wi) in heatWeeks" :key="wi">
                  <view
                    v-for="(d, di) in week"
                    :key="di"
                    class="heat-cell"
                    :class="'lv' + d.level"
                  ></view>
                </view>
              </view>
            </view>
          </view>
          <view class="heat-legend">
            <text>少</text>
            <view class="heat-cell lv0"></view>
            <view class="heat-cell lv1"></view>
            <view class="heat-cell lv2"></view>
            <view class="heat-cell lv3"></view>
            <view class="heat-cell lv4"></view>
            <text>多</text>
            <text class="heat-max" v-if="heatmap.max">单日最多 {{ heatmap.max }} 个</text>
          </view>
        </view>

        <!-- 循环任务按期率 -->
        <view class="card glass">
          <view class="card-head"><text class="card-title">循环任务按期率</text></view>
          <view class="repeat-row" v-for="r in repeatRows" :key="r.kind">
            <text class="r-label">{{ r.label }}</text>
            <view class="r-track"><view class="r-fill" :style="{ width: (r.rate || 0) + '%' }"></view></view>
            <text class="r-val">{{ r.total ? r.rate + '%' : '--' }}</text>
            <text class="r-sub" :class="{ none: !r.total }">{{ r.total ? r.done + '/' + r.total : '本期无排期' }}</text>
          </view>
          <text class="card-hint">按实例到期日统计，已删除的期次不计入分母</text>
        </view>

        <!-- 专注时段 -->
        <view class="card glass">
          <view class="card-head">
            <text class="card-title">专注时段分布</text>
            <text class="card-hint">{{ peakText }}</text>
          </view>
          <view class="hours">
            <view class="hour-col" v-for="(h, i) in hours" :key="i">
              <view class="hour-bar" :style="{ height: hourH(h) + '%' }" :class="{ peak: isPeak(i) }"></view>
            </view>
          </view>
          <view class="hour-axis">
            <text>0</text><text>6</text><text>12</text><text>18</text><text>23</text>
          </view>
          <text class="card-hint" v-if="peakUrgentText">{{ peakUrgentText }}</text>
        </view>

        <view class="footer">
          <text>口径：完成数按完成时间落入区间；完成率 = 已完成 / 应完成（有截止按截止日，无截止按创建日）。</text>
          <text>看板由本机已同步的任务在本地时区 {{ tzLabel }} 计算；其他设备刚产生的改动，同步后才会计入。</text>
        </view>
      </template>
    </scroll-view>
  </view>
</template>

<script>
import AuroraBg from '../../components/aurora-bg.vue'
import { loadTasksCache, loadRepeatSkips, loadRepeatRules } from '../../utils/storage'
import { computeStatsSnapshot } from '../../utils/stats'

export default {
  components: { AuroraBg },
  data() {
    return {
      loading: true,
      error: '',
      data: null,
      rangeDays: 7,
      ranges: [
        { days: 7, text: '近7天' },
        { days: 30, text: '近30天' },
        { days: 90, text: '近90天' },
        { days: 0, text: '全部' }
      ]
    }
  },
  computed: {
    // 本机时区标签：聚合用的是设备本地日历，写死 Asia/Shanghai 会误导
    tzLabel() {
      const offset = -new Date().getTimezoneOffset() / 60
      return 'UTC' + (offset >= 0 ? '+' : '-') + Math.abs(offset)
    },
    blank() {
      return !!this.data && this.data.is_blank === true
    },
    summary() {
      return (this.data && this.data.summary) || {}
    },
    trend() {
      return (this.data && this.data.trend) || { buckets: [], created: [], completed: [], completion_rate: [] }
    },
    heatmap() {
      return (this.data && this.data.heatmap) || { days: [], max: 0 }
    },
    hours() {
      return (this.data && this.data.hours) || []
    },
    changePercent() {
      const prev = this.summary.completed_prev || 0
      if (prev <= 0) return null
      return Math.round((((this.summary.completed || 0) - prev) / prev) * 100)
    },
    compareText() {
      if (this.changePercent === null) return '上周期暂无数据'
      return '较上周期 ' + (this.changePercent > 0 ? '+' : '') + this.changePercent + '%'
    },
    compareClass() {
      if (this.changePercent === null) return ''
      return this.changePercent >= 0 ? 'up' : 'down'
    },
    sparseHint() {
      const due = this.summary.due_total || 0
      return due > 0 && due < 5 ? '样本较少' : ''
    },
    finishText() {
      const h = this.summary.avg_finish_median_hours
      if (h === null || h === undefined) return '--'
      if (h < 1) return Math.round(h * 60) + ' 分钟'
      if (h < 48) return this.trimUnit(h) + ' 小时'
      return this.trimUnit(h / 24) + ' 天'
    },
    finishHint() {
      const fastest = this.summary.fastest_minutes
      const slowest = this.summary.slowest_days
      if (fastest === null || fastest === undefined) return ''
      if (slowest === null || slowest === undefined) return ''
      return '最快 ' + this.durationText(fastest) + ' · 最慢 ' + this.durationText(slowest * 1440)
    },
    trendEmpty() {
      const sum = (list) => (list || []).reduce((a, b) => a + (b || 0), 0)
      return sum(this.trend.created) === 0 && sum(this.trend.completed) === 0
    },
    trendPeak() {
      const t = this.trend
      let peak = 0
      ;(t.buckets || []).forEach((b, i) => {
        peak = Math.max(peak, t.created[i] || 0, t.completed[i] || 0)
      })
      return peak
    },
    trendMid() {
      return Math.round(this.trendPeak / 2)
    },
    // 30 个日桶时柱顶数字会互相压住，只有桶数少到读得开才标
    barW() {
      const n = this.trendBuckets.length
      return n <= 8 ? 16 : n <= 14 ? 12 : 8
    },
    trendBuckets() {
      const t = this.trend
      const list = (t.buckets || []).map((b, i) => ({
        label: this.shortBucket(b),
        created: t.created[i] || 0,
        done: t.completed[i] || 0,
        rate: t.completion_rate[i]
      }))
      const max = Math.max(1, ...list.map((x) => Math.max(x.created, x.done)))
      const capsOn = list.length <= 16
      return list.map((x) => ({
        ...x,
        empty: x.created === 0 && x.done === 0,
        cap: capsOn && x.done > 0 ? x.done : 0,
        createdH: Math.round((x.created / max) * 100),
        doneH: Math.round((x.done / max) * 100)
      }))
    },
    axisTicks() {
      const list = this.trendBuckets
      if (!list.length) return []
      const last = list.length - 1
      const raw = last < 2 ? [0, last] : [0, Math.round(last / 2), last]
      const uniq = Array.from(new Set(raw)).filter((i) => list[i])
      return uniq.map((i) => ({
        i,
        label: list[i].label,
        pct: last ? (i / last) * 100 : 0,
        shift: i === 0 ? '0' : i === last ? '-100%' : '-50%'
      }))
    },
    grainText() {
      const range = (this.data && this.data.range) || {}
      return range.granularity === 'week' ? '按周' : '按日'
    },
    trendRateText() {
      const rate = this.summary.completion_rate
      if (rate === null || rate === undefined) return '本期无排期'
      return '本期完成率 ' + rate + '%'
    },
    monthTicks() {
      const weeks = this.heatWeeks
      if (!weeks.length) return []
      const out = []
      let prev = ''
      weeks.forEach((week, i) => {
        const key = week[0] && week[0].date
        if (!key) return
        const month = String(key).slice(5, 7)
        if (month === prev) return
        prev = month
        // 相邻两周换月会撞字，隔得太近的丢掉后一个
        if (out.length && i - out[out.length - 1].i < 2) return
        out.push({ i, label: Number(month) + '月', pct: (i / weeks.length) * 100 })
      })
      return out
    },
    donutBg() {
      const work = this.typeCount(1)
      const personal = this.typeCount(0)
      const total = work + personal
      if (!total) return 'conic-gradient(var(--track-bg) 0 100%)'
      const p = Math.round((work / total) * 100)
      return 'conic-gradient(var(--stats-blue) 0 ' + p + '%, var(--stats-teal) ' + p + '% 100%)'
    },
    urgencyRows() {
      const colors = ['var(--urgency-normal)', 'var(--urgency-urgent)', 'var(--urgency-important)']
      const labels = ['一般', '紧急', '重要']
      const data = (this.data && this.data.by_urgency) || []
      const max = Math.max(1, ...data.map((x) => x.count))
      return data.map((x) => ({
        urgency: x.urgency,
        label: labels[x.urgency] || '一般',
        count: x.count,
        pct: Math.round((x.count / max) * 100),
        color: colors[x.urgency] || colors[0]
      }))
    },
    heatWeeks() {
      const days = this.heatmap.days || []
      const max = this.heatmap.max || 1
      const weeks = []
      for (let i = 0; i < days.length; i += 7) {
        weeks.push(
          days.slice(i, i + 7).map((d) => {
            const c = d.count || 0
            let level = 0
            if (c > 0) level = Math.min(4, Math.max(1, Math.ceil((c / max) * 4)))
            return { date: d.date, count: c, level }
          })
        )
      }
      return weeks
    },
    repeatRows() {
      const labels = { day: '日任务', week: '周任务', month: '月任务' }
      const data = (this.data && this.data.repeat_rate) || []
      return data.map((x) => ({ ...x, label: labels[x.kind] || x.kind }))
    },
    peakText() {
      const peak = this.data && this.data.peak_hours
      if (!peak) return '暂无完成记录'
      return '高峰 ' + this.hourLabel(peak[0]) + '–' + this.hourLabel(peak[1])
    },
    peakUrgentText() {
      const share = this.data && this.data.peak_urgent_share
      if (share === null || share === undefined) return ''
      return '高峰时段紧急/重要任务占 ' + share + '%'
    }
  },
  onShow() {
    this.load()
  },
  methods: {
    load() {
      this.loading = true
      this.error = ''
      try {
        const tasks = loadTasksCache()
        const skips = loadRepeatSkips()
        const rules = loadRepeatRules()
        // 早期版本只把「仅删除本期」记在规则里，取并集才不会把删过的期次算进分母
        Object.keys(rules).forEach((gid) => {
          const extra = (rules[gid] && rules[gid].skip_dates) || []
          if (!extra.length) return
          skips[gid] = Array.from(new Set([...(skips[gid] || []), ...extra]))
        })
        this.data = computeStatsSnapshot({ tasks, skips, rangeDays: this.rangeDays })
        this.loading = false
      } catch (e) {
        this.loading = false
        this.error = (e && e.message) || '看板数据计算失败'
      }
    },
    pickRange(days) {
      if (this.rangeDays === days) return
      this.rangeDays = days
      this.load()
    },
    rateText(v) {
      return v === null || v === undefined ? '--' : v + '%'
    },
    trimUnit(v) {
      const text = v.toFixed(1)
      return text.endsWith('.0') ? text.slice(0, -2) : text
    },
    // 写死分钟会撑破卡片：180 分钟不如 3 小时好读
    durationText(minutes) {
      if (minutes < 60) return Math.round(minutes) + ' 分钟'
      const inHours = minutes < 48 * 60
      return this.trimUnit(inHours ? minutes / 60 : minutes / 1440) + (inHours ? ' 小时' : ' 天')
    },
    typeCount(type) {
      const list = (this.data && this.data.by_type) || []
      const found = list.find((x) => x.type === (type === 1 ? 'work' : 'personal'))
      return found ? found.count : 0
    },
    typePct(type) {
      const total = this.typeCount(0) + this.typeCount(1)
      if (!total) return 0
      return Math.round((this.typeCount(type) / total) * 100)
    },
    shortBucket(iso) {
      const parts = String(iso).split('-')
      if (parts.length < 3) return iso
      return parts[1] + '/' + parts[2]
    },
    hourH(h) {
      const max = Math.max(1, ...this.hours)
      return Math.round((h / max) * 100)
    },
    hourLabel(h) {
      const suffix = h < 12 ? '上午' : h < 18 ? '下午' : '晚上'
      return suffix + ' ' + String(h).padStart(2, '0') + ':00'
    },
    isPeak(i) {
      const peak = this.data && this.data.peak_hours
      return !!peak && i >= peak[0] && i < peak[1]
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
.range-row {
  display: flex;
  gap: 12rpx;
  margin-bottom: 24rpx;
}
.range-chip {
  flex: 1;
  text-align: center;
  height: 68rpx;
  line-height: 68rpx;
  border-radius: 999rpx;
  font-size: 25rpx;
  color: var(--text-secondary);
  background: var(--chip-bg);
  border: 1rpx solid var(--chip-border);
}
.range-chip.on {
  color: #ffffff;
  background: var(--accent);
  border-color: var(--accent);
  font-weight: 600;
}
.state {
  padding: 200rpx 0;
  text-align: center;
  color: var(--text-tertiary);
  font-size: 26rpx;
}
.state.error {
  color: var(--text-secondary);
}
.retry {
  margin: 24rpx auto 0;
  width: 220rpx;
  height: 72rpx;
  line-height: 72rpx;
  border-radius: 999rpx;
  background: var(--accent);
  color: #ffffff;
  font-size: 26rpx;
}
.metric-grid {
  display: flex;
  flex-wrap: wrap;
  gap: 16rpx;
}
.metric-card {
  width: calc(50% - 8rpx);
  background: var(--card-bg);
  border: 1rpx solid var(--card-border);
  border-radius: 32rpx;
  padding: 24rpx;
  box-sizing: border-box;
  box-shadow: var(--shadow-card);
}
.m-label {
  display: block;
  font-size: 24rpx;
  color: var(--text-tertiary);
}
.m-value {
  display: block;
  font-size: 48rpx;
  font-weight: 700;
  margin-top: 8rpx;
  color: var(--text-primary);
}
.m-unit {
  font-size: 24rpx;
  font-weight: 400;
  margin-left: 4rpx;
  color: var(--text-tertiary);
}
.m-hint {
  display: block;
  font-size: 22rpx;
  color: var(--text-tertiary);
  margin-top: 6rpx;
}
.m-hint.up {
  color: var(--status-completed);
}
.m-hint.down {
  color: var(--danger);
}
.m-hint.sparse {
  color: var(--stats-amber);
}
.card {
  margin-top: 20rpx;
  background: var(--card-bg);
  border: 1rpx solid var(--card-border);
  border-radius: 32rpx;
  padding: 26rpx 24rpx;
  box-shadow: var(--shadow-card);
}
.card-head {
  display: flex;
  align-items: center;
  justify-content: space-between;
  margin-bottom: 20rpx;
}
.card-title {
  font-size: 30rpx;
  font-weight: 700;
  color: var(--text-primary);
}
.card-hint {
  font-size: 22rpx;
  color: var(--text-tertiary);
}
.legend {
  display: flex;
  align-items: center;
  gap: 8rpx;
  font-size: 22rpx;
  color: var(--text-tertiary);
}
.dot {
  width: 14rpx;
  height: 14rpx;
  border-radius: 4rpx;
}
.dot.created {
  background: var(--stats-primary-soft);
}
.dot.done {
  background: var(--stats-teal);
  margin-left: 12rpx;
}
.trend-body {
  display: flex;
  align-items: flex-start;
}
.trend-yaxis {
  position: relative;
  width: 44rpx;
  height: 240rpx;
  flex-shrink: 0;
}
.y-tick {
  position: absolute;
  right: 10rpx;
  font-size: 18rpx;
  line-height: 1;
  color: var(--text-tertiary);
  transform: translateY(-50%);
}
.y-tick.t0 {
  top: 0;
}
.y-tick.t50 {
  top: 50%;
}
.y-tick.t100 {
  top: 100%;
}
.trend-plot {
  flex: 1;
  min-width: 0;
}
.trend-plot-inner {
  position: relative;
  height: 240rpx;
  border-bottom: 1rpx solid var(--stats-axis);
}
.grid-line {
  position: absolute;
  left: 0;
  right: 0;
  border-top: 1rpx dashed var(--stats-grid);
}
.grid-line.top {
  top: 0;
}
.grid-line.mid {
  top: 50%;
}
.trend-bars {
  display: flex;
  align-items: flex-end;
  height: 100%;
  position: relative;
  z-index: 2;
}
.trend-col {
  flex: 1;
  min-width: 0;
  height: 100%;
  display: flex;
  flex-direction: column;
  align-items: center;
  justify-content: flex-end;
  position: relative;
}
.empty-band {
  position: absolute;
  left: 0;
  right: 0;
  top: 0;
  bottom: 0;
  background: var(--stats-band);
}
.trend-pair {
  display: flex;
  align-items: flex-end;
  justify-content: center;
  gap: 3rpx;
  height: 206rpx;
  position: relative;
}
.bar {
  min-height: 2rpx;
  border-radius: 6rpx 6rpx 2rpx 2rpx;
  transition: height 0.3s ease;
}
.bar.created {
  background: var(--stats-primary-soft);
  opacity: 0.55;
}
.bar.done {
  background: var(--stats-teal);
}
.bar-cap {
  position: absolute;
  top: -22rpx;
  left: 50%;
  transform: translateX(-50%);
  font-size: 18rpx;
  color: var(--stats-teal-strong);
}
.trend-axis {
  position: relative;
  height: 30rpx;
  margin-top: 8rpx;
}
.axis-tick {
  position: absolute;
  top: 0;
  font-size: 20rpx;
  white-space: nowrap;
  color: var(--text-tertiary);
}
.head-left {
  display: flex;
  align-items: center;
}
.grain-badge {
  margin-left: 12rpx;
  padding: 2rpx 12rpx;
  border-radius: 8rpx;
  border: 1rpx solid var(--chip-border);
  background: var(--chip-bg);
  font-size: 20rpx;
  color: var(--text-secondary);
}
.head-rate {
  font-size: 22rpx;
  color: var(--stats-teal-strong);
}
.trend-foot {
  display: flex;
  align-items: center;
  justify-content: space-between;
  margin-top: 12rpx;
}
.foot-hint {
  font-size: 20rpx;
  color: var(--text-tertiary);
}
.trend-empty {
  padding: 46rpx 0;
  text-align: center;
  font-size: 22rpx;
  color: var(--text-tertiary);
}
.compose {
  display: flex;
  align-items: center;
  gap: 28rpx;
}
.donut {
  width: 220rpx;
  height: 220rpx;
  border-radius: 50%;
  display: flex;
  align-items: center;
  justify-content: center;
  flex-shrink: 0;
}
.donut-hole {
  width: 140rpx;
  height: 140rpx;
  border-radius: 50%;
  background: var(--card-bg-strong);
  display: flex;
  flex-direction: column;
  align-items: center;
  justify-content: center;
}
.donut-num {
  font-size: 36rpx;
  font-weight: 700;
  color: var(--text-primary);
}
.donut-cap {
  font-size: 20rpx;
  color: var(--text-tertiary);
}
.compose-bars {
  flex: 1;
  min-width: 0;
}
.compose-row {
  display: flex;
  align-items: center;
  margin-bottom: 12rpx;
}
.c-label {
  width: 64rpx;
  font-size: 22rpx;
  color: var(--text-secondary);
  flex-shrink: 0;
}
.c-track {
  flex: 1;
  height: 12rpx;
  border-radius: 6rpx;
  background: var(--track-bg);
  overflow: hidden;
}
.c-fill {
  height: 100%;
  border-radius: 6rpx;
}
.c-fill.work {
  background: var(--stats-blue);
}
.c-fill.personal {
  background: var(--stats-teal);
}
.c-val {
  width: 52rpx;
  text-align: right;
  font-size: 22rpx;
  color: var(--text-tertiary);
}
.heat-body {
  display: flex;
  align-items: flex-start;
}
.heat-days {
  width: 36rpx;
  flex-shrink: 0;
  display: flex;
  flex-direction: column;
  /* 和 .heat-months 同高，否则星期标签比格子整体上一档 */
  margin-top: 28rpx;
}
.d-tick {
  height: 30rpx;
  margin-bottom: 8rpx;
  line-height: 30rpx;
  font-size: 18rpx;
  color: var(--text-tertiary);
}
.heat-main {
  flex: 1;
  min-width: 0;
}
.heat-months {
  position: relative;
  height: 28rpx;
}
.m-tick {
  position: absolute;
  top: 0;
  font-size: 18rpx;
  white-space: nowrap;
  color: var(--text-tertiary);
}
.heat-wrap {
  display: flex;
  gap: 8rpx;
}
.heat-week {
  display: flex;
  flex-direction: column;
  gap: 8rpx;
}
.heat-cell {
  width: 30rpx;
  height: 30rpx;
  border-radius: 6rpx;
}
.lv0 {
  background: rgba(120, 145, 190, 0.16);
}
.lv1 {
  background: #c9c6f5;
}
.lv2 {
  background: #a9a3ef;
}
.lv3 {
  background: #8779e6;
}
.lv4 {
  background: #5b4be0;
}
.theme-dark .lv0 {
  background: rgba(255, 255, 255, 0.08);
}
.theme-dark .lv1 {
  background: rgba(123, 108, 255, 0.3);
}
.theme-dark .lv2 {
  background: rgba(123, 108, 255, 0.55);
}
.theme-dark .lv3 {
  background: rgba(169, 156, 255, 0.78);
}
.theme-dark .lv4 {
  background: #f0ebff;
}
.heat-legend {
  display: flex;
  align-items: center;
  gap: 6rpx;
  margin-top: 16rpx;
  font-size: 20rpx;
  color: var(--text-tertiary);
}
.heat-max {
  margin-left: auto;
}
.repeat-row {
  display: flex;
  align-items: center;
  margin-bottom: 16rpx;
}
.r-label {
  width: 100rpx;
  font-size: 24rpx;
  color: var(--text-secondary);
}
.r-track {
  flex: 1;
  height: 14rpx;
  border-radius: 7rpx;
  background: var(--track-bg);
  overflow: hidden;
}
.r-fill {
  height: 100%;
  border-radius: 7rpx;
  background: linear-gradient(90deg, var(--stats-primary), var(--stats-primary-soft));
}
.r-val {
  width: 80rpx;
  text-align: right;
  font-size: 24rpx;
  font-weight: 600;
  color: var(--text-primary);
}
.r-sub {
  width: 80rpx;
  text-align: right;
  font-size: 20rpx;
  color: var(--text-tertiary);
}
/* 「本期无排期」比 3/5 这类计数长，给它留出字数，否则会被截断 */
.r-sub.none {
  width: 116rpx;
}
.hours {
  display: flex;
  align-items: flex-end;
  height: 180rpx;
  gap: 3rpx;
}
.hour-col {
  flex: 1;
  height: 100%;
  display: flex;
  align-items: flex-end;
}
.hour-bar {
  width: 100%;
  min-height: 2rpx;
  border-radius: 4rpx 4rpx 2rpx 2rpx;
  background: var(--stats-blue);
  opacity: 0.55;
}
.hour-bar.peak {
  background: var(--stats-pink);
  opacity: 1;
}
.hour-axis {
  display: flex;
  justify-content: space-between;
  margin-top: 8rpx;
  font-size: 20rpx;
  color: var(--text-tertiary);
}
.footer {
  margin: 24rpx 4rpx 60rpx;
  display: flex;
  flex-direction: column;
  gap: 8rpx;
  font-size: 21rpx;
  line-height: 1.6;
  color: var(--text-tertiary);
}
</style>
