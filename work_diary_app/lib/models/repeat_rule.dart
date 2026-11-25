import 'repeat_fields.dart';
import 'task.dart';

/// 越界的紧急度按"一般"处理，避免一条脏数据抛 RangeError 拖垮整批读取。
Urgency _urgencyAt(Object? raw) {
  final i = raw is int ? raw : 0;
  if (i < 0 || i >= Urgency.values.length) return Urgency.normal;
  return Urgency.values[i];
}

/// 循环任务规则：与任务实例分离的独立持久化记录。
///
/// 语义：循环任务的"规则"（每天/每周几/每月几号 + 标题与时间）单独保存，
/// 删除某一期实例不影响规则，次日引擎仍会照常补生成；
/// 只有把任务改回"正常任务"或"停止循环"时才把规则标记为 [stopped]。
///
/// 规则会随任务一起同步到云端（`repeat_groups`），这样：
/// - 换一台设备登录，循环任务不会因为"本地没有规则"而失效；
/// - 停止循环的状态能同步到所有设备；
/// - 多端修改规则按 [updatedAt] 走最后写入胜出。
class RepeatRule {
  /// 「该族已停止循环」的哨兵值，写进跳过账本。
  ///
  /// 为什么需要它：引擎在没有规则时会回退到"用现存实例当模板"，所以只删规则
  /// 并不能真正停止循环（同族还有实例就会继续补生成）。停止标记与规则、实例
  /// 都独立，是唯一可靠的"到此为止"信号。
  ///
  /// 规则上云之后 [stopped] 是主信号，哨兵保留给"规则丢失/老数据"的设备兜底。
  static const String stoppedMarker = kRepeatStoppedMarker;

  /// 跳过记录保留天数（本地账本与服务端清理保持一致）
  static const int skipRetentionDays = kRepeatSkipRetentionDays;

  final String repeatGroupId;
  final String title;
  final Urgency urgency;
  final int taskType;
  final int repeatType; // 0正常 1日任务 2周任务 3月任务
  final List<int>? repeatWeekDays; // 周任务：周几（1=周一）
  final int? repeatMonthDay; // 月任务：每月几号（1-31）
  final DateTime? planStartAt; // 计划开始时间（时分秒参与新实例）
  final DateTime? dueAt; // 预计完成时间（时分秒参与新实例）

  /// 用户主动"仅删除本期"的实例日期（YYYY-MM-DD）。
  /// 引擎生成时跳过这些日期，否则删掉的一期会在下一次 _loadTasks 立刻被补回来。
  final List<String> skippedDates;

  /// 已停止循环：不再生成新一期，已有期次原样保留，可随时恢复。
  final bool stopped;

  /// 已永久删除：规则 + 该族全部期次都已删除，且会同步到所有设备。
  ///
  /// 这是"终态"：保留规则本身作为墓碑，让服务端和其它设备知道这个族已经死了，
  /// 而不是"这台设备没有这条规则"（后者会被下一轮同步重新补回来）。
  final bool deleted;

  /// 最后修改时间，用于多端 LWW 合并（规则上云）
  final DateTime updatedAt;

  RepeatRule({
    required this.repeatGroupId,
    required this.title,
    required this.urgency,
    required this.taskType,
    required this.repeatType,
    this.repeatWeekDays,
    this.repeatMonthDay,
    this.planStartAt,
    this.dueAt,
    this.skippedDates = const <String>[],
    this.stopped = false,
    this.deleted = false,
    DateTime? updatedAt,
  }) : updatedAt = updatedAt ?? DateTime.now();

  static String dateKey(DateTime d) =>
      '${d.year.toString().padLeft(4, '0')}-'
      '${d.month.toString().padLeft(2, '0')}-'
      '${d.day.toString().padLeft(2, '0')}';

  /// 该族是否已被用户"停止循环"（永久删除也算停止，引擎不会再生成）
  bool get isStopped => stopped || deleted || skippedDates.contains(stoppedMarker);

  /// 该期是否不应生成
  bool isSkipped(DateTime date) =>
      isStopped || skippedDates.contains(dateKey(date));

  /// 追加一个跳过日期（只保留最近 [skipRetentionDays] 天，避免无限增长）。
  /// 停止标记不是日期，不会被清理掉。
  ///
  /// 跳过记录属于"数据"而不是"配置"：不更新 [updatedAt]，避免每删掉一期
  /// 都和云端规则做一次无意义的 LWW 竞争。
  RepeatRule withSkipped(DateTime date) {
    final key = dateKey(date);
    if (skippedDates.contains(key)) return this;
    final cutoff = DateTime.now()
        .subtract(const Duration(days: skipRetentionDays));
    final kept = <String>[
      for (final s in skippedDates)
        if (DateTime.tryParse(s)?.isBefore(cutoff) != true) s,
      key,
    ]..sort();
    return copyWith(skippedDates: kept);
  }

