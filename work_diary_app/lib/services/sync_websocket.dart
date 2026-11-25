import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:uuid/uuid.dart';
import 'package:web_socket_channel/io.dart';

import 'api_config.dart';
import 'app_logger.dart';
import 'auth_service.dart';
import 'device_identity.dart';

/// 每个 App 启动生成一个随机 client_id，用于服务端排除自己的推送
class SyncClientId {
  static final String instance = const Uuid().v4();
}

/// WebSocket 实时同步：服务端推送 data_changed 事件，客户端触发同步
class SyncWebSocket {
  static final SyncWebSocket instance = SyncWebSocket._();
  SyncWebSocket._();

  IOWebSocketChannel? _channel;
  StreamSubscription? _sub;
  Timer? _reconnectTimer;
  bool _manuallyClosed = false;
  int _attempt = 0;

  /// 重连退避序列（秒）：5 → 10 → 30 → 60 → 120 → 300（上限 5 分钟）
  static const List<int> _backoffSeconds = [5, 10, 30, 60, 120, 300];

  /// 认证失败时服务端使用的关闭码，收到后不再重连
  static const int _authFailedCode = 1008;

  void Function()? onDataChanged;

  /// 附件中转推送（attachment_request / attachment_ready / attachment_taken）
  void Function(Map<String, dynamic> message)? onAttachmentEvent;

  bool get isConnected => _channel != null && !_manuallyClosed;

  /// 幂等连接：已连接时什么都不做。
  ///
  /// 登录可能发生在会话中途（启动时还没登录），所以同步入口要能随时补连；
  /// 用这个方法避免每次同步都重建连接。
  void ensureConnected() {
    if (isConnected) return;
    connect();
  }

  void connect() {
    if (!AuthService.isLoggedIn) return;
    final token = AuthService.token;
    if (token == null || token.isEmpty) return;

    // 只重建连接，不要把退避计数清掉（disconnect() 会归零）：
    // 否则每次重连都从 5 秒重新开始，指数退避失效。
    final keepAttempt = _attempt;
    disconnect();
    _attempt = keepAttempt;
    _manuallyClosed = false;

    final uri = _wsUri(token);
    if (uri == null) {
      AppLogger.instance.log('[WS] 无法从 API 地址推导 WebSocket 地址，已跳过实时同步');
      return;
    }

    try {
      _channel = IOWebSocketChannel.connect(
        uri,
        pingInterval: const Duration(seconds: 30),
      );
    } catch (e, st) {
      AppLogger.instance.error('[WS] 建连失败', e, st);
      _scheduleReconnect();
      return;
    }

    // 连上就重置退避；失败交给 onError/onDone 处理
    unawaited(
      _channel!.ready.then((_) {
        _attempt = 0;
      }).catchError((Object _) {}),
    );

    _sub = _channel!.stream.listen(
      (data) {
        try {
          final decoded = jsonDecode(data as String);
          if (decoded is! Map) return;
          final msg = Map<String, dynamic>.from(decoded);
          final type = msg['type'];
          if (type == 'data_changed') {
            onDataChanged?.call();
          } else if (type == 'attachment_request' ||
              type == 'attachment_ready' ||
              type == 'attachment_taken') {
            onAttachmentEvent?.call(msg);
          }
        } catch (_) {
          // 非 JSON / 非预期消息直接忽略
        }
      },
      onError: (Object e) {
        AppLogger.instance.log('[WS] 连接错误: $e');
        _scheduleReconnect();
      },
      onDone: () {
        final code = _channel?.closeCode;
        if (code == _authFailedCode) {
          // 认证失败：重连只会拿到同样的 1008，白刷日志和服务端
          _manuallyClosed = true;
          AppLogger.instance.log('[WS] 鉴权失败（$code），停止重连，等待重新登录');
          return;
        }
        AppLogger.instance.log('[WS] 连接关闭（code=$code），准备重连');
        _scheduleReconnect();
      },
    );
  }

  void disconnect() {
    _manuallyClosed = true;
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
    _attempt = 0;
    _sub?.cancel();
    _sub = null;
    _channel?.sink.close();
    _channel = null;
  }

  /// 从 API 地址推导 WebSocket 地址（https -> wss，http -> ws），
  /// 不再写死生产域名，否则自建/测试服务器的实时同步会连到别处。
  Uri? _wsUri(String token) {
    try {
      final base = Uri.parse(ApiConfig.baseUrl);
      if (base.host.isEmpty) return null;
      return base.replace(
        scheme: base.scheme == 'https' ? 'wss' : 'ws',
        path: '/ws',
        queryParameters: <String, String>{
          'token': token,
          'client_id': SyncClientId.instance,
          // 服务端按 device_id 决定"这份文件该让哪台机器上传/该把就绪通知发给谁"，
          // 不带就等于放弃了上线自动续传的补发
          'device_id': DeviceIdentity.id,
          'device_name': DeviceIdentity.name,
        },
      );
    } catch (_) {
      return null;
    }
  }

  void _scheduleReconnect() {
    if (_manuallyClosed || !AuthService.isLoggedIn) return;
    _reconnectTimer?.cancel();
    var index = _attempt;
    if (index < 0) index = 0;
    if (index >= _backoffSeconds.length) index = _backoffSeconds.length - 1;
    final seconds = _backoffSeconds[index];
    if (_attempt < _backoffSeconds.length - 1) _attempt++;
    // ±20% 抖动，避免服务端重启时所有客户端同一秒齐刷
    final jitter = 1 + (Random().nextDouble() - 0.5) * 0.4;
    var millis = (seconds * 1000 * jitter).round();
    if (millis < 1000) millis = 1000;
    if (millis > 600000) millis = 600000;
    _reconnectTimer = Timer(Duration(milliseconds: millis), connect);
  }
}
