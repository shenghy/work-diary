import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:hive/hive.dart';
import 'package:path/path.dart' as p;
import 'package:url_launcher/url_launcher.dart';
import 'package:uuid/uuid.dart';

import '../database/attachment_repository.dart';
import '../database/hive_bootstrap.dart';
import '../models/attachment.dart';
import '../utils/attachment_types.dart';
import 'device_identity.dart';

/// 一次附件操作的结论：成功带记录，失败带一句能直接展示给用户的话。
class AttachmentOutcome {
  const AttachmentOutcome.ok(this.attachment) : error = null;
  const AttachmentOutcome.fail(this.error) : attachment = null;

  final Attachment? attachment;
  final String? error;

  bool get ok => attachment != null;
}

/// 本机能不能读到这个附件的内容，读不到是因为什么。
enum AttachmentSource {
  /// link 模式，原件就在记录的路径上
  linked,

  /// copy 模式，原件在附件库里
  copy,

  /// link 模式，但原件被移动/改名/删除了：需要重新定位
  missingOriginal,

  /// 原件在别的设备上，本机连副本都没有
  otherDevice,
}

/// 附件原件的本机仓库，两种存法：
///
/// - **link（默认）**：只记用户磁盘上那个原件的路径，不复制。卡片打开/定位/
///   复制路径都指原件，用户改了原件内容，下一轮刷新会重算哈希并同步给其它设备。
/// - **copy**：把文件收进 `<数据目录>/attachments/<uid>/<文件名>`。
///   截图附件（原件在临时目录，会被系统清掉）、小程序传来的、从别的设备拉下来的，
///   都必须走这条；老附件也保持这条，不做迁移。
///
/// uid 目录让同名文件天然不冲突，也方便同步按 uid 落盘与整份删除。
/// 任何情况下都只删自己附件库里的东西，绝不删用户磁盘上的原件。
class AttachmentStore {
  AttachmentStore({AttachmentRepository? repository})
      : repository = repository ?? AttachmentRepository();

  static const String dirName = 'attachments';
  static const Uuid _uuid = Uuid();

  /// 全局共用一份：仓库内部缓存着 Hive box，多处各建各的只会重复开盒。
  /// 测试用 `AttachmentStore(repository: ...)` 自己造实例。
  static final AttachmentStore instance = AttachmentStore();

  final AttachmentRepository repository;

  /// 桌面端挂附件的默认方式：引用用户磁盘上的原件，还是复制进附件库。
  /// 设置菜单里那个开关就是它；截图、小程序、中转副本不受影响，一律进附件库。
  static bool get linkByDefault {
    try {
      return Hive.box('settings')
              .get('attachment_link_default', defaultValue: true) ==
          true;
    } catch (_) {
      return true; // settings 盒还没开（测试里常见），按默认走
    }
  }

  static Future<void> setLinkByDefault(bool value) async {
    try {
      await Hive.box('settings').put('attachment_link_default', value);
    } catch (_) {}
  }

  Future<String> rootDir() async =>
      p.join(await HiveBootstrap.dataDir(), dirName);

  /// uid 只允许 UUID 用到的字符：对端上报的 uid 同样不可信，
  /// 否则 `../../` 形式的 uid 能把原件写到数据目录之外。
  static String sanitizeUid(String raw) {
    final cleaned = raw.replaceAll(RegExp(r'[^0-9A-Za-z_-]'), '');
    return cleaned.length <= 64 ? cleaned : cleaned.substring(0, 64);
  }

  Future<String> dirOf(String uid) async =>
      p.join(await rootDir(), sanitizeUid(uid));

  /// 现在该拿哪个路径去打开这个附件。原件在不在要用 [hasLocalCopy] / [locate] 判。
  ///
  /// link 模式给记录的原件路径——那是本机自己写进去的绝对路径，不是对端上报的，
  /// 所以不需要清洗。copy 模式的文件名再清洗一遍：其它设备上报的 `file_name`
  /// 是不可信输入，带 `../` 就能把"打开附件"变成"打开任意路径"。
  Future<String> pathOf(Attachment attachment) async {
    if (attachment.isLinked && attachment.sourcePath.isNotEmpty) {
      return attachment.sourcePath;
    }
    return p.join(await dirOf(attachment.uid),
        sanitizeAttachmentFileName(attachment.fileName));
  }

