# -*- coding: utf-8 -*-
"""小程序 tasks.vue 接入生成引擎 + task-card.vue 过期闪烁"""
import io

# ========== tasks.vue ==========
p = r"E:\Code\WorkDiary\work_diary_miniprogram\src\pages\tasks\tasks.vue"
with io.open(p, "r", encoding="utf-8") as f:
    c = f.read()

# 1. import
old = "import { syncTasks, syncMemos, createSyncer, normalizeLocalIds } from '../../utils/sync'"
new = "import { syncTasks, syncMemos, createSyncer, normalizeLocalIds } from '../../utils/sync'\nimport { generateMissing } from '../../utils/repeat'"
assert c.count(old) == 1, "import anchor"
c = c.replace(old, new, 1)
print("mp import ok")

# 2. onShow 加载缓存后接入
old = """    this.tasks = loadTasksCache()
    this.memos = loadMemosCache()
    this.refreshMemoHtml()
    this.deletions = loadTasksDeletions()
    this.pullCloud()"""
new = """    this.tasks = loadTasksCache()
    this.memos = loadMemosCache()
    this.refreshMemoHtml()
    this.deletions = loadTasksDeletions()
    // 循环任务自动补生成（日/周/月）
    this.materializeRepeat()
    this.pullCloud()"""
assert c.count(old) == 1, "onShow anchor"
c = c.replace(old, new, 1)
print("mp onShow ok")

# 3. methods 加 materializeRepeat（pullCloud 前）
old = """    // 下拉刷新（各滑页共用）
    async onRefresh() {"""
new = """    // 循环任务自动补生成：生成缺失实例并静默推送云端（幂等，服务端唯一索引去重）
    materializeRepeat() {
      try {
        const missing = generateMissing(this.tasks, new Date())
        if (!missing.length) return
        this.tasks = [...missing, ...this.tasks]
        this.persistTasks()
      } catch (e) {
        // 静默失败：不影响主流程，下次进入/同步时重试
      }
    },
    // 下拉刷新（各滑页共用）
    async onRefresh() {"""
assert c.count(old) == 1, "method anchor"
c = c.replace(old, new, 1)
print("mp method ok")

# 4. pullCloud 成功后接入
old = """        try {
          const cloud = await syncTasks(this.tasks, this.deletions)
          if (cloud) {
            this.tasks = cloud
            this.deletions = []
            saveTasksDeletions([])
          }
        } catch (e) {
          ok = false
          if (!silent) showToast('同步失败：' + e.message)
        }"""
new = """        try {
          const cloud = await syncTasks(this.tasks, this.deletions)
          if (cloud) {
            this.tasks = cloud
            this.deletions = []
            saveTasksDeletions([])
            // 云端可能新增循环任务模板，拉取后补生成缺失实例
            this.materializeRepeat()
          }
        } catch (e) {
          ok = false
          if (!silent) showToast('同步失败：' + e.message)
        }"""
assert c.count(old) == 1, "pullCloud anchor"
c = c.replace(old, new, 1)
print("mp pullCloud ok")

with io.open(p, "w", encoding="utf-8", newline="\n") as f:
    f.write(c)
print("tasks.vue saved")

# ========== task-card.vue ==========
p2 = r"E:\Code\WorkDiary\work_diary_miniprogram\src\components\task-card.vue"
with io.open(p2, "r", encoding="utf-8") as f:
    c2 = f.read()

# 1. 模板：due tag 前加已过期
old = """          <view class="tag" v-if="dueText" style="color:#FCA5A5;background:#FEF6F6;border-color:#FCA5A5;">{{ dueText }}</view>"""
new = """          <view class="tag expired-tag" v-if="isExpired">已过期</view>
          <view class="tag" v-if="dueText" style="color:#FCA5A5;background:#FEF6F6;border-color:#FCA5A5;">{{ dueText }}</view>"""
assert c2.count(old) == 1, "card template anchor"
c2 = c2.replace(old, new, 1)
print("card template ok")

# 2. computed 加 isExpired
old = """    dueText() {
      return this.task.due_at ? formatDateLabel(this.task.due_at, '完成') : ''
    },"""
new = """    dueText() {
      return this.task.due_at ? formatDateLabel(this.task.due_at, '完成') : ''
    },
    isExpired() {
      return (
        this.task.status !== 2 &&
        !!this.task.due_at &&
        new Date(this.task.due_at).getTime() < Date.now()
      )
    },"""
assert c2.count(old) == 1, "card computed anchor"
c2 = c2.replace(old, new, 1)
print("card computed ok")

# 3. CSS
old = """@import url('../utils/md.css');
"""
if old not in c2:
    old = """.task-card {
"""
    new = """.expired-tag {
  color: #dc2626 !important;
  background: #fef2f2 !important;
  border-color: #dc2626 !important;
  animation: blink-expired 0.8s ease-in-out infinite;
}
@keyframes blink-expired {
  0%, 100% { opacity: 1; }
  50% { opacity: 0.35; }
}
.task-card {
"""
    assert c2.count(old) == 1, "card css anchor"
    c2 = c2.replace(old, new, 1)
    print("card css ok")
else:
    new = old + """.expired-tag {
  color: #dc2626 !important;
  background: #fef2f2 !important;
  border-color: #dc2626 !important;
  animation: blink-expired 0.8s ease-in-out infinite;
}
@keyframes blink-expired {
  0%, 100% { opacity: 1; }
  50% { opacity: 0.35; }
}
"""
    c2 = c2.replace(old, new, 1)
    print("card css ok (after import)")

with io.open(p2, "w", encoding="utf-8", newline="\n") as f:
    f.write(c2)
print("task-card.vue saved")
