import 'dart:io';

/// 附件类型白名单：只允许图片和文档，其它一律拒绝，并且给出可读原因。
///
/// 这份名单与服务端 `app/attachment_types.py` 一一对应。客户端先拦一道，
/// 用户拖错文件立刻知道原因，不用等一次网络往返；服务端仍会独立校验，
/// 两边必须同步改，否则小程序/旧客户端传上来的文件会被服务端拒掉。
class AttachmentTypeCheck {
  const AttachmentTypeCheck({
    required this.allowed,
    this.mime = '',
    this.reason = '',
  });

  final bool allowed;
  final String mime;
  final String reason;
}

const Set<String> kImageExts = {
  '.jpg', '.jpeg', '.png', '.gif', '.webp', '.bmp',
};

const Set<String> kDocExts = {
  '.pdf', '.doc', '.docx', '.xls', '.xlsx', '.ppt', '.pptx',
  '.txt', '.md', '.csv', '.rtf', '.ofd', '.wps', '.et', '.dps',
};

/// 可直接执行的文件：任何情况下都不允许存进任务附件
const Set<String> kExecutableExts = {
  '.exe', '.msi', '.msp', '.bat', '.cmd', '.com', '.scr', '.ps1', '.psm1',
  '.vbs', '.vbe', '.js', '.jse', '.wsf', '.wsh', '.dll', '.sys', '.drv',
  '.reg', '.lnk', '.apk', '.jar', '.sh', '.msu', '.cpl', '.msiexec',
};

const Set<String> kVideoExts = {
  '.mp4', '.mov', '.avi', '.mkv', '.flv', '.wmv', '.webm', '.m4v', '.mpg',
  '.mpeg', '.3gp', '.ts', '.vob', '.rmvb', '.asf',
};

const Set<String> kAudioExts = {
  '.mp3', '.wav', '.m4a', '.flac', '.aac', '.ogg', '.wma', '.amr', '.opus',
  '.mid', '.midi',
};

const Set<String> kArchiveExts = {
  '.zip', '.rar', '.7z', '.tar', '.gz', '.tgz', '.bz2', '.xz', '.iso',
};

const Map<String, String> kMimeByExt = {
  '.jpg': 'image/jpeg', '.jpeg': 'image/jpeg', '.png': 'image/png',
  '.gif': 'image/gif', '.webp': 'image/webp', '.bmp': 'image/bmp',
  '.pdf': 'application/pdf', '.doc': 'application/msword',
  '.docx': 'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
  '.xls': 'application/vnd.ms-excel',
  '.xlsx': 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
  '.ppt': 'application/vnd.ms-powerpoint',
  '.pptx': 'application/vnd.openxmlformats-officedocument.presentationml.presentation',
  '.txt': 'text/plain', '.md': 'text/markdown', '.csv': 'text/csv',
  '.rtf': 'application/rtf', '.ofd': 'application/ofd',
  '.wps': 'application/wps-office.doc', '.et': 'application/wps-office.xlsx',
  '.dps': 'application/wps-office.pptx',
};

/// 与服务端一致的提示语：拒绝原因里必须告诉用户"到底能放什么"
const String kAttachmentAllowedHint = '仅支持图片和文档（jpg/png/gif/webp/bmp、'
    'pdf/word/excel/ppt/txt/md/csv 等）';

/// 单文件大小上限（与服务端 ATTACHMENT_MAX_MB 一致）
const int kAttachmentMaxBytes = 100 * 1024 * 1024;

/// 单个任务/备忘最多几个附件（与服务端 ATTACHMENT_MAX_PER_PARENT 一致）
const int kAttachmentMaxPerParent = 5;

String attachmentExtOf(String fileName) {
  final name = fileName.trim();
  final slash = name.lastIndexOf(Platform.pathSeparator);
  final base = slash >= 0 ? name.substring(slash + 1) : name;
  final dot = base.lastIndexOf('.');
  if (dot <= 0 || dot == base.length - 1) return '';
  return base.substring(dot).toLowerCase();
}

/// 判断文件能否作为附件保存，并给出 MIME 与拒绝原因。
///
/// 拒绝文案与服务端 `classify()` 保持一致，多一层拦截只为了立刻给提示。
AttachmentTypeCheck checkAttachmentFile(String fileName, {int? sizeBytes}) {
  final ext = attachmentExtOf(fileName);
  if (kImageExts.contains(ext) || kDocExts.contains(ext)) {
    if (sizeBytes != null && sizeBytes > kAttachmentMaxBytes) {
      return AttachmentTypeCheck(
        allowed: false,
        reason: '$fileName 超过 ${kAttachmentMaxBytes ~/ (1024 * 1024)}MB 上限',
      );
    }
    return AttachmentTypeCheck(
      allowed: true,
      mime: kMimeByExt[ext] ?? 'application/octet-stream',
    );
  }
  if (kExecutableExts.contains(ext)) {
    return AttachmentTypeCheck(
      allowed: false,
      reason: '可执行文件（$ext）不支持保存，$kAttachmentAllowedHint',
    );
  }
  if (kVideoExts.contains(ext)) {
    return AttachmentTypeCheck(
      allowed: false,
      reason: '视频文件（$ext）不支持保存，$kAttachmentAllowedHint',
    );
  }
  if (kAudioExts.contains(ext)) {
    return AttachmentTypeCheck(
      allowed: false,
      reason: '音频文件（$ext）不支持保存，$kAttachmentAllowedHint',
    );
  }
  if (kArchiveExts.contains(ext)) {
    return AttachmentTypeCheck(
      allowed: false,
      reason: '压缩包（$ext）不支持保存，$kAttachmentAllowedHint',
    );
  }
  return AttachmentTypeCheck(
    allowed: false,
    reason: '该类型（${ext.isEmpty ? '无扩展名' : ext}）不支持保存，$kAttachmentAllowedHint',
  );
}

/// 可读的文件大小，用于卡片上的"2.3 MB"
String formatAttachmentSize(int bytes) {
  if (bytes < 1024) return '$bytes B';
  if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
  return '${(bytes / 1024 / 1024).toStringAsFixed(1)} MB';
}