  Future<bool> hasLocalCopy(Attachment attachment) async {
    if (attachment.isLinked) {
      if (attachment.sourcePath.isEmpty) return false;
      try {
        return await File(attachment.sourcePath).exists();
      } catch (_) {
        return false;
      }
    }
    if (!_hasSafeUid(attachment.uid) || attachment.fileName.isEmpty) return false;
    try {
      return await File(await pathOf(attachment)).exists();
    } catch (_) {
      return false;
    }
  }

  /// 卡片要分清"本机打不开"的三种原因，提示语和可做的动作完全不同。
  Future<AttachmentSource> locate(Attachment attachment) async {
    if (attachment.isLinked) {
      if (attachment.sourcePath.isEmpty) return AttachmentSource.otherDevice;
      return await _exists(attachment.sourcePath)
          ? AttachmentSource.linked
          : AttachmentSource.missingOriginal;
    }
    return await hasLocalCopy(attachment)
        ? AttachmentSource.copy
        : AttachmentSource.otherDevice;
  }

  Future<bool> _exists(String path) async {
    try {
      return await File(path).exists();
    } catch (_) {
      return false;
    }
  }

  /// uid 非法（清洗后和原值不一致）就当"本机没有原件"，而不是去读清洗后的路径：
  /// 清洗后可能恰好指向另一个附件的目录，那样会拿错文件。
  bool _hasSafeUid(String uid) => uid.isNotEmpty && sanitizeUid(uid) == uid;

  /// 某父记录当前占用的附件数（用于 5 个上限提示）。
  Future<int> countForParent(String parentKind, int parentLocalId) async =>
      (await repository.forParent(parentKind, parentLocalId)).length;

  /// 把磁盘上的一个文件挂到某任务/备忘上。
  ///
  /// [link] 为真（桌面端默认）时**不复制**，只记原件路径：用户改原件、
  /// 复制路径、在资源管理器里显示，全都直接作用在他自己的文件上。
  /// 为假时复制进附件库——截图附件必须走这条（临时目录会被系统清掉），
  /// 老附件也一律保持这条，不做迁移。
  /// 每个文件单独报失败原因（类型不符 / 超体积 / 已经挂过 / 数量到顶）。
  Future<AttachmentOutcome> importFile(
    String sourcePath, {
    required String parentKind,
    required int parentLocalId,
    int? parentRemoteId,
    bool isScreenshot = false,
    bool link = false,
  }) async {
    final file = File(sourcePath);
    if (!await file.exists()) {
      return const AttachmentOutcome.fail('文件不存在或已被移动');
    }
    final name = p.basename(sourcePath);
    final size = await file.length();
    final check = checkAttachmentFile(name, sizeBytes: size);
    if (!check.allowed) {
      return AttachmentOutcome.fail(check.reason);
    }
    if (await countForParent(parentKind, parentLocalId) >= kAttachmentMaxPerParent) {
      return AttachmentOutcome.fail(
        '一个${parentKind == Attachment.kindMemo ? '备忘' : '任务'}最多挂 '
        '$kAttachmentMaxPerParent 个附件，请先删除不需要的',
      );
    }

    final digest = await sha256OfFile(sourcePath);
    // 先按内容查重：重复拖同一个文件比再存一份更可能是误操作
    final existing = await repository.forParent(parentKind, parentLocalId);
    if (existing.any((a) => a.sha256 == digest)) {
      return AttachmentOutcome.fail('这个文件已经挂在当前${parentKind == Attachment.kindMemo ? '备忘' : '任务'}上了');
    }

    final uid = _uuid.v4();
    // 截图生成的图在系统临时目录，引用它等于给附件埋一颗定时炸弹
    final useRef = link && !isScreenshot;
    if (!useRef) {
      final error = await _storeCopy(
        sourcePath: sourcePath,
        uid: uid,
        fileName: sanitizeAttachmentFileName(name),
        expectedSize: size,
      );
      if (error != null) return AttachmentOutcome.fail(error);
    }
    final stat = await file.stat();

    final now = DateTime.now();
    final attachment = Attachment(
      uid: uid,
      parentKind: parentKind,
      parentLocalId: parentLocalId,
      parentRemoteId: parentRemoteId,
      ownerDeviceId: DeviceIdentity.id,
      ownerDeviceName: DeviceIdentity.name,
      fileName: name,
      fileSize: size,
      sha256: digest,
      mime: check.mime,
      isScreenshot: isScreenshot,
      contentMode: useRef ? Attachment.modeLink : Attachment.modeCopy,
      sourcePath: useRef ? p.absolute(sourcePath) : '',
      sourceMtimeMs: useRef ? stat.modified.millisecondsSinceEpoch : 0,
      sourceSize: useRef ? size : 0,
      createdAt: now,
    );
    await repository.save(attachment);
    return AttachmentOutcome.ok(attachment);
  }

