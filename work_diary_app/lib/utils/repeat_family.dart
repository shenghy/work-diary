import '../models/repeat_rule.dart';
import '../models/task.dart';
import 'repeat_task_engine.dart';

/// 一个循环任务族（= 一条循环规则 + 它生成的所有期次）的汇总信息。
///
/// 供「循环任务」管理页展示：规则文案、已生成/未完成期数、最近一期、下一期。
class RepeatFamilyInfo {
  const RepeatFamilyInfo({
    required this.groupId,
    required this.title,
    required this.repeatType,
    required this.weekDays,
    required this.monthDay,
    required this.planStartAt,
    required this.stopped,
    required this.hasRule,
    required this.total,
    required this.unfinished,
    required this.latest,
    required this.next,
  });

  final String groupId;
  final String title;
  final int repeatType;
  final List<int>? weekDays;
  final int? monthDay;
  final DateTime? planStartAt;

  /// 已停止循环（不再生成新一期，已有期次保留）
  final bool stopped;

  /// 本机是否有这条规则。false 表示只能从现存实例推断（换设备/规则丢失的老数据）
  final bool hasRule;

  /// 已生成期数
  final int total;

  /// 其中未完成的期数
  final int unfinished;

  /// 最近一期的实例日期
  final DateTime? latest;

  /// 下一期的实例日期；已停止或无法推断时为 null
  final DateTime? next;
}

/// 把任务 + 规则汇总成"族"列表（纯函数，便于单测）
class RepeatFamily {
  static List<RepeatFamilyInfo> build(
    List<Task> tasks,
    Map<String, RepeatRule> rules,
    DateTime now, {
    Map<String, Set<String>> skips = const <String, Set<String>>{},
  }) {
    final ruleByGroup = <String, RepeatRule>{};
    final deletedGroups = <String>{};
    for (final entry in rules.entries) {
      if (entry.key.isEmpty) continue;
      if (entry.value.repeatType <= 0) continue;
      if (entry.value.deleted) {
        // 永久删除的族只保留墓碑，不在管理页/生成引擎里出现
        deletedGroups.add(entry.key);
        continue;
      }
      ruleByGroup[entry.key] = entry.value;
    }

    final instances = <String, List<Task>>{};
    for (final t in tasks) {
      final gid = t.repeatGroupId;
      if (gid == null || gid.isEmpty) continue;
      if (t.repeatType <= 0) continue;
      instances.putIfAbsent(gid, () => <Task>[]).add(t);
    }

    // 族 ID 集合 = 规则 ∪ 实例（两者都可能单独存在）
    final groupIds = <String>{...ruleByGroup.keys, ...instances.keys};

    final result = <RepeatFamilyInfo>[];
    for (final gid in groupIds) {
      // 已永久删除：规则/实例都不再展示（实例正常情况下已被清掉）
      if (deletedGroups.contains(gid)) continue;
      final rule = ruleByGroup[gid];
      final list = instances[gid] ?? const <Task>[];

      // 规则优先；没有规则时退回"最早创建的实例"当模板（与生成引擎一致）
      Task? template;
      for (final t in list) {
        if (template == null || t.createdAt.isBefore(template.createdAt)) {
          template = t;
        }
      }
      if (rule == null && template == null) continue;

      final repeatType = rule?.repeatType ?? template!.repeatType;
      final weekDays = rule?.repeatWeekDays ?? template?.repeatWeekDays;
      final monthDay = rule?.repeatMonthDay ?? template?.repeatMonthDay;
      final planStartAt = rule?.planStartAt ?? template?.planStartAt;
      final title = rule?.title ?? template!.title;

      DateTime? latest;
      var unfinished = 0;
      for (final t in list) {
        if (t.status != TaskStatus.completed) unfinished++;
        final d = t.instanceDate;
        if (d == null) continue;
        final day = DateTime(d.year, d.month, d.day);
        if (latest == null || day.isAfter(latest)) latest = day;
      }

      // 停止信号有两个来源：规则里的 stopped（云端同步的主信号）、
      // 本地跳过账本里的哨兵（老数据/规则丢失时的兜底）。
      final stopped = (rule?.isStopped ?? false) ||
          (skips[gid]?.contains(RepeatRule.stoppedMarker) ?? false);

      final next = stopped
          ? null
          : RepeatTaskEngine.nextInstanceDate(
              repeatType: repeatType,
              weekDays: weekDays,
              monthDay: monthDay,
              now: now,
              after: latest,
            );

      result.add(RepeatFamilyInfo(
        groupId: gid,
        title: title,
        repeatType: repeatType,
        weekDays: weekDays,
        monthDay: monthDay,
        planStartAt: planStartAt,
        stopped: stopped,
        hasRule: rule != null,
        total: list.length,
        unfinished: unfinished,
        latest: latest,
        next: next,
      ));
    }

    // 进行中的排在前面；同组内按下一次生成时间升序（越早越靠前）
    result.sort((a, b) {
      if (a.stopped != b.stopped) return a.stopped ? 1 : -1;
      final an = a.next, bn = b.next;
      if (an != null && bn != null && an != bn) return an.compareTo(bn);
      if (an == null && bn != null) return 1;
      if (an != null && bn == null) return -1;
      return a.title.compareTo(b.title);
    });
    return result;
  }
}
