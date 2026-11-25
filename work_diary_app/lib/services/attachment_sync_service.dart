import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:hive/hive.dart';
import 'package:path/path.dart' as p;

import '../database/hive_bootstrap.dart';
import '../models/attachment.dart';
import 'app_logger.dart';
import 'attachment_api.dart';
import 'attachment_store.dart';
import 'auth_service.dart';
import 'device_identity.dart';

/// 一条附件在本机的中转进度。
enum AttachmentPhase {
  /// 已登记请求，等持有原件的主机上线上传（服务器保留 24 小时，上线自动继续）
  waitingSource,

  /// 本机是源主机，正在把文件传上服务器
  uploading,

  /// 本机正在从服务器下载
  downloading,

  /// 失败，[AttachmentJob.message] 是可直接展示的原因
  failed,
}

@immutable
class AttachmentJob {
  const AttachmentJob({
    required this.phase,
    required this.startedAt,
    this.progress,
    this.message = '',
  });

  final AttachmentPhase phase;
  final DateTime startedAt;

  /// 0~1；体积未知时为 null（UI 显示不确定进度）
  final double? progress;
  final String message;

  bool get active =>
      phase == AttachmentPhase.uploading || phase == AttachmentPhase.downloading;
}

class AttachmentSyncSummary {
  const AttachmentSyncSummary({
    this.incoming = 0,
    this.deleted = 0,
    this.rejectedNames = const <String>[],
  });

  /// 云端新增到本机的附件数
  final int incoming;
  final int deleted;

  /// 服务器拒绝入库的文件名（类型/体积/数量超限），必须提示用户，
  /// 不能让人以为已经保存好了
  final List<String> rejectedNames;

  bool get hasRejections => rejectedNames.isNotEmpty;
}

/// 附件同步：元数据全量 LWW + 文件按需中转。
///
/// 服务器只做一次性中转，所以谁点"同步"谁负责把流程推到底：
/// 目标端 `/request` → 服务器推给源主机 → 源主机分片上传 → 服务器校验后
/// 推 `attachment_ready` → 目标端下载校验 → `/ack` → 服务器删文件。
/// 本类是 UI 的唯一入口，进度通过 [ChangeNotifier] 通知。
class AttachmentSyncService extends ChangeNotifier {
  AttachmentSyncService({AttachmentStore? store})
      : store = store ?? AttachmentStore.instance;

  static final AttachmentSyncService instance = AttachmentSyncService();

  /// 本地待上报的删除墓碑：key = uid，value = 删除时间
  static const String _deletionBoxName = 'attachment_deletions';

  static const int _defaultChunkBytes = 2 * 1024 * 1024;

  final AttachmentStore store;

  final Map<String, AttachmentJob> _jobs = <String, AttachmentJob>{};
  final Set<String> _busy = <String>{};

  AttachmentJob? jobOf(String uid) => _jobs[uid];

  bool get hasActiveJobs => _jobs.values.any((j) => j.active);

  /// 数据落地后要刷新附件列表（新下载完、被远端删除…）
  void Function()? onAttachmentsChanged;

  // ================= 元数据同步 =================

