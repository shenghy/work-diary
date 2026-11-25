<template>
  <view class="tf">
    <view class="tf-label">{{ label }}</view>
    <view class="tf-zones">
      <!-- 日期区：picker 直接包有内容视图（标准触发，点按即弹系统日期选择器） -->
      <picker
        class="tf-zone-picker"
        mode="date"
        :value="tmpDate"
        :start="dateStart"
        :end="dateEnd"
        @change="onDateChange"
        @cancel="cancelPick"
      >
        <view class="tf-zone" :class="{ empty: !value }">
          <text class="tf-zone-val">{{ dateText }}</text>
          <text class="tf-zone-hint">{{ value ? '点按改日期' : '点按选日期' }}</text>
        </view>
      </picker>
      <!-- 时间区：picker 直接包有内容视图（标准触发，点按即弹系统时间选择器） -->
      <picker
        class="tf-zone-picker"
        mode="time"
        :value="tmpTime"
        :start="timeStart"
        :end="timeEnd"
        @change="onTimeChange"
        @cancel="cancelPick"
      >
        <view class="tf-zone" :class="{ empty: !value }">
          <text class="tf-zone-val">{{ timeText }}</text>
          <text class="tf-zone-hint">{{ value ? '点按改时间' : '点按选时间' }}</text>
        </view>
      </picker>
      <!-- 清除按钮：独立于两个 picker 触发区之外，始终可点 -->
      <text v-if="value" class="tf-clear" @click.stop="doClear">×</text>
    </view>
  </view>
</template>

<script>
// 时间选择字段（双区并排版）：日期区 + 时间区各自独立，均为原生 picker 直接包裹有内容触发视图
// 交互：想改哪块点哪块 → 弹系统选择器 → 改动即所见（任一侧选择都用当前 日期+时间 合成完整 ISO）
// 约束对齐桌面端：
//   - 日期层：start/end 由 min/max（ISO）限定
//   - 时间层：所选日期 == min 的日期时 start=min 时分；== max 的日期时 end=max 时分；否则不限
// 事件：change(iso) / clear；最终先后校验由页面负责（保存兜底）
export default {
  name: 'TimeField',
  props: {
    label: { type: String, default: '时间' },
    value: { type: String, default: '' }, // ISO
    min: { type: String, default: '' }, // ISO：最早可选（如截止时间的下限=开始时间）
    max: { type: String, default: '' } // ISO：最晚可选（如开始时间的上限=截止时间）
  },
  data() {
    return {
      tmpDate: '', // YYYY-MM-DD（本地）
      tmpTime: '' // HH:mm（本地）
    }
  },
  computed: {
    dateText() {
      if (!this.value) return '选择日期'
      const d = new Date(this.value)
      if (isNaN(d)) return '选择日期'
      return d.getMonth() + 1 + '/' + d.getDate()
    },
    timeText() {
      if (!this.value) return '选择时间'
      const d = new Date(this.value)
      if (isNaN(d)) return '选择时间'
      return String(d.getHours()).padStart(2, '0') + ':' + String(d.getMinutes()).padStart(2, '0')
    },
    dateStart() {
      return this.min ? this.datePart(this.min) : null
    },
    dateEnd() {
      return this.max ? this.datePart(this.max) : null
    },
    // 时间下限：仅当所选日期 == min 的日期时生效，否则不限
    timeStart() {
      if (this.min && this.tmpDate === this.datePart(this.min)) return this.timePart(this.min)
      return null
    },
    // 时间上限：仅当所选日期 == max 的日期时生效，否则不限
    timeEnd() {
      if (this.max && this.tmpDate === this.datePart(this.max)) return this.timePart(this.max)
      return null
    }
  },
  mounted() {
    this.resetDefault()
  },
  watch: {
    // 外部清空（clear）或值变化：重置默认选中值（保持"清空后重选默认今天"的预期）
    value() {
      this.resetDefault()
    }
  },
  methods: {
    datePart(iso) {
      const d = new Date(iso)
      const m = String(d.getMonth() + 1).padStart(2, '0')
      const day = String(d.getDate()).padStart(2, '0')
      return d.getFullYear() + '-' + m + '-' + day
    },
    timePart(iso) {
      const d = new Date(iso)
      return String(d.getHours()).padStart(2, '0') + ':' + String(d.getMinutes()).padStart(2, '0')
    },
    // 默认值：已有值用其本地日期/时分，否则今天 + 当前时分
    resetDefault() {
      let d = this.value ? new Date(this.value) : new Date()
      if (isNaN(d)) d = new Date()
      this.tmpDate = this.datePart(d)
      this.tmpTime = String(d.getHours()).padStart(2, '0') + ':' + String(d.getMinutes()).padStart(2, '0')
    },
    cancelPick() {
      // 原生选择器取消：不做任何更改
    },
    onDateChange(e) {
      this.tmpDate = e.detail.value
      this.emitChange()
    },
    onTimeChange(e) {
      this.tmpTime = e.detail.value
      this.emitChange()
    },
    // 任一侧选择完成：当前 日期+时间 合成完整 ISO 回传
    emitChange() {
      const iso = new Date(this.tmpDate + 'T' + this.tmpTime + ':00').toISOString()
      this.$emit('change', iso)
    },
    doClear() {
      this.$emit('clear')
    }
  }
}
</script>

<style lang="scss" scoped>
.tf {
  position: relative;
}
.tf-label {
  font-size: 26rpx;
  color: var(--text-secondary);
  margin-bottom: 14rpx;
}
.tf-zones {
  display: flex;
  gap: 16rpx;
  position: relative;
}
/* picker 直接包裹触发视图（标准用法） */
.tf-zone-picker {
  flex: 1;
  display: block;
}
.tf-zone {
  display: flex;
  flex-direction: column;
  align-items: center;
  justify-content: center;
  background: var(--accent-soft);
  border: 2rpx solid var(--accent);
  border-radius: 12rpx;
  padding: 18rpx 0;
  box-sizing: border-box;
}
/* 空态（未设置）：灰色胶囊 */
.tf-zone.empty {
  background: var(--chip-bg);
  border-color: var(--chip-border);
}
.tf-zone-val {
  font-size: 30rpx;
  font-weight: 600;
  color: var(--accent);
}
.tf-zone.empty .tf-zone-val {
  color: var(--text-tertiary);
  font-weight: 400;
  font-size: 26rpx;
}
.tf-zone-hint {
  font-size: 22rpx;
  color: var(--text-tertiary);
  margin-top: 4rpx;
}
/* 清除按钮：独立于 picker 触发区之外（区域右上角），z-index 最高，点击只清除 */
.tf-clear {
  position: absolute;
  right: 10rpx;
  top: -30rpx;
  font-size: 30rpx;
  color: var(--danger);
  padding: 4rpx 10rpx;
  line-height: 1;
  z-index: 30;
}
</style>