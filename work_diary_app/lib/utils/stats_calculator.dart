import '../models/stats.dart';
import '../models/task.dart';

/// 看板聚合：把本地任务算成 `StatsSnapshot`。
///
/// 口径与需求文档 5.3、服务端 `app/routers/stats.py` 逐条对齐，改这里必须同步改那边，
/// 否则同一账号在桌面端和云端会看到两个数字。
///
/// 客户端直接用本地时间分桶：Hive 里存的就是设备本地时间（`toIso8601String()`
/// 不带 Z），不存在服务端那套 naive UTC 换算。
class StatsCalculator {
  const StatsCalculator._();

  static const int heatmapWeeks = 12;

  /// 完成耗时超过 30 天的样本视为异常值（建了没管、后来批量勾掉）。
  static const int finishSampleMaxDays = 30;

  /// 样本不足 3 条时中位数没有意义，显示 `--`。
  static const int finishMinSamples = 3;

  static StatsSnapshot compute({
    required List<Task> tasks,
    required Map<String, Set<String>> skips,
    required StatsRange range,
    DateTime? now,
  }) {
    final reference = now ?? DateTime.now();
    final end = dateOnly(reference);
    final start = range.days == null
        ? _earliestDate(tasks) ?? end
        : end.subtract(Duration(days: range.days! - 1));

    final length = end.difference(start).inDays + 1;
    final prevEnd = start.subtract(const Duration(days: 1));
    final prevStart = prevEnd.subtract(Duration(days: length - 1));
    final heatStart = _mondayOf(end).subtract(
      const Duration(days: 7 * (heatmapWeeks - 1)),
    );

    final completed = _completedBetween(tasks, start, end);
    final completedPrev = _completedBetween(tasks, prevStart, prevEnd);
    final dueTotal = _dueTotal(tasks, start, end);

    final durations = <double>[];
    for (final task in completed) {
      final minutes = task.completedAt!.difference(task.createdAt).inMinutes;
      if (minutes < 0) continue;
      if (minutes > finishSampleMaxDays * 24 * 60) continue;
      durations.add(minutes.toDouble());
    }
    final enoughSamples = durations.length >= finishMinSamples;
    final medianHours = enoughSamples ? _median(durations) / 60 : null;
    final fastestMinutes =
        enoughSamples ? durations.reduce((a, b) => a < b ? a : b).round() : null;
    final slowestDays = enoughSamples
        ? double.parse(
            (durations.reduce((a, b) => a > b ? a : b) / 60 / 24).toStringAsFixed(1),
          )
        : null;

    final completedDates = <DateTime>{};
    final perDayCount = <DateTime, int>{};
    for (final task in tasks) {
      if (task.status != TaskStatus.completed || task.completedAt == null) {
        continue;
      }
      final day = dateOnly(task.completedAt!);
      completedDates.add(day);
      perDayCount[day] = (perDayCount[day] ?? 0) + 1;
    }

    final heatCounts = [
      for (var i = 0; i < heatmapWeeks * 7; i++)
        perDayCount[heatStart.add(Duration(days: i))] ?? 0
    ];

    final buckets = _trendBuckets(start, end, byWeek: range.byWeek);
    final createdPerBucket = <DateTime, int>{};
    final completedPerBucket = <DateTime, int>{};
    for (final task in tasks) {
      final created = dateOnly(task.createdAt);
      if (_inWindow(created, start, end)) {
        final key = range.byWeek ? _mondayOf(created) : created;
        createdPerBucket[key] = (createdPerBucket[key] ?? 0) + 1;
      }
      if (task.status == TaskStatus.completed && task.completedAt != null) {
        final day = dateOnly(task.completedAt!);
        if (_inWindow(day, start, end)) {
          final key = range.byWeek ? _mondayOf(day) : day;
          completedPerBucket[key] = (completedPerBucket[key] ?? 0) + 1;
        }
      }
    }

    final trendCreated = [for (final b in buckets) createdPerBucket[b] ?? 0];
    final trendCompleted = [for (final b in buckets) completedPerBucket[b] ?? 0];
    final trendRates = [
      for (var i = 0; i < buckets.length; i++)
        trendCreated[i] == 0
            ? null
            : (trendCompleted[i] / trendCreated[i] * 100).round()
    ];

    final hours = List<int>.filled(24, 0);
    for (final task in completed) {
      hours[task.completedAt!.hour] += 1;
    }
    final peak = _peakHours(hours);
    // 「这两个时段完成的紧急/重要任务占该时段 X%」需要按峰值区间单独算一次。
    final peakUrgentShare = peak == null
        ? null
        : _urgentShareInRange(completed, peak.$1, peak.$2);

    final repeatRate = [
      for (final entry in const [('day', 1), ('week', 2), ('month', 3)])
        _repeatRate(tasks, skips, entry.$1, entry.$2, start, end),
    ];

    return StatsSnapshot(
      range: range,
      summary: StatsSummary(
        completed: completed.length,
        completedPrev: completedPrev.length,
        completionRate:
            dueTotal == 0 ? null : (completed.length / dueTotal * 100).round(),
        dueTotal: dueTotal,
        undone: (dueTotal - completed.length).clamp(0, dueTotal),
        streakDays: _streak(completedDates, end),
        streakBest: _bestStreak(completedDates),
        medianFinishHours: medianHours == null
            ? null
            : double.parse(medianHours.toStringAsFixed(1)),
        fastestMinutes: fastestMinutes,
        slowestDays: slowestDays,
        finishSamples: durations.length,
      ),
      trend: StatsTrend(
        dates: buckets,
        created: trendCreated,
        completed: trendCompleted,
        rates: trendRates,
      ),
      heatmap: StatsHeatmap(
        start: heatStart,
        counts: heatCounts,
        max: heatCounts.isEmpty ? 0 : heatCounts.reduce((a, b) => a > b ? a : b),
      ),
      workCount: completed.where((t) => t.taskType == 1).length,
      personalCount: completed.where((t) => t.taskType == 0).length,
      urgencyCounts: [
        for (final level in Urgency.values)
          completed.where((t) => t.urgency == level).length,
      ],
      repeatRate: repeatRate,
      hours: hours,
      peakStartHour: peak?.$1,
      peakEndHour: peak?.$2,
      peakUrgentShare: peakUrgentShare,
      generatedAt: reference,
    );
  }

