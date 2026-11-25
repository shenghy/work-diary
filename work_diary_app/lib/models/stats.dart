/// 个人数据看板的数据模型。
///
/// 字段与服务端 `GET /api/stats/me` 的响应一一对应：本地聚合出来的结果和
/// 云端下发的结果可以互换，小程序接云端时直接用这套 fromJson。
library;

/// 时间范围胶囊。近 90 天与全部按周聚合，否则柱子会挤成一片。
enum StatsRange {
  last7('近 7 天', 7, false),
  last30('近 30 天', 30, false),
  last90('近 90 天', 90, true),
  all('全部', null, true);

  const StatsRange(this.label, this.days, this.byWeek);

  final String label;

  /// null = 不设上限（全部）。
  final int? days;
  final bool byWeek;

  bool get isAll => days == null;
}

class StatsSummary {
  const StatsSummary({
    required this.completed,
    required this.completedPrev,
    required this.completionRate,
    required this.dueTotal,
    required this.undone,
    required this.streakDays,
    required this.streakBest,
    required this.medianFinishHours,
    required this.fastestMinutes,
    required this.slowestDays,
    required this.finishSamples,
  });

  /// 窗口内完成的任务数（与「已完成」tab 角标同一口径）。
  final int completed;
  final int completedPrev;

  /// 应完成数为 0 时是 null，前端显示 `--` 而不是 0%。
  final int? completionRate;
  final int dueTotal;
  final int undone;
  final int streakDays;
  final int streakBest;

  /// 完成耗时中位数（小时）。样本不足 3 条时为 null。
  final double? medianFinishHours;
  final int? fastestMinutes;
  final double? slowestDays;
  final int finishSamples;

  /// 环比：上一个等长窗口没有数据时返回 null（不显示 +0%）。
  int? get changePercent {
    if (completedPrev <= 0) return null;
    return ((completed - completedPrev) / completedPrev * 100).round();
  }

  /// 小样本指标要标「样本较少」，否则 1 条任务也能算出 100% 完成率。
  bool get isSparse => dueTotal < 5;

  /// 主耗时数值：优先天数（1.4 天），不足 1 小时时改用分钟更好读。
  ({String value, String unit}) get finishDuration {
    final hours = medianFinishHours;
    if (hours == null) return (value: '--', unit: '');
    if (hours < 1) return (value: '${(hours * 60).round()}', unit: '分钟');
    if (hours < 48) return (value: hours.toStringAsFixed(1), unit: '小时');
    return (value: (hours / 24).toStringAsFixed(1), unit: '天');
  }

  /// 分钟数自适应单位。卡片那行「最快 X · 最慢 Y」写死分钟会撑破卡片宽度
  /// 被截成省略号，180 分钟也不如 3 小时好读。
  static String durationText(double? minutes) {
    if (minutes == null) return '--';
    if (minutes < 60) return '${minutes.round()} 分钟';
    final inHours = minutes < 48 * 60;
    final text = (inHours ? minutes / 60 : minutes / (24 * 60)).toStringAsFixed(1);
    // 3.0 这种整数小时不留小数点，一行能省下两个字符的宽度。
    final cut = text.endsWith('.0') ? text.substring(0, text.length - 2) : text;
    return '$cut ${inHours ? '小时' : '天'}';
  }

  Map<String, dynamic> toJson() => {
        'completed': completed,
        'completed_prev': completedPrev,
        'completion_rate': completionRate,
        'due_total': dueTotal,
        'undone': undone,
        'streak_days': streakDays,
        'streak_best': streakBest,
        'avg_finish_median_hours': medianFinishHours,
        'fastest_minutes': fastestMinutes,
        'slowest_days': slowestDays,
        'finish_samples': finishSamples,
      };

  factory StatsSummary.fromJson(Map<String, dynamic> json) => StatsSummary(
        completed: json['completed'] as int? ?? 0,
        completedPrev: json['completed_prev'] as int? ?? 0,
        completionRate: json['completion_rate'] as int?,
        dueTotal: json['due_total'] as int? ?? 0,
        undone: json['undone'] as int? ?? 0,
        streakDays: json['streak_days'] as int? ?? 0,
        streakBest: json['streak_best'] as int? ?? 0,
        medianFinishHours: (json['avg_finish_median_hours'] as num?)?.toDouble(),
        fastestMinutes: json['fastest_minutes'] as int?,
        slowestDays: (json['slowest_days'] as num?)?.toDouble(),
        finishSamples: json['finish_samples'] as int? ?? 0,
      );
}

class StatsTrend {
  const StatsTrend({
    required this.dates,
    required this.created,
    required this.completed,
    required this.rates,
  });

  /// 每个桶的起始日（按周时为周一）。
  final List<DateTime> dates;
  final List<int> created;
  final List<int> completed;

  /// 桶内没有新建任务时为 null：完成率无定义，折线断点比画个 0 更诚实。
  final List<int?> rates;

