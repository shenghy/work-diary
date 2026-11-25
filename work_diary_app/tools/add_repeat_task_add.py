# -*- coding: utf-8 -*-
"""Windows home_screen 接入循环任务：新增/编辑弹窗 + 生成引擎 + 接入时机"""
import io

p = r"E:\Code\WorkDiary\work_diary_app\lib\screens\home_screen.dart"
with io.open(p, "r", encoding="utf-8") as f:
    c = f.read()

# ========== 1. import ==========
old = "import '../utils/subtask_parser.dart';"
new = "import '../utils/subtask_parser.dart';\nimport '../utils/repeat_task_engine.dart';"
assert c.count(old) == 1
c = c.replace(old, new, 1)
print("import ok")

# ========== 2. _loadTasks 接入生成 ==========
old = """    await _maybeCreateWelcomeTask();

    final all = await _repo.getTasks();"""
new = """    await _maybeCreateWelcomeTask();
    // 循环任务自动补生成（日/周/月任务）
    await _materializeRepeatTasks();

    final all = await _repo.getTasks();"""
assert c.count(old) == 1
c = c.replace(old, new, 1)
print("loadTasks ok")

# ========== 3. 新增 _materializeRepeatTasks 方法（_loadTasks 前） ==========
old = """  Future<void> _loadTasks() async {"""
new = """  /// 循环任务（日/周/月）自动补生成最近一期实例；幂等，无新增时不动作
  Future<void> _materializeRepeatTasks() async {
    try {
      final all = await _repo.getTasks();
      final missing = RepeatTaskEngine.generateMissing(all, DateTime.now());
      if (missing.isEmpty) return;
      for (final t in missing) {
        await _repo.insertTask(t);
      }
      AppLogger.instance.log('循环任务自动生成 ${missing.length} 期');
      _syncAfterChange();
    } catch (e) {
      AppLogger.instance.error('循环任务自动生成失败', e);
    }
  }

  Future<void> _loadTasks() async {"""
assert c.count(old) == 1
c = c.replace(old, new, 1)
print("materialize ok")

# ========== 4. 新建弹窗：变量 ==========
old = """    int taskType = 1; // 0个人任务 1工作任务，默认工作任务
    DateTime? planStartAt = initialPlanStartAt;
    DateTime? dueAt = initialDueAt;

    await showDialog("""
new = """    int taskType = 1; // 0个人任务 1工作任务，默认工作任务
    int repeatType = 0; // 0正常 1日任务 2周任务 3月任务
    List<int> repeatWeekDays = [DateTime.monday];
    int repeatMonthDay = 1;
    DateTime? planStartAt = initialPlanStartAt;
    DateTime? dueAt = initialDueAt;

    await showDialog("""
assert c.count(old) == 1
c = c.replace(old, new, 1)
print("add vars ok")

