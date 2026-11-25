import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart' show kDebugMode;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// 应用全局日志服务
///
/// 日志写到应用数据目录的 app.log，用户遇到问题时可以一键导出发给开发者。
/// 自动截断：超过 5MB 自动裁剪保留最近一半。
class AppLogger {
  AppLogger._();
  static final AppLogger instance = AppLogger._();

  File? _logFile;
  bool _initialized = false;

  /// 距离上次检查日志大小已写入的行数
  int _writesSinceRotateCheck = 0;

  static const int _maxSize = 5 * 1024 * 1024; // 5MB

  Future<void> init() async {
    if (_initialized) return;
    try {
      final dir = await getApplicationSupportDirectory();
      _logFile = File(p.join(dir.path, 'app.log'));
      // 轮转放后台：启动时同步读取 5MB 日志会拖慢首帧
      unawaited(_rotateIfNeeded());
      _initialized = true;
      log('AppLogger initialized');
    } catch (_) {}
  }

  /// 记录一条日志
  void log(String message) {
    final line = '[${DateTime.now().toIso8601String()}] $message';
    // 只有 debug 才打印到控制台：release 下 print 也会走到 stdout 处理路径
    if (kDebugMode) {
      // ignore: avoid_print
      print(line);
    }
    final file = _logFile;
    if (file == null) return;
    try {
      // 日志量很小，同步追加可保证升级退出前落盘，也不会在异步 flush
      // 尚未完成时再次写入同一个 IOSink。
      file.writeAsStringSync(
        '$line\n',
        mode: FileMode.append,
        flush: true,
      );
    } catch (_) {
      // 日志写入失败不能影响正常操作或升级。
      return;
    }
    // 旧实现只在 init 里检查一次大小：应用常驻托盘运行数周后日志无上限增长。
    if (++_writesSinceRotateCheck >= 200) {
      _writesSinceRotateCheck = 0;
      unawaited(_rotateIfNeeded());
    }
  }

  /// 记录错误
  void error(String message, [Object? e, StackTrace? st]) {
    final buf = StringBuffer()..write('ERROR: $message');
    if (e != null) buf.write(' | $e');
    if (st != null) buf.write('\n$st');
    log(buf.toString());
  }

  /// 导出日志文件路径（供"导出日志"按钮使用）
  Future<String?> get logFilePath async {
    await init();
    return _logFile?.path;
  }

  /// 导出日志到用户指定位置（对话框选择）
  /// 返回导出后的文件路径，取消则返回 null
  Future<String?> exportLog() async {
    await init();
    if (_logFile == null || !await _logFile!.exists()) return null;
    // 复制到桌面，文件名带时间戳
    try {
      final desktop = Directory(
        '${Platform.environment['USERPROFILE']}\\Desktop',
      );
      final name =
          'work_diary_log_${DateTime.now().millisecondsSinceEpoch}.txt';
      final dest = File(p.join(desktop.path, name));
      await _logFile!.copy(dest.path);
      return dest.path;
    } catch (_) {
      return null;
    }
  }

  /// 日志文件过大时，只保留最后一半
  Future<void> _rotateIfNeeded() async {
    try {
      if (_logFile == null || !await _logFile!.exists()) return;
      final len = await _logFile!.length();
      if (len < _maxSize) return;
      final lines = await _logFile!.readAsLines();
      final keep = lines.length ~/ 2;
      final kept = lines.sublist(keep).join('\n');
      await _logFile!.writeAsString(kept);
    } catch (_) {}
  }
}
