/// 循环任务的展示文案（卡片徽章、管理页、下一期提示共用）。
library;

const List<String> _weekdayNames = [
  '周一',
  '周二',
  '周三',
  '周四',
  '周五',
  '周六',
  '周日',
];

/// 1..7 → '周一'..'周日'，越界返回空串
String weekdayLabel(int weekday) {
  if (weekday < 1 || weekday > 7) return '';
  return _weekdayNames[weekday - 1];
}

/// 1..7 → '一'..'日'（用于「每周一、三、五」这种紧凑文案）
String weekdayShort(int weekday) {
  if (weekday < 1 || weekday > 7) return '';
  return _weekdayNames[weekday - 1].substring(1);
}

/// 规则文案：
/// - 日任务 → 每日
/// - 周任务 → 工作日 / 每周一、三、五 / 每周
/// - 月任务 → 每月15日
/// - 正常任务 → 不循环
String repeatRuleLabel({
  required int repeatType,
  List<int>? weekDays,
  int? monthDay,
}) {
  switch (repeatType) {
    case 1:
      return '每日';
    case 2:
      final days = <int>{
        for (final d in weekDays ?? const <int>[])
          if (d >= DateTime.monday && d <= DateTime.sunday) d,
      }.toList()
        ..sort();
      if (days.isEmpty) return '每周';
      // 周一到周五单独给一个更短的文案
      if (days.length == 5 && days.every((d) => d <= DateTime.friday)) {
        return '工作日';
      }
      return '每周${days.map(weekdayShort).join('、')}';
    case 3:
      return '每月${monthDay ?? 1}日';
    default:
      return '不循环';
  }
}

/// 'M/d'
String shortDate(DateTime d) => '${d.month}/${d.day}';

/// 'M/d 周X'
String shortDateWithWeekday(DateTime d) =>
    '${shortDate(d)} ${weekdayLabel(d.weekday)}';

/// 'HH:mm'
String clockLabel(DateTime? t) {
  if (t == null) return '';
  return '${t.hour.toString().padLeft(2, '0')}:'
      '${t.minute.toString().padLeft(2, '0')}';
}

/// 「11/5 周四 09:00」；没有计划时间时省略时间部分
String formatDueDate(DateTime date, {DateTime? planStartAt}) {
  final time = clockLabel(planStartAt);
  return time.isEmpty
      ? shortDateWithWeekday(date)
      : '${shortDateWithWeekday(date)} $time';
}
