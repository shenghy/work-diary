import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:tray_manager/tray_manager.dart';
import 'package:uuid/uuid.dart';
import 'package:window_manager/window_manager.dart';

import '../database/hive_utils.dart';
import 'api_config.dart';
import 'app_logger.dart';
import 'windows_upgrade_launcher.dart';

class LatestVersion {
  final String version;
  final String downloadUrl;
  final String releaseNotes;
  final bool forceUpdate;
  final int? fileSize;
  final String publishedAt;

  LatestVersion({
    required this.version,
    required this.downloadUrl,
    required this.releaseNotes,
    required this.forceUpdate,
    this.fileSize,
    required this.publishedAt,
  });

  factory LatestVersion.fromJson(Map<String, dynamic> json) => LatestVersion(
    version: json['version'] ?? '',
    downloadUrl: json['download_url'] ?? '',
    releaseNotes: json['release_notes'] ?? '',
    forceUpdate: json['force_update'] == true || json['force_update'] == 1,
    fileSize: json['file_size'],
    publishedAt: json['published_at'] ?? '',
  );
}

/// 后台下载 -> 保留待升级状态 -> 点击升级 -> 独立进程替换 -> 启动确认/回滚。
/// 网络、存储目录和可执行路径可注入，避免测试触碰真实安装及用户数据。
class UpgradeService {
  UpgradeService({
    http.Client Function()? clientFactory,
    Future<Directory> Function()? supportDirectory,
    String? executablePath,
  }) : _clientFactory = clientFactory ?? http.Client.new,
       _supportDirectory = supportDirectory ?? getApplicationSupportDirectory,
       _executablePath = executablePath ?? Platform.resolvedExecutable;

  static final UpgradeService instance = UpgradeService();
  final http.Client Function() _clientFactory;
  final Future<Directory> Function() _supportDirectory;
  final String _executablePath;
  List<String> launchArguments = const [];
  String? _currentVersion;
  LatestVersion? _latest;
  File? _downloadedZip;
  String? _lastDownloadError;
  Future<bool>? _checkFuture;
  bool _downloading = false;
  bool _upgrading = false;

  String get currentVersion => _currentVersion ?? '0.0.0';
  LatestVersion? get latest => _latest;
  bool get isForceUpdate => _latest?.forceUpdate ?? false;
  File? get downloadedZip => _downloadedZip;
  String? get lastDownloadError => _lastDownloadError;
  bool get downloading => _downloading;

  void _log(String message) => AppLogger.instance.log('[升级] $message');

  Future<void> init() async {
    final info = await PackageInfo.fromPlatform();
    _currentVersion = info.version;
  }

  bool _validVersion(String version) =>
      RegExp(r'^\d+\.\d+\.\d+(?:\+\d+)?$').hasMatch(version);

  bool _isNewer(String current, String remote) {
    if (!_validVersion(current) || !_validVersion(remote)) return false;
    final a = current.split('+').first.split('.').map(int.parse).toList();
    final b = remote.split('+').first.split('.').map(int.parse).toList();
    for (var i = 0; i < 3; i++) {
      if (b[i] != a[i]) return b[i] > a[i];
    }
    return false;
  }

  Future<bool> checkUpdate() {
    return _checkFuture ??= _doCheck().whenComplete(() => _checkFuture = null);
  }

  Future<bool> _doCheck() async {
    final client = _clientFactory();
    try {
      if (_currentVersion == null) await init();
      final response = await client
          .get(Uri.parse('${ApiConfig.baseUrl}/api/version/latest'))
          .timeout(const Duration(seconds: 8));
      if (response.statusCode != 200) return false;
      final data = jsonDecode(utf8.decode(response.bodyBytes));
      if (data['has_update'] != true) return false;
      final version = LatestVersion.fromJson(data);
      if (!_isNewer(currentVersion, version.version)) return false;
      _latest = version;
      return true;
    } catch (e) {
      _log('检查更新失败: $e');
      return false;
    } finally {
      client.close();
    }
  }

  Future<File> _supportFile(String name) async =>
      File(p.join((await _supportDirectory()).path, name));

  Future<File> _cachedZip(String version) =>
      _supportFile('work_diary_update_$version.zip');