  /// 与云端对账：上报本机全部附件（父记录已同步的），合并云端结果。
  ///
  /// [taskLocalToRemote] / [memoLocalToRemote] 是本轮任务/备忘同步后的
  /// 本地 id → 云端 id 映射，用来回填附件的父记录指向，以及把云端附件挂到
  /// 本机对应的卡片上。
  Future<AttachmentSyncSummary> syncMetadata({
    required Map<int, int> taskLocalToRemote,
    required Map<int, int> memoLocalToRemote,
  }) async {
    if (!AuthService.isLoggedIn) return const AttachmentSyncSummary();
    await store.repository
        .backfillRemoteIds(Attachment.kindTask, taskLocalToRemote);
    await store.repository
        .backfillRemoteIds(Attachment.kindMemo, memoLocalToRemote);

    final all = await store.repository.getAll();
    final byUid = <String, Attachment>{for (final a in all) a.uid: a};
    // 父记录还没拿到云端 id 的先不上报：服务器会按"父记录不存在"拒收。
    // 已孤儿的（本机删过任务/备忘）也不上报：云端父记录多半已软删除，
    // 报上去只会被拒，然后给用户弹一条"文件类型不支持"的假错误。
    final uploadable = all
        .where((a) => !a.orphaned && a.parentRemoteId != null)
        .toList();
    final tombstones = await pendingDeletions();

    final payload = await AttachmentApi.sync(
      attachments: uploadable,
      deletions: [
        for (final entry in tombstones.entries)
          (uid: entry.key, deletedAt: entry.value)
      ],
    );

    final taskLocalByRemote = _invert(taskLocalToRemote);
    final memoLocalByRemote = _invert(memoLocalToRemote);
    var incoming = 0;
    final staleLinked = <String>[];
    final outOfDate = <Attachment>[];
    for (final remote in payload.attachments) {
      final parentLocalId = (remote.parentKind == Attachment.kindMemo
              ? memoLocalByRemote
              : taskLocalByRemote)[remote.parentRemoteId];
      final local = await store.repository.byUid(remote.uid);
      if (local == null) {
        // 父记录不在本机（还没同步下来）就跳过，下一轮再挂
        if (parentLocalId == null) continue;
        await store.repository
            .save(remote.copyWith(parentLocalId: parentLocalId));
        incoming++;
        continue;
      }
      if (remote.updatedAt.isAfter(local.updatedAt)) {
        // 云端这条更新，元数据以它为准；但 contentMode/sourcePath 是本机私有的，
        // 接口里根本没这两个字段，照单全收会把"引用原文件"打回副本、
        // 把用户自己选的原件路径抹掉。
        final changed = remote.sha256.isNotEmpty &&
            local.sha256.isNotEmpty &&
            remote.sha256.toLowerCase() != local.sha256.toLowerCase();
        await store.repository.save(remote.copyWith(
          parentLocalId: parentLocalId ?? local.parentLocalId,
          contentMode: local.contentMode,
          sourcePath: local.sourcePath,
          sourceMtimeMs: local.sourceMtimeMs,
          sourceSize: local.sourceSize,
          staleCopy: changed,
        ));
        if (changed) {
          if (local.isLinked) {
            staleLinked.add(local.uid);
          } else {
            outOfDate.add(remote.copyWith(parentLocalId: local.parentLocalId));
          }
        }
        if (parentLocalId == null && local.parentLocalId != null) incoming++;
      } else if (local.blobState != remote.blobState) {
        // blob_state 只在本机用于"服务器上有/没有中转副本"，不参与 LWW
        await store.repository.save(local.copyWith(blobState: remote.blobState));
      }
    }

    for (final uid in payload.deletedUids) {
      final local = await store.repository.byUid(uid);
      if (local == null) continue;
      // 对端明确删除了这个附件：本机记录与原件一起清，
      // （删任务不走这里，那条路径保留原件）
      await store.remove(local, deleteOriginal: true);
      _jobs.remove(uid);
    }
    await clearDeletions(tombstones.keys);

    final rejectedNames = <String>[
      for (final uid in payload.rejectedUids)
        byUid[uid]?.fileName ?? '未知文件',
    ];
    // 副本过期：本机这份是旧版，自动重新取一次。引用原件的那种不动用户的文件，
    // 只在卡片上标"云端有更新"，由用户决定是推本机这份还是取云端那份。
    if (outOfDate.isNotEmpty) {
      unawaited(() async {
        for (final attachment in outOfDate) {
          await pull(attachment);
        }
      }());
    }
    if (incoming > 0 || payload.deletedUids.isNotEmpty ||
        staleLinked.isNotEmpty || outOfDate.isNotEmpty) {
      onAttachmentsChanged?.call();
    }
    return AttachmentSyncSummary(
      incoming: incoming,
      deleted: payload.deletedUids.length,
      rejectedNames: rejectedNames,
    );
  }

