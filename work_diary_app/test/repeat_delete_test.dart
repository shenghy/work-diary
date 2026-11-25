import 'package:flutter_test/flutter_test.dart';

import 'package:work_diary_app/models/repeat_fields.dart';
import 'package:work_diary_app/models/repeat_rule.dart';
import 'package:work_diary_app/models/task.dart';
import 'package:work_diary_app/utils/repeat_family.dart';
import 'package:work_diary_app/utils/repeat_task_engine.dart';

/// 永久删除循环任务：墓碑序列化、管理页过滤、引擎不再补生成。
void main() {
  RepeatRule rule({
    String gid = 'g1',
    bool stopped = false,
    bool deleted = false,
  }) {
    return RepeatRule(
      repeatGroupId: gid,
      title: '每天运动',
      urgency: Urgency.normal,
      taskType: 1,
      repeatType: 1,
      stopped: stopped,
      deleted: deleted,
      updatedAt: DateTime(2026, 11, 10, 9),
    );
  }

  Task instance(String gid, DateTime date) {
    return Task(
      id: 1,
      title: '每天运动',
      status: TaskStatus.planned,
      repeatType: 1,
      repeatGroupId: gid,
      instanceDate: date,
      createdAt: date,
      updatedAt: date,
    );
  }

  group('永久删除墓碑', () {
    test('toMap / fromMap 保留 deleted', () {
      final restored = RepeatRule.fromMap(rule(deleted: true).toMap());
      expect(restored.deleted, isTrue);
      expect(restored.isStopped, isTrue, reason: '已删除也必须算停止，引擎不能再生成');
    });

    test('copyWith(deleted: true) 同时保留原规则字段', () {
      final tombstone = rule().copyWith(deleted: true, stopped: true);
      expect(tombstone.deleted, isTrue);
      expect(tombstone.stopped, isTrue);
      expect(tombstone.title, '每天运动');
      expect(tombstone.repeatType, 1);
    });

    test('已删除的族不会出现在循环任务管理页', () {
      final families = RepeatFamily.build(
        [instance('g1', DateTime(2026, 11, 9))],
        {'g1': rule(deleted: true)},
        DateTime(2026, 11, 10),
      );
      expect(families, isEmpty);
    });

    test('已删除的族不会再被生成引擎补一期', () {
      final generated = RepeatTaskEngine.generateMissing(
        [instance('g1', DateTime(2026, 11, 9))],
        {'g1': rule(deleted: true)},
        DateTime(2026, 11, 10, 9),
      );
      expect(generated, isEmpty);
    });

    test('删除只影响自己那一族', () {
      final families = RepeatFamily.build(
        [
          instance('g1', DateTime(2026, 11, 9)),
          instance('g2', DateTime(2026, 11, 9)),
        ],
        {
          'g1': rule(deleted: true),
          'g2': rule(gid: 'g2'),
        },
        DateTime(2026, 11, 10),
      );
      expect(families, hasLength(1));
      expect(families.single.groupId, 'g2');
    });
  });
}