# ========== 5. 新建弹窗：类别 UI 插入（任务类型行后第一次出现） ==========
ui_block = r'''                const SizedBox(height: 16),
                const Text(
                  '任务类别',
                  style: TextStyle(fontSize: 13, color: Colors.grey),
                ),
                const SizedBox(height: 8),
                Row(
                  children: [0, 1, 2, 3].map((rt) {
                    final selected = repeatType == rt;
                    final label = rt == 0
                        ? '正常'
                        : rt == 1
                        ? '日任务'
                        : rt == 2
                        ? '周任务'
                        : '月任务';
                    final color = const Color(0xFF3B82F6);
                    return Expanded(
                      child: GestureDetector(
                        onTap: () => setDialogState(() {
                          repeatType = rt;
                          if (rt > 0 && planStartAt == null && dueAt == null) {
                            final now = DateTime.now();
                            planStartAt = DateTime(now.year, now.month, now.day, 9, 0);
                            dueAt = rt == 1
                                ? DateTime(now.year, now.month, now.day, 23, 59)
                                : DateTime(now.year, now.month, now.day, 18, 0);
                          }
                        }),
                        child: Container(
                          margin: const EdgeInsets.symmetric(horizontal: 3),
                          padding: const EdgeInsets.symmetric(vertical: 8),
                          decoration: BoxDecoration(
                            color: selected
                                ? color.withValues(alpha: 0.15)
                                : Colors.grey.shade50,
                            borderRadius: BorderRadius.circular(8),
                            border: Border.all(
                              color: selected ? color : Colors.grey.shade200,
                              width: selected ? 1.5 : 1,
                            ),
                          ),
                          child: Row(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              Container(
                                width: 8,
                                height: 8,
                                decoration: BoxDecoration(
                                  color: color,
                                  shape: BoxShape.circle,
                                ),
                              ),
                              const SizedBox(width: 6),
                              Text(
                                label,
                                style: TextStyle(
                                  fontSize: 12,
                                  color: selected ? Colors.black87 : Colors.grey,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    );
                  }).toList(),
                ),
                if (repeatType == 2) ...[
                  const SizedBox(height: 12),
                  const Text(
                    '每周重复（可多选）',
                    style: TextStyle(fontSize: 12, color: Colors.grey),
                  ),
                  const SizedBox(height: 6),
                  Wrap(
                    spacing: 6,
                    runSpacing: 6,
                    children: [1, 2, 3, 4, 5, 6, 7].map((wd) {
                      final selected = repeatWeekDays.contains(wd);
                      final wdLabel = ['一', '二', '三', '四', '五', '六', '日'][wd - 1];
                      return GestureDetector(
                        onTap: () => setDialogState(() {
                          if (selected) {
                            repeatWeekDays = List.of(repeatWeekDays)..remove(wd);
                            if (repeatWeekDays.isEmpty) repeatWeekDays = [wd];
                          } else {
                            repeatWeekDays = List.of(repeatWeekDays)..add(wd);
                            repeatWeekDays.sort();
                          }
                        }),
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 10,
                            vertical: 5,
                          ),
                          decoration: BoxDecoration(
                            color: selected
                                ? const Color(0xFF3B82F6).withValues(alpha: 0.15)
                                : Colors.grey.shade50,
                            borderRadius: BorderRadius.circular(6),
                            border: Border.all(
                              color: selected
                                  ? const Color(0xFF3B82F6)
                                  : Colors.grey.shade200,
                              width: selected ? 1.5 : 1,
                            ),
                          ),
                          child: Text(
                            '周$wdLabel',
                            style: TextStyle(
                              fontSize: 11,
                              color: selected ? const Color(0xFF1D4ED8) : Colors.grey,
                            ),
                          ),
                        ),
                      );
                    }).toList(),
                  ),
                ],
                if (repeatType == 3) ...[
                  const SizedBox(height: 12),
                  Row(
                    children: [
                      const Text(
                        '每月',
                        style: TextStyle(fontSize: 12, color: Colors.grey),
                      ),
                      DropdownButton<int>(
                        value: repeatMonthDay,
                        style: const TextStyle(fontSize: 12, color: Colors.black87),
                        items: [
                          for (var i = 1; i <= 31; i++)
                            DropdownMenuItem(
                              value: i,
                              child: Text('$i 号', style: const TextStyle(fontSize: 12)),
                            ),
                        ],
                        onChanged: (v) =>
                            setDialogState(() => repeatMonthDay = v ?? 1),
                      ),
                    ],
                  ),
                ],
                if (repeatType == 1) ...[
                  const SizedBox(height: 10),
                  const Text(
                    '每天自动生成新的一期，时间可自定义',
                    style: TextStyle(fontSize: 12, color: Colors.grey),
                  ),
                ],
'''
old = """                  ],
                ),
                const SizedBox(height: 16),
                _buildTimeRow(
                  context,
                  setDialogState,
                  '计划开始',
                  planStartAt,
                  (v) => setDialogState(() => planStartAt = v),
                  maxTime: dueAt,
                ),
                const SizedBox(height: 8),
                _buildTimeRow(
                  context,
                  setDialogState,
                  '预计完成',
                  dueAt,
                  (v) => setDialogState(() => dueAt = v),
                  minTime: planStartAt,
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('取消'),
            ),
            ElevatedButton(
              onPressed: () async {
                final title = titleCtrl.text.trim();
                if (title.isEmpty) return;
                final sortOrder = await _nextSortOrder(TaskStatus.planned);
                await _repo.insertTask(
                  Task(
                    title: title,
                    urgency: urgency,
                    taskType: taskType,
                    createdAt: DateTime.now(),
                    planStartAt: planStartAt,
                    dueAt: dueAt,
                    sortOrder: sortOrder,
                  ),
                );"""
new = """                  ],
                ),
''' + ui_block + r'''                const SizedBox(height: 16),
                _buildTimeRow(
                  context,
                  setDialogState,
                  '计划开始',
                  planStartAt,
                  (v) => setDialogState(() => planStartAt = v),
                  maxTime: dueAt,
                ),
                const SizedBox(height: 8),
                _buildTimeRow(
                  context,
                  setDialogState,
                  '预计完成',
                  dueAt,
                  (v) => setDialogState(() => dueAt = v),
                  minTime: planStartAt,
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('取消'),
            ),
            ElevatedButton(
              onPressed: () async {
                final title = titleCtrl.text.trim();
                if (title.isEmpty) return;
                final sortOrder = await _nextSortOrder(TaskStatus.planned);
                final now = DateTime.now();
                // 循环任务：生成族ID + 初始实例日期，并把时间重定位到实例日期
                String? groupId;
                DateTime? instanceDate;
                if (repeatType > 0) {
                  groupId = _genRepeatGroupId();
                  instanceDate = RepeatTaskEngine.initialInstanceDate(
                    repeatType: repeatType,
                    weekDays: repeatWeekDays,
                    monthDay: repeatMonthDay,
                    now: now,
                  );
                  planStartAt = _timeOnDate(planStartAt, instanceDate);
                  dueAt = _timeOnDate(dueAt, instanceDate);
                }
                await _repo.insertTask(
                  Task(
                    title: title,
                    urgency: urgency,
                    taskType: taskType,
                    createdAt: now,
                    planStartAt: planStartAt,
                    dueAt: dueAt,
                    sortOrder: sortOrder,
                    repeatType: repeatType,
                    repeatWeekDays: repeatType == 2 ? List.of(repeatWeekDays) : null,
                    repeatMonthDay: repeatType == 3 ? repeatMonthDay : null,
                    repeatGroupId: groupId,
                    instanceDate: instanceDate,
                  ),
                );"""
assert c.count(old) == 1, "add dialog anchor not found"
c = c.replace(old, new, 1)
print("add dialog ui ok")

with io.open(p, "w", encoding="utf-8", newline="\n") as f:
    f.write(c)
print("part1 saved")
