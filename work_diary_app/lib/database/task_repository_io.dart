import 'package:hive_flutter/hive_flutter.dart';
import '../models/repeat_rule.dart';
import '../models/task.dart';
import 'hive_bootstrap.dart';
import 'task_repository.dart';

/// 桌面/移动端 Hive 本地数据库实现
/// Hive 是纯 Dart 实现的轻量数据库，无需安装、跨平台、无原生依赖
class TaskRepositoryImpl implements TaskRepository {
  static const String _boxName = 'tasks';
  static const String _rulesBoxName = 'repeat_rules';
  static const String _skipsBoxName = 'repeat_skips';
  Box? _box;
  Box? _rulesBox;
  Box? _skipsBox;
  int _nextId = 1;

  Future<Box> get _database async {
    if (_box != null) return _box!;
    await HiveBootstrap.ensureInitialized();
    _box = await Hive.openBox(_boxName);
    // 从已有数据推算下一个自增 ID
    for (final key in _box!.keys) {
      final id = int.tryParse(key.toString());
      if (id != null && id >= _nextId) _nextId = id + 1;
    }
    return _box!;
  }

  @override
  Future<int> insertTask(Task task) async {
    final box = await _database;
    final id = _nextId++;
    final newTask = task.copyWith(id: id);
    await box.put('$id', newTask.toMap());
    return id;
  }

  @override
  Future<List<Task>> getTasks({TaskStatus? status}) async {
    final box = await _database;
    // 逐条解析：一条损坏/旧格式的记录不能让整批读取失败，
    // 否则界面会显示成"所有任务都没了"。
    final tasks = <Task>[];
    for (final value in box.values) {
      try {
        tasks.add(Task.fromMap(Map<String, dynamic>.from(value as Map)));
      } catch (_) {
        // 跳过损坏记录
      }
    }
    if (status != null) {
      return tasks.where((t) => t.status == status).toList()..sort(_compare);
    }
    // 已完成置底；未完成的组内按 sortOrder 升序，相同则按创建时间倒序
    tasks.sort(_compare);
    return tasks;
  }

  static int _compare(Task a, Task b) {
    final aDone = a.status == TaskStatus.completed ? 1 : 0;
    final bDone = b.status == TaskStatus.completed ? 1 : 0;
    if (aDone != bDone) return aDone - bDone;
    // 组内按 sortOrder 升序
    if (a.sortOrder != b.sortOrder) return a.sortOrder - b.sortOrder;
    // sortOrder 相同时按创建时间倒序（新的在前）
    return b.createdAt.compareTo(a.createdAt);
  }

  @override
  Future<int> updateTask(Task task) async {
    final box = await _database;
    // id 为空时写入会产生 'null' 这个幽灵键（下次读取出现删不掉的记录）
    if (task.id == null) return 0;
    final key = '${task.id}';
    if (!box.containsKey(key)) return 0;
    await box.put(key, task.toMap());
    return 1;
  }

  @override
  Future<int> deleteTask(int id) async {
    final box = await _database;
    await box.delete('$id');
    return 1;
  }

  @override
  Future<void> replaceAll(List<Task> tasks, {DateTime? keepAfter}) async {
    final box = await _database;
    // 增量写入，不做 clear() + 全量重写：
    // 1) clear 之后到写完之间崩溃/强退会让本地任务全部丢失；
    // 2) 同步请求发出到返回的这段时间里用户新建的任务不在 tasks 里，
    //    全量重写会把它直接抹掉（真实丢数据）。
    var nextId = 1;
    for (final key in box.keys) {
      final id = int.tryParse(key.toString());
      if (id != null && id >= nextId) nextId = id + 1;
    }

    final keep = <String>{};
    final pending = <Task>[];
    for (final task in tasks) {
      final id = task.id;
      if (id == null) {
        pending.add(task);
        continue;
      }
      var key = '$id';
      if (keep.contains(key)) {
        // 多条云端记录映射到同一个本地 id（多设备各自从 1 开始自增导致）：
        // 换一个新的本地 id，避免后者覆盖前者造成任务丢失。remoteId 保留，
        // 下一次同步服务端仍会按 remote_id 命中正确的行。
        key = '${nextId++}';
      }
      keep.add(key);
      final assigned = int.parse(key);
      await box.put(key, task.copyWith(id: assigned).toMap());
      if (assigned >= nextId) nextId = assigned + 1;
    }

    // 再给没有本地 id 的任务分配新 id（显式 id 已全部落库，避免撞车）
    for (final task in pending) {
      final id = nextId++;
      final key = '$id';
      keep.add(key);
      await box.put(key, task.copyWith(id: id).toMap());
    }

    // 删除云端已不存在、且本次没有写回的旧记录。
    // 但同步请求发出之后本地又被修改/新建的任务不在这次云端结果里，
    // 必须保留，否则"同步过程中新建的任务"会被这里删掉。
    final stale = <String>[];
    for (final key in box.keys) {
      final k = key.toString();
      if (keep.contains(k)) continue;
      final raw = box.get(key);
      if (raw is Map) {
        // 还没拿到云端 id 的本地新任务：云端这次没返回它是正常的（它可能就是
        // 刚刚才上传的），删掉就是真丢数据。必须先保留。
        if (raw['remote_id'] == null) continue;
        if (keepAfter != null) {
          final at = DateTime.tryParse('${raw['updated_at'] ?? ''}');
          // 解析不了也保留，宁可多留一条也不误删
          if (at == null || at.isAfter(keepAfter)) continue;
        }
      }
      stale.add(k);
    }
    if (stale.isNotEmpty) await box.deleteAll(stale);

    _nextId = nextId;
  }

