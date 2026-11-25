import '../models/repeat_rule.dart';
import '../models/task.dart';

/// 循环任务生成引擎（日/周/月任务）
///
/// 语义：**只补"最近一期已到期但尚未生成"的实例**，不预生成未来、不补更早的缺失期。
/// - 日任务：每天一期，实例日期 = 当天
/// - 周任务：按 repeatWeekDays 命中的日期，一期对应最近一个 ≤ 今天的命中日
/// - 月任务：每月 repeatMonthDay 一期，取当月该日（超当月天数取当月最后一天）
/// - 若某期日期 ≤ 该族已生成的最晚实例日期，视为已处理，跳过
/// - 若该族已被用户"停止循环"（跳过账本里有 [RepeatRule.stoppedMarker]），整族不生成
///
/// 多端幂等：生成的实例带 repeat_group_id + instance_date，服务端唯一索引去重。
class RepeatTaskEngine {
  /// 已停止循环的哨兵（转发自 RepeatRule，方便调用方只 import 本文件）
  static const String stoppedMarker = RepeatRule.stoppedMarker;

  /// 创建循环任务时的初始实例日期（第一期）
  /// - 日任务：今天
  /// - 周任务：今天是命中日 → 今天；否则 → 下一个命中日
  /// - 月任务：今天是当月 day → 今天；否则 → 本月 day（已过 → 下月 day）
  static DateTime initialInstanceDate({
    required int repeatType,
    List<int>? weekDays,
    int? monthDay,
    required DateTime now,
  }) {
    final today = DateTime(now.year, now.month, now.day);
    switch (repeatType) {
      case 1:
        return today;
      case 2:
        final days = _sanitizeWeekDays(weekDays);
        var d = today;
        for (var i = 0; i < 8; i++) {
          if (days.contains(d.weekday)) return d;
          // 用日期构造而不是 Duration(days: 1)：夏令时切换日只有 23 小时，
          // 加 24 小时会落到同一个日历日的 00:00（等于没前进）。
          d = DateTime(d.year, d.month, d.day + 1);
        }
        return today;
      case 3:
        final day = _sanitizeMonthDay(monthDay);
        final thisMonth = _monthDayOf(today.year, today.month, day);
        if (!thisMonth.isBefore(today)) return thisMonth;
        final nextMonth = _monthDayOf(today.year, today.month + 1, day);
        return nextMonth;
      default:
        return today;
    }
  }

  /// 下一期的实例日期（用于"下次生成"提示）。
  ///
  /// [after] 是本族最近一期的实例日期：返回**严格晚于它**的第一个命中日。
  /// [after] 为空（还没有任何实例）时，返回"引擎下次会生成的那一期"，
  /// 可能是今天、最近一个命中日或本月该日（与补生成逻辑保持一致）。
  /// 正常任务（repeatType=0）返回 null。
  static DateTime? nextInstanceDate({
    required int repeatType,
    List<int>? weekDays,
    int? monthDay,
    required DateTime now,
    DateTime? after,
  }) {
    final today = DateTime(now.year, now.month, now.day);
    if (after == null) {
      return _dueDateFor(
        repeatType: repeatType,
        weekDays: weekDays,
        monthDay: monthDay,
        today: today,
      );
    }
    final base = DateTime(after.year, after.month, after.day);
    switch (repeatType) {
      case 1:
        return DateTime(base.year, base.month, base.day + 1);
      case 2:
        final days = _sanitizeWeekDays(weekDays);
        var d = DateTime(base.year, base.month, base.day + 1);
        for (var i = 0; i < 15; i++) {
          if (days.contains(d.weekday)) return d;
          d = DateTime(d.year, d.month, d.day + 1);
        }
        return null;
      case 3:
        final day = _sanitizeMonthDay(monthDay);
        var y = base.year;
        var m = base.month;
        for (var i = 0; i < 24; i++) {
          final d = _monthDayOf(y, m, day);
          if (d.isAfter(base)) return d;
          m++;
          if (m > 12) {
            m = 1;
            y++;
          }
        }
        return null;
      default:
        return null;
    }
  }

  /// 星期集合清洗：只保留 1..7，空/全非法时退回周一。
  ///
  /// 旧实现直接把 repeatWeekDays 拿去 contains 判断，云端脏数据（0/8）会让
  /// 该族**永远不生成**且没有任何提示。
  static List<int> _sanitizeWeekDays(List<int>? weekDays) {
    final cleaned = <int>{};
    for (final d in weekDays ?? const <int>[]) {
      if (d >= DateTime.monday && d <= DateTime.sunday) cleaned.add(d);
    }
    if (cleaned.isEmpty) return const [DateTime.monday];
    return cleaned.toList()..sort();
  }

