import 'package:hive_flutter/hive_flutter.dart';
import '../models/memo.dart';
import 'hive_bootstrap.dart';
import 'memo_repository.dart';

/// Hive 本地数据库实现（与任务存储分离的独立 box `memos`）
/// 独立 box 保证：旧版本客户端升级后，原 tasks box 数据完全不受影响
class MemoRepositoryImpl implements MemoRepository {
  static const String _boxName = 'memos';
  Box? _box;
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
  Future<int> insertMemo(Memo memo) async {
    final box = await _database;
    final id = _nextId++;
    final newMemo = memo.copyWith(id: id);
    await box.put('$id', newMemo.toMap());
    return id;
  }

  @override
  Future<List<Memo>> getMemos() async {
    final box = await _database;
    // 逐条解析：单条损坏跳过，不影响整体
    final memos = <Memo>[];
    for (final value in box.values) {
      try {
        memos.add(Memo.fromMap(Map<String, dynamic>.from(value as Map)));
      } catch (_) {
        // 跳过损坏记录
      }
    }
    // 按创建时间倒序（新的在前）
    memos.sort((a, b) => b.createdAt.compareTo(a.createdAt));
    return memos;
  }

  @override
  Future<int> updateMemo(Memo memo) async {
    final box = await _database;
    // id 为空时写入会产生 'null' 幽灵键
    if (memo.id == null) return 0;
    final key = '${memo.id}';
    if (!box.containsKey(key)) return 0;
    await box.put(key, memo.toMap());
    return 1;
  }

  @override
  Future<int> deleteMemo(int id) async {
    final box = await _database;
    await box.delete('$id');
    return 1;
  }

  @override
  Future<void> replaceAll(List<Memo> memos, {DateTime? keepAfter}) async {
    final box = await _database;
    // 增量写入：不做 clear() + 全量重写，避免同步期间新建的备忘被抹掉、
    // 以及写一半崩溃导致整个 box 只剩半份数据。
    var nextId = 1;
    for (final key in box.keys) {
      final id = int.tryParse(key.toString());
      if (id != null && id >= nextId) nextId = id + 1;
    }

    final keep = <String>{};
    final pending = <Memo>[];
    for (final memo in memos) {
      final id = memo.id;
      if (id == null) {
        pending.add(memo);
        continue;
      }
      var key = '$id';
      if (keep.contains(key)) {
        // 不同设备各自的本地 id 撞车：换新 id，保留 remoteId
        key = '${nextId++}';
      }
      keep.add(key);
      final assigned = int.parse(key);
      await box.put(key, memo.copyWith(id: assigned).toMap());
      if (assigned >= nextId) nextId = assigned + 1;
    }

    for (final memo in pending) {
      final id = nextId++;
      final key = '$id';
      keep.add(key);
      await box.put(key, memo.copyWith(id: id).toMap());
    }

    final stale = <String>[];
    for (final key in box.keys) {
      final k = key.toString();
      if (keep.contains(k)) continue;
      if (keepAfter != null) {
        final raw = box.get(key);
        if (raw is Map) {
          final at = DateTime.tryParse('${raw['updated_at'] ?? ''}');
          if (at == null || at.isAfter(keepAfter)) continue;
        }
      }
      stale.add(k);
    }
    if (stale.isNotEmpty) await box.deleteAll(stale);

    _nextId = nextId;
  }
}
