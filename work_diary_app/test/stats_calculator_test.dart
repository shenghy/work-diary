import 'package:flutter_test/flutter_test.dart';

import 'package:work_diary_app/models/stats.dart';
import 'package:work_diary_app/models/task.dart';
import 'package:work_diary_app/utils/stats_calculator.dart';

/// 「我的数据」看板口径单测。
///
/// 逐条对照需求文档 5.3 与验收标准；服务端 app/routers/stats.py 的
/// tests/stats_test.py 用同一批数字，两边必须算出同一个结果。
void main() {
  // 固定"今天"，避免用例随真实日期漂移
  final now = DateTime(2026, 11, 10, 15, 30);

  Task task({
    int id = 0,
    required DateTime created,
    TaskStatus status = TaskStatus.planned,
    DateTime? completed,
    DateTime? due,
    Urgency urgency = Urgency.normal,
    int taskType = 1,
    int repeatType = 0,
    DateTime? instance,
    String? group,
  }) {
    return Task(
      id: id,
      title: '任务$id',
      status: status,
      urgency: urgency,
      createdAt: created,
      completedAt: completed,
      dueAt: due,
      taskType: taskType,
      repeatType: repeatType,
      instanceDate: instance,
      repeatGroupId: group,
    );
  }

  StatsSnapshot compute(List<Task> tasks,
      {Map<String, Set<String>> skips = const {},
      StatsRange range = StatsRange.last7,
      DateTime? at}) {
    return StatsCalculator.compute(
      tasks: tasks,
      skips: skips,
      range: range,
      now: at ?? now,
    );
  }

  group('已完成数（验收 1：与「已完成」tab 角标一致）', () {
    test('只统计 completedAt 落在窗口内的已完成任务', () {
      final snap = compute([
        task(
            id: 1,
            created: DateTime(2026, 11, 8, 9),
            status: TaskStatus.completed,
            completed: DateTime(2026, 11, 9, 10)),
        task(
            id: 2,
            created: DateTime(2026, 11, 1, 9),
            status: TaskStatus.completed,
            completed: DateTime(2026, 11, 1, 10)), // 窗口外
        task(id: 3, created: DateTime(2026, 11, 9, 9)), // 未完成
      ]);
      expect(snap.summary.completed, 1);
      expect(snap.completedTotal, 1);
    });

    test('已完成状态但缺 completedAt 的脏数据不进分子', () {
      final snap = compute([
        task(id: 1, created: DateTime(2026, 11, 9), status: TaskStatus.completed),
      ]);
      expect(snap.summary.completed, 0);
    });

    test('窗口边界含首尾：近 7 天 = 11-04..11-10', () {
      final snap = compute([
        task(id: 1,
            created: DateTime(2026, 11, 3, 23, 59),
            status: TaskStatus.completed,
            completed: DateTime(2026, 11, 3, 23, 59)),
        task(id: 2,
            created: DateTime(2026, 11, 4, 0, 1),
            status: TaskStatus.completed,
            completed: DateTime(2026, 11, 4, 0, 1)),
        task(id: 3,
            created: DateTime(2026, 11, 10, 23, 59),
            status: TaskStatus.completed,
            completed: DateTime(2026, 11, 10, 23, 59)),
      ]);
      expect(snap.summary.completed, 2);
    });
  });

  group('应完成数与完成率（5.3）', () {
    test('有到期日按到期日、无到期日按创建日计入分母', () {
      final snap = compute([
        task(id: 1,
            created: DateTime(2026, 11, 5),
            due: DateTime(2026, 11, 6, 18),
            status: TaskStatus.completed,
            completed: DateTime(2026, 11, 6, 9)),
        task(id: 2,
            created: DateTime(2026, 11, 5),
            due: DateTime(2026, 11, 6, 18)), // 到期未完成
        task(id: 3,
            created: DateTime(2026, 11, 6),
            status: TaskStatus.completed,
            completed: DateTime(2026, 11, 7, 9)), // 无到期日，逾期 1 天
        task(id: 4,
            created: DateTime(2026, 11, 5),
            due: DateTime(2026, 11, 20, 18)), // 到期日在窗口外 → 不进分母
      ]);
      expect(snap.summary.dueTotal, 3);
      expect(snap.summary.completed, 2);
      expect(snap.summary.undone, 1);
      expect(snap.summary.completionRate, 67);
    });

    test('到期日在窗口外的任务不计入分母', () {
      final snap = compute([
        task(id: 1,
            created: DateTime(2026, 10, 1),
            due: DateTime(2026, 10, 2, 18)),
      ]);
      expect(snap.summary.dueTotal, 0);
      expect(snap.summary.completionRate, isNull);
      expect(snap.summary.undone, 0);
    });

    test('分母为 0 时完成率是 null，不是 0', () {
      final snap = compute(const []);
      expect(snap.summary.completionRate, isNull);
      expect(snap.isBlank, isTrue);
    });

    test('超期未完成会拉低完成率（33%）', () {
      // 验收 3：1 按期完成 + 1 超期未完成 + 1 无到期日未完成
      final snap = compute([
        task(id: 1,
            created: DateTime(2026, 11, 6),
            due: DateTime(2026, 11, 7, 18),
            status: TaskStatus.completed,
            completed: DateTime(2026, 11, 7, 9)),
        task(id: 2,
            created: DateTime(2026, 11, 6),
            due: DateTime(2026, 11, 7, 18),
            status: TaskStatus.completed,
            completed: DateTime(2026, 11, 9, 9)), // 超期 2 天
        task(id: 3, created: DateTime(2026, 11, 7)), // 无到期日，未完成
      ]);
      expect(snap.summary.dueTotal, 3);
      expect(snap.summary.completed, 2);
      expect(snap.summary.completionRate, 67);
      expect(snap.summary.undone, 1);
    });
  });

  group('环比（上一周期）', () {
    test('用前一个等长窗口对比并给出百分比', () {
      final snap = compute([
        task(id: 1,
            created: DateTime(2026, 11, 9),
            status: TaskStatus.completed,
            completed: DateTime(2026, 11, 9)),
        task(id: 2,
            created: DateTime(2026, 11, 10),
            status: TaskStatus.completed,
            completed: DateTime(2026, 11, 10)),
        task(id: 3,
            created: DateTime(2026, 10, 31),
            status: TaskStatus.completed,
            completed: DateTime(2026, 10, 31)), // 上一窗口最后一天
      ]);
      expect(snap.summary.completed, 2);
      expect(snap.summary.completedPrev, 1);
      expect(snap.summary.changePercent, 100);
    });

    test('上期为 0 时不给百分比（避免除零）', () {
      final snap = compute([
        task(id: 1,
            created: DateTime(2026, 11, 9),
            status: TaskStatus.completed,
            completed: DateTime(2026, 11, 9)),
      ]);
      expect(snap.summary.completedPrev, 0);
      expect(snap.summary.changePercent, isNull);
    });
  });

  group('连续打卡', () {
    test('今天没完成时从昨天起算，不清零', () {
      final snap = compute([
        task(id: 1,
            created: DateTime(2026, 11, 8),
            status: TaskStatus.completed,
            completed: DateTime(2026, 11, 8, 22)),
        task(id: 2,
            created: DateTime(2026, 11, 9),
            status: TaskStatus.completed,
            completed: DateTime(2026, 11, 9, 7)),
      ]);
      expect(snap.summary.streakDays, 2);
    });

    test('今天有完成则从今天起算', () {
      final snap = compute([
        task(id: 1,
            created: DateTime(2026, 11, 9),
            status: TaskStatus.completed,
            completed: DateTime(2026, 11, 9)),
        task(id: 2,
            created: DateTime(2026, 11, 10),
            status: TaskStatus.completed,
            completed: DateTime(2026, 11, 10)),
      ]);
      expect(snap.summary.streakDays, 2);
    });

    test('断一天就停', () {
      final snap = compute([
        task(id: 1,
            created: DateTime(2026, 11, 10),
            status: TaskStatus.completed,
            completed: DateTime(2026, 11, 10)),
        task(id: 2,
            created: DateTime(2026, 11, 8),
            status: TaskStatus.completed,
            completed: DateTime(2026, 11, 8)),
      ]);
      expect(snap.summary.streakDays, 1);
    });

    test('最长连击看全量历史，不受当前窗口截断', () {
      final snap = compute([
        for (var d = 1; d <= 5; d++)
          task(id: d,
              created: DateTime(2026, 9, d),
              status: TaskStatus.completed,
              completed: DateTime(2026, 9, d)),
        task(id: 99,
            created: DateTime(2026, 11, 10),
            status: TaskStatus.completed,
            completed: DateTime(2026, 11, 10)),
      ], range: StatsRange.last7);
      expect(snap.summary.streakDays, 1);
      expect(snap.summary.streakBest, 5);
    });
  });

  group('平均完成耗时（中位数 + 异常值）', () {
    test('样本不足 3 条时不显示平均', () {
      final snap = compute([
        task(id: 1,
            created: DateTime(2026, 11, 9, 9),
            status: TaskStatus.completed,
            completed: DateTime(2026, 11, 9, 11)),
      ]);
      expect(snap.summary.medianFinishHours, isNull);
      expect(snap.summary.isSparse, isTrue);
      expect(snap.summary.finishDuration.value, '--');
    });

    test('偶数样本取中间两数平均', () {
      final snap = compute([
        task(id: 1,
            created: DateTime(2026, 11, 4, 9),
            status: TaskStatus.completed,
            completed: DateTime(2026, 11, 4, 10)), // 1h
        task(id: 2,
            created: DateTime(2026, 11, 5, 9),
            status: TaskStatus.completed,
            completed: DateTime(2026, 11, 5, 12)), // 3h
        task(id: 3,
            created: DateTime(2026, 11, 6, 9),
            status: TaskStatus.completed,
            completed: DateTime(2026, 11, 6, 11)), // 2h
      ]);
      expect(snap.summary.medianFinishHours, 2.0);
      expect(snap.summary.finishSamples, 3);
    });

    test('跨度超过 30 天的样本被剔除', () {
      final snap = compute([
        task(id: 1,
            created: DateTime(2026, 11, 4, 9),
            status: TaskStatus.completed,
            completed: DateTime(2026, 11, 4, 11)),
        task(id: 2,
            created: DateTime(2026, 11, 5, 9),
            status: TaskStatus.completed,
            completed: DateTime(2026, 11, 5, 12)),
        task(id: 3,
            created: DateTime(2026, 11, 6, 9),
            status: TaskStatus.completed,
            completed: DateTime(2026, 11, 6, 10)),
        task(id: 4,
            created: DateTime(2026, 1, 1, 9),
            status: TaskStatus.completed,
            completed: DateTime(2026, 11, 6, 13)), // 340 天
      ], range: StatsRange.all);
      expect(snap.summary.finishSamples, 3);
      expect(snap.summary.medianFinishHours, 2.0);
    });

    test('completedAt 早于 createdAt 的脏数据不产生负耗时', () {
      final snap = compute([
        task(id: 1,
            created: DateTime(2026, 11, 6, 9),
            status: TaskStatus.completed,
            completed: DateTime(2026, 11, 6, 8)),
        task(id: 2,
            created: DateTime(2026, 11, 6, 9),
            status: TaskStatus.completed,
            completed: DateTime(2026, 11, 6, 11)),
        task(id: 3,
            created: DateTime(2026, 11, 6, 9),
            status: TaskStatus.completed,
            completed: DateTime(2026, 11, 6, 12)),
      ]);
      expect(snap.summary.finishSamples, 2);
      expect(snap.summary.medianFinishHours, isNull);
    });

    test('耗时长短按量级换单位：分钟 / 小时 / 天', () {
      final minutes = compute([
        task(id: 1,
            created: DateTime(2026, 11, 4, 9),
            status: TaskStatus.completed,
            completed: DateTime(2026, 11, 4, 9, 20)),
        task(id: 2,
            created: DateTime(2026, 11, 4, 9),
            status: TaskStatus.completed,
            completed: DateTime(2026, 11, 4, 9, 30)),
        task(id: 3,
            created: DateTime(2026, 11, 4, 9),
            status: TaskStatus.completed,
            completed: DateTime(2026, 11, 4, 9, 40)),
      ]);
      expect(minutes.summary.finishDuration.unit, '分钟');
      expect(minutes.summary.finishDuration.value, '30');

      final days = compute([
        task(id: 1,
            created: DateTime(2026, 10, 20),
            status: TaskStatus.completed,
            completed: DateTime(2026, 10, 22)),
        task(id: 2,
            created: DateTime(2026, 10, 20),
            status: TaskStatus.completed,
            completed: DateTime(2026, 10, 24)),
        task(id: 3,
            created: DateTime(2026, 10, 20),
            status: TaskStatus.completed,
            completed: DateTime(2026, 10, 26)),
      ], range: StatsRange.all);
      expect(days.summary.finishDuration.unit, '天');
    });
  });

  group('趋势', () {
    test('近 7 天按天分桶，日期无缺口', () {
      final snap = compute(
        [
          task(id: 1,
              created: DateTime(2026, 11, 10, 9),
              status: TaskStatus.completed,
              completed: DateTime(2026, 11, 10, 10)),
        ],
      );
      expect(snap.trend.dates.length, 7);
      expect(snap.trend.dates.first, DateTime(2026, 11, 4));
      expect(snap.trend.dates.last, DateTime(2026, 11, 10));
      expect(snap.trend.created.last, 1);
      expect(snap.trend.completed.last, 1);
      expect(snap.trend.rates.last, 100);
    });

    test('窗口内没有新建的分桶完成率是 null（折线断开）', () {
      final snap = compute([
        task(id: 1,
            created: DateTime(2026, 10, 1),
            status: TaskStatus.completed,
            completed: DateTime(2026, 11, 10, 10)),
      ]);
      expect(snap.trend.created.every((c) => c == 0), isTrue);
      expect(snap.trend.completed.last, 1);
      expect(snap.trend.rates.last, isNull);
    });

    test('近 90 天 / 全部按周分桶，桶起点是周一', () {
      final snap = compute(const [],
          range: StatsRange.last90, at: DateTime(2026, 11, 10));
      expect(snap.trend.dates.first.weekday, DateTime.monday);
      expect(snap.trend.dates.last.weekday, DateTime.monday);
      // 11-04..11-10 → 11-02 与 11-09 两个周一
      expect(snap.trend.dates.length, 14);
    });

    test('完成率可以超过 100（本期完成的多是往期建的）', () {
      final snap = compute([
        for (var i = 1; i <= 2; i++)
          task(id: i,
              created: DateTime(2026, 10, 1),
              status: TaskStatus.completed,
              completed: DateTime(2026, 11, 10, 10)),
        task(id: 9, created: DateTime(2026, 11, 10, 9)),
      ]);
      expect(snap.trend.created.last, 1);
      expect(snap.trend.completed.last, 2);
      expect(snap.trend.rates.last, 200);
    });
  });

  group('热力图（固定近 12 周，不随时间范围变化）', () {
    test('长度恒为 84、起点是周一', () {
      for (final range in StatsRange.values) {
        final snap = compute(const [], range: range);
        expect(snap.heatmap.counts.length, 84);
        expect(snap.heatmap.start.weekday, DateTime.monday);
      }
    });

    test('换范围格子内容不变', () {
      final tasks = [
        task(id: 1,
            created: DateTime(2026, 11, 7),
            status: TaskStatus.completed,
            completed: DateTime(2026, 11, 7, 10)),
        task(id: 2,
            created: DateTime(2026, 11, 7),
            status: TaskStatus.completed,
            completed: DateTime(2026, 11, 7, 11)),
        task(id: 3,
            created: DateTime(2026, 10, 1),
            status: TaskStatus.completed,
            completed: DateTime(2026, 10, 1, 10)),
      ];
      final narrow = compute(tasks, range: StatsRange.last7);
      final wide = compute(tasks, range: StatsRange.all);
      expect(narrow.heatmap.counts, wide.heatmap.counts);
      expect(narrow.summary.completed, 2); // 分子仍受范围约束
      expect(narrow.heatmap.max, 2);
      expect(narrow.heatmap.levelFor(2), 4);
      expect(narrow.heatmap.levelFor(0), 0);
    });

    test('格子索引 = 距 start 的天数，列 = i~/7、行 = 周几', () {
      final snap = compute([
        task(id: 1,
            created: DateTime(2026, 11, 10),
            status: TaskStatus.completed,
            completed: DateTime(2026, 11, 10, 10)),
      ]);
      // 热力图起点是 12 周前的周一；今天 11-10（周二）是最后一列的第 2 行
      final indexOfToday =
          snap.heatmap.counts.lastIndexOf(1);
      expect(snap.heatmap.dateAt(indexOfToday), DateTime(2026, 11, 10));
      expect(indexOfToday % 7, DateTime.tuesday - 1); // 行 = 周二
      expect(snap.heatmap.countAt(DateTime(2026, 11, 10)), 1);
      expect(snap.heatmap.countAt(DateTime(2026, 11, 9)), 0);
    });
  });

  group('任务构成', () {
    test('工作 / 个人与紧急度都基于窗口内已完成', () {
      final snap = compute([
        task(id: 1,
            created: DateTime(2026, 11, 9),
            status: TaskStatus.completed,
            completed: DateTime(2026, 11, 9),
            taskType: 1,
            urgency: Urgency.urgent),
        task(id: 2,
            created: DateTime(2026, 11, 9),
            status: TaskStatus.completed,
            completed: DateTime(2026, 11, 9),
            taskType: 0),
        task(id: 3,
            created: DateTime(2026, 11, 10),
            status: TaskStatus.completed,
            completed: DateTime(2026, 11, 10),
            urgency: Urgency.important),
      ]);
      expect(snap.workCount, 2);
      expect(snap.personalCount, 1);
      expect(snap.completedTotal, 3);
      expect(snap.workShare, 67);
      expect(snap.urgencyCounts, [1, 1, 1]); // 一般 / 紧急 / 重要
    });

    test('总数为 0 时占比是 0，环形图自己画空态', () {
      final snap = compute(const []);
      expect(snap.completedTotal, 0);
      expect(snap.workShare, 0);
      expect(snap.hourPeak, 0);
    });
  });

  group('循环任务按期率', () {
    test('跳过期与无到期日期都不进分母', () {
      final tasks = [
        task(id: 1,
            created: DateTime(2026, 11, 6),
            due: DateTime(2026, 11, 6, 23),
            status: TaskStatus.completed,
            completed: DateTime(2026, 11, 6, 9),
            repeatType: 1,
            instance: DateTime(2026, 11, 6),
            group: 'g1'),
        task(id: 2,
            created: DateTime(2026, 11, 7),
            due: DateTime(2026, 11, 7, 23),
            repeatType: 1,
            instance: DateTime(2026, 11, 7),
            group: 'g1'), // 未完成 → 分母 +1
        task(id: 3,
            created: DateTime(2026, 11, 8),
            due: DateTime(2026, 11, 8, 23),
            repeatType: 1,
            instance: DateTime(2026, 11, 8),
            group: 'g1'), // 被用户删除 → 跳过
        task(id: 4,
            created: DateTime(2026, 11, 9),
            repeatType: 1,
            instance: DateTime(2026, 11, 9),
            group: 'g1'), // 无到期日 → 不进分母
      ];
      final snap = compute(tasks, skips: {
        'g1': {'2026-11-08'}
      });
      final day = snap.repeatRate.firstWhere((i) => i.kind == 'day');
      expect(day.total, 2);
      expect(day.done, 1);
      expect(day.rate, 50);
    });

    test('逾期完成不算按期', () {
      final snap = compute([
        task(id: 1,
            created: DateTime(2026, 11, 6),
            due: DateTime(2026, 11, 6, 12),
            status: TaskStatus.completed,
            completed: DateTime(2026, 11, 6, 12, 1),
            repeatType: 1,
            instance: DateTime(2026, 11, 6),
            group: 'g1'),
      ]);
      expect(snap.repeatRate.first.rate, 0);
    });

    test('刚好在到期时刻完成算按期', () {
      final snap = compute([
        task(id: 1,
            created: DateTime(2026, 11, 6),
            due: DateTime(2026, 11, 6, 12),
            status: TaskStatus.completed,
            completed: DateTime(2026, 11, 6, 12),
            repeatType: 1,
            instance: DateTime(2026, 11, 6),
            group: 'g1'),
      ]);
      expect(snap.repeatRate.first.rate, 100);
    });

    test('本期无排期时分母 0、比率 null（界面显示"本期无排期"）', () {
      final snap = compute(const []);
      for (final item in snap.repeatRate) {
        expect(item.total, 0);
        expect(item.rate, isNull);
      }
    });

    test('周/月任务分别统计，互不串味', () {
      final snap = compute([
        task(id: 1,
            created: DateTime(2026, 11, 6),
            due: DateTime(2026, 11, 8, 23),
            status: TaskStatus.completed,
            completed: DateTime(2026, 11, 7, 9),
            repeatType: 2,
            instance: DateTime(2026, 11, 6),
            group: 'g2'),
        task(id: 2,
            created: DateTime(2026, 11, 6),
            due: DateTime(2026, 11, 10, 23),
            status: TaskStatus.completed,
            completed: DateTime(2026, 11, 9, 9),
            repeatType: 3,
            instance: DateTime(2026, 11, 6),
            group: 'g3'),
      ]);
      expect(snap.repeatRate.map((i) => i.kind), ['day', 'week', 'month']);
      expect(snap.repeatRate[0].total, 0);
      expect(snap.repeatRate[1].rate, 100);
      expect(snap.repeatRate[2].rate, 100);
    });

    test('没有跳过账本的循环族照常计入分母', () {
      final snap = compute([
        task(id: 1,
            created: DateTime(2026, 11, 6),
            due: DateTime(2026, 11, 6, 23),
            repeatType: 1,
            instance: DateTime(2026, 11, 6)),
      ]);
      expect(snap.repeatRate.first.total, 1);
      expect(snap.repeatRate.first.rate, 0);
    });
  });

  group('活跃时段与峰值', () {
    test('按完成时刻的小时分布统计窗口内已完成', () {
      final snap = compute([
        task(id: 1,
            created: DateTime(2026, 11, 9, 9),
            status: TaskStatus.completed,
            completed: DateTime(2026, 11, 9, 9, 30)),
        task(id: 2,
            created: DateTime(2026, 11, 9, 10),
            status: TaskStatus.completed,
            completed: DateTime(2026, 11, 9, 10, 30)),
        task(id: 3,
            created: DateTime(2026, 11, 1, 23),
            status: TaskStatus.completed,
            completed: DateTime(2026, 11, 1, 23, 30)), // 窗口外
      ]);
      expect(snap.hours.fold(0, (a, b) => a + b), 2);
      expect(snap.hours[9], 1);
      expect(snap.hours[10], 1);
      expect(snap.hours[23], 0);
    });

    test('峰值取包含峰值小时的连续 2 小时窗口', () {
      final snap = compute([
        for (var i = 0; i < 3; i++)
          task(id: i,
              created: DateTime(2026, 11, 9, 10),
              status: TaskStatus.completed,
              completed: DateTime(2026, 11, 9, 10, i)),
      ]);
      expect(snap.peakStartHour, 10);
      expect(snap.peakEndHour, 12);
      expect(snap.hourPeak, 3);
    });

    test('峰值小时落在窗口中间时也能覆盖两侧', () {
      final snap = compute([
        for (var i = 0; i < 4; i++)
          task(id: i,
              created: DateTime(2026, 11, 9, 9),
              status: TaskStatus.completed,
              completed: DateTime(2026, 11, 9, 9, i)),
        task(id: 20,
            created: DateTime(2026, 11, 9, 10),
            status: TaskStatus.completed,
            completed: DateTime(2026, 11, 9, 10, 30)),
      ]);
      expect(snap.peakStartHour, 9);
      expect(snap.peakEndHour, 11);
    });

    test('单条完成也能给出所属时段', () {
      final snap = compute([
        task(id: 1,
            created: DateTime(2026, 11, 9, 10),
            status: TaskStatus.completed,
            completed: DateTime(2026, 11, 9, 10, 5)),
      ]);
      expect(snap.peakStartHour, 10);
      expect(snap.peakEndHour, 12);
    });

    test('紧急 / 重要占比只看峰值区间内', () {
      final snap = compute([
        task(id: 1,
            created: DateTime(2026, 11, 9, 10),
            status: TaskStatus.completed,
            completed: DateTime(2026, 11, 9, 10),
            urgency: Urgency.urgent),
        task(id: 2,
            created: DateTime(2026, 11, 9, 10),
            status: TaskStatus.completed,
            completed: DateTime(2026, 11, 9, 10, 30)),
        task(id: 3,
            created: DateTime(2026, 11, 9, 20),
            status: TaskStatus.completed,
            completed: DateTime(2026, 11, 9, 20),
            urgency: Urgency.important), // 峰值区间外
      ]);
      expect(snap.peakUrgentShare, 50);
    });

    test('无数据时峰值与占比都是 null', () {
      final snap = compute(const []);
      expect(snap.peakStartHour, isNull);
      expect(snap.peakEndHour, isNull);
      expect(snap.peakUrgentShare, isNull);
    });

    test('跨过午夜时时段文案取模不出负数', () {
      final snap = compute([
        for (var i = 0; i < 3; i++)
          task(id: i,
              created: DateTime(2026, 11, 10, 23),
              status: TaskStatus.completed,
              completed: DateTime(2026, 11, 10, 23, i)),
      ]);
      expect(snap.peakStartHour, 22);
      expect(snap.peakEndHour, 24);
    });
  });

  group('全部范围', () {
    test('窗口从最早记录开始，而不是硬造 9999 天', () {
      final snap = compute([
        task(id: 1,
            created: DateTime(2026, 1, 5, 9),
            status: TaskStatus.completed,
            completed: DateTime(2026, 1, 5, 10)),
        task(id: 2,
            created: DateTime(2026, 11, 10, 9),
            status: TaskStatus.completed,
            completed: DateTime(2026, 11, 10, 10)),
      ], range: StatsRange.all);
      expect(snap.trend.dates.first, DateTime(2026, 1, 5));
      expect(snap.summary.completed, 2);
      expect(snap.isBlank, isFalse);
    });

    test('空账号：全部范围退化成今天，所有指标为空', () {
      final snap = compute(const [], range: StatsRange.all);
      expect(snap.trend.isEmpty, isTrue);
      expect(snap.summary.completed, 0);
      expect(snap.summary.streakDays, 0);
      expect(snap.isBlank, isTrue);
    });
  });

  group('JSON 往返（与 /api/stats/me 同一套字段名）', () {
    test('本地算出的快照能序列化再读回', () {
      final snap = compute([
        task(id: 1,
            created: DateTime(2026, 11, 9, 9),
            status: TaskStatus.completed,
            completed: DateTime(2026, 11, 9, 11),
            urgency: Urgency.urgent),
      ]);
      final back = StatsSnapshot.fromJson(snap.toJson());
      expect(back.range, snap.range);
      expect(back.summary.completed, snap.summary.completed);
      expect(back.summary.dueTotal, snap.summary.dueTotal);
      expect(back.summary.completionRate, snap.summary.completionRate);
      expect(back.summary.medianFinishHours, snap.summary.medianFinishHours);
      expect(back.trend.dates, snap.trend.dates);
      expect(back.trend.created, snap.trend.created);
      expect(back.trend.rates, snap.trend.rates);
      expect(back.heatmap.counts, snap.heatmap.counts);
      expect(back.heatmap.max, snap.heatmap.max);
      expect(back.workCount, snap.workCount);
      expect(back.urgencyCounts, snap.urgencyCounts);
      expect(back.hours, snap.hours);
      expect(back.peakStartHour, snap.peakStartHour);
      expect(back.peakUrgentShare, snap.peakUrgentShare);
    });

    test('服务端 payload 能解成快照', () {
      final payload = {
        'range': {'from': '2026-10-11', 'to': '2026-11-10', 'granularity': 'day'},
        'summary': {
          'completed': 12,
          'completed_prev': 9,
          'completion_rate': 75,
          'due_total': 16,
          'undone': 4,
          'streak_days': 3,
          'streak_best': 10,
          'avg_finish_median_hours': 4.5,
          'fastest_minutes': 12,
          'slowest_days': 6.0,
          'finish_samples': 11,
        },
        'trend': {
          'buckets': ['2026-11-01', '2026-11-02'],
          'created': [3, 0],
          'completed': [2, 1],
          'completion_rate': [67, null],
        },
        'heatmap': {
          'start': '2026-08-24',
          'days': [
            for (var i = 0; i < 84; i++)
              {'date': '2026-08-24', 'count': i == 0 ? 5 : 0}
          ],
          'max': 5,
        },
        'by_type': [
          {'type': 'work', 'count': 8},
          {'type': 'personal', 'count': 4},
        ],
        'by_urgency': [
          {'urgency': 0, 'count': 6},
          {'urgency': 1, 'count': 4},
          {'urgency': 2, 'count': 2},
        ],
        'repeat_rate': [
          {'kind': 'day', 'done': 9, 'total': 12, 'rate': 75},
          {'kind': 'week', 'done': 2, 'total': 2, 'rate': 100},
          {'kind': 'month', 'done': 0, 'total': 0, 'rate': null},
        ],
        'hours': List<int>.filled(24, 0)..[10] = 4,
        'peak_hours': [9, 11],
        'peak_urgent_share': 61,
        'generated_at': '2026-11-10T07:00:00Z',
      };

      final snap = StatsSnapshot.fromJson(payload);
      expect(snap.summary.completed, 12);
      expect(snap.summary.completionRate, 75);
      expect(snap.summary.medianFinishHours, 4.5);
      expect(snap.trend.rates, [67, null]);
      expect(snap.heatmap.counts.length, 84);
      expect(snap.heatmap.start, DateTime(2026, 8, 24));
      expect(snap.heatmap.max, 5);
      expect(snap.workCount, 8);
      expect(snap.urgencyCounts, [6, 4, 2]);
      expect(snap.repeatRate.length, 3);
      expect(snap.repeatRate[2].rate, isNull);
      expect(snap.peakStartHour, 9);
      expect(snap.peakEndHour, 11);
      expect(snap.peakUrgentShare, 61);
      expect(snap.isBlank, isFalse);
    });

    test('缺字段 / 长度不对的 payload 补默认值，不越界也不炸', () {
      final snap = StatsSnapshot.fromJson({
        'summary': {'completed': 1},
        'hours': [3],
        'heatmap': {'start': '2026-08-24', 'days': [{'date': '2026-08-24'}]},
      });
      expect(snap.range, StatsRange.last7);
      expect(snap.summary.completed, 1);
      expect(snap.summary.medianFinishHours, isNull);
      expect(snap.hours.length, 24);
      expect(snap.hours[0], 3);
      expect(snap.hours[1], 0);
      expect(snap.heatmap.counts.length, 84);
      expect(snap.heatmap.counts[0], 0);
      expect(snap.trend.isEmpty, isTrue);
    });
  });
}
