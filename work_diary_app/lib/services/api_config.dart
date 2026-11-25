import 'dart:io';

import 'package:flutter/foundation.dart';

import 'app_logger.dart';

/// 服务端 API 地址 —— 客户端唯一需要配置的地方。
///
/// 生效顺序：
/// 1. 优先读取 exe 同目录下的 `api_url.txt`（内容为一行 API 地址），
///    换服务器 / 本机测试时改这个文件即可，不用重新编译；
/// 2. 没有该文件时，使用下方的内置默认地址。
class ApiConfig {
  /// 内置默认地址：发布版默认连这里，部署到服务器后改成你的服务器地址
  static const String _defaultBaseUrl = 'https://work.jspang.com';

  /// 首次读取后缓存：这个 getter 在每个网络请求里都会被调用，
  /// 每次都做 existsSync + readAsStringSync 会在机械盘/杀软环境明显卡顿。
  static String? _cached;

  /// 实际生效的 API 地址
  static String get baseUrl => _cached ??= _resolve();

  static String _resolve() {
    if (kIsWeb) return _defaultBaseUrl;
    String raw;
    try {
      final exeDir = File(Platform.resolvedExecutable).parent.path;
      final file = File('$exeDir${Platform.pathSeparator}api_url.txt');
      if (!file.existsSync()) return _defaultBaseUrl;
      raw = file.readAsStringSync().trim();
    } catch (_) {
      // 读取失败时使用默认地址
      return _defaultBaseUrl;
    }
    if (raw.isEmpty) return _defaultBaseUrl;
    return _validated(raw);
  }

  /// 校验 api_url.txt 的内容。
  ///
  /// 升级下载明确只允许 HTTPS，这里必须同样严格：否则把地址改成 http 就能
  /// 让 `Authorization: Bearer <token>` 和全部任务内容走明文传输。
  /// 本机调试保留 http 例外。
  static String _validated(String raw) {
    final uri = Uri.tryParse(raw);
    if (uri == null || !uri.hasScheme || uri.host.isEmpty) {
      AppLogger.instance.error('api_url.txt 不是合法的地址，已回退默认服务器', raw);
      return _defaultBaseUrl;
    }
    final loopback = uri.host == 'localhost' ||
        uri.host == '127.0.0.1' ||
        uri.host == '::1';
    if (uri.scheme != 'https' && !(uri.scheme == 'http' && loopback)) {
      AppLogger.instance.error('api_url.txt 必须使用 https，已回退默认服务器', raw);
      return _defaultBaseUrl;
    }
    // 去掉结尾的 '/'，避免拼出 'https://host//api/tasks/sync'
    final text = uri.toString();
    return text.endsWith('/') ? text.substring(0, text.length - 1) : text;
  }

  /// 仅测试用：清空缓存，让下次读取重新解析 api_url.txt
  @visibleForTesting
  static void resetCache() => _cached = null;

  /// 仅测试用：把 API 地址钉到本机测试服务（端到端用例连的是 127.0.0.1）
  @visibleForTesting
  static void useBaseUrlForTest(String url) => _cached = url;
}
