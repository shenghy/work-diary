# -*- coding: utf-8 -*-
"""小程序同步：入场动画 + 已完成/全部分页、搜索、筛选 + 搜索框样式"""
import io

p = r"E:\Code\WorkDiary\work_diary_miniprogram\src\pages\tasks\tasks.vue"
with io.open(p, "r", encoding="utf-8") as f:
    c = f.read()

# ========== 1. template：任务滑页加搜索/筛选/加载更多/动画 ==========
old1 = '''      <!-- 任务视图：计划中 / 执行中 / 已完成 / 全部 -->
      <swiper-item v-for="(tab, i) in taskTabs" :key="tab.key">
        <scroll-view
          class="list-scroll"
          :scroll-y="!dragActive"
          :refresher-enabled="!dragActive"
          :refresher-triggered="refreshing"
          @refresherrefresh="onRefresh"
          @scrolltolower="onLower(i)"
        >
          <!-- 首次加载骨架屏：云端拉取期间，空列表不白屏 -->
          <view class="skeleton-list" v-if="loading && taskListByKey(tab.key).length === 0">
            <view class="skeleton-card" v-for="n in 6" :key="'skt' + n">
              <view class="sk-head">
                <view class="sk-bar" :style="{ background: SKEL_TONES[n % 3] }"></view>
                <view class="sk-lines">
                  <view class="sk-title"></view>
                  <view class="sk-sub"></view>
                </view>
              </view>
              <view class="sk-progress"><view class="sk-progress-inner"></view></view>
              <view class="sk-foot"><view class="sk-dot"></view><view class="sk-dot"></view><view class="sk-chip"></view></view>
            </view>
          </view>
          <view class="list" :class="{ bounce: bounces[i] }" v-else-if="taskListByKey(tab.key).length > 0">
            <view
              v-for="(t, ti) in taskListByKey(tab.key)"
              :key="t.remote_id || t.id"
              :id="'drag-item-' + i + '-' + ti"
              class="drag-item"
              :class="{ dragging: dragActive && dragPageIdx === i && dragIndex === ti }"
              :style="dragItemStyle(t, ti, i)"
              @touchstart="onDragStart($event, t, ti, i)"
              @touchmove="onDragMove"
              @touchend="onDragEnd"
              @touchcancel="onDragEnd"
            >
              <task-card
                :task="t"
                @status-action="statusAction"
                @edit="goTaskEdit"
                @delete="deleteTask"
                @subtask-change="subtaskChange"
              />
            </view>
          </view>
          <view class="empty" v-else>
            <text class="empty-text">{{ emptyTextByKey(tab.key) }}</text>
          </view>
        </scroll-view>
      </swiper-item>'''
new1 = '''      <!-- 任务视图：计划中 / 执行中 / 已完成 / 全部 -->
      <swiper-item v-for="(tab, i) in taskTabs" :key="tab.key">
        <scroll-view
          class="list-scroll"
          :scroll-y="!dragActive"
          :refresher-enabled="!dragActive"
          :refresher-triggered="refreshing"
          @refresherrefresh="onRefresh"
          @scrolltolower="onLower(i)"
        >
          <!-- 搜索 + 筛选（仅已完成/全部 tab） -->
          <view class="task-search-wrap" v-if="tab.key === 2 || tab.key === 'all'">
            <view class="task-search-bar">
              <input
                v-model="taskKeyword"
                class="task-search-input"
                placeholder="搜索任务标题 / 子任务内容…"
                placeholder-class="ph"
                confirm-type="search"
              />
            </view>
            <view class="filter-row">
              <text class="filter-chip" :class="{ on: taskUrgencyFilter === null }" @click="setUrgencyFilter(null)">全部</text>
              <text class="filter-chip" :class="{ on: taskUrgencyFilter === '一般' }" @click="setUrgencyFilter('一般')">一般</text>
              <text class="filter-chip" :class="{ on: taskUrgencyFilter === '重要' }" @click="setUrgencyFilter('重要')">重要</text>
              <text class="filter-chip" :class="{ on: taskUrgencyFilter === '紧急' }" @click="setUrgencyFilter('紧急')">紧急</text>
              <text class="filter-divider">|</text>
              <text class="filter-chip" :class="{ on: taskTypeFilter === null }" @click="setTypeFilter(null)">全部</text>
              <text class="filter-chip" :class="{ on: taskTypeFilter === 1 }" @click="setTypeFilter(1)">工作</text>
              <text class="filter-chip" :class="{ on: taskTypeFilter === 0 }" @click="setTypeFilter(0)">个人</text>
            </view>
          </view>
          <!-- 首次加载骨架屏：云端拉取期间，空列表不白屏 -->
          <view class="skeleton-list" v-if="loading && taskListByKey(tab.key).length === 0">
            <view class="skeleton-card" v-for="n in 6" :key="'skt' + n">
              <view class="sk-head">
                <view class="sk-bar" :style="{ background: SKEL_TONES[n % 3] }"></view>
                <view class="sk-lines">
                  <view class="sk-title"></view>
                  <view class="sk-sub"></view>
                </view>
              </view>
              <view class="sk-progress"><view class="sk-progress-inner"></view></view>
              <view class="sk-foot"><view class="sk-dot"></view><view class="sk-dot"></view><view class="sk-chip"></view></view>
            </view>
          </view>
          <view
            class="list"
            :class="{ bounce: bounces[i] }"
            :key="'lst-' + i + '-' + animTick"
            v-else-if="displayedTasks(tab.key).length > 0"
          >
            <view
              v-for="(t, ti) in displayedTasks(tab.key)"
              :key="t.remote_id || t.id"
              :id="'drag-item-' + i + '-' + ti"
              class="drag-item"
              :class="{ dragging: dragActive && dragPageIdx === i && dragIndex === ti, 'fade-up': animOn && current === i }"
              :style="[dragItemStyle(t, ti, i), { animationDelay: animDelay(ti) }]"
              @touchstart="onDragStart($event, t, ti, i)"
              @touchmove="onDragMove"
              @touchend="onDragEnd"
              @touchcancel="onDragEnd"
            >
              <task-card
                :task="t"
                @status-action="statusAction"
                @edit="goTaskEdit"
                @delete="deleteTask"
                @subtask-change="subtaskChange"
              />
            </view>
            <!-- 加载更多（仅已完成/全部） -->
            <view class="load-more" v-if="hasMore(tab.key)" @click="loadMore(tab.key)">
              <text class="load-more-text">{{ loadMoreText(tab.key) }}</text>
            </view>
          </view>
          <view class="empty" v-else>
            <text class="empty-text">{{ emptyTextByKey(tab.key) }}</text>
          </view>
        </scroll-view>
      </swiper-item>'''