  /// 把一份文件原子地收进 uid 目录，返回 null 表示成功、否则是一句失败原因。
  Future<String?> _storeCopy({
    required String sourcePath,
    required String uid,
    required String fileName,
    required int expectedSize,
  }) async {
    final target = File(p.join(await dirOf(uid), fileName));
    try {
      await target.parent.create(recursive: true);
      // 先落 .part 再改名：中途失败不会留下"看起来完整"的半个原件
      final part = File('${target.path}.part');
      await File(sourcePath).copy(part.path);
      if (await part.length() != expectedSize) {
        await part.delete();
        return '文件复制不完整，请重试';
      }
      await part.rename(target.path);
      return null;
    } catch (e) {
      try {
        if (await target.parent.exists()) await target.parent.delete(recursive: true);
      } catch (_) {}
      return '保存到本机失败：$e';
    }
  }

  /// 原件改过没有：只 stat，mtime 或大小变了才重算哈希并写回记录。
  ///
  /// 返回 true = 内容确实变了，调用方要触发一次同步把新哈希推上云端，
  /// 其它设备才会发现副本过期并重新取。原件不见了不算"变化"，
  /// 那是卡片上的失联状态，哈希得留着等用户重新定位。
  Future<bool> refreshLink(Attachment attachment) async {
    if (!attachment.isLinked || attachment.sourcePath.isEmpty) return false;
    final file = File(attachment.sourcePath);
    final FileStat stat;
    try {
      if (!await file.exists()) return false;
      stat = await file.stat();
    } catch (_) {
      // 网盘占位、U 盘没插、权限问题：stat 不动它，下一轮再看
      return false;
    }
    if (stat.modified.millisecondsSinceEpoch == attachment.sourceMtimeMs &&
        stat.size == attachment.sourceSize) {
      return false; // 没改过，连哈希都不算
    }
    final digest = await sha256OfFile(attachment.sourcePath);
    final name = p.basename(attachment.sourcePath);
    if (digest == attachment.sha256 &&
        stat.size == attachment.fileSize &&
        name == attachment.fileName) {
      // 只是被重新保存了一遍（内容、大小、名字都没变）：挪一下基准时间，
      // 免得每轮刷新都对同一个大文件重算一次哈希
      await repository.save(attachment.copyWith(
        sourceMtimeMs: stat.modified.millisecondsSinceEpoch,
        sourceSize: stat.size,
      ));
      return false;
    }
    await repository.save(attachment.copyWith(
      fileName: name,
      mime: checkAttachmentFile(name, sizeBytes: stat.size).mime,
      fileSize: stat.size,
      sha256: digest,
      sourceMtimeMs: stat.modified.millisecondsSinceEpoch,
      sourceSize: stat.size,
      updatedAt: DateTime.now(),
    ));
    return true;
  }

  /// 重新定位 / 改为引用原文件：把这条附件指向用户新指定的那个文件。
  ///
  /// 不新增记录，所以不受"每个任务最多 5 个"限制；但类型和体积照样要过，
  /// 否则云端会拒收，用户以为存好了其实没有。
  Future<AttachmentOutcome> relocate(Attachment attachment, String newPath) async {
    final file = File(newPath);
    if (!await file.exists()) {
      return const AttachmentOutcome.fail('文件不存在或已被移动');
    }
    final name = p.basename(newPath);
    final size = await file.length();
    final check = checkAttachmentFile(name, sizeBytes: size);
    if (!check.allowed) return AttachmentOutcome.fail(check.reason);

    // 引用过去就没有附件库副本什么事了：留着它会有两份内容不一致的"原件"
    final digest = await sha256OfFile(newPath);
    final stat = await file.stat();
    final saved = attachment.copyWith(
      fileName: name,
      mime: check.mime,
      fileSize: size,
      sha256: digest,
      contentMode: Attachment.modeLink,
      sourcePath: p.absolute(newPath),
      sourceMtimeMs: stat.modified.millisecondsSinceEpoch,
      sourceSize: size,
      staleCopy: false,
      isScreenshot: false,
      updatedAt: DateTime.now(),
    );
    await repository.save(saved);
    await _deleteStoredCopy(attachment.uid);
    return AttachmentOutcome.ok(saved);
  }