  static Map<int, int> _invert(Map<int, int> map) {
    final out = <int, int>{};
    map.forEach((local, remote) => out[remote] = local);
    return out;
  }

  // ================= 删除墓碑 =================

  Future<Box> _deletionBox() async {
    await HiveBootstrap.ensureInitialized();
    return Hive.openBox(_deletionBoxName);
  }

  Future<Map<String, DateTime>> pendingDeletions() async {
    final box = await _deletionBox();
    final out = <String, DateTime>{};
    for (final key in box.keys) {
      final value = box.get(key);
      if (value is Map && value['deleted_at'] is String) {
        out['$key'] = DateTime.tryParse('${value['deleted_at']}') ?? DateTime.now();
      }
    }
    return out;
  }

  Future<void> recordDeletion(String uid) async {
    if (uid.isEmpty) return;
    final box = await _deletionBox();
    await box.put(uid, {
      'uid': uid,
      'deleted_at': DateTime.now().toUtc().toIso8601String(),
    });
  }

  Future<void> clearDeletions(Iterable<String> uids) async {
    final box = await _deletionBox();
    for (final uid in uids) {
      await box.delete(uid);
    }
  }

  /// 用户从卡片上删掉一个附件：本机记录与原件删掉，云端等下次同步打墓碑。
  Future<void> deleteAttachment(Attachment attachment) async {
    await store.remove(attachment, deleteOriginal: true);
    await recordDeletion(attachment.uid);
    clearJob(attachment.uid);
    onAttachmentsChanged?.call();
  }

  /// 父任务/备忘被删除：附件按"孤儿"处理（原件留着，截图原件删掉），
  /// 本机的中转进度一并收掉。云端那边靠任务墓碑，不需要额外上报。
  Future<void> onParentDeleted(String parentKind, int parentLocalId) async {
    final attached =
        await store.repository.forParent(parentKind, parentLocalId);
    for (final attachment in attached) {
      clearJob(attachment.uid);
    }
    await store.onParentDeleted(parentKind, parentLocalId);
    if (attached.isNotEmpty) onAttachmentsChanged?.call();
  }

  // ================= 按需中转 =================

  /// 目标端一键同步。本机副本是旧版（[Attachment.staleCopy]）时也会重取。
  Future<void> pull(Attachment attachment) async {
    if (!AuthService.isLoggedIn) {
      _fail(attachment.uid, '登录后才能从其它主机同步文件');
      return;
    }
    if (!attachment.staleCopy && await store.hasLocalCopy(attachment)) {
      clearJob(attachment.uid);
      return;
    }
    await _guard(attachment.uid, () async {
      _setJob(
        attachment.uid,
        AttachmentJob(
          phase: AttachmentPhase.waitingSource,
          startedAt: DateTime.now(),
          message: '正在通知其它主机…',
        ),
      );
      final result = await AttachmentApi.request(
        attachment.uid,
        DeviceIdentity.id,
        DeviceIdentity.name,
      );
      switch (result.state) {
        case 'ready':
          await _download(attachment);
          break;
        case 'done':
          clearJob(attachment.uid);
          break;
        case 'waiting':
          _setJob(attachment.uid, _waiting(attachment.uid, result.message));
          break;
        case 'requested':
          _setJob(
            attachment.uid,
            _waiting(
              attachment.uid,
              result.sources > 1
                  ? '已通知 ${result.sources} 台主机，等待对方上传'
                  : '已通知持有该文件的主机，等待上传',
            ),
          );
          break;
        default:
          _fail(attachment.uid, result.message.isEmpty ? '服务器未接受同步请求' : result.message);
      }
    });
  }

