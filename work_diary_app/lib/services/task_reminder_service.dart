import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

import '../models/task.dart';

/// 任务提醒服务：每分钟轮询，在计划开始前10分钟、预计完成前20分钟弹出提醒。
class TaskReminderService {
  static final TaskReminderService instance = TaskReminderService._();
  TaskReminderService._();

  static const int _startRemindMinutes = 10;
  static const int _dueRemindMinutes = 20;

  /// 提醒调试日志开关（默认关闭，避免每分钟写盘）
  static const bool _verboseLog = false;

  Timer? _timer;

  /// 已提醒记录：key（含任务时间戳）-> 提醒时间。
  /// 用 Map 而不是 Set，便于按时间清理，避免长期运行无限增长。
  final Map<String, DateTime> _reminded = {};
  bool _enabled = true;
  bool _initialized = false;

  /// 获取当前任务列表的回调
  List<Task> Function()? taskProvider;

  /// 提醒触发回调：tasks 为到点的任务列表，type 为 'start' 或 'due'
  void Function(List<Task> tasks, String type)? onRemind;

  /// 初始化服务，启动轮询
  void init({
    required List<Task> Function() taskProvider,
    required void Function(List<Task> tasks, String type) onRemind,
  }) {
    this.taskProvider = taskProvider;
    this.onRemind = onRemind;
    _initAsync();
  }

  Future<void> _initAsync() async {
    if (_initialized) return;
    _initialized = true;
    await _loadEnabled();
    _log('init: enabled=$_enabled, starting timer');
    _start();
  }

  void _start() {
    _timer?.cancel();
    if (!_enabled) {
      _log('start: disabled, timer not started');
      return;
    }
    _checkNow(); // 启动时立即检查一次
    _timer = Timer.periodic(const Duration(minutes: 1), (_) => _checkNow());
    _log('start: timer started, interval=1min');
  }

  /// 立即检查一次（外部也可调用）
  void checkNow() => _checkNow();

  void _checkNow() {
    if (!_enabled) return;
    final provider = taskProvider;
    if (provider == null) return;
    final now = DateTime.now();
    final tasks = provider();

    final startTasks = <Task>[];
    final dueTasks = <Task>[];

    for (final task in tasks) {
      if (task.status == TaskStatus.completed) continue; // 已完成不提醒

      // 开始提醒：计划开始前 10 分钟内
      if (task.planStartAt != null) {
        final diff = task.planStartAt!.difference(now).inMinutes;
        if (diff >= 0 && diff <= _startRemindMinutes) {
          // key 带上计划时间：用户改期后 key 变化，会重新提醒一次。
          // 旧实现只用任务 id，改期后永远不再提醒。
          final key = '${task.id ?? task.title}_start_'
              '${task.planStartAt!.millisecondsSinceEpoch}';
          if (!_reminded.containsKey(key)) {
            _reminded[key] = now;
            startTasks.add(task);
          }
        }
      }

      // 完成提醒：预计完成前 20 分钟内
      if (task.dueAt != null) {
        final diff = task.dueAt!.difference(now).inMinutes;
        if (diff >= 0 && diff <= _dueRemindMinutes) {
          final key = '${task.id ?? task.title}_due_'
              '${task.dueAt!.millisecondsSinceEpoch}';
          if (!_reminded.containsKey(key)) {
            _reminded[key] = now;
            dueTasks.add(task);
          }
        }
      }
    }

    _pruneReminded(now);

    if (startTasks.isNotEmpty) onRemind?.call(startTasks, 'start');
    if (dueTasks.isNotEmpty) onRemind?.call(dueTasks, 'due');
  }

  /// 记录集膨胀到一定规模时清理 7 天前的条目
  void _pruneReminded(DateTime now) {
    if (_reminded.length < 512) return;
    final cutoff = now.subtract(const Duration(days: 7));
    _reminded.removeWhere((_, at) => at.isBefore(cutoff));
  }

  /// 提醒开关状态
  bool get enabled => _enabled;

  /// 设置提醒开关
  void setEnabled(bool value) {
    _enabled = value;
    _saveEnabled();
    _log('setEnabled: $value');
    if (value) {
      _start();
    } else {
      _timer?.cancel();
      _log('setEnabled: timer cancelled');
    }
  }

  // ---- 开关状态持久化 ----

  Future<File> get _configFile async {
    final dir = await getApplicationSupportDirectory();
    return File('${dir.path}/reminder_config.json');
  }

  Future<void> _loadEnabled() async {
    try {
      final file = await _configFile;
      if (await file.exists()) {
        final data = jsonDecode(await file.readAsString()) as Map<String, dynamic>;
        _enabled = data['enabled'] as bool? ?? true;
        _log('_loadEnabled: loaded from file, enabled=$_enabled');
      } else {
        _log('_loadEnabled: config file not exist, default enabled=true');
      }
    } catch (e) {
      _enabled = true; // 读取失败默认开启
      _log('_loadEnabled: error=$e, default enabled=true');
    }
  }

  Future<void> _saveEnabled() async {
    try {
      final file = await _configFile;
      await file.writeAsString(jsonEncode({'enabled': _enabled}));
    } catch (_) {
      // 保存失败不影响运行
    }
  }

  // ---- 调试日志 ----

  Future<File> get _logFile async {
    final dir = await getApplicationSupportDirectory();
    return File('${dir.path}/reminder_debug.log');
  }

  Future<void> _log(String msg) async {
    // 默认关闭：旧实现每分钟为每个任务追加一行并 flush，任务一多就是
    // 持续磁盘写入 + 日志无限增长。排查问题时把它改成 true。
    if (!_verboseLog) return;
    try {
      final file = await _logFile;
      final ts = DateTime.now().toIso8601String();
      await file.writeAsString('[$ts] $msg\n', mode: FileMode.append, flush: true);
    } catch (_) {
      // 日志失败不影响运行
    }
  }
}
