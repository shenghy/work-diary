import 'repeat_fields.dart';

/// 任务状态：计划中 → 执行中 → 已完成
enum TaskStatus { planned, executing, completed }

/// 紧急程度：一般（灰）、紧急（黄）、重要（红）
enum Urgency { normal, urgent, important }

/// 任务数据模型
class Task {
  final int? id;
  final int? remoteId; // 远端数据库ID，用于同步
  final String title;
  final TaskStatus status;
  final Urgency urgency;
  final DateTime createdAt;
  final DateTime? startedAt;
  final DateTime? completedAt;
  final DateTime? planStartAt; // 计划开始执行时间
  final DateTime? dueAt; // 预计交付/完成时间
  final int sortOrder; // 拖拽排序顺序，组内升序
  final int taskType; // 0个人任务 1工作任务
  final int repeatType; // 0正常 1日任务 2周任务 3月任务
  final List<int>? repeatWeekDays; // 周任务：周几（1=周一）
  final int? repeatMonthDay; // 月任务：每月几号（1-31）
  final String? repeatGroupId; // 循环任务族ID
  final DateTime? instanceDate; // 实例所属日期
  final DateTime updatedAt; // 最后修改时间，用于同步冲突判断

  Task({
    this.id,
    this.remoteId,
    required this.title,
    this.status = TaskStatus.planned,
    this.urgency = Urgency.normal,
    required this.createdAt,
    this.startedAt,
    this.completedAt,
    this.planStartAt,
    this.dueAt,
    this.sortOrder = 0,
    this.taskType = 1,
    this.repeatType = 0,
    this.repeatWeekDays,
    this.repeatMonthDay,
    this.repeatGroupId,
    this.instanceDate,
    DateTime? updatedAt,
  }) : updatedAt = updatedAt ?? createdAt;

  Task copyWith({
    int? id,
    int? remoteId,
    String? title,
    TaskStatus? status,
    Urgency? urgency,
    DateTime? createdAt,
    DateTime? startedAt,
    DateTime? completedAt,
    DateTime? planStartAt,
    DateTime? dueAt,
    int? sortOrder,
    int? taskType,
    int? repeatType,
    List<int>? repeatWeekDays,
    int? repeatMonthDay,
    String? repeatGroupId,
    DateTime? instanceDate,
    DateTime? updatedAt,
    bool clearStartedAt = false,
    bool clearCompletedAt = false,
    bool clearPlanStartAt = false,
    bool clearDueAt = false,
    bool clearRepeatWeekDays = false,
    bool clearRepeatMonthDay = false,
    bool clearRepeatGroupId = false,
    bool clearInstanceDate = false,
  }) {
    return Task(
      id: id ?? this.id,
      remoteId: remoteId ?? this.remoteId,
      title: title ?? this.title,
      status: status ?? this.status,
      urgency: urgency ?? this.urgency,
      createdAt: createdAt ?? this.createdAt,
      startedAt: clearStartedAt ? null : (startedAt ?? this.startedAt),
      completedAt:
          clearCompletedAt ? null : (completedAt ?? this.completedAt),
      planStartAt:
          clearPlanStartAt ? null : (planStartAt ?? this.planStartAt),
      dueAt: clearDueAt ? null : (dueAt ?? this.dueAt),
      sortOrder: sortOrder ?? this.sortOrder,
      taskType: taskType ?? this.taskType,
      repeatType: repeatType ?? this.repeatType,
      repeatWeekDays:
          clearRepeatWeekDays ? null : (repeatWeekDays ?? this.repeatWeekDays),
      repeatMonthDay:
          clearRepeatMonthDay ? null : (repeatMonthDay ?? this.repeatMonthDay),
      repeatGroupId:
          clearRepeatGroupId ? null : (repeatGroupId ?? this.repeatGroupId),
      instanceDate:
          clearInstanceDate ? null : (instanceDate ?? this.instanceDate),
      updatedAt: updatedAt ?? this.updatedAt,
    );
  }

  Map<String, dynamic> toMap() {
    return {
      'id': id,
      'remote_id': remoteId,
      'title': title,
      'status': status.index,
      'urgency': urgency.index,
      'created_at': createdAt.toIso8601String(),
      'started_at': startedAt?.toIso8601String(),
      'completed_at': completedAt?.toIso8601String(),
      'plan_start_at': planStartAt?.toIso8601String(),
      'due_at': dueAt?.toIso8601String(),
      'sort_order': sortOrder,
      'task_type': taskType,
      'repeat_type': repeatType,
      'repeat_week_days': repeatWeekDays?.join(','),
      'repeat_month_day': repeatMonthDay,
      'repeat_group_id': repeatGroupId,
      'instance_date': instanceDate == null
          ? null
          : '${instanceDate!.year.toString().padLeft(4, '0')}-'
              '${instanceDate!.month.toString().padLeft(2, '0')}-'
              '${instanceDate!.day.toString().padLeft(2, '0')}',
      'updated_at': updatedAt.toIso8601String(),
    };
  }

  factory Task.fromMap(Map<String, dynamic> map) {
    // 解析必须容错：旧版本/损坏的一条记录不能让整批任务读取失败
    //（那样界面会显示成"全部任务都没了"）。
    final createdAt = map['created_at'] is String
        ? (DateTime.tryParse(map['created_at'] as String) ?? DateTime.now())
        : DateTime.now();
    DateTime? optionalTime(Object? raw) =>
        raw is String ? DateTime.tryParse(raw) : null;
    return Task(
      id: map['id'] as int?,
      remoteId: map['remote_id'] as int?,
      title: (map['title'] as String?) ?? '',
      status: _statusAt(map['status']),
      urgency: _urgencyAt(map['urgency']),
      createdAt: createdAt,
      startedAt: optionalTime(map['started_at']),
      completedAt: optionalTime(map['completed_at']),
      planStartAt: optionalTime(map['plan_start_at']),
      dueAt: optionalTime(map['due_at']),
      sortOrder: (map['sort_order'] as int?) ?? 0,
      taskType: (map['task_type'] as int?) ?? 1,
      // 循环任务字段容错：旧版本/脏数据不能让整条任务读不出来
      repeatType: normalizeRepeatType(map['repeat_type']),
      repeatWeekDays: parseRepeatWeekDays(map['repeat_week_days']),
      repeatMonthDay: normalizeRepeatMonthDay(map['repeat_month_day']),
      repeatGroupId: map['repeat_group_id'] is String &&
              (map['repeat_group_id'] as String).isNotEmpty
          ? map['repeat_group_id'] as String
          : null,
      instanceDate: map['instance_date'] is String
          ? DateTime.tryParse(map['instance_date'] as String)
          : null,
      updatedAt: optionalTime(map['updated_at']) ?? createdAt,
    );
  }
}

/// 越界的状态按"计划中"处理
TaskStatus _statusAt(Object? raw) {
  final i = raw is int ? raw : 0;
  if (i < 0 || i >= TaskStatus.values.length) return TaskStatus.planned;
  return TaskStatus.values[i];
}

/// 越界的紧急度按"一般"处理
Urgency _urgencyAt(Object? raw) {
  final i = raw is int ? raw : 0;
  if (i < 0 || i >= Urgency.values.length) return Urgency.normal;
  return Urgency.values[i];
}