  /// 处理服务器推送：attachment_request / attachment_ready / attachment_taken。
  Future<void> handlePush(Map<String, dynamic> msg) async {
    final type = '${msg['type'] ?? ''}';
    final uid = '${msg['uid'] ?? ''}';
    if (uid.isEmpty || !AuthService.isLoggedIn) return;
    final attachment = await store.repository.byUid(uid);
    if (attachment == null) return; // 本机没有这条记录，推给它也没意义

    switch (type) {
      case 'attachment_request':
        // 服务器把请求广播给该用户的其它设备：谁本机有原件谁应答
        if (!await store.hasLocalCopy(attachment)) return;
        if (_jobs[uid]?.phase == AttachmentPhase.uploading) return;
        await _guard(uid, () => _upload(attachment));
        break;
      case 'attachment_ready':
        if (!attachment.staleCopy && await store.hasLocalCopy(attachment)) {
          clearJob(uid);
          return;
        }
        // 上传完成是全站广播，别的主机自己传给自己用不着下：
        // 只有服务器确认"这台设备登记过拉取请求"才下载
        try {
          final st = await AttachmentApi.state(uid);
          if (!st.thisDeviceRequested(DeviceIdentity.id)) {
            clearJob(uid);
            return;
          }
        } on AttachmentApiException catch (e) {
          if (!e.retryable) {
            clearJob(uid);
            return;
          }
          rethrow;
        }
        await _guard(uid, () => _download(attachment));
        break;
      case 'attachment_taken':
        // 文件已被取走并从服务器删除：本机这边的等待/上传都可以收了
        final job = _jobs[uid];
        if (job != null && job.phase != AttachmentPhase.failed) clearJob(uid);
        break;
    }
  }

  Future<void> _guard(String uid, Future<void> Function() body) async {
    if (!_busy.add(uid)) return; // 同一份文件同时只跑一个中转
    try {
      await body();
    } on AttachmentApiException catch (e) {
      _fail(uid, e.message);
    } catch (e, st) {
      AppLogger.instance.error('附件中转失败[$uid]', e, st);
      _fail(uid, '同步失败，请稍后重试');
    } finally {
      _busy.remove(uid);
    }
  }

  /// 只把这一条附件的元数据推上云端：原件刚被用户改过、又正好有别的设备在等文件时，
  /// 得先让服务器知道新版哈希，这趟中转才校验得过。父记录还没同步上云的没法推。
  Future<void> _pushMetadata(Attachment attachment) async {
    if (attachment.parentRemoteId == null) return;
    try {
      await AttachmentApi.sync(
        attachments: <Attachment>[attachment],
        deletions: const <({String uid, DateTime deletedAt})>[],
      );
    } on AttachmentApiException {
      // 推不上去就算了：下面的 sha256 对账会拦住这趟上传，不会传完才发现对不上
    }
  }

