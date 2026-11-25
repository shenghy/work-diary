/// 附件模型：文件原件存在本机，这条记录是"元数据 + 本机位置"。
///
/// 与服务端的 `attachments` 表字段一一对应；`parentLocalId` 只在本机有用
/// （任务/备忘的 Hive 自增 id），上报云端只用 `parentRemoteId`，因为新建
/// 任务可能还没同步、还没有云端 id。
///
/// [contentMode] 往下几个字段是本机私有的（原件路径、mtime、副本是否过期），
/// 只进 Hive 的 `toMap`，不进 `toApi`：路径换台机器就毫无意义，还会白泄用户目录结构。
class Attachment {
  static const String kindTask = 'task';
  static const String kindMemo = 'memo';

  /// 客户端生成的 UUID，跨设备对齐同一条附件
  final String uid;
  final String parentKind;

  /// 所属任务/备忘的本地 id（未同步时也能定位到卡片）
  final int? parentLocalId;

  /// 所属任务/备忘的云端 id，同步后才能填上
  final int? parentRemoteId;

  /// 原件所在设备（"此文件在 XXX 上"就显示它）
  final String ownerDeviceId;
  final String ownerDeviceName;

  final String fileName;
  final int fileSize;
  final String sha256;
  final String mime;

  /// 截图建任务生成的图片：删任务时直接删原件
  final bool isScreenshot;

  /// 所属任务/备忘已删除，只剩这条记录等着清理
  final bool orphaned;

  /// 服务器中转状态缓存（none / ready / taken），由同步接口回写
  final String blobState;

  /// 内容放在哪：`link` = 直接指向用户磁盘上的原件，`copy` = 已收进本机附件库。
  ///
  /// 只有桌面端"用户自己选/拖进来的文件"会用 link；截图附件、小程序附件、
  /// 从别的设备拉下来的副本都必须落进附件库，否则原件一没就救不回来。
  final String contentMode;

  /// link 模式下原件在本机的绝对路径。不上报云端：这条路径只对创建它的
  /// 那台机器有意义，传过去只会泄漏目录结构，对端也打不开。
  final String sourcePath;

  /// 上次刷新时原件的修改时间与字节数：判断"用户改过没有"只 stat，不重算哈希。
  final int sourceMtimeMs;
  final int sourceSize;

  /// 云端的内容哈希已经变了、本机副本还是旧版：卡片提示并自动重新取。
  /// 同样只在本机有意义（副本落盘校验通过就清掉）。
  final bool staleCopy;

  final DateTime createdAt;
  final DateTime updatedAt;

  const Attachment({
    required this.uid,
    required this.parentKind,
    this.parentLocalId,
    this.parentRemoteId,
    required this.ownerDeviceId,
    required this.ownerDeviceName,
    required this.fileName,
    required this.fileSize,
    required this.sha256,
    required this.mime,
    this.isScreenshot = false,
    this.orphaned = false,
    this.blobState = 'none',
    this.contentMode = modeCopy,
    this.sourcePath = '',
    this.sourceMtimeMs = 0,
    this.sourceSize = 0,
    this.staleCopy = false,
    required this.createdAt,
    DateTime? updatedAt,
  }) : updatedAt = updatedAt ?? createdAt;

  static const String modeLink = 'link';
  static const String modeCopy = 'copy';

  bool get isTask => parentKind == kindTask;

  /// 是否直接引用磁盘上的原件。
  bool get isLinked => contentMode == modeLink;

  Attachment copyWith({
    String? parentKind,
    int? parentLocalId,
    int? parentRemoteId,
    String? ownerDeviceId,
    String? ownerDeviceName,
    String? fileName,
    int? fileSize,
    String? sha256,
    String? mime,
    bool? isScreenshot,
    bool? orphaned,
    String? blobState,
    String? contentMode,
    String? sourcePath,
    int? sourceMtimeMs,
    int? sourceSize,
    bool? staleCopy,
    DateTime? createdAt,
    DateTime? updatedAt,
  }) {
    return Attachment(
      uid: uid,
      parentKind: parentKind ?? this.parentKind,
      parentLocalId: parentLocalId ?? this.parentLocalId,
      parentRemoteId: parentRemoteId ?? this.parentRemoteId,
      ownerDeviceId: ownerDeviceId ?? this.ownerDeviceId,
      ownerDeviceName: ownerDeviceName ?? this.ownerDeviceName,
      fileName: fileName ?? this.fileName,
      fileSize: fileSize ?? this.fileSize,
      sha256: sha256 ?? this.sha256,
      mime: mime ?? this.mime,
      isScreenshot: isScreenshot ?? this.isScreenshot,
      orphaned: orphaned ?? this.orphaned,
      blobState: blobState ?? this.blobState,
      contentMode: contentMode ?? this.contentMode,
      // 切回 copy 时要能把路径清空，所以 null 之外还要能显式传空串
      sourcePath: sourcePath ?? this.sourcePath,
      sourceMtimeMs: sourceMtimeMs ?? this.sourceMtimeMs,
      sourceSize: sourceSize ?? this.sourceSize,
      staleCopy: staleCopy ?? this.staleCopy,
      createdAt: createdAt ?? this.createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
    );
  }