  bool get isEmpty =>
      created.every((v) => v == 0) && completed.every((v) => v == 0);

  int get maxValue {
    var max = 0;
    for (final v in created) {
      if (v > max) max = v;
    }
    for (final v in completed) {
      if (v > max) max = v;
    }
    return max;
  }

  Map<String, dynamic> toJson() => {
        'buckets': dates.map(formatDate).toList(),
        'created': created,
        'completed': completed,
        'completion_rate': rates,
      };

  factory StatsTrend.fromJson(Map<String, dynamic> json) => StatsTrend(
        dates: (json['buckets'] as List<dynamic>? ?? [])
            .map((e) => parseDate(e as String))
            .toList(),
        created: (json['created'] as List<dynamic>? ?? [])
            .map((e) => (e as num).toInt())
            .toList(),
        completed: (json['completed'] as List<dynamic>? ?? [])
            .map((e) => (e as num).toInt())
            .toList(),
        rates: (json['completion_rate'] as List<dynamic>? ?? [])
            .map((e) => e == null ? null : (e as num).toInt())
            .toList(),
      );
}

class StatsHeatmap {
  const StatsHeatmap({
    required this.start,
    required this.counts,
    required this.max,
  });

  /// 第一列（周一）的日期。
  final DateTime start;

  /// 84 格，按「周」优先展开：counts[week * 7 + weekday]。
  final List<int> counts;
  final int max;

  static const int weeks = 12;

  bool get isEmpty => max == 0;

  int levelFor(int count) {
    if (max <= 0 || count <= 0) return 0;
    final level = (count / max * 4).ceil();
    return level.clamp(0, 4);
  }

  Map<String, dynamic> toJson() => {
        'start': formatDate(start),
        'days': [
          for (var i = 0; i < counts.length; i++)
            {
              'date': formatDate(dateAt(i)),
              'count': counts[i],
            }
        ],
        'max': max,
      };

  factory StatsHeatmap.fromJson(Map<String, dynamic> json) {
    final days = (json['days'] as List<dynamic>? ?? [])
        .cast<Map<String, dynamic>>();
    final counts =
        days.map((e) => (e['count'] as num?)?.toInt() ?? 0).toList();
    final start = json['start'] is String
        ? parseDate(json['start'] as String)
        : DateTime.now();
    // 格子数固定：少一格就会整列错位，缺的直接补 0，多出来的截掉。
    final normalized = List<int>.generate(
      weeks * 7,
      (i) => i < counts.length ? counts[i] : 0,
    );
    return StatsHeatmap(
      start: start,
      counts: normalized,
      max: (json['max'] as num?)?.toInt() ??
          normalized.fold(0, (a, b) => a > b ? a : b),
    );
  }

  DateTime dateAt(int index) => start.add(Duration(days: index));

  int countAt(DateTime day) {
    final diff = day.difference(start).inDays;
    if (diff < 0 || diff >= counts.length) return 0;
    return counts[diff];
  }
}

class RepeatRateItem {
  const RepeatRateItem({
    required this.kind,
    required this.done,
    required this.total,
    required this.rate,
  });

  final String kind; // day / week / month
  final int done;
  final int total;
  final int? rate;

  String get label => switch (kind) {
        'day' => '日任务',
        'week' => '周任务',
        'month' => '月任务',
        _ => kind,
      };

  Map<String, dynamic> toJson() =>
      {'kind': kind, 'done': done, 'total': total, 'rate': rate};

  factory RepeatRateItem.fromJson(Map<String, dynamic> json) => RepeatRateItem(
        kind: json['kind'] as String? ?? 'day',
        done: (json['done'] as num?)?.toInt() ?? 0,
        total: (json['total'] as num?)?.toInt() ?? 0,
        rate: json['rate'] == null ? null : (json['rate'] as num).toInt(),
      );
}

class StatsSnapshot {
  const StatsSnapshot({
    required this.range,
    required this.summary,
    required this.trend,
    required this.heatmap,
    required this.workCount,
    required this.personalCount,
    required this.urgencyCounts,
    required this.repeatRate,
    required this.hours,
    required this.peakStartHour,
    required this.peakEndHour,
    required this.peakUrgentShare,
    required this.generatedAt,
  });

  final StatsRange range;
  final StatsSummary summary;
  final StatsTrend trend;
  final StatsHeatmap heatmap;

  /// 构成图只看窗口内已完成任务，保证三处数字对得上。
  final int workCount;
  final int personalCount;

  /// 下标 = urgency（0 一般 / 1 紧急 / 2 重要）。
  final List<int> urgencyCounts;
  final List<RepeatRateItem> repeatRate;

  /// 24 桶，按完成时间的本地小时。
  final List<int> hours;

  /// 峰值时段 [start, end)，end 是开区间：9 和 10 两个桶 -> 9:00–11:00。
  final int? peakStartHour;
  final int? peakEndHour;

