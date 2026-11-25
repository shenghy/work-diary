<template>
  <view class="page" :class="themeClass">
    <aurora-bg />
    <!-- 自定义导航：品牌（高度按胶囊位置动态撑开，避免压住筛选行） -->
    <view class="nav-bar" :style="navStyle">
      <view class="nav-brand">
        <view class="brand-dot"></view>
        <text class="brand-title">极简工作日记</text>
      </view>
    </view>

    <!-- 顶部筛选标签：可横向滑动，设置入口常驻最右侧 -->
    <view class="filter-bar">
      <scroll-view
        scroll-x
        class="filter-scroll"
        :show-scrollbar="false"
        :scroll-into-view="filterScrollInto"
        scroll-with-animation
      >
        <view
          v-for="(tab, i) in tabs"
          :key="tab.key"
          :id="'filter-tab-' + tab.key"
          class="filter-tab"
          :class="{ active: current === i }"
          @click="setTab(i)"
        >
          <view class="tab-ico" :class="'ico-tab-' + tab.icon"></view>
          <text>{{ tab.text }}</text>
          <view
            v-if="(tab.key === 0 || tab.key === 1) && counts[tab.key] > 0"
            class="tab-badge"
          >{{ counts[tab.key] }}</view>
        </view>
      </scroll-view>
      <view class="filter-settings" @click="goSettings">⚙︎</view>
    </view>

    <!-- 启动进度：本地缓存已渲染列表，这条细线表示云端同步仍在进行 -->
    <view class="boot-line" v-if="boot.show && !boot.full">
      <view class="boot-line-track">
        <view class="boot-line-fill" :style="{ width: bootFill }"></view>
      </view>
      <text class="boot-line-text">{{ bootText }}</text>
    </view>

    <!-- 滑动内容区：左右滑动切换，与顶部标签联动 -->
    <swiper
      class="content-swiper"
      :current="current"
      :duration="250"
      :disable-touch="dragActive"
      @change="onSwiperChange"
    >
      <swiper-item v-for="(tab, i) in tabs" :key="tab.key">
        <!-- 备忘 -->
        <view class="memo-wrap" v-if="tab.key === 'memo'">
          <view class="memo-tools">
            <view class="search-bar">
              <input
                v-model="memoKeyword"
                class="search-input"
                placeholder="搜索备忘内容"
                placeholder-class="ph"
              />
            </view>
            <view class="export-btn" @click="exportMemos">导出</view>
          </view>
          <scroll-view
            class="list-scroll"
            scroll-y
            refresher-enabled
            :refresher-triggered="refreshing"
            @refresherrefresh="onRefresh"
            @scrolltolower="onLower(i)"
          >
            <!-- 首次加载骨架屏（备忘卡占位） -->
            <view class="skeleton-list" v-if="loading && filteredMemos.length === 0">
              <view class="skeleton-memo" v-for="n in 4" :key="'skm' + n">
                <view class="sk-memo-bar" :style="{ background: SKEL_TONES[n % 3] }"></view>
                <view class="sk-line" :style="{ width: (70 - n * 8) + '%' }"></view>
                <view class="sk-line" style="width: 45%"></view>
              </view>
            </view>
            <view class="list" :class="{ bounce: bounces[i] }" v-else-if="filteredMemos.length > 0">
              <view
                v-for="m in filteredMemos"
                :key="m.remote_id || m.id"
                class="memo-item"
                @click="goMemoEdit(m)"
              >
                <view
                  class="memo-bar"
                  :style="{ background: memoTone[m.remote_id || m.id] || MEMO_TONE_DEFAULT }"
                ></view>
                <mp-html
                  v-if="memoHtml[m.remote_id || m.id]"
                  :content="memoHtml[m.remote_id || m.id]"
                  :tag-style="mdTagStyle"
                />
                <text v-else class="memo-content">{{ m.content }}</text>
                <attachment-strip
                  parent-kind="memo"
                  :parent-local-id="m.id"
                  @changed="onAttachmentChange"
                />
                <text class="memo-time">{{ formatDateTime(m.created_at) }}</text>
              </view>
            </view>
            <view class="empty" v-else>
              <text class="empty-text">{{ memoKeyword ? '没有匹配的备忘' : '还没有备忘，点右下角 ＋ 记一笔' }}</text>
            </view>
          </scroll-view>
        </view>

        <!-- 任务视图：计划中 / 执行中 / 已完成 / 全部 -->
        <scroll-view
          v-else
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
              <text class="filter-chip" :class="{ on: taskUrgencyFilter === 0 }" @click="setUrgencyFilter(0)">一般</text>
              <text class="filter-chip" :class="{ on: taskUrgencyFilter === 2 }" @click="setUrgencyFilter(2)">重要</text>
              <text class="filter-chip" :class="{ on: taskUrgencyFilter === 1 }" @click="setUrgencyFilter(1)">紧急</text>
              <text class="filter-divider">|</text>
              <text class="filter-chip" :class="{ on: taskTypeFilter === null }" @click="setTypeFilter(null)">全部</text>
              <text class="filter-chip" :class="{ on: taskTypeFilter === 1 }" @click="setTypeFilter(1)">工作</text>
              <text class="filter-chip" :class="{ on: taskTypeFilter === 0 }" @click="setTypeFilter(0)">个人</text>
            </view>
          </view>
          <!-- 首次启动且无本地缓存：整屏进度卡（有缓存时列表直接渲染，只留顶部细线） -->
          <view class="boot-card" v-if="boot.full && boot.show">
            <text class="boot-card-title">正在准备你的工作日记</text>
            <view class="boot-card-track">
              <view class="boot-card-fill" :style="{ width: bootFill }"></view>
            </view>
            <text class="boot-card-step">{{ bootText }}</text>
            <text class="boot-card-tip">首次同步需要几秒，完成后自动显示任务</text>
          </view>
          <!-- 首次加载骨架屏：云端拉取期间，空列表不白屏 -->
          <view class="skeleton-list" v-else-if="loading && taskListByKey(tab.key).length === 0">
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
                @back-to-planned="backToPlanned"
                @edit="goTaskEdit"
                @delete="deleteTask"
                @subtask-change="subtaskChange"
                @attachment-change="onAttachmentChange"
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
      </swiper-item>
    </swiper>

    <!-- 状态流转飞球（对齐桌面端 _FlyingBall）：卡片中心生成，300ms 抛物线飞入目标标签 -->
    <view v-if="ball.show" class="fly-ball" :class="ball.u" :style="ball.outerStyle">
      <view class="fly-ball-inner" :class="{ fly: ball.fly }"></view>
    </view>

    <!-- 新建按钮（对齐桌面端 FloatingActionButton：圆角方形 + 细加号） -->
    <view class="fab" @click="goCreate">
      <text class="fab-plus">+</text>
    </view>

    <!-- 功能菜单按钮（左下角，对齐桌面端主菜单） -->
    <view class="side-fab" @click="toggleSideMenu">
      <text class="side-fab-icon">☰</text>
    </view>

    <!-- 功能菜单弹层：云端同步 / 我的数据 / 循环任务 / 个人中心 -->
    <view class="mask" v-if="showSideMenu" @click="closeSideMenu">
      <view class="create-menu" @click.stop>
        <view class="menu-title">功能</view>
        <view class="menu-sub">更多操作</view>
        <view class="menu-option side-option" @click="menuCloudSync">
          <view class="opt-icon side-icon"><text>⟳</text></view>
          <view class="opt-body">
            <view class="opt-title">云端同步</view>
            <view class="opt-desc">手动拉取最新数据</view>
          </view>
        </view>
        <view class="menu-option side-option" @click="menuStats">
          <view class="opt-icon side-icon"><text>▥</text></view>
          <view class="opt-body">
            <view class="opt-title">我的数据</view>
            <view class="opt-desc">趋势、热力图与完成率</view>
          </view>
        </view>
        <view class="menu-option side-option" @click="menuRepeat">
          <view class="opt-icon side-icon"><text>↻</text></view>
          <view class="opt-body">
            <view class="opt-title">循环任务</view>
            <view class="opt-desc">管理规则、停止与恢复</view>
          </view>
        </view>
        <view class="menu-option side-option" @click="menuMine">
          <view class="opt-icon side-icon"><text>☺</text></view>
          <view class="opt-body">
            <view class="opt-title">个人中心</view>
            <view class="opt-desc">账号信息、退出登录</view>
          </view>
        </view>
        <view class="menu-cancel" @click="closeSideMenu">取消</view>
      </view>
    </view>

    <!-- 新建选择弹窗（与桌面端一致） -->
    <view class="mask" v-if="showCreateMenu" @click="closeCreateMenu">
      <view class="create-menu" @click.stop>
        <view class="menu-title">新建</view>
        <view class="menu-sub">选择一个类型</view>
        <view class="menu-option task-option" @click="createTask">
          <view class="opt-icon">
            <view class="icon-task"></view>
          </view>
          <view class="opt-body">
            <view class="opt-title">新建任务</view>
            <view class="opt-desc">带状态、紧急度、计划时间</view>
          </view>
        </view>
        <view class="menu-option memo-option" @click="createMemo">
          <view class="opt-icon">
            <view class="icon-memo"></view>
          </view>
          <view class="opt-body">
            <view class="opt-title">新建备忘</view>
            <view class="opt-desc">纯记录，支持搜索</view>
          </view>
        </view>
        <view class="menu-cancel" @click="closeCreateMenu">取消</view>
      </view>
    </view>
  </view>
