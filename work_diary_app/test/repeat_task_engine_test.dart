import 'package:flutter_test/flutter_test.dart';

import 'package:work_diary_app/models/repeat_rule.dart';
import 'package:work_diary_app/models/task.dart';
import 'package:work_diary_app/utils/repeat_task_engine.dart';

void main() {
  Task base({String? gid, DateTime? instanceDate, int repeatType = 1,
             int sortOrder = 0, DateTime? createdAt, int? repeatMonthDay}) {
    return Task(
      title: '测试任务',
      repeatType: repeatType,
      repeatGroupId: gid,
      instanceDate: instanceDate,
      repeatWeekDays: repeatType == 2 ? [DateTime.monday] : null,
      repeatMonthDay: repeatMonthDay ?? (repeatType == 3 ? 1 : null),
      createdAt: createdAt ?? DateTime(2026, 9, 1),
      sortOrder: sortOrder,
    );
  }

  group('initialInstanceDate', () {
    final now = DateTime(2026, 10, 7); // 周三

    test('日任务初始实例 = 今天', () {
      final d = RepeatTaskEngine.initialInstanceDate(
          repeatType: 1, now: now);
      expect(d, DateTime(2026, 10, 7));
    });

    test('周任务：今天命中（周三）→ 今天', () {
      final d = RepeatTaskEngine.initialInstanceDate(
          repeatType: 2, weekDays: [DateTime.wednesday], now: now);
      expect(d, DateTime(2026, 10, 7));
    });

    test('周任务：今天未命中（周一）→ 下一个命中日（下周一）', () {
      final d = RepeatTaskEngine.initialInstanceDate(
          repeatType: 2, weekDays: [DateTime.monday], now: now);
      expect(d, DateTime(2026, 10, 12));
    });

    test('月任务：本月 15 号未到 → 本月 15 号', () {
      final d = RepeatTaskEngine.initialInstanceDate(
          repeatType: 3, monthDay: 15, now: now);
      expect(d, DateTime(2026, 10, 15));
    });

    test('月任务：本月 1 号已过 → 下月 1 号', () {
      final d = RepeatTaskEngine.initialInstanceDate(
          repeatType: 3, monthDay: 1, now: now);
      expect(d, DateTime(2026, 11, 1));
    });

    test('月任务：31 号在 2 月 → 2 月最后一天（创建于 2/10）', () {
      final d = RepeatTaskEngine.initialInstanceDate(
          repeatType: 3,
          monthDay: 31,
          now: DateTime(2026, 2, 10));
      expect(d, DateTime(2026, 2, 28));
    });
  });

  group('generateMissing', () {
    test('日任务：今天无实例 → 生成今天', () {
      final tasks = [base(gid: 'g1', instanceDate: DateTime(2026, 10, 6))];
      final r = RepeatTaskEngine.generateMissing(tasks, const {}, DateTime(2026, 10, 7, 8));
      expect(r.length, 1);
      expect(r[0].instanceDate, DateTime(2026, 10, 7));
      expect(r[0].repeatGroupId, 'g1');
      expect(r[0].status, TaskStatus.planned);
    });

    test('日任务：今天已有实例 → 不生成', () {
      final tasks = [base(gid: 'g1', instanceDate: DateTime(2026, 10, 7))];
      final r = RepeatTaskEngine.generateMissing(tasks, const {}, DateTime(2026, 10, 7, 8));
      expect(r, isEmpty);
    });

    test('日任务：昨天有实例 → 生成今天', () {
      final tasks = [base(gid: 'g1', instanceDate: DateTime(2026, 10, 6))];
      final r = RepeatTaskEngine.generateMissing(tasks, const {}, DateTime(2026, 10, 7, 8));
      expect(r.length, 1);
      expect(r[0].instanceDate, DateTime(2026, 10, 7));
    });

    test('周任务：本周一已生成（今天是周二）→ 不生成', () {
      final tasks = [base(
        gid: 'g1',
        instanceDate: DateTime(2026, 10, 5), // 周一
        repeatType: 2,
      )];
      final r = RepeatTaskEngine.generateMissing(tasks, const {}, DateTime(2026, 10, 6, 8));
      expect(r, isEmpty);
    });

    test('周任务：今天周一无实例 → 生成今天', () {
      final tasks = [base(
        gid: 'g1',
        instanceDate: DateTime(2026, 9, 28), // 上一期
        repeatType: 2,
      )];
      final r = RepeatTaskEngine.generateMissing(tasks, const {}, DateTime(2026, 10, 5, 8));
      expect(r.length, 1);
      expect(r[0].instanceDate, DateTime(2026, 10, 5));
    });

    test('周任务：周五创建（实例=下周一）周二打开 → 不生成', () {
      final tasks = [base(
        gid: 'g1',
        instanceDate: DateTime(2026, 10, 12), // 下周一（未来期）
        repeatType: 2,
      )];
      final r = RepeatTaskEngine.generateMissing(tasks, const {}, DateTime(2026, 10, 6, 8));
      expect(r, isEmpty);
    });

    test('周任务：未来期已过去后（周一过了）→ 生成新一期', () {
      final tasks = [base(
        gid: 'g1',
        instanceDate: DateTime(2026, 10, 12), // 上上期
        repeatType: 2,
      )];
      final r = RepeatTaskEngine.generateMissing(tasks, const {}, DateTime(2026, 10, 19, 8));
      expect(r.length, 1);
      expect(r[0].instanceDate, DateTime(2026, 10, 19));
    });

    test('月任务：本月 1 号已过且无实例 → 生成本月 1 号（补提醒）', () {
      final tasks = [base(
        gid: 'g1',
        instanceDate: DateTime(2026, 9, 1),
        repeatType: 3,
      )];
      final r = RepeatTaskEngine.generateMissing(tasks, const {}, DateTime(2026, 10, 7, 8));
      expect(r.length, 1);
      expect(r[0].instanceDate, DateTime(2026, 10, 1));
    });

    test('月任务：本月已有实例 → 不生成', () {
      final tasks = [base(
        gid: 'g1',
        instanceDate: DateTime(2026, 10, 1),
        repeatType: 3,
      )];
      final r = RepeatTaskEngine.generateMissing(tasks, const {}, DateTime(2026, 10, 7, 8));
      expect(r, isEmpty);
    });

    test('月任务：31 号在 2 月 → 补 2 月最后一天（今天=2月末）', () {
      final tasks = [
        base(
          gid: 'g1',
          instanceDate: DateTime(2026, 1, 31),
          repeatType: 3,
          repeatMonthDay: 31,
        ),
      ];
      final r = RepeatTaskEngine.generateMissing(tasks, const {}, DateTime(2026, 2, 28, 8));
      expect(r.length, 1);
      expect(r[0].instanceDate, DateTime(2026, 2, 28));
    });

    test('月任务：31 号在 2 月，今天 2/10 未到期 → 不生成', () {
      final tasks = [
        base(
          gid: 'g1',
          instanceDate: DateTime(2026, 1, 31),
          repeatType: 3,
          repeatMonthDay: 31,
        ),
      ];
      final r = RepeatTaskEngine.generateMissing(tasks, const {}, DateTime(2026, 2, 10, 8));
      expect(r, isEmpty);
    });

    test('正常任务（repeatType=0）不参与生成', () {
      final tasks = [base(gid: 'g1', instanceDate: DateTime(2026, 10, 6), repeatType: 0)];
      final r = RepeatTaskEngine.generateMissing(tasks, const {}, DateTime(2026, 10, 7, 8));
      expect(r, isEmpty);
    });

    test('时间分量套用：模板 9:00-23:59 套到实例日期', () {
      final tasks = [
        base(gid: 'g1', instanceDate: DateTime(2026, 10, 6))
            .copyWith(
              planStartAt: DateTime(2026, 10, 6, 9, 0),
              dueAt: DateTime(2026, 10, 6, 23, 59),
            ),
      ];
      final r = RepeatTaskEngine.generateMissing(tasks, const {}, DateTime(2026, 10, 7, 8));
      expect(r.length, 1);
      expect(r[0].planStartAt, DateTime(2026, 10, 7, 9, 0));
      expect(r[0].dueAt, DateTime(2026, 10, 7, 23, 59));
    });

    test('新实例 sortOrder 置顶（全局最小-1）', () {
      final tasks = [
        base(gid: 'g1', instanceDate: DateTime(2026, 10, 6), sortOrder: 3),
        base(gid: 'g2', instanceDate: DateTime(2026, 10, 6), sortOrder: 5),
      ];
      final r = RepeatTaskEngine.generateMissing(tasks, const {}, DateTime(2026, 10, 7, 8));
      expect(r.length, 2);
      expect(r.map((e) => e.sortOrder).toSet(), {-1, -2});
    });
  });

  group('generateMissing · 规则库（删除实例后循环继续）', () {
    RepeatRule rule({
      String gid = 'g1',
      int repeatType = 1,
      List<int>? weekDays,
      int? monthDay,
      DateTime? planStartAt,
      DateTime? dueAt,
    }) {
      return RepeatRule(
        repeatGroupId: gid,
        title: '每天走路1小时',
        urgency: Urgency.normal,
        taskType: 1,
        repeatType: repeatType,
        repeatWeekDays: weekDays,
        repeatMonthDay: monthDay,
        planStartAt: planStartAt,
        dueAt: dueAt,
      );
    }

    test('【核心回归】族内实例被全部删除，仅剩规则 → 仍生成今天', () {
      // 昨天删掉了唯一实例，tasks 为空
      final tasks = <Task>[];
      final rules = {'g1': rule()};
      final r = RepeatTaskEngine.generateMissing(
          tasks, rules, DateTime(2026, 10, 14, 8));
      expect(r.length, 1, reason: '有规则无实例时应照常生成');
      expect(r[0].instanceDate, DateTime(2026, 10, 14));
      expect(r[0].repeatGroupId, 'g1');
      expect(r[0].title, '每天走路1小时');
      expect(r[0].status, TaskStatus.planned);
    });

    test('规则存在且今天已有实例 → 不生成（幂等）', () {
      final tasks = [
        base(gid: 'g1', instanceDate: DateTime(2026, 10, 14)),
      ];
      final rules = {'g1': rule()};
      final r = RepeatTaskEngine.generateMissing(
          tasks, rules, DateTime(2026, 10, 14, 8));
      expect(r, isEmpty);
    });

    test('规则时间套用：模板 9:00-23:59 套到实例日期', () {
      final rules = {
        'g1': rule(
          planStartAt: DateTime(2026, 10, 1, 9, 0),
          dueAt: DateTime(2026, 10, 1, 23, 59),
        ),
      };
      final r = RepeatTaskEngine.generateMissing(
          const [], rules, DateTime(2026, 10, 14, 8));
      expect(r.length, 1);
      expect(r[0].planStartAt, DateTime(2026, 10, 14, 9, 0));
      expect(r[0].dueAt, DateTime(2026, 10, 14, 23, 59));
    });

    test('周任务规则：实例删光后，今天（周一）生成', () {
      final rules = {'g1': rule(repeatType: 2, weekDays: [DateTime.monday])};
      final r = RepeatTaskEngine.generateMissing(
          const [], rules, DateTime(2026, 10, 12, 8)); // 周一
      expect(r.length, 1);
      expect(r[0].instanceDate, DateTime(2026, 10, 12));
    });

    test('周任务规则：非命中日打开 → 补最近一期命中日（周一）', () {
      final rules = {'g1': rule(repeatType: 2, weekDays: [DateTime.monday])};
      final r = RepeatTaskEngine.generateMissing(
          const [], rules, DateTime(2026, 10, 13, 8)); // 周二
      expect(r.length, 1);
      expect(r[0].instanceDate, DateTime(2026, 10, 12));
    });

    test('月任务规则：实例删光后，本月该日生成', () {
      final rules = {'g1': rule(repeatType: 3, monthDay: 1)};
      final r = RepeatTaskEngine.generateMissing(
          const [], rules, DateTime(2026, 10, 7, 8));
      expect(r.length, 1);
      expect(r[0].instanceDate, DateTime(2026, 10, 1));
    });

    test('规则被删除（改回正常）→ 不生成', () {
      final tasks = <Task>[];
      final rules = <String, RepeatRule>{}; // 规则已删
      final r = RepeatTaskEngine.generateMissing(tasks, rules, DateTime(2026, 10, 14, 8));
      expect(r, isEmpty);
    });

    test('规则 repeatType=0 不参与生成', () {
      final rules = {'g1': rule(repeatType: 0)};
      final r = RepeatTaskEngine.generateMissing(
          const [], rules, DateTime(2026, 10, 14, 8));
      expect(r, isEmpty);
    });

    test('实例与规则并存：规则优先作为模板', () {
      final tasks = [
        base(gid: 'g1', instanceDate: DateTime(2026, 10, 13)),
      ];
      final rules = {
        'g1': rule(
          repeatType: 2,
          weekDays: [DateTime.monday],
        ),
      };
      // 实例模板是日任务（10/13 已生成），规则模板是周任务（今天周二不命中）
      final r = RepeatTaskEngine.generateMissing(
          tasks, rules, DateTime(2026, 10, 14, 8));
      expect(r, isEmpty, reason: '规则优先：周任务周二不生成，而非按实例的日任务生成');
    });
  });
}
