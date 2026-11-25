import 'package:flutter_test/flutter_test.dart';
import 'package:work_diary_app/models/task.dart';
import 'package:work_diary_app/utils/repeat_task_engine.dart';

void main() {
  final now = DateTime(2026, 11, 1, 9, 30);

  Task yesterdayInstance() => Task(
        title: '每天运动 1 个小时',
        createdAt: now.subtract(const Duration(days: 1)),
        updatedAt: now.subtract(const Duration(days: 1)),
        repeatType: 1,
        repeatGroupId: 'g1',
        instanceDate: DateTime(2026, 10, 31),
      );

  test('没有规则也没有跳过记录时，会补生成今天这一期', () {
    final missing = RepeatTaskEngine.generateMissing(
      [yesterdayInstance()],
      const {},
      now,
    );
    expect(missing, hasLength(1));
  });

  test('跳过账本命中今天时不再补生成（规则不存在也要生效）', () {
    final missing = RepeatTaskEngine.generateMissing(
      [yesterdayInstance()],
      const {},
      now,
      skips: const {
        'g1': {'2026-11-01'},
      },
    );
    expect(missing, isEmpty);
  });

  test('跳过账本只影响命中的那一天', () {
    final missing = RepeatTaskEngine.generateMissing(
      [yesterdayInstance()],
      const {},
      now,
      skips: const {
        'g1': {'2026-10-30'},
      },
    );
    expect(missing, hasLength(1));
  });

  test('族内已有今天的实例时，不会重复生成', () {
    final todayInstance = Task(
      title: '每天运动 1 个小时',
      createdAt: now,
      updatedAt: now,
      repeatType: 1,
      repeatGroupId: 'g1',
      instanceDate: DateTime(2026, 11, 1),
    );
    final missing = RepeatTaskEngine.generateMissing(
      [yesterdayInstance(), todayInstance],
      const {},
      now,
    );
    expect(missing, isEmpty);
  });
}