</template>

<script>
import AuroraBg from '../../components/aurora-bg.vue'
import TaskCard from '../../components/task-card.vue'
import AttachmentStrip from '../../components/attachment-strip.vue'
import mpHtml from 'mp-html/dist/uni-app/components/mp-html/mp-html'
import { isLoggedIn } from '../../utils/auth'
import { isMarkdown, renderMarkdown } from '../../utils/markdown'
import {
  loadTasksCache,
  saveTasksCache,
  loadTasksDeletions,
  saveTasksDeletions,
  loadMemosCache,
  saveMemosCache,
  loadRepeatRules,
  loadRepeatSkips,
  skipRepeatInstance,
  stopRepeatGroup
} from '../../utils/storage'
import { syncTasks, syncMemos, syncAttachments, createSyncer, normalizeLocalIds } from '../../utils/sync'
import * as attachmentSync from '../../utils/attachment_sync'
import { generateMissing } from '../../utils/repeat'
import { connectWS, setOnDataChanged, setOnAttachmentPush } from '../../utils/ws'
import { showToast, formatDateTime as formatDateTimeUtil } from '../../utils/util'
import {
  computeTargetIndex,
  computeOffsets,
  moveItem,
  rebuildSortOrder
} from '../../utils/drag-sort'

export default {
  components: { AuroraBg, TaskCard, AttachmentStrip, mpHtml },
  data() {
    return {
      current: 0,
      // 自定义导航高度：按胶囊底部动态计算，保证筛选行始终在胶囊下方
      navStyle: '',
      refreshing: false,
      // 首次加载骨架屏：初始 true，首次云端同步完成后置 false（本地有缓存时列表直接渲染，不闪骨架）
      loading: true,
      // 启动进度：full=false 走顶部细线，full=true（无本地缓存）走整屏进度卡
      boot: { show: false, full: false, percent: 0, target: 0, label: '' },
      bootDone: false,
      bootTickTimer: null,
      bootWatchTimer: null,
      // 骨架屏色条取色（红/黄/蓝，与备忘细条一致）
      SKEL_TONES: ['#EF4444', '#EAB308', '#3B82F6'],
      bounces: [false, false, false, false, false],
      showCreateMenu: false,
      showSideMenu: false,
      // 备忘 Markdown 渲染：key=备忘id → HTML（memos 数组保持纯净，不同步脏字段）
      memoHtml: {},
      // 备忘顶部细条颜色：key=备忘id → 六色渐变（按内容哈希取色，对齐桌面端备忘录 6 色调）
      memoTone: {},
      MEMO_TONE_DEFAULT: 'linear-gradient(90deg, #3B82F6, #93C5FD)',
      mdTagStyle: {
        p: 'margin:0 0 8rpx;font-size:28rpx;color:var(--text-secondary);line-height:1.7;',
        h1: 'margin:12rpx 0 8rpx;font-size:36rpx;font-weight:bold;color:var(--text-primary);',
        h2: 'margin:12rpx 0 8rpx;font-size:33rpx;font-weight:bold;color:var(--text-primary);',
        h3: 'margin:10rpx 0 6rpx;font-size:31rpx;font-weight:600;color:var(--text-primary);',
        h4: 'margin:10rpx 0 6rpx;font-size:31rpx;font-weight:600;color:var(--text-primary);',
        ul: 'margin:0 0 8rpx;padding-left:36rpx;',
        ol: 'margin:0 0 8rpx;padding-left:36rpx;',
        li: 'font-size:28rpx;color:var(--text-secondary);line-height:1.7;',
        code: 'font-size:24rpx;background:none;color:var(--text-tertiary);padding:0;border-radius:0;',
        pre: 'background:var(--code-bg);border-radius:8rpx;padding:12rpx 16rpx;margin:0 0 10rpx;line-height:1.45;',
        blockquote: 'margin:0 0 8rpx;padding:0 16rpx;color:var(--text-secondary);background:var(--chip-bg);border-left:6rpx solid var(--card-border);',
        a: 'color:var(--accent);'
      },
      dragActive: false,
      dragPageIdx: -1,
      dragIndex: -1,
      dragId: null,
      dragDy: 0,
      dragItemHeight: 120,
      dragTimer: null,
      dragStartY: 0,
      dragCandidate: null,
      // 本地修改保护窗口：对齐桌面端 _ignoreWsSyncUntil（本地刚改，5 秒内忽略后台拉取，避免覆盖刚保存的顺序/内容）
      ignoreWsUntil: 0,
      tabs: [
        { key: 0, text: '计划中', icon: 'planned' },
        { key: 1, text: '执行中', icon: 'exec' },
        { key: 'memo', text: '备忘', icon: 'memo' },
        { key: 2, text: '已完成', icon: 'done' },
        { key: 'all', text: '全部', icon: 'all' }
      ],
      tasks: [],
      memos: [],
      memoKeyword: '',
      taskKeyword: '', // 已完成/全部 tab 搜索词
      taskUrgencyFilter: null, // 紧急度筛选（null=全部）
      taskTypeFilter: null, // 类型筛选（null=全部，0个人，1工作）
      pageSize: 10,
      visibleCounts: { 2: 10, all: 10 }, // 各分页 tab 已展开条数
      animTick: 1, // 入场动画重放标志（切 tab 时 +1，重建列表重放动画）
      animOn: true, // 是否启用入场动画
      // 飞球槽位：单球，新飞行顶替旧的；outerStyle 承载起点与平移量
      ball: { show: false, fly: false, u: 'u-normal', outerStyle: '' },
      filterScrollInto: '',
      ballFlyTimer: null,
      ballEndTimer: null,
      ballScrollTimer: null,
      deletions: [],
      syncer: null,
      memoSyncer: null,
      attachmentSyncer: null,
      pollTimer: null
    }
  },
  computed: {
    taskTabs() {
      return this.tabs.filter((t) => t.key !== 'memo')
    },
    counts() {
      const c = { 0: 0, 1: 0, 2: 0 }
      this.tasks.forEach((t) => {
        if (c[t.status] !== undefined) c[t.status]++
      })
      return c
    },
    filteredMemos() {
      const kw = this.memoKeyword.trim().toLowerCase()
      if (!kw) return this.memos
      return this.memos.filter((m) => m.content.toLowerCase().indexOf(kw) >= 0)
    },
    bootFill() {
      return Math.round(this.boot.percent) + '%'
    },
    bootText() {
      return this.boot.label + ' ' + Math.round(this.boot.percent) + '%'
    }
  },
  onShow() {
    if (!isLoggedIn()) {
      uni.reLaunch({ url: '/pages/login/login' })
      return
    }
    // 只有首次进入走启动进度；之后回到本页只做静默同步
    const firstBoot = !this.bootDone
    if (firstBoot) this.startBoot()
    // 清洗存量负 id 数据（历史版本遗留，导致同步失败；幂等，正常数据不受影响）
    normalizeLocalIds()
    this.tasks = loadTasksCache()
    this.memos = loadMemosCache()
    this.refreshMemoHtml()
    this.deletions = loadTasksDeletions()
    if (firstBoot) {
      // 本地完全没有数据才升级为整屏进度卡，否则列表已渲染，只留顶部细线
      this.boot.full = this.tasks.length === 0 && this.memos.length === 0
      this.bootStep(22, '正在补齐循环任务')
    }
    // 循环任务自动补生成（日/周/月）
    this.materializeRepeat()
    if (firstBoot) this.bootStep(35, '正在同步云端任务')
    this.pullCloud()
    // 确保 WebSocket 已连接（App 回前台时也会重连，此处兜底）
    connectWS()
    // 60s 轮询保底：WebSocket 静默失效时也能拉到其他端的修改
    if (this.pollTimer) clearInterval(this.pollTimer)
    this.pollTimer = setInterval(() => this.pullCloud(true), 60000)
  },
  onHide() {
    if (this.pollTimer) {
      clearInterval(this.pollTimer)
      this.pollTimer = null
    }
    this.clearBootTimers()
    this.clearBallTimers()
    this.ball = { ...this.ball, show: false, fly: false }
  },
  onUnload() {
    if (this.pollTimer) {
      clearInterval(this.pollTimer)
      this.pollTimer = null
    }
    this.clearBootTimers()
    this.clearBallTimers()
  },
  mounted() {
    this.applyNavMetrics()
    this.syncer = createSyncer(() => this.doFullSync())
    this.memoSyncer = createSyncer(() => this.doMemoSync())
    this.attachmentSyncer = createSyncer(() => this.doAttachmentSync())
    // 收到服务端 data_changed 推送（桌面端等设备修改后触发）→ 静默拉取全量
    setOnDataChanged(() => this.pullCloud(true))
    // 附件中转推送：谁有原件谁上传、谁的请求已备齐谁下载
    setOnAttachmentPush((msg) => {
      attachmentSync.handlePush(msg)
    })
  },
  methods: {
    // 胶囊（右上角 ··· ⊙）会盖住紧贴状态栏的自定义导航，这里按胶囊底部撑高导航区
    applyNavMetrics() {
      let statusBar = 20
      let menuBottom = 64
      try {
        const win =
          typeof wx !== 'undefined' && wx.getWindowInfo
            ? wx.getWindowInfo()
            : uni.getSystemInfoSync()
        if (win && win.statusBarHeight) statusBar = win.statusBarHeight
        menuBottom = statusBar + 44
      } catch (e) {}
      try {
        const rect = uni.getMenuButtonBoundingClientRect()
        if (rect && rect.bottom) menuBottom = rect.bottom
      } catch (e) {}
      this.navStyle = `height:${menuBottom + 8}px;padding-top:${statusBar}px;`
    },
    // 模板使用的时间格式化（包装 util 函数，供模板直接调用）
    formatDateTime(iso) {
      return formatDateTimeUtil(iso)
    },
    // 当前滑页对应标签
    currentTab() {
      return this.tabs[this.current] || this.tabs[0]
    },
    // 点击标签：切到对应滑页（重置搜索/筛选/分页，重放入场动画）
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
    },
    // 各任务滑页的列表（按 sort_order 排序；拖拽排序依赖此顺序）
    taskListByKey(key) {
      const sorted = [...this.tasks].sort((a, b) => {
        const sa = a.sort_order ?? 0
        const sb = b.sort_order ?? 0
        if (sa !== sb) return sa - sb
        return new Date(b.created_at) - new Date(a.created_at)
      })
      if (key === 'all') return sorted
      return sorted.filter((t) => t.status === key)
    },
    emptyTextByKey(key) {
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
        // urgency 为数字：0=一般 1=紧急 2=重要（旧数据缺失时按 0 一般处理）
        list = list.filter((t) => (t.urgency === undefined || t.urgency === null ? 0 : t.urgency) === this.taskUrgencyFilter)
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
    },
    // ---- 拖拽排序（长按 300ms 激活） ----
    onDragStart(e, task, index, pageIdx) {
      // 已完成(2)/全部(3)为分页+筛选列表，禁用拖拽避免索引错乱
      if (pageIdx === 4 || pageIdx === 2 || pageIdx === 3 || this.dragActive) return
      const touch = e.touches[0]
      if (!touch) return
      this.dragStartY = touch.clientY
      this.dragCandidate = { pageIdx: pageIdx, index: index, id: task.remote_id || task.id }
      clearTimeout(this.dragTimer)
      this.dragTimer = setTimeout(() => {
        const c = this.dragCandidate
        if (!c) return
        // 测量卡片实际高度，用于让位计算
        const query = uni.createSelectorQuery().in(this)
        query
          .select('#drag-item-' + c.pageIdx + '-' + c.index)
          .boundingClientRect((rect) => {
            if (rect && rect.height > 0) this.dragItemHeight = rect.height
          })
          .exec()
        this.dragActive = true
        this.dragPageIdx = c.pageIdx
        this.dragIndex = c.index
        this.dragId = c.id
        this.dragDy = 0
      }, 300)
    },
    onDragMove(e) {
      if (this.dragActive) {
        const touch = e.touches[0]
        if (!touch) return
        this.dragDy = touch.clientY - this.dragStartY
        return
      }
      // 未激活：位移超过阈值判定为滚动/下拉意图，取消长按，避免误触发拖拽
      const touch = e.touches[0]
      if (!touch || !this.dragCandidate) return
      if (Math.abs(touch.clientY - this.dragStartY) > 10) {
        clearTimeout(this.dragTimer)
        this.dragTimer = null
        this.dragCandidate = null
      }
    },
    onDragEnd() {
      clearTimeout(this.dragTimer)
      this.dragTimer = null
      const wasActive = this.dragActive
      const pageIdx = this.dragPageIdx
      const fromIndex = this.dragIndex
      const dy = this.dragDy
      this.dragCandidate = null
      this.resetDrag()
      if (!wasActive || pageIdx < 0 || fromIndex < 0) return
      const key = this.tabs[pageIdx] ? this.tabs[pageIdx].key : 'all'
      const viewTasks = this.taskListByKey(key)
      if (!viewTasks.length) return
      const toIndex = computeTargetIndex(fromIndex, dy, this.dragItemHeight || 1, viewTasks.length)
      const newView = toIndex !== fromIndex ? moveItem(viewTasks, fromIndex, toIndex) : viewTasks
      const rebuilt = rebuildSortOrder(this.tasks, key, newView)
      const changed =
        rebuilt.length !== this.tasks.length ||
        rebuilt.some((t, i) => {
          const old = this.tasks[i]
          return (
            !old ||
            (old.remote_id || old.id) !== (t.remote_id || t.id) ||
            (old.sort_order ?? -1) !== (t.sort_order ?? -1)
          )
        })
      if (changed) {
        this.tasks = rebuilt
        this.persistTasks()
        // 立即推送排序到云端，避免自动同步（60s 轮询/WS）拉回旧顺序覆盖本地
        this.pushSortOrder()
      }
    },
    // 拖拽排序后立即推送；失败静默，后续轮询/下拉刷新会补推
    async pushSortOrder() {
      try {
        const cloud = await syncTasks(this.tasks, this.deletions)
        if (cloud) {
          this.tasks = cloud
          this.deletions = loadTasksDeletions()
        }
      } catch (e) {
        // 静默失败：不打断拖拽操作，等待下一次同步机会
      }
    },
    resetDrag() {
      this.dragActive = false
      this.dragPageIdx = -1
      this.dragIndex = -1
      this.dragId = null
      this.dragDy = 0
    },
    // 拖拽中目标索引（供其他卡片让位）
    currentDragTarget() {
      const key = this.tabs[this.dragPageIdx] ? this.tabs[this.dragPageIdx].key : 'all'
      const len = this.taskListByKey(key).length
      return computeTargetIndex(this.dragIndex, this.dragDy, this.dragItemHeight || 1, len)
    },
    // 拖拽中每张卡片的样式：被拖卡片跟随手指，其余卡片平滑让位
    dragItemStyle(task, index, pageIdx) {
      if (!this.dragActive || this.dragPageIdx !== pageIdx) return ''
      if (this.dragIndex === index) {
        return 'transform: translateY(' + this.dragDy + 'px) scale(1.03); z-index: 10; transition: none;'
      }
      if (this.dragId === (task.remote_id || task.id)) return ''
      const off = computeOffsets(this.dragIndex, this.currentDragTarget(), this.dragItemHeight).get(index)
      if (off) {
        return 'transform: translateY(' + off + 'px); transition: transform 0.2s ease;'
      }
      return ''
    },
    // 触底反弹：列表滑到底时内容区做一次下拉-回弹动画（防重入）
    onLower(index) {
      if (this.bounces[index]) return
      this.bounces = this.bounces.map((b, i) => (i === index ? true : b))
      setTimeout(() => {
        this.bounces = this.bounces.map((b, i) => (i === index ? false : b))
      }, 450)
    },
    // 重新计算备忘的 Markdown HTML 缓存（memos 变化后调用）
    refreshMemoHtml() {
      const map = {}
      const tones = {}
      this.memos.forEach((m) => {
        const key = m.remote_id || m.id
        if (key == null) return
        if (isMarkdown(m.content)) {
          map[key] = renderMarkdown(m.content)
        }
        tones[key] = this.memoToneFor(m.content)
      })
      this.memoHtml = map
      this.memoTone = tones
    },
    // 备忘顶部细条取色：与桌面端 6 种备忘色调一致（字符串哈希 → 稳定取色）
    memoToneFor(content) {
      let h = 0
      const s = String(content || '')
      for (let i = 0; i < s.length; i++) {
        h = (h * 31 + s.charCodeAt(i)) & 0x7fffffff
      }
      const tones = [
        'linear-gradient(90deg, #3B82F6, #93C5FD)', // 蓝
        'linear-gradient(90deg, #8B5CF6, #C4B5FD)', // 紫
        'linear-gradient(90deg, #10B981, #6EE7B7)', // 绿
        'linear-gradient(90deg, #F59E0B, #FCD34D)', // 橙
        'linear-gradient(90deg, #EF4444, #FCA5A5)', // 红
        'linear-gradient(90deg, #06B6D4, #67E8F9)' // 青
      ]
      return tones[h % tones.length]
    },
    // 循环任务自动补生成：生成缺失实例并静默推送云端（幂等，服务端唯一索引去重）
    materializeRepeat() {
      try {
        const missing = generateMissing(this.tasks, loadRepeatRules(), new Date(), loadRepeatSkips())
        if (!missing.length) return
        this.tasks = [...missing, ...this.tasks]
        this.persistTasks()
      } catch (e) {
        // 静默失败：不影响主流程，下次进入/同步时重试
      }
    },
    // ---------------- 启动进度 ----------------
    startBoot() {
      this.boot.show = true
      this.boot.full = false
      this.boot.percent = 0
      this.boot.target = 12
      this.boot.label = '正在读取本地数据'
      this.clearBootTimers()
      // 网络请求没有真实进度，用「向目标值逼近」让条形匀速前进而不会假死
      this.bootTickTimer = setInterval(() => {
        const gap = this.boot.target - this.boot.percent
        if (gap <= 0) return
        // 最后一点直接贴到目标，避免条形永远差一截停在原地
        this.boot.percent =
          gap <= 0.6 ? this.boot.target : Math.min(this.boot.target, this.boot.percent + Math.max(0.6, gap * 0.12))
      }, 80)
      // 6 秒兜底：先落到本地数据，云端同步继续在后台跑，不让用户等一条不结束的进度条
      this.bootWatchTimer = setTimeout(() => {
        this.finishBoot('网络较慢，已先用本地数据')
      }, 6000)
    },
    bootStep(target, label) {
      if (!this.boot.show) return
      if (target > this.boot.target) this.boot.target = target
      if (label) this.boot.label = label
    },
    finishBoot(label) {
      if (this.bootDone) return
      this.bootDone = true
      this.loading = false
      if (this.boot.show) {
        this.boot.percent = 100
        if (label) this.boot.label = label
        setTimeout(() => {
          this.boot.show = false
        }, 350)
      }
      this.clearBootTimers()
    },
    clearBootTimers() {
      if (this.bootTickTimer) {
        clearInterval(this.bootTickTimer)
        this.bootTickTimer = null
      }
      if (this.bootWatchTimer) {
        clearTimeout(this.bootWatchTimer)
        this.bootWatchTimer = null
      }
    },
    // 下拉刷新（各滑页共用）
    async onRefresh() {
      this.refreshing = true
      await this.pullCloud()
      this.refreshing = false
    },
    // silent=true：后台轮询/WS 推送触发，失败不打扰用户（下次自动重试）
    async pullCloud(silent) {
      if (!isLoggedIn()) return false
      // 本地刚修改（拖拽排序/状态切换/子任务/删除）的保护窗口内：静默拉取直接跳过，避免覆盖刚保存的数据
      if (silent && Date.now() < this.ignoreWsUntil) return true
      let ok = true
      // 拖拽进行中：跳过任务拉取，避免云端旧顺序覆盖导致正在拖动的卡片回弹
      if (!this.dragActive) {
        try {
          this.bootStep(78, '正在同步云端任务')
          const cloud = await syncTasks(this.tasks, this.deletions)
          if (cloud) {
            this.tasks = cloud
            // 删除记录由 syncTasks 统一收尾（已上云的清除、待匹配的从云端补 remote_id）
            this.deletions = loadTasksDeletions()
            // 云端可能新增循环任务模板，拉取后补生成缺失实例
            this.materializeRepeat()
          }
        } catch (e) {
          ok = false
          if (!silent) showToast('同步失败：' + e.message)
        }
      }
      try {
        this.bootStep(92, '正在同步备忘')
        const memos = await syncMemos(this.memos, [])
        if (memos) {
          this.memos = memos
          this.refreshMemoHtml()
        }
      } catch (e) {
        ok = false
      }
      // 附件元数据必须排在任务/备忘之后：服务器按父记录是否已入库决定收不收，
      // 早报只会拿到 rejected，再把云端问题误报成"这个文件有问题"。
      try {
        this.bootStep(96, '正在同步附件')
        await this.doAttachmentSync(silent)
      } catch (e) {
        ok = false
      }
      this.finishBoot()
      // 首次加载结束（无论成功/失败）：关闭骨架屏，落到真实列表或空状态
      if (this.loading) this.loading = false
      return ok
    },
    async doFullSync() {
      const cloud = await syncTasks(this.tasks, this.deletions)
      if (cloud) {
        this.tasks = cloud
        this.deletions = loadTasksDeletions()
      }
    },
    async doMemoSync() {
      const cloud = await syncMemos(this.memos, [])
      if (cloud) {
        this.memos = cloud
        this.refreshMemoHtml()
      }
    },
    // 附件元数据对账。silent（轮询/推送）时不拿"未同步"打扰用户：
    // 绝大多数拒收只是父记录还没上云，下一轮自己就好；手动同步时才需要如实告知。
    async doAttachmentSync(silent) {
      const summary = await syncAttachments()
      const rejected = (summary && summary.rejectedNames) || []
      if (!rejected.length || silent) return
      const names = rejected.slice(0, 3).join('、')
      const more = rejected.length > 3 ? ' 等 ' + rejected.length + ' 个文件' : ''
      showToast('附件未同步：' + names + more)
    },
    // 卡片上删了附件：墓碑要尽快上云，否则另一台机器还以为文件还在
    onAttachmentChange() {
      if (this.attachmentSyncer) this.attachmentSyncer()
    },
    persistTasks() {
      saveTasksCache(this.tasks)
      saveTasksDeletions(this.deletions)
      // 本地数据刚变更：开启 5 秒保护窗口，忽略后台（WS/轮询）拉取，防止云端旧数据覆盖
      this.ignoreWsUntil = Date.now() + 5000
      if (this.syncer) this.syncer()
    },
    persistMemos() {
      saveMemosCache(this.memos)
      if (this.memoSyncer) this.memoSyncer()
    },
    // 点击加号：弹出新建选择菜单（与桌面端一致）
    goCreate() {
      this.showCreateMenu = true
    },
    closeCreateMenu() {
      this.showCreateMenu = false
    },
    // ---- 功能菜单（左下角，对齐桌面端主菜单；截图任务不制作） ----
    toggleSideMenu() {
      this.showSideMenu = true
    },
    closeSideMenu() {
      this.showSideMenu = false
    },
    async menuCloudSync() {
      this.showSideMenu = false
      uni.showLoading({ title: '同步中', mask: true })
      const ok = await this.pullCloud()
      uni.hideLoading()
      if (ok) showToast('同步完成', 'success')
    },
    menuStats() {
      this.showSideMenu = false
      uni.navigateTo({ url: '/pkgData/stats/stats' })
    },
    menuRepeat() {
      this.showSideMenu = false
      uni.navigateTo({ url: '/pkgMine/repeat-manager/repeat-manager' })
    },
    menuMine() {
      this.showSideMenu = false
      uni.navigateTo({ url: '/pkgMine/mine/mine' })
    },
    goSettings() {
      uni.navigateTo({ url: '/pkgMine/settings/settings' })
    },
    // 导出全部备忘为 Markdown 文件（对齐桌面端导出入口）
    exportMemos() {
      if (!this.memos.length) {
        showToast('暂无备忘可导出')
        return
      }
      const lines = ['# 极简工作日记 · 备忘导出', '']
      this.memos.forEach((m) => {
        lines.push('## ' + formatDateTimeUtil(m.created_at))
        lines.push('')
        lines.push(m.content || '')
        lines.push('')
      })
      const now = new Date()
      const two = (n) => String(n).padStart(2, '0')
      const name =
        '备忘导出_' +
        now.getFullYear() +
        two(now.getMonth() + 1) +
        two(now.getDate()) +
        '_' +
        two(now.getHours()) +
        two(now.getMinutes()) +
        '.md'
      const content = lines.join('\n')
      try {
        const fs = wx.getFileSystemManager()
        const path = wx.env.USER_DATA_PATH + '/' + name
        fs.writeFileSync(path, content, 'utf8')
        wx.shareFileMessage({
          filePath: path,
          fileName: name,
          success: () => showToast('已导出', 'success'),
          fail: () => showToast('导出已取消')
        })
      } catch (e) {
        // 基础库不支持分享文件时，退化为复制内容
        uni.setClipboardData({
          data: content,
          success: () => showToast('已复制 Markdown 内容', 'success')
        })
      }
    },
    createTask() {
      this.showCreateMenu = false
      uni.navigateTo({ url: '/pkgEdit/task-edit/task-edit' })
    },
    createMemo() {
      this.showCreateMenu = false
      uni.navigateTo({ url: '/pkgEdit/memo-edit/memo-edit' })
    },
    goTaskEdit(task) {
      uni.navigateTo({
        url: '/pkgEdit/task-edit/task-edit?id=' + (task.remote_id || task.id)
      })
    },
    goMemoEdit(memo) {
      uni.navigateTo({
        url: '/pkgEdit/memo-edit/memo-edit?id=' + (memo.remote_id || memo.id)
      })
    },
    // 状态流转：开始 / 完成 / 重开（桌面端按钮逻辑）+ 飞球动画
    statusAction(task) {
      this.changeStatus(task)
    },
    // 执行中退回计划中：桌面端「回到计划中」同一口径，清掉开始/完成时间
    backToPlanned(task) {
      this.changeStatus(task, 0)
    },
    changeStatus(task, to) {
      const target = typeof to === 'number' ? to : task.status === 1 ? 2 : 1
      const targetKey = target
      const key = this.tabs[this.current] ? this.tabs[this.current].key : 'all'
      const idx = this.displayedTasks(key).findIndex(
        (t) => (t.remote_id || t.id) === (task.remote_id || task.id)
      )
      if (!this.animOn || idx < 0) {
        this.applyStatus(task, target)
        return
      }
      const cardSel = '#drag-item-' + this.current + '-' + idx
      const tabSel = '#filter-tab-' + targetKey
      uni
        .createSelectorQuery()
        .in(this)
        .select(cardSel)
        .boundingClientRect()
        .select(tabSel)
        .boundingClientRect()
        .select('.filter-scroll')
        .boundingClientRect()
        .exec((res) => {
          const cardRect = res && res[0]
          const tabRect = res && res[1]
          const barRect = res && res[2]
          // 量不到位置时直接切换（桌面端同款兜底）
          if (!cardRect || !tabRect || !barRect) {
            this.applyStatus(task, target)
            return
          }
          const offscreen = tabRect.left < barRect.left || tabRect.right > barRect.right
          if (!offscreen) {
            this.launchBall(task, cardRect, tabRect, target)
            return
          }
          // 窄屏落点标签露不出来：先滚进可视区再复量落点
          this.filterScrollInto = 'filter-tab-' + targetKey
          clearTimeout(this.ballScrollTimer)
          this.ballScrollTimer = setTimeout(() => {
            this.filterScrollInto = ''
            uni
              .createSelectorQuery()
              .in(this)
              .select(tabSel)
              .boundingClientRect()
              .exec((r2) => {
                if (r2 && r2[0]) this.launchBall(task, cardRect, r2[0], target)
                else this.applyStatus(task, target)
              })
          }, 260)
        })
    },
    // 生成小球并立即切换列表（小球独立播放，不受列表刷新影响）
    launchBall(task, cardRect, tabRect, target) {
      const sx = cardRect.left + cardRect.width / 2
      const sy = cardRect.top + cardRect.height / 2
      const ex = tabRect.left + tabRect.width / 2
      const ey = tabRect.top + tabRect.height / 2
      const u = Number(task.urgency)
      const base = 'left:' + (sx - 14) + 'px;top:' + (sy - 14) + 'px;'
      this.clearBallTimers()
      this.ball = {
        show: true,
        fly: false,
        u: u === 1 ? 'u-urgent' : u === 2 ? 'u-important' : 'u-normal',
        outerStyle: base + 'transform:translate(0,0);'
      }
      this.applyStatus(task, target)
      // 起点样式先落一帧，再触发 transition 与内层抛物线 keyframes
      this.ballFlyTimer = setTimeout(() => {
        this.ball = {
          ...this.ball,
          fly: true,
          outerStyle: base + 'transform:translate(' + (ex - sx) + 'px,' + (ey - sy) + 'px);'
        }
      }, 20)
      this.ballEndTimer = setTimeout(() => {
        this.ball = { ...this.ball, show: false, fly: false }
      }, 340)
    },
    clearBallTimers() {
      clearTimeout(this.ballFlyTimer)
      clearTimeout(this.ballEndTimer)
      clearTimeout(this.ballScrollTimer)
      this.ballFlyTimer = null
      this.ballEndTimer = null
      this.ballScrollTimer = null
    },
    applyStatus(task, to) {
      const now = new Date().toISOString()
      const target = typeof to === 'number' ? to : task.status === 1 ? 2 : 1
      const updated = { ...task, status: target, updated_at: now }
      if (target === 0) {
        // 退回计划中：开始/完成时间一并清掉（桌面端 clearStartedAt/clearCompletedAt）
        updated.started_at = null
        updated.completed_at = null
      } else if (target === 1) {
        // 计划中/已完成 → 执行中
        updated.started_at = now
        updated.completed_at = null
      } else {
        // 执行中 → 已完成
        updated.completed_at = now
      }
      this.replaceTask(updated)
    },
    // 子任务勾选
    subtaskChange(updated) {
      this.replaceTask(updated)
    },
    replaceTask(updated) {
      const idx = this.tasks.findIndex((t) => (t.remote_id || t.id) === (updated.remote_id || updated.id))
      const list = [...this.tasks]
      if (idx >= 0) list[idx] = updated
      else list.unshift(updated)
      this.tasks = list
      this.persistTasks()
    },
    // 删除任务：循环任务提供「仅删除本期 / 停止循环并删除」两档（彻底取消循环）
    deleteTask(task) {
      const doDelete = (stopRepeat) => {
        if (task.repeat_type > 0 && task.repeat_group_id) {
          if (stopRepeat) {
            // 停止循环：规则 stopped（随同步下发）+ 本地 STOP 哨兵兜底；
            // 同族其它期次保留，只是不再产生新一期
            stopRepeatGroup(task.repeat_group_id)
          } else if (task.instance_date) {
            // 仅删除本期：写跳过账本，避免下一次补生成又把它补回来
            skipRepeatInstance(task)
          }
        }
        const deletions = [...this.deletions]
        deletions.push({
          local_id: task.id,
          remote_id: task.remote_id,
          deleted_at: new Date().toISOString()
        })
        this.deletions = deletions
        this.tasks = this.tasks.filter((t) => (t.remote_id || t.id) !== (task.remote_id || task.id))
        // 附件跟着任务走：记录标孤儿、不再上报，原件留着；截图任务的图片当场删掉
        attachmentSync.onParentDeleted('task', task.id)
        // 停止/跳过状态已在上面写入本地账本
        this.persistTasks()
        showToast('已删除', 'success')
      }
      if (task.repeat_type > 0) {
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
        content: '确定要删除这个任务吗？删除后不可恢复。',
        confirmColor: '#EF4444',
        success: (res) => {
          if (res.confirm) doDelete(false)
        }
      })
    }
  }
}
</script>