  /// 峰值 [start, end) 两个小时内，紧急 + 重要任务占该时段完成数的比例。
  static int? _urgentShareInRange(
    List<Task> completed,
    int start,
    int end,
  ) {
    var inRange = 0;
    var urgent = 0;
    for (final task in completed) {
      final hour = task.completedAt!.hour;
      if (hour < start || hour >= end) continue;
      inRange++;
      if (task.urgency != Urgency.normal) urgent++;
    }
    if (inRange == 0) return null;
    return (urgent / inRange * 100).round();
  }

  static List<Task> _completedBetween(
    List<Task> tasks,
    DateTime start,
    DateTime end,
  ) =>
      [
        for (final task in tasks)
          if (task.status == TaskStatus.completed &&
              task.completedAt != null &&
              _inWindow(dateOnly(task.completedAt!), start, end))
            task,
      ];

  /// 应完成数：有到期日的按到期日落窗，无到期日的按创建日落窗。
  static int _dueTotal(List<Task> tasks, DateTime start, DateTime end) {
    var total = 0;
    for (final task in tasks) {
      final due = task.dueAt == null ? null : dateOnly(task.dueAt!);
      if (due != null) {
        if (_inWindow(due, start, end)) total++;
      } else if (_inWindow(dateOnly(task.createdAt), start, end)) {
        total++;
      }
    }
    return total;
  }