  /// 复制并覆盖部分字段（[updatedAt] 默认保留原值，需要同步时显式传入）
  RepeatRule copyWith({
    String? title,
    Urgency? urgency,
    int? taskType,
    int? repeatType,
    List<int>? repeatWeekDays,
    int? repeatMonthDay,
    DateTime? planStartAt,
    DateTime? dueAt,
    List<String>? skippedDates,
    bool? stopped,
    bool? deleted,
    DateTime? updatedAt,
    bool clearRepeatWeekDays = false,
    bool clearRepeatMonthDay = false,
    bool clearPlanStartAt = false,
    bool clearDueAt = false,
  }) {
    return RepeatRule(
      repeatGroupId: repeatGroupId,
      title: title ?? this.title,
      urgency: urgency ?? this.urgency,
      taskType: taskType ?? this.taskType,
      repeatType: repeatType ?? this.repeatType,
      repeatWeekDays:
          clearRepeatWeekDays ? null : (repeatWeekDays ?? this.repeatWeekDays),
      repeatMonthDay:
          clearRepeatMonthDay ? null : (repeatMonthDay ?? this.repeatMonthDay),
      planStartAt: clearPlanStartAt ? null : (planStartAt ?? this.planStartAt),
      dueAt: clearDueAt ? null : (dueAt ?? this.dueAt),
      skippedDates: skippedDates ?? this.skippedDates,
      stopped: stopped ?? this.stopped,
      deleted: deleted ?? this.deleted,
      updatedAt: updatedAt ?? this.updatedAt,
    );
  }

  /// 从现有任务实例提取规则（创建/编辑循环任务时调用）。
  ///
  /// [skippedDates]、[stopped] 必须由调用方传入原有规则里的值：编辑任务时是
  /// "覆盖写一份规则"，不带上原有状态等于把用户删过的期次/停止标记又放出来。
  factory RepeatRule.fromTask(
    Task t, {
    List<String>? skippedDates,
    bool stopped = false,
    bool deleted = false,
  }) {
    return RepeatRule(
      repeatGroupId: t.repeatGroupId ?? '',
      title: t.title,
      urgency: t.urgency,
      taskType: t.taskType,
      repeatType: t.repeatType,
      repeatWeekDays: t.repeatWeekDays,
      repeatMonthDay: t.repeatMonthDay,
      planStartAt: t.planStartAt,
      dueAt: t.dueAt,
      skippedDates: skippedDates ?? const <String>[],
      stopped: stopped,
      deleted: deleted,
    );
  }

  Map<String, dynamic> toMap() {
    return {
      'repeat_group_id': repeatGroupId,
      'title': title,
      'urgency': urgency.index,
      'task_type': taskType,
      'repeat_type': repeatType,
      'repeat_week_days': repeatWeekDays?.join(','),
      'repeat_month_day': repeatMonthDay,
      'plan_start_at': planStartAt?.toIso8601String(),
      'due_at': dueAt?.toIso8601String(),
      'skip_dates': skippedDates.join(','),
      'stopped': stopped ? 1 : 0,
      'deleted': deleted ? 1 : 0,
      'updated_at': updatedAt.toIso8601String(),
    };
  }

  /// 容错解析：旧版本/损坏的规则不能让整批读取失败，更不能抛异常。
  factory RepeatRule.fromMap(Map<String, dynamic> map) {
    final rawStopped = map['stopped'];
    final rawDeleted = map['deleted'];
    final savedAt = parseRepeatTime(map['updated_at']);
    return RepeatRule(
      repeatGroupId: '${map['repeat_group_id'] ?? ''}',
      title: '${map['title'] ?? ''}',
      urgency: _urgencyAt(map['urgency']),
      taskType: map['task_type'] is int ? map['task_type'] as int : 1,
      repeatType: normalizeRepeatType(map['repeat_type']),
      repeatWeekDays: parseRepeatWeekDays(map['repeat_week_days']),
      repeatMonthDay: normalizeRepeatMonthDay(map['repeat_month_day']),
      planStartAt: parseRepeatTime(map['plan_start_at']),
      dueAt: parseRepeatTime(map['due_at']),
      skippedDates: parseRepeatSkips(map['skip_dates']),
      stopped: rawStopped == true || rawStopped == 1,
      deleted: rawDeleted == true || rawDeleted == 1,
      // 老数据没有 updated_at：给一个"足够旧"的时间，让云端规则能覆盖它，
      // 而不是每次读取都变成"最新"、永远压住云端。
      updatedAt: savedAt ?? DateTime.fromMillisecondsSinceEpoch(0),
    );
  }

  /// 转成模板任务，供生成引擎复用（引擎内部统一按 Task 处理）
  Task asTemplateTask(DateTime now) {
    return Task(
      title: title,
      status: TaskStatus.planned,
      urgency: urgency,
      createdAt: now,
      planStartAt: planStartAt,
      dueAt: dueAt,
      taskType: taskType,
      repeatType: repeatType,
      repeatWeekDays: repeatWeekDays,
      repeatMonthDay: repeatMonthDay,
      repeatGroupId: repeatGroupId,
    );
  }
}
