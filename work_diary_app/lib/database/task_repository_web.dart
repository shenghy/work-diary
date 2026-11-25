import '../models/repeat_rule.dart';
import '../models/task.dart';
import 'task_repository.dart';

/// Web 端内存实现（Web 不支持 SQLite FFI）
/// 数据仅在当前会话有效，刷新后丢失——用于 Demo 验证 UI 与逻辑
class TaskRepositoryImpl implements TaskRepository {
  final List<Task> _tasks = [];
  final Map<String, RepeatRule> _rules = {};
  final Map<String, Set<String>> _skips = {};
  int _nextId = 1;

  @override
  Future<int> insertTask(Task task) async {
    final newTask = task.copyWith(id: _nextId++);
    _tasks.add(newTask);
    return newTask.id!;
  }

  @override
  Future<List<Task>> getTasks({TaskStatus? status}) async {
    var list = List<Task>.from(_tasks);
    if (status != null) {
      list = list.where((t) => t.status == status).toList();
    }
    // 已完成置底；未完成的按计划开始时间升序（无计划排最后），再按创建时间倒序
    list.sort((a, b) {
      final aDone = a.status == TaskStatus.completed ? 1 : 0;
      final bDone = b.status == TaskStatus.completed ? 1 : 0;
      if (aDone != bDone) return aDone - bDone;
      if (a.planStartAt != null && b.planStartAt != null) {
        return a.planStartAt!.compareTo(b.planStartAt!);
      }
      if (a.planStartAt != null) return -1;
      if (b.planStartAt != null) return 1;
      return b.createdAt.compareTo(a.createdAt);
    });
    return list;
  }

  @override
  Future<int> updateTask(Task task) async {
    final idx = _tasks.indexWhere((t) => t.id == task.id);
    if (idx != -1) _tasks[idx] = task;
    return 1;
  }

  @override
  Future<int> deleteTask(int id) async {
    _tasks.removeWhere((t) => t.id == id);
    return 1;
  }

  @override
  Future<void> replaceAll(List<Task> tasks, {DateTime? keepAfter}) async {
    _tasks.clear();
    _nextId = 1;
    for (final task in tasks) {
      final id = task.id ?? _nextId++;
      _tasks.add(task.copyWith(id: id));
      if (id >= _nextId) _nextId = id + 1;
    }
  }

  // ===== 循环任务规则库（内存，随会话失效）=====
  @override
  Future<Map<String, RepeatRule>> getRepeatRules() async {
    return Map<String, RepeatRule>.from(_rules);
  }

  @override
  Future<void> putRepeatRule(RepeatRule rule) async {
    _rules[rule.repeatGroupId] = rule;
  }

  @override
  Future<void> deleteRepeatRule(String repeatGroupId) async {
    _rules.remove(repeatGroupId);
  }

  @override
  Future<void> skipRepeatInstance(Task task) async {
    final groupId = task.repeatGroupId;
    final date = task.instanceDate;
    if (groupId == null || groupId.isEmpty || date == null) return;
    _skips.putIfAbsent(groupId, () => <String>{}).add(RepeatRule.dateKey(date));
    final rule = _rules[groupId];
    if (rule != null) {
      _rules[groupId] = rule.withSkipped(date);
    }
  }

  @override
  Future<Map<String, Set<String>>> getRepeatSkips() async => {
        for (final entry in _skips.entries)
          entry.key: Set<String>.from(entry.value),
      };

  @override
  Future<void> stopRepeatGroup(String groupId) async {
    if (groupId.isEmpty) return;
    final rule = _rules[groupId];
    if (rule != null && !rule.stopped) {
      _rules[groupId] = rule.copyWith(stopped: true, updatedAt: DateTime.now());
    }
    _skips.putIfAbsent(groupId, () => <String>{}).add(RepeatRule.stoppedMarker);
  }

  @override
  Future<void> resumeRepeatGroup(String groupId) async {
    final rule = _rules[groupId];
    if (rule != null && rule.stopped) {
      _rules[groupId] = rule.copyWith(stopped: false, updatedAt: DateTime.now());
    }
    final set = _skips[groupId];
    if (set == null) return;
    set.remove(RepeatRule.stoppedMarker);
    if (set.isEmpty) _skips.remove(groupId);
  }

  @override
  Future<void> mergeRepeatRules(Map<String, RepeatRule> rules) async {
    for (final entry in rules.entries) {
      if (entry.key.isEmpty) continue;
      final existing = _rules[entry.key];
      // 永久删除是终态：墓碑优先，不能被本地旧规则复活。
      if (entry.value.deleted) {
        _tasks.removeWhere((t) => t.repeatGroupId == entry.key);
        _rules[entry.key] = entry.value.copyWith(stopped: true, deleted: true);
        _skips
            .putIfAbsent(entry.key, () => <String>{})
            .add(RepeatRule.stoppedMarker);
        continue;
      }
      if (existing?.deleted == true) continue;
      if (existing != null && !entry.value.updatedAt.isAfter(existing.updatedAt)) {
        continue;
      }
      final merged = entry.value.copyWith(
        skippedDates: <String>{
          ...entry.value.skippedDates,
          ...?existing?.skippedDates,
        }.toList()
          ..sort(),
      );
      _rules[entry.key] = merged;
      if (merged.isStopped) {
        _skips.putIfAbsent(entry.key, () => <String>{}).add(
              RepeatRule.stoppedMarker,
            );
      } else {
        _skips[entry.key]?.remove(RepeatRule.stoppedMarker);
      }
    }
  }

  @override
  Future<void> mergeRepeatSkips(Map<String, Set<String>> skips) async {
    for (final entry in skips.entries) {
      if (entry.key.isEmpty) continue;
      _skips.putIfAbsent(entry.key, () => <String>{}).addAll(entry.value);
    }
  }
}