  Future<File?> downloadUpdate({
    void Function(double progress)? onProgress,
  }) async {
    if (_latest == null || _downloading || _upgrading) return null;
    final version = _latest!;
    if (!_validVersion(version.version)) return null;
    _downloading = true;
    _lastDownloadError = null;
    File? partial;
    final client = _clientFactory();
    try {
      final zip = await _cachedZip(version.version);
      // 回滚、重启、手动检查更新都复用已校验的缓存，不再次联网下载。
      if (await _verifyZip(zip, version.fileSize)) {
        _downloadedZip = zip;
        await _savePending(version, zip);
        onProgress?.call(1);
        _log('复用已下载的 v${version.version}');
        return zip;
      }
      partial = File('${zip.path}.part');
      await partial.parent.create(recursive: true);
      final uri = Uri.parse(ApiConfig.baseUrl).resolve(version.downloadUrl);
      // 升级包只允许走 HTTPS：客户端能校验 ZIP 结构，但无法验证发布者签名，
      // 明文 HTTP 下载等于把“装什么”交给网络中间人。本机调试除外。
      final isLoopback = uri.host == 'localhost' ||
          uri.host == '127.0.0.1' ||
          uri.host == '::1';
      if (uri.scheme != 'https' && !isLoopback) {
        throw const FormatException('升级包地址必须是 HTTPS');
      }
      final response = await client
          .send(http.Request('GET', uri))
          .timeout(const Duration(seconds: 30));
      if (response.statusCode != 200) {
        throw HttpException('下载返回 ${response.statusCode}');
      }
      var received = 0;
      final sink = partial.openWrite();
      try {
        // 逐块写入，避免 IOSink.addStream 在超时或网络中断时仍处于绑定状态，
        // 随后的 close() 会抛出 "StreamSink is bound to a stream"。
        await for (final bytes in response.stream.timeout(
          const Duration(seconds: 30),
        )) {
          received += bytes.length;
          final size = response.contentLength ?? version.fileSize ?? 0;
          if (size > 0) {
            onProgress?.call((received / size).clamp(0.0, 1.0));
          }
          sink.add(bytes);
        }
        await sink.flush();
      } finally {
        await sink.close();
      }
      if (response.contentLength != null &&
          received != response.contentLength) {
        throw const FormatException('升级包不完整或不是 Windows 应用 ZIP');
      }
      // 后台记录的 file_size 可能因替换文件后未刷新而过期。只要实际 ZIP
      // 完整且 CRC/目录校验通过，就允许继续，并记录该配置问题。
      if (!await _verifyZip(partial, version.fileSize)) {
        if (version.fileSize != null && await _verifyZip(partial, null)) {
          _log('服务器 file_size=${version.fileSize} 与实际下载大小不一致，已按 ZIP 完整性校验通过');
        } else {
          throw const FormatException('升级包不完整或不是 Windows 应用 ZIP');
        }
      }
      if (await zip.exists()) await zip.delete();
      await partial.rename(zip.path);
      _downloadedZip = zip;
      await _savePending(version, zip);
      onProgress?.call(1);
      _log('v${version.version} 下载及完整性校验成功');
      return zip;
    } catch (e) {
      _lastDownloadError = e.toString().replaceFirst('FormatException: ', '');
      _log('下载失败: $e');
      if (partial != null && await partial.exists()) await partial.delete();
      return null;
    } finally {
      client.close();
      _downloading = false;
    }
  }

  Future<bool> _verifyZip(File zip, int? expectedSize) async {
    try {
      if (!await zip.exists()) return false;
      if (expectedSize != null &&
          expectedSize > 0 &&
          await zip.length() != expectedSize) {
        return false;
      }
      final decoder = ZipDecoder();
      final archive = decoder.decodeBytes(
        await zip.readAsBytes(),
        verify: true,
      );
      final checksums = {
        for (final header in decoder.directory.fileHeaders)
          header.filename: header.crc32,
      };
      final files = <String>{};
      for (final entry in archive) {
        final name = entry.name.replaceAll('\\', '/');
        if (name.startsWith('/') ||
            name.contains(':') ||
            name.split('/').contains('..') ||
            entry.isSymbolicLink) {
          return false;
        }
        if (entry.isFile) {
          // archive 4.2.0 的 verify 参数未实际执行 CRC 检查，显式解压核对。
          final bytes = entry.readBytes();
          if (bytes == null ||
              bytes.length != entry.size ||
              getCrc32(bytes) != checksums[entry.name]) {
            return false;
          }
          if (entry.size > 0) files.add(name);
        }
      }
      return files.containsAll({
        'work_diary_app.exe',
        'flutter_windows.dll',
        'data/app.so',
        'data/icudtl.dat',
        'msvcp140.dll',
        'vcruntime140.dll',
        'vcruntime140_1.dll',
      });
    } catch (e) {
      _log('升级包校验失败: $e');
      return false;
    }
  }

