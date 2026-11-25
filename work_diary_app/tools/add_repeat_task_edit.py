# -*- coding: utf-8 -*-
"""Windows home_screen 循环任务 part2：编辑弹窗 + 辅助函数"""
import io

p = r"E:\Code\WorkDiary\work_diary_app\lib\screens\home_screen.dart"
with io.open(p, "r", encoding="utf-8") as f:
    c = f.read()

# ========== 1. 辅助函数（_materializeRepeatTasks 后插入） ==========
old = """  Future<void> _loadTasks() async {"""
new = """  /// 循环任务族ID：时间戳 + 随机数
  String _genRepeatGroupId() {
    final now = DateTime.now();
    final rand = Random();
    final buf = StringBuffer();
    buf.write(now.microsecondsSinceEpoch.toRadixString(16));
    for (var i = 0; i < 8; i++) {
      buf.write(rand.nextInt(16).toRadixString(16));
    }
    return buf.toString();
  }

  /// 把时间 t 的时分秒套用到 date 上
  DateTime? _timeOnDate(DateTime? t, DateTime date) {
    if (t == null) return null;
    return DateTime(date.year, date.month, date.day, t.hour, t.minute, t.second);
  }

  Future<void> _loadTasks() async {"""
assert c.count(old) == 1
c = c.replace(old, new, 1)
print("helpers ok")

# ========== 2. 编辑弹窗：变量 ==========
old = """    int taskType = task.taskType;
    DateTime? planStartAt = task.planStartAt;
    DateTime? dueAt = task.dueAt;"""
new = """    int taskType = task.taskType;
    int repeatType = task.repeatType;
    List<int> repeatWeekDays = List.of(task.repeatWeekDays ?? [DateTime.monday]);
    int repeatMonthDay = task.repeatMonthDay ?? 1;
    DateTime? planStartAt = task.planStartAt;
    DateTime? dueAt = task.dueAt;"""
assert c.count(old) == 1
c = c.replace(old, new, 1)
print("edit vars ok")

# ========== 3. 编辑弹窗：类别 UI（任务类型行后，第二次出现） ==========
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
                final now = DateTime.now();
                var updated = task.copyWith("""
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
                final now = DateTime.now();
                var updated = task.copyWith("""
assert c.count(old) == 1, "edit dialog anchor not found"
c = c.replace(old, new, 1)
print("edit dialog ui ok")

# ========== 4. 编辑保存逻辑：循环字段 ==========
old = """                await _repo.updateTask(updated);
                if (context.mounted) Navigator.pop(context);
                _loadTasks();
                _syncAfterChange();"""
new = """                // 循环任务规则：升级为循环任务 / 修改规则 / 降级为正常任务
                if (repeatType > 0) {
                  if (task.repeatGroupId == null) {
                    // 普通任务 → 循环任务：本期作为第一期
                    final inst = RepeatTaskEngine.initialInstanceDate(
                      repeatType: repeatType,
                      weekDays: repeatWeekDays,
                      monthDay: repeatMonthDay,
                      now: now,
                    );
                    updated = updated.copyWith(
                      repeatType: repeatType,
                      repeatGroupId: _genRepeatGroupId(),
                      instanceDate: inst,
                      planStartAt: _timeOnDate(updated.planStartAt, inst),
                      dueAt: _timeOnDate(updated.dueAt, inst),
                    );
                  } else {
                    // 已有循环任务：仅更新规则与时间，实例日期保持不变
                    updated = updated.copyWith(
                      repeatType: repeatType,
                      repeatWeekDays:
                          repeatType == 2 ? List.of(repeatWeekDays) : null,
                      repeatMonthDay: repeatType == 3 ? repeatMonthDay : null,
                      clearRepeatWeekDays: repeatType != 2,
                    );
                  }
                } else {
                  // 改回正常任务：清除循环字段
                  updated = updated.copyWith(
                    repeatType: 0,
                    clearRepeatWeekDays: true,
                    clearRepeatGroupId: true,
                    clearInstanceDate: true,
                  );
                }
                await _repo.updateTask(updated);
                if (context.mounted) Navigator.pop(context);
                _loadTasks();
                _syncAfterChange();"""
assert c.count(old) == 1
c = c.replace(old, new, 1)
print("edit save ok")

with io.open(p, "w", encoding="utf-8", newline="\n") as f:
    f.write(c)
print("part2 saved")