  Map<String, dynamic> toMap() => {
        'uid': uid,
        'parent_kind': parentKind,
        'parent_local_id': parentLocalId,
        'parent_remote_id': parentRemoteId,
        'owner_device_id': ownerDeviceId,
        'owner_device_name': ownerDeviceName,
        'file_name': fileName,
        'file_size': fileSize,
        'sha256': sha256,
        'mime': mime,
        'is_screenshot': isScreenshot ? 1 : 0,
        'orphaned': orphaned ? 1 : 0,
        'blob_state': blobState,
        'content_mode': contentMode,
        'source_path': sourcePath,
        'source_mtime_ms': sourceMtimeMs,
        'source_size': sourceSize,
        'stale_copy': staleCopy ? 1 : 0,
        'created_at': createdAt.toIso8601String(),
        'updated_at': updatedAt.toIso8601String(),
      };

  factory Attachment.fromMap(Map<dynamic, dynamic> map) {
    final created = DateTime.tryParse('${map['created_at']}') ?? DateTime.now();
    return Attachment(
      uid: '${map['uid'] ?? ''}',
      parentKind: map['parent_kind'] == kindMemo ? kindMemo : kindTask,
      parentLocalId: map['parent_local_id'] is int ? map['parent_local_id'] : null,
      parentRemoteId: map['parent_remote_id'] is int ? map['parent_remote_id'] : null,
      ownerDeviceId: '${map['owner_device_id'] ?? ''}',
      ownerDeviceName: '${map['owner_device_name'] ?? ''}',
      fileName: '${map['file_name'] ?? ''}',
      fileSize: map['file_size'] is int ? map['file_size'] : 0,
      sha256: '${map['sha256'] ?? ''}',
      mime: '${map['mime'] ?? ''}',
      isScreenshot: map['is_screenshot'] == 1 || map['is_screenshot'] == true,
      orphaned: map['orphaned'] == 1 || map['orphaned'] == true,
      blobState: '${map['blob_state'] ?? 'none'}',
      contentMode: '${map['content_mode'] ?? modeCopy}' == modeLink ? modeLink : modeCopy,
      sourcePath: '${map['source_path'] ?? ''}',
      sourceMtimeMs: map['source_mtime_ms'] is int ? map['source_mtime_ms'] : 0,
      sourceSize: map['source_size'] is int ? map['source_size'] : 0,
      staleCopy: map['stale_copy'] == 1 || map['stale_copy'] == true,
      createdAt: created,
      updatedAt: DateTime.tryParse('${map['updated_at']}') ?? created,
    );
  }

  /// -> 服务端 `/api/attachments/sync` 的一条元数据
  Map<String, dynamic> toApi() => {
        'uid': uid,
        'parent_kind': parentKind,
        'parent_remote_id': parentRemoteId,
        'owner_device_id': ownerDeviceId,
        'owner_device_name': ownerDeviceName,
        'file_name': fileName,
        'file_size': fileSize,
        'sha256': sha256,
        'mime': mime,
        'is_screenshot': isScreenshot,
        'orphaned': orphaned,
        'created_at': _utcIso(createdAt),
        'updated_at': _utcIso(updatedAt),
      };

  /// <- 服务端返回的一条元数据（时间是带 Z 的 UTC 字符串）
  factory Attachment.fromApi(Map<String, dynamic> m) {
    DateTime parse(Object? raw) =>
        raw is String ? (DateTime.tryParse(raw)?.toLocal() ?? DateTime.now()) : DateTime.now();
    final created = parse(m['created_at']);
    return Attachment(
      uid: '${m['uid'] ?? ''}',
      parentKind: m['parent_kind'] == kindMemo ? kindMemo : kindTask,
      parentRemoteId: m['parent_remote_id'] is int ? m['parent_remote_id'] : null,
      ownerDeviceId: '${m['owner_device_id'] ?? ''}',
      ownerDeviceName: '${m['owner_device_name'] ?? ''}',
      fileName: '${m['file_name'] ?? ''}',
      fileSize: m['file_size'] is int ? m['file_size'] : 0,
      sha256: '${m['sha256'] ?? ''}',
      mime: '${m['mime'] ?? ''}',
      isScreenshot: m['is_screenshot'] == true,
      orphaned: m['orphaned'] == true,
      blobState: '${m['blob_state'] ?? 'none'}',
      createdAt: created,
      updatedAt: parse(m['updated_at']),
    );
  }

  static String _utcIso(DateTime dt) => dt.toUtc().toIso8601String();
}
