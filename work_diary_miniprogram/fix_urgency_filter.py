# -*- coding: utf-8 -*-
"""修复小程序紧急度筛选：urgency 是数字(0一般/1紧急/2重要)，不能用字符串比较"""
import io

p = r"E:\Code\WorkDiary\work_diary_miniprogram\src\pages\tasks\tasks.vue"
with io.open(p, "r", encoding="utf-8") as f:
    c = f.read()

# 1. 模板：筛选 chip 改为数字
old1 = '''              <text class="filter-chip" :class="{ on: taskUrgencyFilter === null }" @click="setUrgencyFilter(null)">全部</text>
              <text class="filter-chip" :class="{ on: taskUrgencyFilter === '一般' }" @click="setUrgencyFilter('一般')">一般</text>
              <text class="filter-chip" :class="{ on: taskUrgencyFilter === '重要' }" @click="setUrgencyFilter('重要')">重要</text>
              <text class="filter-chip" :class="{ on: taskUrgencyFilter === '紧急' }" @click="setUrgencyFilter('紧急')">紧急</text>'''
new1 = '''              <text class="filter-chip" :class="{ on: taskUrgencyFilter === null }" @click="setUrgencyFilter(null)">全部</text>
              <text class="filter-chip" :class="{ on: taskUrgencyFilter === 0 }" @click="setUrgencyFilter(0)">一般</text>
              <text class="filter-chip" :class="{ on: taskUrgencyFilter === 2 }" @click="setUrgencyFilter(2)">重要</text>
              <text class="filter-chip" :class="{ on: taskUrgencyFilter === 1 }" @click="setUrgencyFilter(1)">紧急</text>'''
assert old1 in c, "tpl FAIL"
c = c.replace(old1, new1, 1)
print("tpl ok")

# 2. displayedTasks：数字比较
old2 = '''      if (this.taskUrgencyFilter !== null) {
        list = list.filter((t) => (t.urgency || '一般') === this.taskUrgencyFilter)
      }'''
new2 = '''      if (this.taskUrgencyFilter !== null) {
        // urgency 为数字：0=一般 1=紧急 2=重要（旧数据缺失时按 0 一般处理）
        list = list.filter((t) => (t.urgency === undefined || t.urgency === null ? 0 : t.urgency) === this.taskUrgencyFilter)
      }'''
assert old2 in c, "filter FAIL"
c = c.replace(old2, new2, 1)
print("filter ok")

with io.open(p, "w", encoding="utf-8", newline="\n") as f:
    f.write(c)
print("saved")