  static RepeatRateItem _repeatRate(
    List<Task> tasks,
    Map<String, Set<String>> skips,
    String kind,
    int repeatType,
    DateTime start,
    DateTime end,
  ) {
    var total = 0;
    var done = 0;
    for (final task in tasks) {
      if (task.repeatType != repeatType) continue;
      final instance = task.instanceDate;
      if (instance == null || !_inWindow(dateOnly(instance), start, end)) {
        continue;
      }
      // 被跳过的期次不算"应该做但没做"
      final groupId = task.repeatGroupId;
      if (groupId != null && skips[groupId]?.contains(formatDate(instance)) == true) {
        continue;
      }
      // 没有到期日就无从判断"按期"，整期不进分母
      if (task.dueAt == null) continue;
      total++;
      if (task.status == TaskStatus.completed &&
          task.completedAt != null &&
          !task.completedAt!.isAfter(task.dueAt!)) {
        done++;
      }
    }
    return RepeatRateItem(
      kind: kind,
      done: done,
      total: total,
      rate: total == 0 ? null : (done / total * 100).round(),
    );
  }

  /// 从今天往前数连续有完成的天数；今天还没完成就从昨天起算，
  /// 否则每天早上打开软件 streak 都会清零。
  static int _streak(Set<DateTime> days, DateTime today) {
    var cursor = days.contains(today)
        ? today
        : today.subtract(const Duration(days: 1));
    var count = 0;
    while (days.contains(cursor)) {
      count++;
      cursor = cursor.subtract(const Duration(days: 1));
    }
    return count;
  }

  static int _bestStreak(Set<DateTime> days) {
    if (days.isEmpty) return 0;
    final ordered = days.toList()..sort();
    var best = 1;
    var run = 1;
    for (var i = 1; i < ordered.length; i++) {
      if (ordered[i].difference(ordered[i - 1]).inDays == 1) {
        run++;
      } else {
        run = 1;
      }
      if (run > best) best = run;
    }
    return best;
  }

  static List<DateTime> _trendBuckets(
    DateTime start,
    DateTime end, {
    required bool byWeek,
  }) {
    if (!byWeek) {
      return [
        for (var i = 0; i <= end.difference(start).inDays; i++)
          start.add(Duration(days: i))
      ];
    }
    var cursor = _mondayOf(start);
    final buckets = <DateTime>[];
    while (!cursor.isAfter(end)) {
      buckets.add(cursor);
      cursor = cursor.add(const Duration(days: 7));
    }
    return buckets;
  }

  /// 完成数最高的连续 2 小时区间，返回 [起始时, 结束时)（与文案 9:00–11:00 对齐）。
  static (int, int)? _peakHours(List<int> hours) {
    final total = hours.fold(0, (a, b) => a + b);
    if (total <= 0) return null;
    var peak = 0;
    for (var h = 1; h < hours.length; h++) {
      if (hours[h] > hours[peak]) peak = h;
    }
    var bestStart = 0;
    var bestScore = (-1, -1);
    for (var start = 0; start < 23; start++) {
      final score = (hours[start] + hours[start + 1], -(start - peak).abs());
      if (score.$1 > bestScore.$1 ||
          (score.$1 == bestScore.$1 && score.$2 > bestScore.$2)) {
        bestStart = start;
        bestScore = score;
      }
    }
    return (bestStart, bestStart + 2);
  }

  static DateTime? _earliestDate(List<Task> tasks) {
    DateTime? earliest;
    for (final task in tasks) {
      for (final raw in [task.createdAt, task.completedAt, task.dueAt]) {
        if (raw == null) continue;
        final day = dateOnly(raw);
        if (earliest == null || day.isBefore(earliest)) earliest = day;
      }
    }
    return earliest;
  }

  static bool _inWindow(DateTime day, DateTime start, DateTime end) =>
      !day.isBefore(start) && !day.isAfter(end);

  static DateTime _mondayOf(DateTime day) =>
      dateOnly(day).subtract(Duration(days: day.weekday - 1));

  static double _median(List<double> values) {
    if (values.isEmpty) return 0;
    final ordered = [...values]..sort();
    final mid = ordered.length ~/ 2;
    if (ordered.length.isOdd) return ordered[mid];
    return (ordered[mid - 1] + ordered[mid]) / 2;
  }

  static DateTime dateOnly(DateTime value) =>
      DateTime(value.year, value.month, value.day);
}