  Future<void> _savePending(LatestVersion version, File zip) async {
    final file = await _supportFile('upgrade_pending.json');
    final temporary = File('${file.path}.tmp');
    await temporary.writeAsString(
      jsonEncode({
        'version': version.version,
        'download_url': version.downloadUrl,
        'release_notes': version.releaseNotes,
        'force_update': version.forceUpdate,
        'file_size': version.fileSize,
        'zip_path': zip.path,
        'time': DateTime.now().toIso8601String(),
      }),
      flush: true,
    );
    await temporary.rename(file.path);
  }

  Future<void> _clearPending() async {
    final file = await _supportFile('upgrade_pending.json');
    if (await file.exists()) await file.delete();
    _downloadedZip = null;
  }

  Future<bool> restorePending() async {
    try {
      _downloadedZip = null;
      final file = await _supportFile('upgrade_pending.json');
      if (!await file.exists()) return false;
      if (_currentVersion == null) await init();
      final data =
          jsonDecode(await file.readAsString()) as Map<String, dynamic>;
      final version = LatestVersion.fromJson(data);
      if (!_isNewer(currentVersion, version.version)) {
        await _clearPending();
        return false;
      }
      final zip = await _cachedZip(version.version);
      if (p.normalize(data['zip_path'] as String) != p.normalize(zip.path) ||
          !await _verifyZip(zip, version.fileSize)) {
        await _clearPending();
        return false;
      }
      _latest = version;
      _downloadedZip = zip;
      _log('恢复待升级 v${version.version}，无需重新下载');
      return true;
    } catch (e) {
      _log('恢复升级记录失败: $e');
      await _clearPending();
      return false;
    }
  }

  /// 由主页在本地任务加载、首帧完成后调用。只有目标版本及事务匹配才确认。
  /// 备份由独立升级进程管理；客户端不再提前删除备份。
  Future<void> confirmUpgradeSuccess() async {
    if (!launchArguments.contains('--upgrade')) return;
    final marker = File(
      p.join(p.dirname(_executablePath), 'upgrade_pending.txt'),
    );
    if (!await marker.exists()) return;
    if (_currentVersion == null) await init();
    final content = (await marker.readAsString())
        .replaceFirst('\uFEFF', '')
        .trim();
    if (content != 'pending') {
      Map<String, dynamic> data;
      try {
        data = jsonDecode(content) as Map<String, dynamic>;
      } catch (e) {
        _log('升级标记内容损坏，保留回滚标记: $e');
        return;
      }
      if (data['version'] != currentVersion ||
          !launchArguments.contains('--upgrade-id=${data['transaction']}')) {
        _log('升级确认不匹配，保留回滚标记');
        return;
      }
    }
    // 兼容旧版本升级脚本使用的 pending 文本；不删除任何旧目录。
    await marker.delete();
    _log('v$currentVersion 初始化与首帧完成，已确认升级');
  }

  /// 将独立进程的失败原因写入 app.log，用户可通过原有“导出日志”提供。
  Future<String?> takeUpgradeFailure() async {
    final file = await _supportFile('upgrade_result.json');
    if (!await file.exists()) return null;
    Map<String, dynamic> result;
    try {
      result = jsonDecode(
        (await file.readAsString()).replaceFirst('\uFEFF', ''),
      ) as Map<String, dynamic>;
    } catch (e) {
      // 结果文件损坏不能中断整个升级初始化流程（否则本次会话不再检查更新）
      _log('升级结果文件损坏，已忽略: $e');
      try {
        await file.delete();
      } catch (_) {}
      return null;
    }
    await file.delete();
    if (result['status'] == 'success') return null;
    _log(
      '上次升级 ${result['status']}: ${result['message']}; backup=${result['backup_dir']}',
    );
    final scriptLog = await _supportFile('upgrade.log');
    if (await scriptLog.exists()) {
      final lines = await scriptLog.readAsLines();
      _log(lines.skip(lines.length > 40 ? lines.length - 40 : 0).join('\n'));
    }
    return result['status'] == 'recovery_failed'
        ? '升级恢复未完成，请使用安装包修复，并导出日志联系作者。'
        : '上次升级未完成，已保留原版本和升级包，可点击“立即升级”重试。';
  }