  /// 源主机：把本机原件分片传到服务器（支持断点续传，偏移以服务器为准）。
  Future<void> _upload(Attachment attachment) async {
    final uid = attachment.uid;
    // 引用模式的原件用户说改就改：先对一次账，内容变了就把新哈希抢在中传之前报上云端，
    // 否则分片全传完，服务器只会拿旧 sha256 判成校验失败。
    var record = attachment;
    if (record.isLinked && await store.refreshLink(record)) {
      record = await store.repository.byUid(uid) ?? record;
      await _pushMetadata(record);
    }
    final path = await store.pathOf(record);
    final file = File(path);
    if (!await file.exists()) {
      // 原件不在了就别再占着请求：服务器等 TTL 到期自己清
      clearJob(uid);
      return;
    }
    final size = await file.length();
    if (record.fileSize > 0 && size != record.fileSize) {
      _fail(uid, '本机文件已被修改（大小与记录不符），请重新添加该附件');
      return;
    }
    final init = await AttachmentApi.uploadInit(
        uid, DeviceIdentity.id, DeviceIdentity.name);
    if (init.state == 'ready') {
      // 另一台持有者已经传完了，本机不用再出一份
      clearJob(uid);
      return;
    }
    if (init.sha256.isNotEmpty &&
        init.sha256.toLowerCase() != record.sha256.toLowerCase()) {
      // 服务器认的是别台机器推上去的那一版，本机这份不是它要的内容：
      // 让持有新版的主机应答，本机硬传上去也只会被人当成坏文件
      clearJob(uid);
      return;
    }
    final chunkSize = init.chunkSize > 0 ? init.chunkSize : _defaultChunkBytes;
    var offset = init.nextOffset.clamp(0, size);
    var lastPercent = -1;

    final raf = await file.open();
    try {
      await raf.setPosition(offset);
      while (offset < size) {
        final bytes = await raf.read(math.min(chunkSize, size - offset));
        if (bytes.isEmpty) break;
        final ack = await AttachmentApi.uploadChunk(uid, offset, bytes);
        if (ack.nextOffset <= offset) {
          _fail(uid, '上传没有进展，请检查网络后重试');
          return;
        }
        offset = ack.nextOffset;
        await raf.setPosition(math.min(offset, size));
        final percent = (offset * 100 / math.max(1, size)).floor();
        // 只在整数百分比变化时刷新，避免大文件把 UI 拖垮
        if (percent != lastPercent) {
          lastPercent = percent;
          _setJob(
            uid,
            AttachmentJob(
              phase: AttachmentPhase.uploading,
              startedAt: DateTime.now(),
              progress: offset / math.max(1, size),
              message: '正在上传到服务器 $percent%',
            ),
          );
        }
      }
    } finally {
      await raf.close();
    }
    await AttachmentApi.uploadComplete(uid, DeviceIdentity.id, DeviceIdentity.name);
    clearJob(uid);
  }

  /// 目标端：下载、校验、落进本机，然后确认让服务器删文件。
  Future<void> _download(Attachment attachment) async {
    final uid = attachment.uid;
    _setJob(uid, AttachmentJob(
      phase: AttachmentPhase.downloading,
      startedAt: DateTime.now(),
      message: '正在下载到本机…',
    ));
    final tmp = p.join(await store.rootDir(), '.incoming', '$uid.part');
    try {
      await AttachmentApi.download(uid, DeviceIdentity.id, tmp);
      final saved = await store.saveIncoming(
        attachment: attachment,
        sourcePath: tmp,
        parentLocalId: attachment.parentLocalId,
      );
      if (!saved.ok) {
        _fail(uid, saved.error!);
        return;
      }
      await AttachmentApi.ack(uid, DeviceIdentity.id, DeviceIdentity.name);
      clearJob(uid);
      onAttachmentsChanged?.call();
    } finally {
      try {
        final leftover = File(tmp);
        if (await leftover.exists()) await leftover.delete();
      } catch (_) {}
    }
  }

  // ================= 进度状态 =================

  AttachmentJob _waiting(String uid, String message) {
    final previous = _jobs[uid];
    return AttachmentJob(
      phase: AttachmentPhase.waitingSource,
      startedAt: previous?.startedAt ?? DateTime.now(),
      message: message,
    );
  }

  void _setJob(String uid, AttachmentJob job) {
    _jobs[uid] = job;
    notifyListeners();
  }

  void _fail(String uid, String message) {
    _jobs[uid] = AttachmentJob(
      phase: AttachmentPhase.failed,
      startedAt: DateTime.now(),
      message: message,
    );
    notifyListeners();
  }

  void clearJob(String uid) {
    if (_jobs.remove(uid) != null) notifyListeners();
  }

  /// 失败提示被用户关掉后别再挂着
  void dismiss(String uid) => clearJob(uid);

  @visibleForTesting
  void resetForTest() {
    _jobs.clear();
    _busy.clear();
  }

  /// 仅测试用：直接钉一条进度，让附件条的各档状态能被单独验证。
  @visibleForTesting
  void setJobForTest(String uid, AttachmentJob job) => _setJob(uid, job);
}
