import 'package:flutter_test/flutter_test.dart';

import 'package:work_diary_app/models/repeat_fields.dart';
import 'package:work_diary_app/models/repeat_rule.dart';
import 'package:work_diary_app/models/task.dart';
import 'package:work_diary_app/utils/repeat_task_engine.dart';

/// 日/周/月任务：停止循环、跳过账单、同步过滤、脏数据容错的回归测试。
void main() {
  Task instance({
    required String gid,
    required DateTime date,
    int repeatType = 1,
    List<int>? weekDays,
    int? monthDay,
    TaskStatus status = TaskStatus.planned,
    int? id,
    DateTime? createdAt,
  }) {
    return Task(
      id: id,
      title: '每天运动',
      status: status,
      repeatType: repeatType,
      repeatGroupId: gid,
      instanceDate: date,
      repeatWeekDays: weekDays,
      repeatMonthDay: monthDay,
      createdAt: createdAt ?? date,
      updatedAt: date,
    );
  }

  RepeatRule rule({
    String gid = 'g1',
    int repeatType = 1,
    List<int>? weekDays,
    int? monthDay,
    List<String> skipped = const <String>[],
  }) {
    return RepeatRule(
      repeatGroupId: gid,
      title: '每天运动',
      urgency: Urgency.normal,
      taskType: 1,
      repeatType: repeatType,
      repeatWeekDays: weekDays,
      repeatMonthDay: monthDay,
      skippedDates: skipped,
    );
  }

  group('停止循环（哨兵标记）', () {
    final now = DateTime(2026, 11, 2, 9);

    test('【核心回归】规则还在 + 旧实例还在，整族也不再生成了', () {
      // 停止循环以前的实现只删规则：引擎会拿现存实例当模板继续补生成，
      // 于是"停止循环并删除"删完立刻又被补回来。
      final tasks = [instance(gid: 'g1', date: DateTime(2026, 11, 1))];
      final rules = {'g1': rule()};
      final skips = {
        'g1': {RepeatRule.stoppedMarker},
      };
      final r = RepeatTaskEngine.generateMissing(tasks, rules, now, skips: skips);
      expect(r, isEmpty, reason: '已停止循环的族不允许再生成新一期');
    });

    test('只有实例没有规则 + 停止标记 → 不生成', () {
      final tasks = [instance(gid: 'g1', date: DateTime(2026, 11, 1))];
      final r = RepeatTaskEngine.generateMissing(
        tasks,
        const {},
        now,
        skips: const {
          'g1': {RepeatRule.stoppedMarker},
        },
      );
      expect(r, isEmpty);
    });

    test('停止标记只影响自己那一族', () {
      final tasks = [
        instance(gid: 'g1', date: DateTime(2026, 11, 1)),
        instance(gid: 'g2', date: DateTime(2026, 11, 1)),
      ];
      final r = RepeatTaskEngine.generateMissing(
        tasks,
        const {},
        now,
        skips: const {
          'g1': {RepeatRule.stoppedMarker},
        },
      );
      expect(r, hasLength(1));
      expect(r.single.repeatGroupId, 'g2');
    });

    test('RepeatRule.isSkipped 对停止标记同样返回 true', () {
      final r = rule(skipped: const [RepeatRule.stoppedMarker]);
      expect(r.isStopped, isTrue);
      expect(r.isSkipped(DateTime(2026, 11, 2)), isTrue);
    });

    test('withSkipped 不会把停止标记清理掉（它不是日期）', () {
      final r = rule(skipped: const [RepeatRule.stoppedMarker])
          .withSkipped(DateTime(2026, 11, 2));
      expect(r.skippedDates, contains(RepeatRule.stoppedMarker));
      expect(r.skippedDates, contains('2026-11-02'));
    });
  });

  group('仅删除本期（跳过账单）', () {
    test('删掉今天 → 今天不补，明天照常', () {
      final tasks = [instance(gid: 'g1', date: DateTime(2026, 11, 1))];
      final skips = {
        'g1': {'2026-11-02'},
      };
      // 当天：不补
      expect(
        RepeatTaskEngine.generateMissing(
            tasks, const {}, DateTime(2026, 11, 2, 9), skips: skips),
        isEmpty,
      );
      // 次日：正常生成
      final next = RepeatTaskEngine.generateMissing(
          tasks, const {}, DateTime(2026, 11, 3, 9), skips: skips);
      expect(next, hasLength(1));
      expect(next.single.instanceDate, DateTime(2026, 11, 3));
    });
  });

  group('同步下发实例过滤', () {
    final local = [
      instance(gid: 'g1', id: 1, date: DateTime(2026, 11, 2)),
    ];

    test('本机删掉的期次被别的设备补生成回来 → 丢弃', () {
      final incoming = [
        instance(gid: 'g1', id: 1, date: DateTime(2026, 11, 2)),
      ];
      final r = RepeatTaskEngine.filterIncomingInstances(
        incoming,
        local,
        skips: const {
          'g1': {'2026-11-02'},
        },
      );
      expect(r, isEmpty);
    });

    test('未标记的多余期次照常保留', () {
      final incoming = [
        instance(gid: 'g1', id: 1, date: DateTime(2026, 11, 2)),
        instance(gid: 'g2', id: 2, date: DateTime(2026, 11, 2)),
      ];
      final r = RepeatTaskEngine.filterIncomingInstances(
        incoming,
        local,
        skips: const {
          'g1': {'2026-11-02'},
        },
      );
      expect(r, hasLength(1));
      expect(r.single.repeatGroupId, 'g2');
    });

    test('已停止循环的族：本机已有的期次保留，新补出来的丢弃', () {
      final incoming = [
        instance(gid: 'g1', id: 1, date: DateTime(2026, 11, 2)), // 本机已有
        instance(gid: 'g1', id: 9, date: DateTime(2026, 11, 5)), // 别的设备补的
      ];
      final r = RepeatTaskEngine.filterIncomingInstances(
        incoming,
        local,
        skips: const {
          'g1': {RepeatRule.stoppedMarker},
        },
      );
      expect(r, hasLength(1));
      expect(r.single.instanceDate, DateTime(2026, 11, 2));
    });

    test('普通任务与无账本的任务不受影响', () {
      final plain = Task(id: 3, title: '普通任务', createdAt: DateTime(2026, 11, 1));
      final r = RepeatTaskEngine.filterIncomingInstances(
        [plain],
        local,
        skips: const {
          'g1': {RepeatRule.stoppedMarker},
        },
      );
      expect(r, hasLength(1));
    });

    test('账本为空时原样返回', () {
      final incoming = [instance(gid: 'g1', date: DateTime(2026, 11, 2))];
      final r = RepeatTaskEngine.filterIncomingInstances(incoming, local);
      expect(r, hasLength(1));
    });
  });

  group('星期 / 每月几号的脏数据兜底', () {
    final now = DateTime(2026, 11, 2, 9); // 周一

    test('星期含越界值（0/8）时只保留合法值', () {
      expect(parseRepeatWeekDays('0,8,3'), [3]);
      expect(parseRepeatWeekDays([DateTime.sunday]), [7]);
      expect(parseRepeatWeekDays(''), isNull);
      expect(parseRepeatWeekDays('0,99'), isNull);
    });

    test('周任务星期全非法时按周一兜底，仍会生成', () {
      // 引擎侧传入的 Task 可能来自云端脏数据，这里直接构造越界星期
      final t = instance(
        gid: 'g1',
        date: DateTime(2026, 10, 26),
        repeatType: 2,
        weekDays: [0, 99],
      );
      final r = RepeatTaskEngine.generateMissing([t], const {}, now);
      expect(r, hasLength(1));
      expect(r.single.instanceDate, DateTime(2026, 11, 2)); // 周一
    });

    test('每月几号越界按月初兜底', () {
      expect(normalizeRepeatMonthDay(0), isNull);
      expect(normalizeRepeatMonthDay(45), isNull);
      expect(normalizeRepeatMonthDay('15'), 15);
      expect(normalizeRepeatMonthDay(31), 31);
    });
  });

  group('模型容错（旧数据/脏数据不能抛异常）', () {
    test('Task.fromMap 遇到越界的循环字段不抛异常', () {
      final t = Task.fromMap({
        'id': 1,
        'title': 'x',
        'created_at': DateTime(2026, 11, 1).toIso8601String(),
        'repeat_type': 9,
        'repeat_week_days': '0,8,3',
        'repeat_month_day': 45,
      });
      expect(t.repeatType, 0);
      expect(t.repeatWeekDays, [3]);
      expect(t.repeatMonthDay, isNull);
    });

    test('RepeatRule.fromMap 缺字段/时间格式错也不抛异常', () {
      final r = RepeatRule.fromMap({
        'repeat_group_id': 'g1',
        'repeat_type': 2,
        'repeat_week_days': '1,3',
        'plan_start_at': '不是时间',
        'skip_dates': '2026-11-01,,2026-11-02',
      });
      expect(r.title, '');
      expect(r.repeatType, 2);
      expect(r.repeatWeekDays, [1, 3]);
      expect(r.planStartAt, isNull);
      expect(r.skippedDates, ['2026-11-01', '2026-11-02']);
    });

    test('fromTask 默认不带上跳过记录，但可由调用方传入（编辑时保留）', () {
      final t = instance(gid: 'g1', date: DateTime(2026, 11, 2));
      expect(RepeatRule.fromTask(t).skippedDates, isEmpty);
      expect(
        RepeatRule.fromTask(t, skippedDates: const ['2026-11-01']).skippedDates,
        ['2026-11-01'],
      );
    });
  });

  group('同族配置同步（徽章一致性）', () {
    test('sameSchedule 正确识别配置是否变化', () {
      final daily = instance(gid: 'g1', date: DateTime(2026, 11, 2));
      expect(
        RepeatTaskEngine.sameSchedule(daily, repeatType: 1),
        isTrue,
      );
      expect(
        RepeatTaskEngine.sameSchedule(daily, repeatType: 2, weekDays: [1]),
        isFalse,
      );

      final weekly = instance(
        gid: 'g1',
        date: DateTime(2026, 11, 2),
        repeatType: 2,
        weekDays: [1, 4],
      );
      expect(
        RepeatTaskEngine.sameSchedule(weekly,
            repeatType: 2, weekDays: [4, 1]),
        isTrue,
        reason: '星期顺序不同但集合相同，视为未变化',
      );
      expect(
        RepeatTaskEngine.sameSchedule(weekly,
            repeatType: 2, weekDays: [1]),
        isFalse,
      );
    });

    test('applySchedule 切换类型时清理多余字段', () {
      final monthly = instance(
        gid: 'g1',
        date: DateTime(2026, 11, 2),
        repeatType: 3,
        monthDay: 15,
      );
      final moved = RepeatTaskEngine.applySchedule(
        monthly,
        repeatType: 2,
        weekDays: [1, 3],
        now: DateTime(2026, 11, 2, 10),
      );
      expect(moved.repeatType, 2);
      expect(moved.repeatWeekDays, [1, 3]);
      expect(moved.repeatMonthDay, isNull, reason: '切到周任务要清掉每月几号');
      expect(moved.title, monthly.title, reason: '只改 schedule 字段');
      expect(moved.instanceDate, monthly.instanceDate);
      expect(moved.updatedAt, DateTime(2026, 11, 2, 10));
    });
  });
}