  Future<void> performUpgrade() async {
    if (_upgrading) return;
    _upgrading = true;
    try {
      final version = _latest;
      final zip = _downloadedZip;
      if (version == null ||
          zip == null ||
          !await _verifyZip(zip, version.fileSize)) {
        throw StateError('升级包不可用，请重新检查更新。');
      }
      await _savePending(version, zip);
      final transaction = const Uuid().v4();
      final helperDir = await Directory.systemTemp.createTemp(
        'workdiary-upgrade-',
      );
      final scriptFile = File(p.join(helperDir.path, 'upgrade.ps1'));
      final configFile = File(p.join(helperDir.path, 'config.json'));
      final ready = File(p.join(helperDir.path, 'ready'));
      final proceed = File(p.join(helperDir.path, 'proceed'));
      final result = await _supportFile('upgrade_result.json');
      if (await result.exists()) await result.delete();
      final template = await rootBundle.loadString(
        'assets/upgrade/windows_upgrade.ps1',
      );
      await scriptFile.writeAsString('\uFEFF$template', flush: true);
      await configFile.writeAsString(
        jsonEncode({
          'app_dir': p.dirname(_executablePath),
          'exe_name': p.basename(_executablePath),
          'transaction': transaction,
          'version': version.version,
          'zip_path': zip.path,
          'pending_path': (await _supportFile('upgrade_pending.json')).path,
          'result_path': result.path,
          'log_path': (await _supportFile('upgrade.log')).path,
          'ready_path': ready.path,
          'proceed_path': proceed.path,
        }),
        flush: true,
      );
      _log(
        '准备升级 v${version.version}: ${p.dirname(_executablePath)}; transaction=$transaction',
      );
      final helper = await launchWindowsUpgradeHelper(
        scriptPath: scriptFile.path,
        configPath: configFile.path,
        workingDirectory: helperDir.path,
      );
      final helperErrors = StringBuffer();
      helper.stdout.listen((_) {});
      helper.stderr.transform(utf8.decoder).listen((message) {
        if (helperErrors.length < 4096) helperErrors.write(message);
      });
      int? helperExitCode;
      helper.exitCode.then((code) => helperExitCode = code);
      _log('升级助手已启动 (PID ${helper.pid})，等待准备完成');
      final deadline = DateTime.now().add(const Duration(minutes: 2));
      while (!await ready.exists()) {
        if (helperExitCode != null) {
          final detail = helperErrors.toString().trim();
          _log('升级助手退出：code=$helperExitCode; stderr=$detail');
          throw StateError(
            '升级助手提前退出（代码 $helperExitCode）。${detail.isEmpty ? '请导出日志检查。' : detail}',
          );
        }
        if (await result.exists()) {
          final data = jsonDecode(
            (await result.readAsString()).replaceFirst('\uFEFF', ''),
          );
          _log('升级准备失败: ${data['message']}');
          throw StateError('无法准备升级文件，请确认安装目录可写；升级包已保留。');
        }
        if (DateTime.now().isAfter(deadline)) {
          throw StateError('升级程序未能启动，请导出日志检查；升级包已保留。');
        }
        await Future<void>.delayed(const Duration(milliseconds: 200));
      }
      final readyValue = (await ready.readAsString()).trim();
      if (readyValue != transaction) {
        throw StateError('升级准备校验失败，升级包已保留。');
      }
      // 遍历所有已打开的 box：旧实现写死了 ['tasks','settings','auth',
      // 'sync_deletions']，漏了 memos 和 repeat_rules，而升级是 exit(0)
      // 硬退出，这两个 box 里待写的帧会丢。
      await flushOpenHiveBoxes();
      await proceed.writeAsString(transaction, flush: true);
      _log('升级文件就绪，正在退出旧版本');
      try {
        await trayManager.destroy();
      } catch (_) {}
      try {
        await windowManager.destroy();
      } catch (_) {}
      exit(0);
    } catch (e, st) {
      AppLogger.instance.error('执行升级失败', e, st);
      rethrow;
    } finally {
      _upgrading = false;
    }
  }
}