  // ===== 循环任务规则库 =====
  Future<Box> get _rulesDatabase async {
    if (_rulesBox != null) return _rulesBox!;
    await HiveBootstrap.ensureInitialized();
    _rulesBox = await Hive.openBox(_rulesBoxName);
    return _rulesBox!;
  }

  /// 跳过账本：键 = repeatGroupId，值 = 被用户删掉的实例日期列表。
  /// 与规则分开存，因为规则不同步、可能根本不存在。
  Future<Box> get _skipsDatabase async {
    if (_skipsBox != null) return _skipsBox!;
    await HiveBootstrap.ensureInitialized();
    _skipsBox = await Hive.openBox(_skipsBoxName);
    return _skipsBox!;
  }

  @override
  Future<Map<String, RepeatRule>> getRepeatRules() async {
    final box = await _rulesDatabase;
    final result = <String, RepeatRule>{};
    for (final entry in box.toMap().entries) {
      final key = entry.key.toString();
      try {
        result[key] = RepeatRule.fromMap(
          Map<String, dynamic>.from(entry.value as Map),
        );
      } catch (_) {
        // 单条损坏不阻塞整体读取
      }
    }
    return result;
  }

  @override
  Future<void> putRepeatRule(RepeatRule rule) async {
    final box = await _rulesDatabase;
    await box.put(rule.repeatGroupId, rule.toMap());
  }

  @override
  Future<void> deleteRepeatRule(String repeatGroupId) async {
    final box = await _rulesDatabase;
    await box.delete(repeatGroupId);
  }

  @override
  Future<void> skipRepeatInstance(Task task) async {
    final groupId = task.repeatGroupId;
    final date = task.instanceDate;
    if (groupId == null || groupId.isEmpty || date == null) return;
    final dateKey = RepeatRule.dateKey(date);

    // 1) 独立跳过账本：不依赖规则是否存在。
    //    循环规则只存在于创建任务的那台设备，别的设备上根本没有规则记录，
    //    旧实现在这里直接 return，导致"删除本期"在第二台设备上完全无效。
    final skipsBox = await _skipsDatabase;
    final existing = (skipsBox.get(groupId) as List?)?.cast<String>().toList() ??
        <String>[];
    if (!existing.contains(dateKey)) {
      existing.add(dateKey);
      await skipsBox.put(groupId, existing);
    }

    // 2) 有规则时同步写一份，保持规则自洽（引擎两处都会看）
    final box = await _rulesDatabase;
    final raw = box.get(groupId);
    if (raw is Map) {
      try {
        final rule = RepeatRule.fromMap(Map<String, dynamic>.from(raw));
        await box.put(groupId, rule.withSkipped(date).toMap());
      } catch (_) {
        // 规则损坏不影响跳过账本
      }
    }
  }

  @override
  Future<Map<String, Set<String>>> getRepeatSkips() async {
    final box = await _skipsDatabase;
    final result = <String, Set<String>>{};
    for (final entry in box.toMap().entries) {
      final key = entry.key.toString();
      final value = entry.value;
      if (value is List) {
        result[key] = value.map((e) => e.toString()).toSet();
      }
    }
    return result;
  }

  /// 跳过账本里某族的集合（不存在时为空集）
  Future<Set<String>> _skipSet(String groupId) async {
    final box = await _skipsDatabase;
    return ((box.get(groupId) as List?)?.map((e) => e.toString()) ?? const [])
        .toSet();
  }

  Future<void> _writeSkipSet(String groupId, Set<String> values) async {
    final box = await _skipsDatabase;
    if (values.isEmpty) {
      if (box.containsKey(groupId)) await box.delete(groupId);
      return;
    }
    await box.put(groupId, values.toList()..sort());
  }

  /// 读取本地规则（不存在 / 损坏返回 null）
  Future<RepeatRule?> _readRule(String groupId) async {
    final box = await _rulesDatabase;
    final raw = box.get(groupId);
    if (raw is! Map) return null;
    try {
      return RepeatRule.fromMap(Map<String, dynamic>.from(raw));
    } catch (_) {
      return null;
    }
  }