  static int _sanitizeMonthDay(int? monthDay) {
    if (monthDay == null || monthDay < 1) return 1;
    if (monthDay > 31) return 31;
    return monthDay;
  }

  /// 最近一个 ≤ today 的命中日（已到期应出现但可能未生成的日期）
  static DateTime? _dueDate(Task template, DateTime today) => _dueDateFor(
        repeatType: template.repeatType,
        weekDays: template.repeatWeekDays,
        monthDay: template.repeatMonthDay,
        today: today,
      );

  /// [_dueDate] 的纯参数版本（"下一期"提示在只有规则、没有实例时也要用）
  static DateTime? _dueDateFor({
    required int repeatType,
    List<int>? weekDays,
    int? monthDay,
    required DateTime today,
  }) {
    switch (repeatType) {
      case 1:
        return today;
      case 2:
        final days = _sanitizeWeekDays(weekDays);
        var d = today;
        for (var i = 0; i < 7; i++) {
          if (days.contains(d.weekday)) return d;
          d = DateTime(d.year, d.month, d.day - 1);
        }
        // 星期集合已清洗为 1..7 且非空，7 天内必然命中；兜底返回今天，
        // 避免任何意外让整个族静默失效。
        return today;
      case 3:
        final day = _sanitizeMonthDay(monthDay);
        return _monthDayOf(today.year, today.month, day);
      default:
        return null;
    }
  }

  /// 返回当月 day 号；若当月没有该日（如 31 号在 2 月），取当月最后一天
  static DateTime _monthDayOf(int year, int month, int day) {
    final c = DateTime(year, month, day);
    if (c.month != month) {
      return DateTime(year, month + 1, 0); // 当月最后一天
    }
    return DateTime(c.year, c.month, c.day);
  }

  /// 生成缺失实例：返回需要插入的新任务列表
  ///
  /// [rules] 为循环任务规则库（键=repeatGroupId）。族模板来源：
  /// **规则优先**（规则即最新配置），规则缺失的族再回退到现存实例中最早创建的一条。
  /// 这样删除族内全部实例后，只要规则还在，仍能照常补生成。
  static List<Task> generateMissing(
    List<Task> tasks,
    Map<String, RepeatRule> rules,
    DateTime now, {
    /// 用户主动删掉的实例日期（键=族 ID，值=YYYY-MM-DD 集合）。
    /// 与规则分离：规则只存在于创建任务的那台设备，删除记录必须独立存在。
    /// 集合里还可能有 [RepeatRule.stoppedMarker]（该族已停止循环）。
    Map<String, Set<String>> skips = const <String, Set<String>>{},
  }) {
    final today = DateTime(now.year, now.month, now.day);
    // 每个族只处理一次，模板 = 规则（优先）或最早创建的实例（兜底）
    final groups = <String, Task>{};
    for (final entry in rules.entries) {
      if (entry.key.isEmpty) continue;
      if (entry.value.repeatType <= 0) continue;
      groups[entry.key] = entry.value.asTemplateTask(now);
    }
    for (final t in tasks) {
      if (t.repeatType > 0 && t.repeatGroupId != null && t.repeatGroupId!.isNotEmpty) {
        final gid = t.repeatGroupId!;
        if (groups.containsKey(gid)) continue; // 已有规则模板
        final old = groups[gid];
        if (old == null || t.createdAt.isBefore(old.createdAt)) {
          groups[gid] = t;
        }
      }
    }
    if (groups.isEmpty) return const [];

    // 族内最晚实例日期
    final latestByGroup = <String, DateTime>{};
    for (final t in tasks) {
      if (t.repeatGroupId == null ||
          t.repeatGroupId!.isEmpty ||
          t.instanceDate == null) {
        continue;
      }
      final d = DateTime(
        t.instanceDate!.year,
        t.instanceDate!.month,
        t.instanceDate!.day,
      );
      final old = latestByGroup[t.repeatGroupId];
      if (old == null || d.isAfter(old)) {
        latestByGroup[t.repeatGroupId!] = d;
      }
    }

    // 新实例置于列表最上方：取全局最小 sortOrder - 1（列表按 sortOrder 升序）
    var minSort = 0;
    for (final t in tasks) {
      if (t.sortOrder < minSort) minSort = t.sortOrder;
    }

    final result = <Task>[];
    for (final entry in groups.entries) {
      final template = entry.value;
      final gid = entry.key;
      final rule = rules[gid];
      // 该族已被用户停止循环：规则、旧实例都还在也不再生成新一期
      if (skips[gid]?.contains(stoppedMarker) ?? false) continue;
      if (rule != null && rule.isStopped) continue;
      final due = _dueDate(template, today);
      if (due == null) continue;
      // 未到期：不预生成未来
      if (due.isAfter(today)) continue;
      // 用户主动删掉了这一期（仅删除本期）：不要再补回来
      final skipped = skips[gid];
      if (skipped != null && skipped.contains(RepeatRule.dateKey(due))) {
        continue;
      }
      if (rule != null && rule.isSkipped(due)) continue;
      // 已处理过（族内已有 ≥ 该日期的实例）
      final latest = latestByGroup[gid];
      if (latest != null && !due.isAfter(latest)) continue;

      result.add(_buildInstance(template, due, now, --minSort));
    }
    return result;
  }