  /// 另存副本到本机：从"引用原件"切成"收进附件库"，之后原件怎么乱都不影响这条附件。
  Future<AttachmentOutcome> pinCopy(Attachment attachment) async {
    if (!attachment.isLinked) return AttachmentOutcome.ok(attachment);
    final source = attachment.sourcePath;
    if (source.isEmpty || !await File(source).exists()) {
      return const AttachmentOutcome.fail('原件已经不在了，没法另存副本');
    }
    final size = await File(source).length();
    final error = await _storeCopy(
      sourcePath: source,
      uid: attachment.uid,
      fileName: sanitizeAttachmentFileName(attachment.fileName),
      expectedSize: size,
    );
    if (error != null) return AttachmentOutcome.fail(error);
    final saved = attachment.copyWith(
      contentMode: Attachment.modeCopy,
      sourcePath: '',
      sourceMtimeMs: 0,
      sourceSize: 0,
      staleCopy: false,
      updatedAt: DateTime.now(),
    );
    await repository.save(saved);
    return AttachmentOutcome.ok(saved);
  }

  /// 只删附件库里这个 uid 的目录（自己造的东西），绝不碰用户磁盘上的原件。
  Future<void> _deleteStoredCopy(String uid) async {
    if (!_hasSafeUid(uid)) return;
    try {
      final dir = Directory(await dirOf(uid));
      if (await dir.exists()) await dir.delete(recursive: true);
    } catch (_) {
      // 目录删不掉只留个空壳，不影响功能
    }
  }

  /// 流式 SHA-256：100MB 的文件也不能整份读进内存。
  Future<String> sha256OfFile(String path) async {
    final collector = _DigestCollector();
    final input = sha256.startChunkedConversion(collector);
    await for (final chunk in File(path).openRead()) {
      input.add(chunk);
    }
    input.close();
    return '${collector.value ?? ''}';
  }

  /// 把已下载好的临时文件收进本机，并按元数据校验内容。
  ///
  /// 中转下载的落地路径：校验不过直接拒绝，绝不留下一个"名字对、内容不对"的原件。
  Future<AttachmentOutcome> saveIncoming({
    required Attachment attachment,
    required String sourcePath,
    int? parentLocalId,
  }) async {
    if (!_hasSafeUid(attachment.uid)) {
      return const AttachmentOutcome.fail('附件标识不合法，无法保存到本机');
    }
    final file = File(sourcePath);
    if (!await file.exists()) {
      return const AttachmentOutcome.fail('下载文件不存在');
    }
    final size = await file.length();
    if (attachment.fileSize > 0 && size != attachment.fileSize) {
      return AttachmentOutcome.fail('文件大小不符（期望 ${formatAttachmentSize(attachment.fileSize)}，'
          '实际 ${formatAttachmentSize(size)}）');
    }
    final digest = await sha256OfFile(sourcePath);
    if (attachment.sha256.isNotEmpty && digest.toLowerCase() != attachment.sha256.toLowerCase()) {
      return const AttachmentOutcome.fail('文件校验失败，请重新同步');
    }
    final target = File(p.join(
        await dirOf(attachment.uid), sanitizeAttachmentFileName(attachment.fileName)));
    try {
      await target.parent.create(recursive: true);
      if (await target.exists()) await target.delete();
      try {
        await file.rename(target.path);
      } on FileSystemException {
        // 临时目录可能在另一个盘符，rename 跨盘会失败，退回复制
        await file.copy(target.path);
        await file.delete();
      }
    } catch (e) {
      return AttachmentOutcome.fail('保存到本机失败：$e');
    }
    final saved = attachment.copyWith(
      fileName: p.basename(target.path),
      fileSize: size,
      sha256: digest,
      parentLocalId: parentLocalId ?? attachment.parentLocalId,
      // 内容已经落盘并校验过，"副本过期"这个标记就该收掉
      staleCopy: false,
      // 原件失联后从别的设备取回副本：引用已经指不到东西，切成附件库副本才诚实
      contentMode: attachment.isLinked ? Attachment.modeCopy : attachment.contentMode,
      sourcePath: attachment.isLinked ? '' : attachment.sourcePath,
      sourceMtimeMs: attachment.isLinked ? 0 : attachment.sourceMtimeMs,
      sourceSize: attachment.isLinked ? 0 : attachment.sourceSize,
      updatedAt: DateTime.now(),
    );
    await repository.save(saved);
    return AttachmentOutcome.ok(saved);
  }

