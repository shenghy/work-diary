import 'package:flutter_test/flutter_test.dart';

import 'package:work_diary_app/models/repeat_rule.dart';
import 'package:work_diary_app/models/task.dart';
import 'package:work_diary_app/utils/repeat_family.dart';
import 'package:work_diary_app/utils/repeat_format.dart';
import 'package:work_diary_app/utils/repeat_task_engine.dart';

/// 循环规则上云 / 下一期提示 / 管理页汇总 的回归测试。
void main() {
  group('RepeatRule 序列化（规则上云）', () {
    final savedAt = DateTime(2026, 11, 2, 10, 30);

    test('toMap / fromMap 往返保留 stopped 与 updatedAt', () {
      final rule = RepeatRule(
        repeatGroupId: 'g1',
        title: '每天运动',
        urgency: Urgency.urgent,
        taskType: 0,
        repeatType: 2,
        repeatWeekDays: [1, 4],
        planStartAt: DateTime(2026, 11, 1, 9),
        stopped: true,
        updatedAt: savedAt,
        skippedDates: const ['2026-11-01'],
      );
      final back = RepeatRule.fromMap(rule.toMap());
      expect(back.repeatGroupId, 'g1');
      expect(back.title, '每天运动');
      expect(back.urgency, Urgency.urgent);
      expect(back.taskType, 0);
      expect(back.repeatType, 2);
      expect(back.repeatWeekDays, [1, 4]);
      expect(back.stopped, isTrue);
      expect(back.isStopped, isTrue);
      expect(back.updatedAt, savedAt);
      expect(back.skippedDates, ['2026-11-01']);
    });

    test('老数据没有 stopped/updated_at：默认未停止 + 时间足够旧', () {
      final back = RepeatRule.fromMap({
        'repeat_group_id': 'g1',
        'title': 'x',
        'repeat_type': 1,
      });
      expect(back.stopped, isFalse);
      expect(back.isStopped, isFalse);
      expect(
        back.updatedAt.isBefore(DateTime(2000)),
        isTrue,
        reason: '老数据必须比云端旧，否则永远盖住云端规则',
      );
    });

    test('copyWith 默认保留 stopped / 跳过记录', () {
      final rule = RepeatRule(
        repeatGroupId: 'g1',
        title: 'x',
        urgency: Urgency.normal,
        taskType: 1,
        repeatType: 1,
        stopped: true,
        skippedDates: const ['2026-11-01'],
        updatedAt: savedAt,
      );
      final changed = rule.copyWith(repeatType: 3, repeatMonthDay: 15);
      expect(changed.stopped, isTrue);
      expect(changed.skippedDates, ['2026-11-01']);
      expect(changed.updatedAt, savedAt, reason: '不显式传就不刷新时间戳');
      expect(changed.repeatType, 3);
    });

    test('停止的规则让引擎不再生成（不需要哨兵）', () {
      final now = DateTime(2026, 11, 2, 9);
      final tasks = [
        Task(
          title: '每天运动',
          repeatType: 1,
          repeatGroupId: 'g1',
          instanceDate: DateTime(2026, 11, 1),
          createdAt: DateTime(2026, 11, 1),
        ),
      ];
      final rules = {
        'g1': RepeatRule(
          repeatGroupId: 'g1',
          title: '每天运动',
          urgency: Urgency.normal,
          taskType: 1,
          repeatType: 1,
          stopped: true,
        ),
      };
      expect(
        RepeatTaskEngine.generateMissing(tasks, rules, now),
        isEmpty,
      );
    });
  });

  group('下一期日期', () {
    final now = DateTime(2026, 11, 2, 10); // 周一

    test('日任务：已有一期 → 次日', () {
      expect(
        RepeatTaskEngine.nextInstanceDate(
          repeatType: 1,
          now: now,
          after: DateTime(2026, 11, 2),
        ),
        DateTime(2026, 11, 3),
      );
    });

    test('日任务：一期都没有 → 今天', () {
      expect(
        RepeatTaskEngine.nextInstanceDate(repeatType: 1, now: now),
        DateTime(2026, 11, 2),
      );
    });

    test('周任务：跳过不在规则里的日期', () {
      expect(
        RepeatTaskEngine.nextInstanceDate(
          repeatType: 2,
          weekDays: [1, 4],
          now: now,
          after: DateTime(2026, 11, 2),
        ),
        DateTime(2026, 11, 5), // 周四
      );
    });

    test('月任务：31 号在小月取月末', () {
      expect(
        RepeatTaskEngine.nextInstanceDate(
          repeatType: 3,
          monthDay: 31,
          now: now,
          after: DateTime(2026, 10, 31),
        ),
        DateTime(2026, 11, 30),
      );
      expect(
        RepeatTaskEngine.nextInstanceDate(
          repeatType: 3,
          monthDay: 31,
          now: now,
          after: DateTime(2026, 11, 30),
        ),
        DateTime(2026, 12, 31),
      );
    });

    test('正常任务没有下一期', () {
      expect(RepeatTaskEngine.nextInstanceDate(repeatType: 0, now: now), isNull);
    });
  });

  group('文案', () {
    test('周任务文案不再重复"周"字', () {
      expect(
        repeatRuleLabel(repeatType: 2, weekDays: [1, 3, 5]),
        '每周一、三、五',
      );
    });

    test('周一到周五显示为「工作日」', () {
      expect(repeatRuleLabel(repeatType: 2, weekDays: [1, 2, 3, 4, 5]), '工作日');
      expect(
        repeatRuleLabel(repeatType: 2, weekDays: [1, 2, 3, 4, 5, 6]),
        '每周一、二、三、四、五、六',
      );
    });

    test('日/月任务文案', () {
      expect(repeatRuleLabel(repeatType: 1), '每日');
      expect(repeatRuleLabel(repeatType: 3, monthDay: 15), '每月15日');
      expect(repeatRuleLabel(repeatType: 0), '不循环');
    });

    test('下一期展示带星期与时间', () {
      expect(
        formatDueDate(DateTime(2026, 11, 5),
            planStartAt: DateTime(2026, 11, 1, 9, 0)),
        '11/5 周四 09:00',
      );
      expect(formatDueDate(DateTime(2026, 11, 5)), '11/5 周四');
    });
  });

  group('管理页汇总', () {
    final now = DateTime(2026, 11, 2, 10);
    Task ins({
      required int id,
      required String gid,
      required DateTime date,
      TaskStatus status = TaskStatus.planned,
      int repeatType = 1,
    }) {
      return Task(
        id: id,
        title: '每天运动',
        status: status,
        repeatType: repeatType,
        repeatGroupId: gid,
        instanceDate: date,
        createdAt: date,
      );
    }

    test('只有实例、没有规则：仍能汇总并给出下一期', () {
      final families = RepeatFamily.build(
        [
          ins(id: 1, gid: 'g1', date: DateTime(2026, 11, 1),
              status: TaskStatus.completed),
          ins(id: 2, gid: 'g1', date: DateTime(2026, 11, 2)),
        ],
        const {},
        now,
      );
      expect(families, hasLength(1));
      final f = families.single;
      expect(f.hasRule, isFalse);
      expect(f.total, 2);
      expect(f.unfinished, 1);
      expect(f.latest, DateTime(2026, 11, 2));
      expect(f.next, DateTime(2026, 11, 3));
      expect(f.stopped, isFalse);
    });

    test('规则存在：标题/星期取规则，停止后没有下一期', () {
      final rules = {
        'g1': RepeatRule(
          repeatGroupId: 'g1',
          title: '周会',
          urgency: Urgency.normal,
          taskType: 1,
          repeatType: 2,
          repeatWeekDays: [1],
          stopped: true,
        ),
      };
      final families = RepeatFamily.build(
        [ins(id: 1, gid: 'g1', date: DateTime(2026, 11, 2), repeatType: 2)],
        rules,
        now,
      );
      final f = families.single;
      expect(f.title, '周会');
      expect(f.hasRule, isTrue);
      expect(f.stopped, isTrue);
      expect(f.next, isNull);
    });

    test('只有规则、没有任何实例：也能列出来', () {
      final rules = {
        'g2': RepeatRule(
          repeatGroupId: 'g2',
          title: '月度复盘',
          urgency: Urgency.normal,
          taskType: 1,
          repeatType: 3,
          repeatMonthDay: 1,
        ),
      };
      final families = RepeatFamily.build(const [], rules, now);
      expect(families, hasLength(1));
      expect(families.single.total, 0);
      expect(families.single.latest, isNull);
      expect(families.single.next, DateTime(2026, 11, 1));
    });

    test('本地哨兵也能让族显示为已停止（规则丢失时的兜底）', () {
      final families = RepeatFamily.build(
        [ins(id: 1, gid: 'g1', date: DateTime(2026, 11, 2))],
        const {},
        now,
        skips: const {
          'g1': {RepeatRule.stoppedMarker},
        },
      );
      expect(families.single.stopped, isTrue);
      expect(families.single.next, isNull);
    });

    test('进行中的排在已停止前面', () {
      final families = RepeatFamily.build(
        [
          ins(id: 1, gid: 'a', date: DateTime(2026, 11, 2)),
          ins(id: 2, gid: 'b', date: DateTime(2026, 11, 2)),
        ],
        const {},
        now,
        skips: const {
          'b': {RepeatRule.stoppedMarker},
        },
      );
      expect(families.map((f) => f.groupId).toList(), ['a', 'b']);
    });
  });
}