<style lang="scss" scoped>
.page {
  height: 100vh;
  display: flex;
  flex-direction: column;
  background: transparent;
  overflow: hidden;
  box-sizing: border-box;
}
.filter-bar {
  padding: 20rpx 24rpx 4rpx;
  flex-shrink: 0;
  display: flex;
  align-items: center;
  gap: 12rpx;
}
.filter-scroll {
  flex: 1;
  min-width: 0;
  white-space: nowrap;
}
.filter-settings {
  flex-shrink: 0;
  width: 64rpx;
  height: 64rpx;
  border-radius: 12rpx;
  margin-top: 12rpx;
  display: flex;
  align-items: center;
  justify-content: center;
  font-size: 32rpx;
  color: var(--text-secondary);
  background: var(--float-bg);
  border: 1rpx solid var(--float-border);
  -webkit-backdrop-filter: blur(20rpx);
  backdrop-filter: blur(20rpx);
  box-shadow: inset 0 1rpx 0 var(--glass-topline);
}
.filter-settings:active {
  background: var(--accent-soft);
  color: var(--accent);
}
/* 状态胶囊：顶部留 12rpx 给右上角徽标，避免被 scroll-view 裁掉 */
.filter-tab {
  position: relative;
  display: inline-flex;
  align-items: center;
  justify-content: center;
  gap: 8rpx;
  height: 64rpx;
  padding: 0 24rpx;
  box-sizing: border-box;
  margin: 12rpx 16rpx 0 0;
  border-radius: 32rpx;
  font-size: 26rpx;
  color: var(--text-secondary);
  transition: background 0.16s ease-out, border-color 0.16s ease-out,
    color 0.16s ease-out, box-shadow 0.16s ease-out;
}
.tab-ico {
  flex: none;
  width: 28rpx;
  height: 28rpx;
  color: var(--text-tertiary);
  background-color: currentColor;
  -webkit-mask-repeat: no-repeat;
  -webkit-mask-position: center;
  -webkit-mask-size: 100% 100%;
  mask-repeat: no-repeat;
  mask-position: center;
  mask-size: 100% 100%;
}
.filter-tab.active .tab-ico {
  color: #ffffff;
}
.tab-badge {
  position: absolute;
  top: -12rpx;
  right: -12rpx;
  min-width: 32rpx;
  height: 32rpx;
  padding: 0 8rpx;
  box-sizing: border-box;
  display: flex;
  align-items: center;
  justify-content: center;
  border-radius: 32rpx;
  border: 3rpx solid #ffffff;
  background: var(--danger);
  color: #ffffff;
  font-size: 20rpx;
  font-weight: 700;
  line-height: 1;
}
.filter-tab.active .tab-badge {
  background: #ffffff;
  border-color: var(--accent);
  color: var(--accent);
}
.ico-tab-planned {
  -webkit-mask: url("data:image/svg+xml;base64,PHN2ZyB4bWxucz0iaHR0cDovL3d3dy53My5vcmcvMjAwMC9zdmciIHZpZXdCb3g9IjAgMCAyNCAyNCI+PHBhdGggZD0iTTE3IDEwSDd2MmgxMHYtMnptMi03aC0xVjFoLTJ2Mkg4VjFINnYySDVjLTEuMTEgMC0xLjk5LjktMS45OSAyTDMgMTljMCAxLjEuODkgMiAyIDJoMTRjMS4xIDAgMi0uOSAyLTJWNWMwLTEuMS0uOS0yLTItMnptMCAxNkg1VjhoMTR2MTF6bS01LTVIN3YyaDd2LTJ6Ii8+PC9zdmc+") no-repeat center / 100% 100%;
  mask: url("data:image/svg+xml;base64,PHN2ZyB4bWxucz0iaHR0cDovL3d3dy53My5vcmcvMjAwMC9zdmciIHZpZXdCb3g9IjAgMCAyNCAyNCI+PHBhdGggZD0iTTE3IDEwSDd2MmgxMHYtMnptMi03aC0xVjFoLTJ2Mkg4VjFINnYySDVjLTEuMTEgMC0xLjk5LjktMS45OSAyTDMgMTljMCAxLjEuODkgMiAyIDJoMTRjMS4xIDAgMi0uOSAyLTJWNWMwLTEuMS0uOS0yLTItMnptMCAxNkg1VjhoMTR2MTF6bS01LTVIN3YyaDd2LTJ6Ii8+PC9zdmc+") no-repeat center / 100% 100%;
}
.ico-tab-exec {
  -webkit-mask: url("data:image/svg+xml;base64,PHN2ZyB4bWxucz0iaHR0cDovL3d3dy53My5vcmcvMjAwMC9zdmciIHZpZXdCb3g9IjAgMCAyNCAyNCI+PHBhdGggZD0iTTEwIDE2LjVsNi00LjUtNi00LjV2OXpNMTIgMkM2LjQ4IDIgMiA2LjQ4IDIgMTJzNC40OCAxMCAxMCAxMCAxMC00LjQ4IDEwLTEwUzE3LjUyIDIgMTIgMnptMCAxOGMtNC40MSAwLTgtMy41OS04LThzMy41OS04IDgtOCA4IDMuNTkgOCA4LTMuNTkgOC04IDh6Ii8+PC9zdmc+") no-repeat center / 100% 100%;
  mask: url("data:image/svg+xml;base64,PHN2ZyB4bWxucz0iaHR0cDovL3d3dy53My5vcmcvMjAwMC9zdmciIHZpZXdCb3g9IjAgMCAyNCAyNCI+PHBhdGggZD0iTTEwIDE2LjVsNi00LjUtNi00LjV2OXpNMTIgMkM2LjQ4IDIgMiA2LjQ4IDIgMTJzNC40OCAxMCAxMCAxMCAxMC00LjQ4IDEwLTEwUzE3LjUyIDIgMTIgMnptMCAxOGMtNC40MSAwLTgtMy41OS04LThzMy41OS04IDgtOCA4IDMuNTkgOCA4LTMuNTkgOC04IDh6Ii8+PC9zdmc+") no-repeat center / 100% 100%;
}
.ico-tab-memo {
  -webkit-mask: url("data:image/svg+xml;base64,PHN2ZyB4bWxucz0iaHR0cDovL3d3dy53My5vcmcvMjAwMC9zdmciIHZpZXdCb3g9IjAgMCAyNCAyNCI+PHBhdGggZD0iTTE5IDNINWMtMS4xIDAtMiAuOS0yIDJ2MTRjMCAxLjEuOSAyIDIgMmgxMGw2LTZWNWMwLTEuMS0uOS0yLTItMnptMCAxMWgtNXY1SDVWNWgxNHY5eiIvPjwvc3ZnPg==") no-repeat center / 100% 100%;
  mask: url("data:image/svg+xml;base64,PHN2ZyB4bWxucz0iaHR0cDovL3d3dy53My5vcmcvMjAwMC9zdmciIHZpZXdCb3g9IjAgMCAyNCAyNCI+PHBhdGggZD0iTTE5IDNINWMtMS4xIDAtMiAuOS0yIDJ2MTRjMCAxLjEuOSAyIDIgMmgxMGw2LTZWNWMwLTEuMS0uOS0yLTItMnptMCAxMWgtNXY1SDVWNWgxNHY5eiIvPjwvc3ZnPg==") no-repeat center / 100% 100%;
}
.ico-tab-done {
  -webkit-mask: url("data:image/svg+xml;base64,PHN2ZyB4bWxucz0iaHR0cDovL3d3dy53My5vcmcvMjAwMC9zdmciIHZpZXdCb3g9IjAgMCAyNCAyNCI+PGNpcmNsZSBjeD0iMTIiIGN5PSIxMiIgcj0iOC42IiBmaWxsPSJub25lIiBzdHJva2U9IiMwMDAiIHN0cm9rZS13aWR0aD0iMS43Ii8+PHBhdGggZD0iTTguMSAxMi4ybDIuNiAyLjYgNS4zLTUuOCIgZmlsbD0ibm9uZSIgc3Ryb2tlPSIjMDAwIiBzdHJva2Utd2lkdGg9IjEuNyIgc3Ryb2tlLWxpbmVjYXA9InJvdW5kIiBzdHJva2UtbGluZWpvaW49InJvdW5kIi8+PC9zdmc+") no-repeat center / 100% 100%;
  mask: url("data:image/svg+xml;base64,PHN2ZyB4bWxucz0iaHR0cDovL3d3dy53My5vcmcvMjAwMC9zdmciIHZpZXdCb3g9IjAgMCAyNCAyNCI+PGNpcmNsZSBjeD0iMTIiIGN5PSIxMiIgcj0iOC42IiBmaWxsPSJub25lIiBzdHJva2U9IiMwMDAiIHN0cm9rZS13aWR0aD0iMS43Ii8+PHBhdGggZD0iTTguMSAxMi4ybDIuNiAyLjYgNS4zLTUuOCIgZmlsbD0ibm9uZSIgc3Ryb2tlPSIjMDAwIiBzdHJva2Utd2lkdGg9IjEuNyIgc3Ryb2tlLWxpbmVjYXA9InJvdW5kIiBzdHJva2UtbGluZWpvaW49InJvdW5kIi8+PC9zdmc+") no-repeat center / 100% 100%;
}
.ico-tab-all {
  -webkit-mask: url("data:image/svg+xml;base64,PHN2ZyB4bWxucz0iaHR0cDovL3d3dy53My5vcmcvMjAwMC9zdmciIHZpZXdCb3g9IjAgMCAyNCAyNCI+PHBhdGggZD0iTTMgM2g4djhIM1Yzem0xMCAwaDh2OGgtOFYzek0zIDEzaDh2OEgzdi04em0xMCAwaDh2OGgtOHYtOHoiLz48L3N2Zz4=") no-repeat center / 100% 100%;
  mask: url("data:image/svg+xml;base64,PHN2ZyB4bWxucz0iaHR0cDovL3d3dy53My5vcmcvMjAwMC9zdmciIHZpZXdCb3g9IjAgMCAyNCAyNCI+PHBhdGggZD0iTTMgM2g4djhIM1Yzem0xMCAwaDh2OGgtOFYzek0zIDEzaDh2OEgzdi04em0xMCAwaDh2OGgtOHYtOHoiLz48L3N2Zz4=") no-repeat center / 100% 100%;
}
.content-swiper {
  flex: 1;
  min-height: 0;
}
.memo-wrap {
  height: 100%;
  display: flex;
  flex-direction: column;
  padding: 0 24rpx;
  box-sizing: border-box;
}
.search-bar {
  flex-shrink: 0;
  padding-bottom: 16rpx;
}
.search-input {
  height: 80rpx;
  background: #ffffff;
  border: 1rpx solid #f3f4f6;
  border-radius: 999rpx;
  padding: 0 32rpx;
  font-size: 26rpx;
}
.ph {
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
.list-scroll {
  height: 100%;
  box-sizing: border-box;
}
.list {
  padding: 4rpx 24rpx 200rpx;
}
.drag-item {
  position: relative;
  transition: transform 0.2s ease;
  z-index: 1;
}
.drag-item.dragging {
  transition: none;
  z-index: 10;
  box-shadow: 0 12rpx 40rpx rgba(0, 0, 0, 0.18);
  border-radius: 20rpx;
}
.bounce {
  animation: list-bounce 0.4s ease-out;
}
@keyframes list-bounce {
  0% {
    transform: translateY(0);
  }
  40% {
    transform: translateY(24rpx);
  }
  100% {
    transform: translateY(0);
  }
}
.memo-item {
  position: relative;
  /* 备忘纸面染色：与桌面 memoPaperTop / memoPaperBottom 一致 */
  background: var(--memo-paper);
  border: 1rpx solid var(--card-border);
  border-radius: 36rpx;
  padding: 30rpx 28rpx 24rpx;
  margin-bottom: 24rpx;
  overflow: hidden;
  box-shadow: var(--shadow-card);
}
/* 顶部 3px 渐变细条：颜色由 memoTone 内联样式动态指定（红/黄/蓝） */
.memo-bar {
  position: absolute;
  left: 0;
  top: 0;
  width: 100%;
  height: 6rpx;
  z-index: 2;
}
.memo-content {
  display: block;
  font-size: 28rpx;
  color: #111827;
  line-height: 1.6;
  word-break: break-all;
  white-space: pre-wrap;
}
.memo-time {
  display: block;
  font-size: 22rpx;
  color: #9ca3af;
  margin-top: 12rpx;
}
.empty {
  padding: 160rpx 0;
  text-align: center;
}
.empty-text {
  color: #9ca3af;
  font-size: 26rpx;
}
/* ---- 骨架屏（首次加载占位，避免白屏闪烁） ---- */
/* ---------------- 启动进度 ---------------- */
/* 细线版：贴在筛选行下方，本地已有缓存时列表照常渲染，只多这一条进度 */
.boot-line {
  display: flex;
  align-items: center;
  gap: 16rpx;
  padding: 0 24rpx 10rpx;
  flex-shrink: 0;
}
.boot-line-track {
  flex: 1;
  height: 6rpx;
  border-radius: 6rpx;
  background: var(--track-bg);
  overflow: hidden;
}
.boot-line-fill {
  height: 100%;
  border-radius: 6rpx;
  background: linear-gradient(90deg, var(--stats-primary-soft), var(--accent));
  transition: width 0.25s ease;
}
.boot-line-text {
  flex-shrink: 0;
  font-size: 21rpx;
  color: var(--text-secondary);
}
/* 整屏版：全新安装/清空缓存后本地无数据，用进度卡替代骨架屏 */
.boot-card {
  margin: 120rpx 24rpx 0;
  padding: 44rpx 36rpx 40rpx;
  border-radius: 28rpx;
  background: var(--card-bg);
  border: 2rpx solid var(--card-border);
  box-shadow: var(--shadow-card);
  box-sizing: border-box;
  text-align: center;
}
.boot-card-title {
  display: block;
  font-size: 30rpx;
  font-weight: 600;
  color: var(--text-primary);
}
.boot-card-track {
  margin: 28rpx 0 18rpx;
  height: 10rpx;
  border-radius: 6rpx;
  background: var(--track-bg);
  overflow: hidden;
}
.boot-card-fill {
  height: 100%;
  border-radius: 6rpx;
  background: linear-gradient(90deg, var(--stats-primary-soft), var(--accent));
  transition: width 0.25s ease;
}
.boot-card-step {
  display: block;
  font-size: 23rpx;
  color: var(--text-secondary);
}
.boot-card-tip {
  display: block;
  margin-top: 12rpx;
  font-size: 21rpx;
  line-height: 1.6;
  color: var(--text-tertiary);
}
.skeleton-list {
  padding: 4rpx 24rpx 200rpx;
}
/* 任务卡骨架：色条 + 两行文字 + 进度条 + 操作按钮位 */
.skeleton-card {
  background: #ffffff;
  border-radius: 20rpx;
  padding: 24rpx 28rpx;
  margin-bottom: 20rpx;
  box-shadow: 0 2rpx 8rpx rgba(0, 0, 0, 0.04);
  animation: sk-blink 1.2s ease-in-out infinite;
}
.sk-head {
  display: flex;
  align-items: center;
}
.sk-bar {
  width: 6rpx;
  height: 64rpx;
  border-radius: 3rpx;
  margin-right: 16rpx;
  flex-shrink: 0;
}
.sk-lines {
  flex: 1;
}
.sk-title {
  width: 55%;
  height: 30rpx;
  border-radius: 6rpx;
  background: #e5e7eb;
}
.sk-sub {
  width: 75%;
  height: 24rpx;
  border-radius: 6rpx;
  background: #f3f4f6;
  margin-top: 14rpx;
}
.sk-progress {
  height: 12rpx;
  background: #f3f4f6;
  border-radius: 6rpx;
  margin-top: 20rpx;
  overflow: hidden;
}
.sk-progress-inner {
  width: 42%;
  height: 100%;
  background: #dbeafe;
  border-radius: 6rpx;
}
.sk-foot {
  display: flex;
  align-items: center;
  gap: 14rpx;
  margin-top: 20rpx;
}
.sk-dot {
  width: 44rpx;
  height: 44rpx;
  border-radius: 50%;
  background: #f3f4f6;
}
.sk-chip {
  width: 120rpx;
  height: 36rpx;
  border-radius: 999rpx;
  background: #f3f4f6;
  margin-left: auto;
}
/* 备忘卡骨架：白纸底 + 顶部细条 + 文字行 */
.skeleton-memo {
  position: relative;
  background: linear-gradient(180deg, #ffffff 0%, #f8fbff 100%);
  border-radius: 32rpx;
  padding: 44rpx 28rpx 30rpx;
  margin-bottom: 24rpx;
  box-shadow:
    0 2rpx 6rpx rgba(2, 6, 23, 0.03),
    0 10rpx 24rpx rgba(2, 6, 23, 0.05),
    0 24rpx 48rpx rgba(2, 6, 23, 0.06);
  animation: sk-blink 1.2s ease-in-out infinite;
}
.sk-memo-bar {
  position: absolute;
  left: 0;
  top: 0;
  width: 100%;
  height: 6rpx;
}
.sk-line {
  height: 26rpx;
  border-radius: 6rpx;
  background: #e5e7eb;
  margin-bottom: 14rpx;
}
@keyframes sk-blink {
  0%,
  100% {
    opacity: 1;
  }
  50% {
    opacity: 0.5;
  }
}
.fab {
  position: fixed;
  right: 40rpx;
  bottom: calc(40rpx + env(safe-area-inset-bottom));
  width: 108rpx;
  height: 108rpx;
  /* 圆角方形（桌面端 FAB 默认圆角），非圆形 */
  border-radius: 20rpx;
  background: var(--accent);
  color: #ffffff;
  display: flex;
  align-items: center;
  justify-content: center;
  box-shadow: 0 12rpx 28rpx rgba(37, 99, 235, 0.38),
    inset 0 2rpx 0 rgba(255, 255, 255, 0.38), inset 0 -2rpx 8rpx rgba(0, 0, 0, 0.16);
  z-index: 10;
}
.fab-plus {
  font-size: 52rpx;
  font-weight: 300;
  line-height: 1;
  margin-top: -4rpx;
}
.side-fab {
  position: fixed;
  left: 40rpx;
  bottom: calc(40rpx + env(safe-area-inset-bottom));
  width: 96rpx;
  height: 96rpx;
  border-radius: 50%;
  background: var(--float-bg);
  border: 1rpx solid var(--float-border);
  -webkit-backdrop-filter: blur(20rpx);
  backdrop-filter: blur(20rpx);
  display: flex;
  align-items: center;
  justify-content: center;
  box-shadow: inset 0 1rpx 0 var(--glass-topline), 0 10rpx 26rpx rgba(23, 43, 84, 0.16);
  z-index: 10;
}
.side-fab-icon {
  font-size: 40rpx;
  color: var(--accent);
  line-height: 1;
}
.side-option .side-icon {
  width: 88rpx;
  height: 88rpx;
  border-radius: 20rpx;
  display: flex;
  align-items: center;
  justify-content: center;
  font-size: 40rpx;
  flex-shrink: 0;
}
.mask {
  position: fixed;
  left: 0;
  top: 0;
  right: 0;
  bottom: 0;
  background: rgba(0, 0, 0, 0.4);
  z-index: 100;
  display: flex;
  align-items: center;
  justify-content: center;
  animation: mask-in 0.2s ease-out;
}
@keyframes mask-in {
  from {
    opacity: 0;
  }
  to {
    opacity: 1;
  }
}
.create-menu {
  width: 600rpx;
  background: #ffffff;
  border-radius: 24rpx;
  padding: 48rpx 32rpx 24rpx;
  box-sizing: border-box;
  animation: menu-pop 0.25s ease-out;
}
@keyframes menu-pop {
  from {
    opacity: 0;
    transform: scale(0.9);
  }
  to {
    opacity: 1;
    transform: scale(1);
  }
}
.menu-title {
  font-size: 36rpx;
  font-weight: 700;
  color: #111827;
  text-align: center;
}
.menu-sub {
  font-size: 24rpx;
  color: #9ca3af;
  text-align: center;
  margin: 8rpx 0 28rpx;
}
.menu-option {
  display: flex;
  align-items: center;
  gap: 24rpx;
  border: 2rpx solid #f3f4f6;
  border-radius: 16rpx;
  padding: 24rpx 28rpx;
  margin-bottom: 16rpx;
}
/* 新建任务：蓝色系 */
.task-option {
  background: #eff6ff;
  border-color: #bfdbfe;
}
.task-option .opt-title {
  color: #1d4ed8;
}
.task-option .opt-desc {
  color: #60a5fa;
}
.task-option .opt-icon {
  background: #dbeafe;
}
/* 新建备忘：琥珀色系 */
.memo-option {
  background: #fffbeb;
  border-color: #fde68a;
}
.memo-option .opt-title {
  color: #b45309;
}
.memo-option .opt-desc {
  color: #f59e0b;
}
.memo-option .opt-icon {
  background: #fef3c7;
}
.opt-icon {
  width: 88rpx;
  height: 88rpx;
  border-radius: 20rpx;
  display: flex;
  align-items: center;
  justify-content: center;
  flex-shrink: 0;
}
.opt-body {
  flex: 1;
}
.opt-title {
  font-size: 30rpx;
  font-weight: 600;
}
.opt-desc {
  font-size: 24rpx;
  margin-top: 6rpx;
}
/* 任务图标：圆角方块 + 白色对勾 */
.icon-task {
  width: 44rpx;
  height: 44rpx;
  border-radius: 10rpx;
  background: #2563eb;
  position: relative;
}
.icon-task::after {
  content: '';
  position: absolute;
  left: 10rpx;
  top: 12rpx;
  width: 20rpx;
  height: 10rpx;
  border-left: 4rpx solid #ffffff;
  border-bottom: 4rpx solid #ffffff;
  transform: rotate(-45deg);
}
/* 备忘图标：便签 + 折角 + 内容线 */
.icon-memo {
  width: 44rpx;
  height: 44rpx;
  border-radius: 8rpx;
  background: #f59e0b;
  position: relative;
  overflow: hidden;
}
.icon-memo::before {
  content: '';
  position: absolute;
  right: -1rpx;
  top: -1rpx;
  border-style: solid;
  border-width: 0 0 14rpx 14rpx;
  border-color: transparent transparent #fef3c7 transparent;
}
.icon-memo::after {
  content: '';
  position: absolute;
  left: 8rpx;
  top: 10rpx;
  width: 26rpx;
  height: 4rpx;
  border-radius: 2rpx;
  background: #ffffff;
  box-shadow: 0 11rpx 0 #ffffff, 0 22rpx 0 #ffffff;
}
.menu-cancel {
  margin-top: 8rpx;
  height: 84rpx;
  line-height: 84rpx;
  text-align: center;
  font-size: 28rpx;
  color: #6b7280;
}

/* ---------- 统一主题（对齐桌面端 GlassPalette） ---------- */
.page {
  background: transparent;
  color: var(--text-primary);
}
.nav-bar {
  flex-shrink: 0;
  display: flex;
  align-items: center;
  box-sizing: border-box;
  padding: calc(var(--status-bar-height) + 16rpx) 200rpx 8rpx 28rpx;
}
.nav-brand {
  flex: 1;
  display: flex;
  align-items: center;
  gap: 12rpx;
}
.brand-dot {
  width: 18rpx;
  height: 18rpx;
  border-radius: 50%;
  background: linear-gradient(135deg, var(--accent), var(--stats-primary));
  box-shadow: 0 0 16rpx var(--accent);
}
.brand-title {
  font-size: 34rpx;
  font-weight: 700;
  letter-spacing: 1rpx;
  color: var(--text-primary);
}
.filter-tab {
  background: var(--float-bg);
  border: 1rpx solid var(--float-border);
  color: var(--text-secondary);
  -webkit-backdrop-filter: blur(20rpx);
  backdrop-filter: blur(20rpx);
  box-shadow: inset 0 1rpx 0 var(--glass-topline);
}
.filter-tab.active {
  background: linear-gradient(180deg, var(--tag-gloss), rgba(255, 255, 255, 0) 46%),
    var(--accent);
  border-color: var(--accent-border);
  color: #ffffff;
  font-weight: 600;
  box-shadow: 0 8rpx 28rpx var(--accent-border),
    inset 0 1rpx 0 rgba(255, 255, 255, 0.36);
}
.search-input {
  background: var(--float-bg);
  border-color: var(--float-border);
  color: var(--text-primary);
  -webkit-backdrop-filter: blur(20rpx);
  backdrop-filter: blur(20rpx);
}
.task-search-bar {
  background: var(--float-bg);
  border-color: var(--accent);
  -webkit-backdrop-filter: blur(20rpx);
  backdrop-filter: blur(20rpx);
}
.task-search-input {
  color: var(--text-primary);
}
.filter-chip {
  background: var(--chip-bg);
  color: var(--text-secondary);
  border: 1rpx solid var(--chip-border);
}
.filter-chip.on {
  background: var(--accent);
  color: #ffffff;
  border-color: var(--accent);
}
.filter-divider {
  color: var(--text-tertiary);
}
.load-more-text {
  background: var(--chip-bg);
  color: var(--accent);
  border-color: var(--accent);
}
.memo-item {
  background: var(--memo-paper);
  box-shadow: var(--shadow-card);
  border: 1rpx solid var(--card-border);
}
.memo-content {
  color: var(--text-primary);
}
.memo-time {
  color: var(--text-tertiary);
}
.memo-tools {
  display: flex;
  align-items: center;
  gap: 16rpx;
  padding-bottom: 16rpx;
}
.memo-tools .search-bar {
  flex: 1;
  padding-bottom: 0;
}
.export-btn {
  flex-shrink: 0;
  height: 80rpx;
  padding: 0 28rpx;
  border-radius: 999rpx;
  font-size: 26rpx;
  color: var(--accent);
  background: var(--float-bg);
  border: 1rpx solid var(--float-border);
  -webkit-backdrop-filter: blur(20rpx);
  backdrop-filter: blur(20rpx);
  box-shadow: inset 0 1rpx 0 var(--glass-topline);
  display: flex;
  align-items: center;
}
.empty-text {
  color: var(--text-tertiary);
}
.skeleton-card,
.skeleton-memo {
  background: var(--card-bg);
  border: 1rpx solid var(--card-border);
}
.sk-title,
.sk-sub,
.sk-progress,
.sk-progress-inner,
.sk-line,
.sk-dot,
.sk-chip {
  background: var(--track-bg);
}
.side-option .side-icon {
  background: var(--accent-soft);
  color: var(--accent);
  font-size: 38rpx;
}
.create-menu {
  background: var(--card-bg-strong);
  border: 1rpx solid var(--card-border);
  box-shadow: 0 30rpx 70rpx rgba(0, 0, 0, 0.3), inset 0 1rpx 0 var(--glass-topline);
}
.menu-title {
  color: var(--text-primary);
}
.menu-sub {
  color: var(--text-tertiary);
}
.menu-option {
  border-color: var(--card-border);
  background: var(--chip-bg);
}
.menu-cancel {
  color: var(--text-secondary);
}
.opt-title {
  color: var(--text-primary);
}
.opt-desc {
  color: var(--text-tertiary);
}
.ph {
  color: var(--text-tertiary);
}
.theme-dark .task-option {
  background: rgba(59, 130, 246, 0.16);
  border-color: rgba(59, 130, 246, 0.4);
}
.theme-dark .memo-option {
  background: rgba(245, 158, 11, 0.14);
  border-color: rgba(245, 158, 11, 0.36);
}
/* 子选择器权重高于 .opt-title/.opt-desc，浅色值必须逐条压回深色 */
.theme-dark .task-option .opt-title {
  color: var(--type-work);
}
.theme-dark .task-option .opt-icon {
  background: rgba(59, 130, 246, 0.3);
}
.theme-dark .memo-option .opt-title {
  color: var(--stats-amber);
}
.theme-dark .memo-option .opt-icon {
  background: rgba(245, 158, 11, 0.28);
}

/* 状态流转飞球：外层 transition 负责平移（桌面同曲线），内层 keyframes 负责上拱+缩小，
   合成抛物线；全程渲染层合成，不逐帧 setData */
.fly-ball {
  position: fixed;
  width: 28px;
  height: 28px;
  pointer-events: none;
  z-index: 60;
  transition: transform 300ms cubic-bezier(0.65, 0, 0.35, 1);
  will-change: transform;
}
.fly-ball-inner {
  width: 100%;
  height: 100%;
  border-radius: 50%;
}
.fly-ball-inner.fly {
  animation: ball-arc 300ms linear forwards;
}
@keyframes ball-arc {
  0% {
    transform: translateY(0) scale(1);
  }
  50% {
    transform: translateY(-60px) scale(0.65);
  }
  100% {
    transform: translateY(0) scale(0.3);
  }
}
.fly-ball.u-normal .fly-ball-inner {
  background: var(--urgency-normal);
  box-shadow: 0 0 10px 1px var(--urgency-normal-line);
}
.fly-ball.u-urgent .fly-ball-inner {
  background: var(--urgency-urgent);
  box-shadow: 0 0 10px 1px var(--urgency-urgent-line);
}
.fly-ball.u-important .fly-ball-inner {
  background: var(--urgency-important);
  box-shadow: 0 0 10px 1px var(--urgency-important-line);
}
</style>