  /// 峰值时段内「紧急 + 重要」占该时段完成数的比例，用于需求 4.7 的追加文案。
  final int? peakUrgentShare;
  final DateTime generatedAt;

  int get completedTotal => workCount + personalCount;

  int get workShare =>
      completedTotal == 0 ? 0 : (workCount / completedTotal * 100).round();

  int get hourPeak => hours.isEmpty ? 0 : hours.reduce((a, b) => a > b ? a : b);

  /// 整个账号一条任务都没有：页面切到引导态，而不是画六个 0 值图。
  bool get isBlank =>
      summary.completed == 0 &&
      summary.dueTotal == 0 &&
      trend.isEmpty &&
      heatmap.isEmpty &&
      hours.every((h) => h == 0);

  Map<String, dynamic> toJson() => {
        'range': range.name,
        'summary': summary.toJson(),
        'trend': trend.toJson(),
        'heatmap': heatmap.toJson(),
        'by_type': [
          {'type': 'work', 'count': workCount},
          {'type': 'personal', 'count': personalCount},
        ],
        'by_urgency': [
          for (var i = 0; i < urgencyCounts.length; i++)
            {'urgency': i, 'count': urgencyCounts[i]}
        ],
        'repeat_rate': repeatRate.map((e) => e.toJson()).toList(),
        'hours': hours,
        'peak_hours': peakStartHour == null ? null : [peakStartHour, peakEndHour],
        'peak_urgent_share': peakUrgentShare,
        'generated_at': generatedAt.toIso8601String(),
      };

  factory StatsSnapshot.fromJson(Map<String, dynamic> json) {
    final byType = (json['by_type'] as List<dynamic>? ?? [])
        .cast<Map<String, dynamic>>();
    final byUrgency = (json['by_urgency'] as List<dynamic>? ?? [])
        .cast<Map<String, dynamic>>();
    final peak = (json['peak_hours'] as List<dynamic>?);
    // 本地 toJson 写的是枚举名，服务端 range 是个对象（from/to/granularity/tz），
    // 认不出来就退回默认值，别让一个字段把整页数据带崩。
    final rawRange = json['range'];
    final rangeName = rawRange is String ? rawRange : null;
    return StatsSnapshot(
      range: StatsRange.values.firstWhere(
        (r) => r.name == rangeName,
        orElse: () => StatsRange.last7,
      ),
      summary: StatsSummary.fromJson(
          (json['summary'] as Map<String, dynamic>?) ?? const {}),
      trend: StatsTrend.fromJson(
          (json['trend'] as Map<String, dynamic>?) ?? const {}),
      heatmap: StatsHeatmap.fromJson(
          (json['heatmap'] as Map<String, dynamic>?) ?? const {}),
      workCount: _countByType(byType, 'work'),
      personalCount: _countByType(byType, 'personal'),
      urgencyCounts: [
        for (var level = 0; level < 3; level++)
          _countByUrgency(byUrgency, level)
      ],
      repeatRate: (json['repeat_rate'] as List<dynamic>? ?? [])
          .cast<Map<String, dynamic>>()
          .map(RepeatRateItem.fromJson)
          .toList(),
      hours: _hours24(json['hours']),
      peakStartHour: peak == null || peak.isEmpty
          ? null
          : (peak[0] as num).toInt(),
      peakEndHour: peak == null || peak.length < 2
          ? null
          : (peak[1] as num).toInt(),
      peakUrgentShare: (json['peak_urgent_share'] as num?)?.toInt(),
      generatedAt: DateTime.tryParse(json['generated_at'] as String? ?? '') ??
          DateTime.now(),
    );
  }

  /// 时段图固定 24 格，缺位补 0，否则柱子会整体平移。
  static List<int> _hours24(Object? raw) {
    final list = (raw as List<dynamic>? ?? const []);
    return List<int>.generate(24, (i) => i < list.length
        ? ((list[i] as num?)?.toInt() ?? 0)
        : 0);
  }

  static int _countByType(List<Map<String, dynamic>> rows, String type) {    for (final row in rows) {
      if (row['type'] == type) return (row['count'] as num?)?.toInt() ?? 0;
    }
    return 0;
  }

  static int _countByUrgency(List<Map<String, dynamic>> rows, int level) {
    for (final row in rows) {
      if ((row['urgency'] as num?)?.toInt() == level) {
        return (row['count'] as num?)?.toInt() ?? 0;
      }
    }
    return 0;
  }
}

String formatDate(DateTime day) =>
    '${day.year.toString().padLeft(4, '0')}-'
    '${day.month.toString().padLeft(2, '0')}-'
    '${day.day.toString().padLeft(2, '0')}';

DateTime parseDate(String raw) =>
    DateTime.tryParse(raw)?.toLocal() ?? DateTime.now();
