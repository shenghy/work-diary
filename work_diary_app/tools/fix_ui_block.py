# -*- coding: utf-8 -*-
"""修复 home_screen.dart 中误写入的 ''' + ui_block + r''' 字面量"""
import io

p = r"E:\Code\WorkDiary\work_diary_app\lib\screens\home_screen.dart"
with io.open(p, "r", encoding="utf-8") as f:
    c = f.read()

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

bad = "''' + ui_block + r'''"
n = c.count(bad)
assert n == 2, f"bad literal count = {n}"
c = c.replace(bad, ui_block)
print("replaced", n)

with io.open(p, "w", encoding="utf-8", newline="\n") as f:
    f.write(c)
print("fixed")