  /// 一键打开：交回给系统的错误统一成一句人话。
  Future<String?> open(Attachment attachment) async {
    final source = await locate(attachment);
    if (source == AttachmentSource.missingOriginal) {
      return '原件已不在 ${attachment.sourcePath}，右键附件可以重新定位';
    }
    if (source != AttachmentSource.linked && source != AttachmentSource.copy) {
      final owner = attachment.ownerDeviceName.trim();
      return '此文件在${owner.isEmpty ? '其它主机' : owner}上，先同步到本机再打开';
    }
    final path = await pathOf(attachment);
    try {
      final launched = await launchUrl(Uri.file(path), mode: LaunchMode.externalApplication);
      if (!launched) return '没有可用的程序打开 ${attachment.fileName}';
      return null;
    } catch (_) {
      return '打开失败，请检查文件是否被占用';
    }
  }

  /// 在文件资源管理器里选中这个原件（等同右键"在文件资源管理器中显示"）。
  ///
  /// 路径由调用方带上来（卡片加载时已经算过一次），没带就按元数据再算一遍。
  /// 非 Windows 没有"选中某个文件"的原生命令，退一步打开所在目录。
  Future<String?> revealInFolder(Attachment attachment, {String? path}) async {
    final target = (path == null || path.isEmpty) ? await pathOf(attachment) : path;
    if (!await File(target).exists()) return '本机还没有这个文件的原件';
    if (!Platform.isWindows) {
      try {
        final launched = await launchUrl(Uri.directory(p.dirname(target)),
            mode: LaunchMode.externalApplication);
        return launched ? null : '无法打开文件夹';
      } catch (_) {
        return '无法打开文件夹';
      }
    }
    try {
      // explorer 成功时也会返回非 0，只看它抛不抛异常。
      // 参数必须拆成两段：`/select,"路径"` 合成一个参数时 Dart 会把引号转义，
      // explorer 认不出来，只会退回文档目录、什么都不选中。
      await Process.run('explorer', ['/select,', p.normalize(target)]);
      return null;
    } catch (_) {
      return '资源管理器打不开这个位置';
    }
  }

  /// 删除附件。[deleteOriginal] 只在"截图建任务的图"或用户明确删文件时为真，
  /// 普通附件删除任务时保留原件（用户要求：删任务不动附件本体）。
  ///
  /// 这里的"原件"只指附件库里那份副本：link 模式指向的用户文件任何时候都不删，
  /// 用户删的是记录，不是他桌面上的合同。
  Future<void> remove(Attachment attachment, {bool deleteOriginal = false}) async {
    await repository.delete(attachment.uid);
    if (!deleteOriginal) return;
    await _deleteStoredCopy(attachment.uid);
  }

  /// 父记录删除时调用：非截图附件标孤儿保留原件，截图附件连原件一起清。
  Future<void> onParentDeleted(String parentKind, int parentLocalId) async {
    final orphaned = await repository.markOrphaned(parentKind, parentLocalId);
    for (final attachment in orphaned.where((a) => a.isScreenshot)) {
      await remove(attachment, deleteOriginal: true);
    }
  }

  /// 文件名清洗：去掉路径分隔符与 Windows 非法字符，保留扩展名。
  ///
  /// uid 目录已经隔离了同名冲突，这里只保证"这个名字能落盘"。
  static String sanitizeAttachmentFileName(String raw) {
    var name = raw.replaceAll(r'\', '_').replaceAll('/', '_');
    name = name.replaceAll(RegExp(r'[<>:"|?*\x00-\x1F]'), '_').trim();
    // 结尾的点/空格 Windows 会静默吃掉，留下会以为文件不见了
    name = name.replaceAll(RegExp(r'[. ]+$'), '');
    const keep = 100;
    if (name.length > keep) {
      final ext = p.extension(name);
      final base = name.substring(0, name.length - ext.length);
      final cut = base.length > keep - ext.length ? keep - ext.length : base.length;
      name = '${base.substring(0, cut)}$ext';
    }
    return name.isEmpty ? '附件' : name;
  }
}

/// `sha256.startChunkedConversion` 要求一个 `Sink<Digest>`，
/// crypto 包的 `DigestSink` 没有对外导出，这里自己收一个值。
class _DigestCollector implements Sink<Digest> {
  Digest? value;

  @override
  void add(Digest data) => value = data;

  @override
  void close() {}
}