if old1 in c:
    c = c.replace(old1, new1, 1); print("tpl ok")
else:
    print("tpl FAIL")

# ========== 2. data 新增字段 ==========
old2 = """      memoKeyword: '',
      deletions: [],"""
new2 = """      memoKeyword: '',
      taskKeyword: '', // 已完成/全部 tab 搜索词
      taskUrgencyFilter: null, // 紧急度筛选（null=全部）
      taskTypeFilter: null, // 类型筛选（null=全部，0个人，1工作）
      pageSize: 10,
      visibleCounts: { 2: 10, all: 10 }, // 各分页 tab 已展开条数
      animTick: 1, // 入场动画重放标志（切 tab 时 +1，重建列表重放动画）
      animOn: true, // 是否启用入场动画
      deletions: [],"""
if old2 in c:
    c = c.replace(old2, new2, 1); print("data ok")
else:
    print("data FAIL")

# ========== 3. emptyTextByKey 更新 + 新增方法 ==========
old3 = """    emptyTextByKey(key) {
      if (key === 'all') return '还没有任务，点右下角 ＋ 记一笔'
      const name = this.tabs.find((t) => t.key === key)
      return name ? '没有' + name.text + '的任务' : ''
    },"""
new3 = """    emptyTextByKey(key) {
      if (key === 'all' || key === 2) {
        const kw = (this.taskKeyword || '').trim()
        if (kw || this.taskUrgencyFilter !== null || this.taskTypeFilter !== null) {
          return '没有找到匹配的任务'
        }
      }
      if (key === 'all') return '还没有任务，点右下角 ＋ 记一笔'
      const name = this.tabs.find((t) => t.key === key)
      return name ? '没有' + name.text + '的任务' : ''
    },
    // 已完成/全部：显示列表（状态 → 搜索 → 筛选 → 分页截断）
    displayedTasks(key) {
      let list = this.taskListByKey(key)
      if (key !== 2 && key !== 'all') return list
      const kw = (this.taskKeyword || '').trim().toLowerCase()
      if (kw) {
        list = list.filter((t) => String(t.title || '').toLowerCase().indexOf(kw) >= 0)
      }
      if (this.taskUrgencyFilter !== null) {
        list = list.filter((t) => (t.urgency || '一般') === this.taskUrgencyFilter)
      }
      if (this.taskTypeFilter !== null) {
        list = list.filter((t) => t.task_type === this.taskTypeFilter)
      }
      return list.slice(0, this.visibleCounts[key] || this.pageSize)
    },
    hasMore(key) {
      if (key !== 2 && key !== 'all') return false
      return this.taskListByKey(key).length > (this.visibleCounts[key] || this.pageSize)
    },
    loadMoreText(key) {
      const total = this.taskListByKey(key).length
      const shown = Math.min(total, this.visibleCounts[key] || this.pageSize)
      const remain = total - shown
      return remain > 0 ? '还有 ' + remain + ' 条，点击加载更多' : '没有更多了'
    },
    loadMore(key) {
      this.visibleCounts[key] = (this.visibleCounts[key] || this.pageSize) + this.pageSize
    },
    setUrgencyFilter(v) {
      this.taskUrgencyFilter = v
    },
    setTypeFilter(v) {
      this.taskTypeFilter = v
    },
    resetTaskFilters() {
      this.taskKeyword = ''
      this.taskUrgencyFilter = null
      this.taskTypeFilter = null
      this.visibleCounts[2] = this.pageSize
      this.visibleCounts.all = this.pageSize
    },
    // 入场动画延迟（最多排队 12 张）
    animDelay(ti) {
      return Math.min(ti, 11) * 60 + 'ms'
    },
    replayAnim() {
      this.animTick++
    },"""
