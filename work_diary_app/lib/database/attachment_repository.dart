import 'package:hive_flutter/hive_flutter.dart';

import '../models/attachment.dart';
import 'hive_bootstrap.dart';

/// 附件元数据的本地存储（独立 box `attachments`，键为 uid）。
///
/// 只存元数据，原件在 `<数据目录>/attachments/<uid>/` 下（见 AttachmentStore）。
/// 逐条解析、坏记录跳过：附件是锦上添花的数据，一条脏记录不能让整个附件列表读不出来。
class AttachmentRepository {
  static const String _boxName = 'attachments';

  Box? _box;

  Future<Box> get _database async {
    if (_box != null) return _box!;
    await HiveBootstrap.ensureInitialized();
    _box = await Hive.openBox(_boxName);
    return _box!;
  }

  Future<List<Attachment>> _all() async {
    final box = await _database;
    final list = <Attachment>[];
    for (final value in box.values) {
      try {
        final att = Attachment.fromMap(Map<String, dynamic>.from(value as Map));
        if (att.uid.isEmpty) continue;
        list.add(att);
      } catch (_) {
        // 跳过损坏记录
      }
    }
    list.sort((a, b) => a.createdAt.compareTo(b.createdAt));
    return list;
  }

  Future<List<Attachment>> getAll() => _all();

  Future<Attachment?> byUid(String uid) async {
    if (uid.isEmpty) return null;
    final box = await _database;
    final value = box.get(uid);
    if (value == null) return null;
    try {
      final att = Attachment.fromMap(Map<String, dynamic>.from(value as Map));
      // 键与 uid 不一致（清洗/写入被中断留下的残记录）一律当没有，
      // 否则会拿一条 uid 为空的记录去拼路径、发请求
      return att.uid.isEmpty ? null : att;
    } catch (_) {
      return null;
    }
  }

  Future<void> save(Attachment attachment) async {
    final box = await _database;
    if (attachment.uid.isEmpty) return;
    await box.put(attachment.uid, attachment.toMap());
  }

  Future<void> saveAll(Iterable<Attachment> attachments) async {
    final box = await _database;
    final entries = <String, Map<String, dynamic>>{};
    for (final attachment in attachments) {
      if (attachment.uid.isEmpty) continue;
      entries[attachment.uid] = attachment.toMap();
    }
    if (entries.isNotEmpty) await box.putAll(entries);
  }

  /// 只删元数据记录；文件由调用方决定留不留（删除任务时原件要留着）。
  Future<void> delete(String uid) async {
    final box = await _database;
    await box.delete(uid);
  }

  /// 某个任务/备忘当前挂着的附件（已孤儿的不再显示）。
  Future<List<Attachment>> forParent(String parentKind, int parentLocalId) async {
    final list = await _all();
    return list
        .where((a) =>
            !a.orphaned && a.parentKind == parentKind && a.parentLocalId == parentLocalId)
        .toList();
  }

  /// 按本地父 id 分组，供整页卡片一次性渲染附件条。
  Future<Map<int, List<Attachment>>> groupedByParent(String parentKind) async {
    final list = await _all();
    final grouped = <int, List<Attachment>>{};
    for (final a in list) {
      if (a.orphaned || a.parentKind != parentKind) continue;
      final id = a.parentLocalId;
      if (id == null) continue;
      grouped.putIfAbsent(id, () => <Attachment>[]).add(a);
    }
    return grouped;
  }

  /// 一轮同步后的批量回填：[localToRemote] 是本机 id → 云端 id。
  ///
  /// 新建任务的云端 id 可能晚于附件好几轮才拿到，逐条按父记录更新
  /// 会把整表扫 N 遍，这里一次扫完。
  Future<void> backfillRemoteIds(String parentKind, Map<int, int> localToRemote) async {
    if (localToRemote.isEmpty) return;
    final list = await _all();
    final changed = <Attachment>[];
    for (final a in list) {
      if (a.parentKind != parentKind || a.parentLocalId == null) continue;
      final remote = localToRemote[a.parentLocalId];
      if (remote != null && a.parentRemoteId != remote) {
        changed.add(a.copyWith(parentRemoteId: remote));
      }
    }
    await saveAll(changed);
  }

  /// 父记录被删：标记孤儿。原件保留（截图附件由调用方直接删文件）。
  Future<List<Attachment>> markOrphaned(String parentKind, int parentLocalId) async {
    final list = await _all();
    final orphaned = <Attachment>[];
    for (final a in list) {
      if (a.orphaned || a.parentKind != parentKind || a.parentLocalId != parentLocalId) continue;
      orphaned.add(a.copyWith(orphaned: true, updatedAt: DateTime.now()));
    }
    await saveAll(orphaned);
    return orphaned;
  }
}
