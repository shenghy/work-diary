/// 日/周/月任务（循环任务）字段的共享解析工具与常量。
///
/// 单独放在这个文件里，是为了让 [Task] 和 [RepeatRule] 都能复用同一套
/// 容错解析，而不产生 `task.dart` <-> `repeat_rule.dart` 的循环依赖。
///
/// 这里的解析全部**不抛异常**：一条旧版本/损坏的记录不允许让整批读取失败
/// （那样界面会显示成"所有循环任务都失效了"）。
library;

/// 跳过记录的保留天数：客户端本地账本、规则内副本、服务端清理共用同一个值。
const int kRepeatSkipRetentionDays = 120;

/// 「该循环任务已停止」的哨兵值。
///
/// 写进跳过账本（键 = 族 ID，值集合里包含本字符串）。它不是一个日期，
/// 所以账本里"按日期解析后清理过期记录"的逻辑会自然把它保留下来。
/// 引擎看到它就会整族不再生成新一期，即使规则或旧实例还在。
const String kRepeatStoppedMarker = 'STOP';

/// 重复类型：0正常 1日任务 2周任务 3月任务。越界一律按"正常任务"处理。
int normalizeRepeatType(Object? raw) {
  final i = raw is int ? raw : int.tryParse('${raw ?? ''}');
  if (i == null || i < 0 || i > 3) return 0;
  return i;
}

/// 周任务星期集合：只保留 1..7（1=周一），去重升序；空集合返回 null。
///
/// 越界的值（0/8/负数、云端脏数据）直接丢弃，避免引擎按不存在的星期查找
/// 后永远不生成任何一期（旧实现会静默失效）。
List<int>? parseRepeatWeekDays(Object? raw) {
  Iterable<Object?> source;
  if (raw is List) {
    source = raw;
  } else if (raw is String && raw.trim().isNotEmpty) {
    source = raw.split(',');
  } else {
    return null;
  }
  final days = <int>{};
  for (final e in source) {
    final v = e is int ? e : int.tryParse('${e ?? ''}'.trim());
    if (v != null && v >= DateTime.monday && v <= DateTime.sunday) {
      days.add(v);
    }
  }
  if (days.isEmpty) return null;
  return days.toList()..sort();
}

/// 月任务"每月几号"：只接受 1..31，其它返回 null。
int? normalizeRepeatMonthDay(Object? raw) {
  final v = raw is int ? raw : int.tryParse('${raw ?? ''}'.trim());
  if (v == null || v < 1 || v > 31) return null;
  return v;
}

/// 解析本地时间字符串；格式不对返回 null（旧实现用 `DateTime.parse` 会抛异常）。
DateTime? parseRepeatTime(Object? raw) {
  if (raw is String && raw.isNotEmpty) return DateTime.tryParse(raw);
  return null;
}

/// 解析跳过日期列表："2026-11-01,2026-11-02" 或 List。
///
/// 非日期内容（例如 [kRepeatStoppedMarker]）原样保留，不能丢：停止标记就是
/// 靠它承载的。
List<String> parseRepeatSkips(Object? raw) {
  Iterable<Object?> source;
  if (raw is List) {
    source = raw;
  } else if (raw is String && raw.isNotEmpty) {
    source = raw.split(',');
  } else {
    return const <String>[];
  }
  final result = <String>[];
  for (final e in source) {
    final s = '${e ?? ''}'.trim();
    if (s.isEmpty) continue;
    if (!result.contains(s)) result.add(s);
  }
  return result;
}