if old3 in c:
    c = c.replace(old3, new3, 1); print("methods ok")
else:
    print("methods FAIL")

# ========== 4. setTab / onSwiperChange 重置 + 重放动画 ==========
old4 = """    // 点击标签：切到对应滑页
    setTab(index) {
      this.current = index
    },
    // 滑动切换：同步高亮
    onSwiperChange(e) {
      this.current = e.detail.current
    },"""
new4 = """    // 点击标签：切到对应滑页（重置搜索/筛选/分页，重放入场动画）
    setTab(index) {
      this.current = index
      this.resetTaskFilters()
      this.replayAnim()
    },
    // 滑动切换：同步高亮（重置搜索/筛选/分页，重放入场动画）
    onSwiperChange(e) {
      this.current = e.detail.current
      this.resetTaskFilters()
      this.replayAnim()
    },"""
if old4 in c:
    c = c.replace(old4, new4, 1); print("tab ok")
else:
    print("tab FAIL")

# ========== 5. 拖拽禁用（已完成/全部分页列表） ==========
old5 = """    onDragStart(e, task, index, pageIdx) {
      if (pageIdx === 4 || this.dragActive) return"""
new5 = """    onDragStart(e, task, index, pageIdx) {
      // 已完成(2)/全部(3)为分页+筛选列表，禁用拖拽避免索引错乱
      if (pageIdx === 4 || pageIdx === 2 || pageIdx === 3 || this.dragActive) return"""
if old5 in c:
    c = c.replace(old5, new5, 1); print("drag ok")
else:
    print("drag FAIL")

# ========== 6. style 新增 ==========
old6 = """.ph {
  color: #9ca3af;
}
.list-scroll {"""
new6 = """.ph {
  color: #9ca3af;
}
.task-search-wrap {
  flex-shrink: 0;
  padding: 16rpx 24rpx 0;
  box-sizing: border-box;
}
.task-search-bar {
  border: 2rpx solid #3b82f6;
  background: #eff6ff;
  border-radius: 24rpx;
  box-shadow: 0 4rpx 12rpx rgba(59, 130, 246, 0.1);
  padding: 0 8rpx;
  box-sizing: border-box;
}
.task-search-input {
  height: 72rpx;
  font-size: 26rpx;
  color: #1e293b;
  padding: 0 16rpx;
}
.task-search-input .ph {
  color: #6b93c9;
}
.filter-row {
  display: flex;
  align-items: center;
  flex-wrap: wrap;
  padding: 12rpx 0 4rpx;
}
.filter-chip {
  font-size: 24rpx;
  color: #6b7280;
  background: #f3f4f6;
  border-radius: 999rpx;
  padding: 6rpx 20rpx;
  margin-right: 10rpx;
  margin-bottom: 8rpx;
}
.filter-chip.on {
  background: #3b82f6;
  color: #ffffff;
  font-weight: 500;
}
.filter-divider {
  color: #d1d5db;
  font-size: 24rpx;
  margin: 0 6rpx;
}
.load-more {
  padding: 20rpx 0 8rpx;
  display: flex;
  justify-content: center;
}
.load-more-text {
  font-size: 24rpx;
  color: #3b82f6;
  border: 1rpx solid #3b82f6;
  border-radius: 999rpx;
  padding: 10rpx 28rpx;
  background: #ffffff;
}
@keyframes fadeUp {
  from {
    opacity: 0;
    transform: translateY(20rpx);
  }
  to {
    opacity: 1;
    transform: translateY(0);
  }
}
.fade-up {
  animation: fadeUp 0.3s ease-out both;
}
.list-scroll {"""
if old6 in c:
    c = c.replace(old6, new6, 1); print("style ok")
else:
    print("style FAIL")

with io.open(p, "w", encoding="utf-8", newline="\n") as f:
    f.write(c)
print("saved")