  /// 同步下发实例的过滤：**只保留本机该收的期次**。
  ///
  /// 1) 本机账本里标记为"已删除"的期次：云端还下发说明是别的设备补生成后
  ///    上传的，丢弃，否则用户删掉的一期会在另一台设备上复活。
  /// 2) 已停止循环的族：只认本机已经存在的期次，新补出来的期次一律丢弃
  ///    （停止标记是本地账本，服务端没有这个概念，只能在这里兜住）。
  ///
  /// [local] 必须是**本次同步请求发出前**的本地列表，用来判断"本机是否已有这一期"。
  static List<Task> filterIncomingInstances(
    List<Task> incoming,
    List<Task> local, {
    Map<String, Set<String>> skips = const <String, Set<String>>{},
  }) {
    if (skips.isEmpty) return incoming;
    final localKeys = <String>{};
    for (final t in local) {
      final gid = t.repeatGroupId;
      final date = t.instanceDate;
      if (gid == null || gid.isEmpty || date == null) continue;
      localKeys.add('$gid|${RepeatRule.dateKey(date)}');
    }
    return incoming.where((t) {
      final gid = t.repeatGroupId;
      final date = t.instanceDate;
      if (gid == null || gid.isEmpty || date == null) return true;
      final ledger = skips[gid];
      if (ledger == null || ledger.isEmpty) return true;
      final key = '$gid|${RepeatRule.dateKey(date)}';
      if (ledger.contains(stoppedMarker)) {
        return localKeys.contains(key);
      }
      return !ledger.contains(RepeatRule.dateKey(date));
    }).toList();
  }

  /// 把新的循环配置套到某条实例上（只改 schedule 字段，不动标题/时间/状态）。
  static Task applySchedule(
    Task task, {
    required int repeatType,
    List<int>? weekDays,
    int? monthDay,
    required DateTime now,
  }) {
    return task.copyWith(
      repeatType: repeatType,
      repeatWeekDays: repeatType == 2 ? weekDays : null,
      repeatMonthDay: repeatType == 3 ? monthDay : null,
      clearRepeatWeekDays: repeatType != 2,
      clearRepeatMonthDay: repeatType != 3,
      updatedAt: now,
    );
  }

  /// 该实例的循环配置是否已经是目标配置（用于避免无意义的批量写库）
  static bool sameSchedule(
    Task task, {
    required int repeatType,
    List<int>? weekDays,
    int? monthDay,
  }) {
    if (task.repeatType != repeatType) return false;
    if (repeatType == 2) {
      final a = (task.repeatWeekDays ?? const <int>[]).toList()..sort();
      final b = (weekDays ?? const <int>[]).toList()..sort();
      if (a.length != b.length) return false;
      for (var i = 0; i < a.length; i++) {
        if (a[i] != b[i]) return false;
      }
      return true;
    }
    if (repeatType == 3) {
      return (task.repeatMonthDay ?? 1) == (monthDay ?? 1);
    }
    return true;
  }

  static Task _buildInstance(Task template, DateTime date, DateTime now, int sortOrder) {
    return Task(
      title: template.title,
      status: TaskStatus.planned,
      urgency: template.urgency,
      createdAt: now,
      planStartAt: _applyDate(template.planStartAt, date),
      dueAt: _applyDate(template.dueAt, date),
      sortOrder: sortOrder,
      taskType: template.taskType,
      repeatType: template.repeatType,
      // 生成时顺手把配置规范化：云端脏数据（越界星期/每月几号）不会一代代传染
      repeatWeekDays: template.repeatType == 2
          ? _sanitizeWeekDays(template.repeatWeekDays)
          : null,
      repeatMonthDay: template.repeatType == 3
          ? _sanitizeMonthDay(template.repeatMonthDay)
          : null,
      repeatGroupId: template.repeatGroupId,
      instanceDate: date,
      updatedAt: now,
    );
  }

  /// 把模板时间的时分秒套用到目标日期（同一天内）
  static DateTime? _applyDate(DateTime? t, DateTime date) {
    if (t == null) return null;
    return DateTime(date.year, date.month, date.day, t.hour, t.minute, t.second);
  }
}