  @override
  Future<void> stopRepeatGroup(String groupId) async {
    if (groupId.isEmpty) return;
    // 1) 规则标记 stopped：这条会随同步下发，别的设备也就不再生成新一期
    final rule = await _readRule(groupId);
    if (rule != null && !rule.stopped) {
      final box = await _rulesDatabase;
      await box.put(
        groupId,
        rule.copyWith(stopped: true, updatedAt: DateTime.now()).toMap(),
      );
    }
    // 2) 本地哨兵兜底：规则不存在 / 被清理时同样不生成
    final set = await _skipSet(groupId)..add(RepeatRule.stoppedMarker);
    await _writeSkipSet(groupId, set);
  }

  @override
  Future<void> resumeRepeatGroup(String groupId) async {
    if (groupId.isEmpty) return;
    final rule = await _readRule(groupId);
    if (rule != null && rule.stopped) {
      final box = await _rulesDatabase;
      await box.put(
        groupId,
        rule.copyWith(stopped: false, updatedAt: DateTime.now()).toMap(),
      );
    }
    final set = await _skipSet(groupId);
    if (set.remove(RepeatRule.stoppedMarker)) {
      await _writeSkipSet(groupId, set);
    }
  }

  @override
  Future<void> mergeRepeatRules(Map<String, RepeatRule> rules) async {
    if (rules.isEmpty) return;
    final rulesBox = await _rulesDatabase;
    for (final entry in rules.entries) {
      final gid = entry.key;
      if (gid.isEmpty) continue;
      final incoming = entry.value;
      final existing = await _readRule(gid);

      // 永久删除是终态：云端墓碑优先，本地再新的编辑也不能把它复活。
      if (incoming.deleted) {
        await _deleteTasksOfGroup(gid);
        final tombstone = incoming.copyWith(
          stopped: true,
          deleted: true,
          skippedDates: <String>{
            ...incoming.skippedDates,
            ...?existing?.skippedDates,
          }.toList()
            ..sort(),
        );
        await rulesBox.put(gid, tombstone.toMap());
        final set = await _skipSet(gid)..add(RepeatRule.stoppedMarker);
        await _writeSkipSet(gid, set);
        continue;
      }
      if (existing?.deleted == true) continue;

      // 本地更新（刚改过还没上传）：保留本地，等下一轮同步；时间相同也以本地为准，
      // 避免每次同步都把整批规则重写一遍。
      if (existing != null && !incoming.updatedAt.isAfter(existing.updatedAt)) {
        continue;
      }
      // 跳过记录取并集：本地"仅删除本期"的记录可能还没来得及通过删除通道上传
      final merged = incoming.copyWith(
        skippedDates: <String>{
          ...incoming.skippedDates,
          ...?existing?.skippedDates,
        }.toList()
          ..sort(),
      );
      await rulesBox.put(gid, merged.toMap());
      // 云端的停止状态要落到本地哨兵上（老版本/规则丢失时引擎只认哨兵）
      final set = await _skipSet(gid);
      if (merged.isStopped) {
        set.add(RepeatRule.stoppedMarker);
        await _writeSkipSet(gid, set);
      } else if (set.remove(RepeatRule.stoppedMarker)) {
        await _writeSkipSet(gid, set);
      }
    }
  }

  /// 收到永久删除墓碑时，清掉本机同族全部任务（含已完成）。
  ///
  /// 这里不写 `sync_deletions`：服务端已经软删过一遍，再上报一轮没有意义。
  Future<void> _deleteTasksOfGroup(String groupId) async {
    final box = await _database;
    final keys = <dynamic>[];
    for (final key in box.keys) {
      final raw = box.get(key);
      if (raw is Map && raw['repeat_group_id'] == groupId) {
        keys.add(key);
      }
    }
    if (keys.isNotEmpty) await box.deleteAll(keys);
  }

  @override
  Future<void> mergeRepeatSkips(Map<String, Set<String>> skips) async {
    if (skips.isEmpty) return;
    final box = await _skipsDatabase;
    for (final entry in skips.entries) {
      final groupId = entry.key;
      if (groupId.isEmpty) continue;
      final merged = <String>{
        ...((box.get(groupId) as List?)?.map((e) => e.toString()) ?? const []),
        ...entry.value,
      };
      // 只保留最近 N 天，避免账本无限增长（与规则内副本共用同一个常量）
      final cutoff = DateTime.now()
          .subtract(const Duration(days: RepeatRule.skipRetentionDays));
      merged.removeWhere((s) {
        final d = DateTime.tryParse(s);
        return d != null && d.isBefore(cutoff);
      });
      await box.put(groupId, merged.toList()..sort());
    }
  }
}
