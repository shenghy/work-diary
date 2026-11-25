import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart' show ValueNotifier, WidgetsBinding;
import 'package:hive/hive.dart';
import 'package:window_manager/window_manager.dart';

import 'app_lifecycle.dart';
import 'app_logger.dart';

/// 桌面悬浮气泡服务（仅 Windows）。
///
/// 主窗口被最小化、关闭到托盘、或连续 [inactiveTimeoutMinutes] 分钟不在前台时，
/// 在屏幕右下角显示一个可拖拽的圆形气泡，右上角红点显示未完成任务数；
/// 点击气泡恢复主窗口，主窗口恢复后气泡自动消失。
///
/// 窗口的创建、绘制、拖拽、点击全部由原生层完成
/// （windows/runner/bubble_window.cpp），消息由 main.cpp 的 GetMessage 循环
/// 统一派发。Dart 侧只通过 [MethodChannel] 决定“何时显示 / 显示什么数字 /
/// 何时隐藏”，不自建 Win32 窗口，也不自建消息泵，因此不存在把 Dart 回调
/// 当作窗口过程被反复重入的问题。
class BubbleService {
  BubbleService._();
  static final BubbleService instance = BubbleService._();

  static const MethodChannel _channel = MethodChannel('com.workdiary/bubble');

  // ===== 可调参数 =====
  /// 连续不在前台多久后自动显示气泡（分钟）
  static const int inactiveTimeoutMinutes = 10;

  /// 前台状态轮询间隔
  static const Duration _focusCheckInterval = Duration(seconds: 30);

  // ===== 状态 =====
  /// 总开关：关闭后不再挂监听、不再自动弹出，设置里可随时打开。
  /// 默认开启，老用户升级后行为不变。
  final ValueNotifier<bool> enabled = ValueNotifier<bool>(true);

  static const String _prefKey = 'bubble_enabled';
  bool _prefLoaded = false;
  bool _inited = false;
  bool _bubbleVisible = false;
  bool _checking = false;
  int _inactiveRuns = 0;
  int _lastCount = 0;
  int Function()? _countProvider;

  /// 用户用右键菜单「关闭气泡球」主动关掉过气泡。
  /// 为 true 时不再因为"长时间不在前台"自动弹出；等用户回到主窗口、
  /// 或者再次最小化/关闭窗口（明确动作）时恢复。
  bool _dismissed = false;

  Timer? _focusTimer;
  WindowListener? _windowListener;

  /// 初始化：窗口事件监听 + 前台检查定时器 + 右键菜单回调。
  ///
  /// [startHidden]：本次是带 `--hidden` 静默启动的（开机自启）。这种情况下
  /// 主窗口根本不显示，也不会有最小化/关闭事件，如果不主动弹一次气泡，
  /// 用户开机后桌面上什么也看不到。
  ///
  /// 原生通道在 Runner 启动时已注册完毕，这里不创建任何窗口，因此不会抛异常。
  void init({bool startHidden = false}) {
    if (_inited || !Platform.isWindows) return;
    if (!_prefLoaded) {
      _prefLoaded = true;
      try {
        enabled.value = Hive.box('settings')
            .get(_prefKey, defaultValue: true) as bool;
      } catch (_) {
        // 读不到就用默认值，不影响启动。
      }
    }
    // 关闭状态不挂监听也不启定时器：用户重新打开开关时再挂上。
    if (!enabled.value) {
      AppLogger.instance.log('[Bubble] 设置里已关闭，跳过初始化');
      return;
    }
    _attach(startHidden: startHidden);
  }

  /// 总开关：立即生效并持久化。
  ///
  /// 关闭时先收起当前气泡再摘监听，否则 `_disable()` 之后通道调用会变成空操作。
  /// 打开时只恢复监听/定时器，不主动弹出——此刻用户就在主窗口里。
  void setEnabled(bool value) {
    if (enabled.value == value) return;
    enabled.value = value;
    try {
      Hive.box('settings').put(_prefKey, value);
    } catch (_) {}
    _dismissed = false;
    _inactiveRuns = 0;
    if (!value) {
      hideBubble();
      _disable();
      AppLogger.instance.log('[Bubble] 设置关闭桌面气泡');
    } else {
      // 只有服务初始化过才恢复监听：设置菜单能点开时 init 早已执行，
      // 这里同时避免单测在无窗口绑定的环境里挂定时器。
      if (Platform.isWindows && _prefLoaded) _attach();
      AppLogger.instance.log('[Bubble] 设置开启桌面气泡');
    }
  }

  void _attach({bool startHidden = false}) {
    if (_inited) return;
    _inited = true;
    // 气泡右键菜单（原生 TrackPopupMenu）选中后由原生回传，这里分发到
    // 与托盘菜单相同的入口。
    _channel.setMethodCallHandler(_handleNativeCall);
    _windowListener = _BubbleWindowListener();
    windowManager.addListener(_windowListener!);
    _focusTimer =
        Timer.periodic(_focusCheckInterval, (_) => unawaited(_checkFocus()));
    if (startHidden) {
      _scheduleShowOnStartup();
    }
  }

  /// 静默启动时把气泡放到桌面上。
  ///
  /// 等首帧之后再做：HomeScreen 会在首帧期间挂上"未完成任务数"提供者，
  /// 早于它显示的话角标会是 0。再留一点延迟让开机时的桌面稳定下来。
  void _scheduleShowOnStartup() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      unawaited(
        Future<void>.delayed(const Duration(milliseconds: 800), () {
          if (!_inited || _bubbleVisible) return;
          AppLogger.instance.log('[Bubble] 静默启动，主动显示气泡');
          unawaited(_showBubble());
        }),
      );
    });
  }

  /// 处理原生回调：目前只有气泡右键菜单的 onAction。
  Future<dynamic> _handleNativeCall(MethodCall call) async {
    if (call.method != 'onAction') return null;
    final args = call.arguments;
    final action = args is Map ? args['action']?.toString() : null;
    if (action == null) return null;
    AppLogger.instance.log('[Bubble] 菜单动作: $action');
    switch (action) {
      case 'quick_memo':
        await AppLifecycle.instance.quickAddMemo();
        break;
      case 'quick_task':
        await AppLifecycle.instance.quickAddTask();
        break;
      case 'show_window':
        await AppLifecycle.instance.showWindow();
        break;
      case 'hide_bubble':
        dismissBubble();
        break;
      case 'quit':
        await AppLifecycle.instance.quit();
        break;
    }
    return null;
  }

  /// 挂接未完成任务数提供者（由首页在数据变化后调用 refreshCount）。
  void attachCountProvider(int Function() provider) {
    _countProvider = provider;
    refreshCount();
  }

  /// 用 provider 重算未完成任务数；变化时推送给气泡重绘。
  void refreshCount() {
    if (!_inited) return;
    final provider = _countProvider;
    if (provider == null) return;
    final count = provider();
    if (count == _lastCount) return;
    _lastCount = count;
    if (_bubbleVisible) {
      unawaited(_invoke('updateCount', <String, dynamic>{'count': count}));
    }
  }

  // ===== 触发检测 =====

  Future<void> _checkFocus() async {
    if (!_inited || _checking) return;
    _checking = true;
    try {
      // 气泡可能已被用户点击关闭（原生侧已销毁）：以原生状态为准重新计时，
      // 避免 Dart 侧状态卡在“已显示”而不再响应最小化。
      if (_bubbleVisible) {
        if (await _queryBool('isVisible')) {
          // 兜底：主窗口已经回到前台（例如从托盘恢复时没收到 restore 事件），
          // 气泡不该继续挂在桌面上。
          if (await _queryBool('isMainWindowForeground')) {
            hideBubble();
          }
          return;
        }
        _bubbleVisible = false;
        _inactiveRuns = 0;
        return;
      }

      if (await _queryBool('isMainWindowForeground')) {
        _inactiveRuns = 0;
        // 用户回到了主窗口：解除"手动关闭气泡"的抑制状态
        _dismissed = false;
        return;
      }

      // 用户用右键菜单关掉过气泡：不再因为"长时间不在前台"自动弹出，
      // 只有下一次最小化/关闭窗口（明确动作）才会重新出现。
      if (_dismissed) return;

      _inactiveRuns++;
      final threshold =
          (inactiveTimeoutMinutes * 60) ~/ _focusCheckInterval.inSeconds;
      if (_inactiveRuns >= threshold) {
        _inactiveRuns = 0;
        await _showBubble();
      }
    } finally {
      _checking = false;
    }
  }

  /// 主窗口最小化 / 关闭到托盘 → 显示气泡。
  void onHidden() {
    // 这是用户的明确动作：恢复自动弹出（即使之前手动关掉过气泡）
    _dismissed = false;
    unawaited(_showBubble());
  }

  /// 气泡当前是否显示。
  /// 供"临时把窗口叫出来"的场景记录现场，事后恢复。
  bool get isShown => _bubbleVisible;

  /// 主窗口恢复 → 收起气泡。
  void onRestored() {
    // 回到主窗口：解除"手动关闭气泡"的抑制状态
    _dismissed = false;
    hideBubble();
  }

  /// 用户从气泡右键菜单选择「关闭气泡球」。
  ///
  /// 只关掉这一次，并且不再因为"长时间不在前台"自动弹出（否则用户刚关掉，
  /// 十分钟后它自己又冒出来，会显得没生效）。用户回到主窗口、或再次最小化 /
  /// 关闭窗口时会恢复正常。
  void dismissBubble() {
    if (!_inited) return;
    _dismissed = true;
    _inactiveRuns = 0;
    hideBubble();
    AppLogger.instance.log('[Bubble] 用户手动关闭气泡');
  }

  /// 收起气泡（幂等，原生侧重复调用无副作用）。
  void hideBubble() {
    if (!_inited) return;
    _bubbleVisible = false;
    unawaited(_invoke('hide'));
  }

  Future<void> _showBubble() async {
    // _dismissed 由「关闭气泡球」置位：即使有并发的定时检查，也不会把它又弹出来
    if (!_inited || _dismissed) return;
    if (_bubbleVisible) {
      // 原生气泡可能已被点击销毁，而 Dart 侧状态还没跟上（点击气泡是原生
      // 处理的，不回调 Dart）。这里以原生为准，否则"点气泡回到窗口 → 再次
      // 关闭窗口"会因为 _bubbleVisible 仍是 true 而不再显示气泡。
      if (await _queryBool('isVisible')) return;
      _bubbleVisible = false;
    }
    refreshCount(); // 显示前取最新计数
    _bubbleVisible = true;
    AppLogger.instance.log('[Bubble] show, count=$_lastCount');
    final shown =
        await _invokeForResult('show', <String, dynamic>{'count': _lastCount});
    if (!shown && _bubbleVisible) {
      _bubbleVisible = false;
      AppLogger.instance.log('[Bubble] show failed');
    }
  }

  /// 释放监听与定时器（仅在需要彻底关闭气泡功能时调用）。
  Future<void> dispose() async {
    final wasInited = _inited;
    _disable();
    if (wasInited) {
      await _invoke('hide');
    }
  }

  /// 关闭服务并摘除监听（原生通道不可用时也会走这里）。
  void _disable() {
    if (!_inited) return;
    _inited = false;
    _bubbleVisible = false;
    _focusTimer?.cancel();
    _focusTimer = null;
    final listener = _windowListener;
    if (listener != null) {
      windowManager.removeListener(listener);
      _windowListener = null;
    }
  }

  // ===== 通道调用 =====

  Future<void> _invoke(
    String method, [
    Map<String, dynamic>? arguments,
  ]) async {
    try {
      await _channel.invokeMethod<void>(method, arguments);
    } catch (e, st) {
      AppLogger.instance.error('BubbleService.$method', e, st);
    }
  }

  Future<bool> _invokeForResult(
    String method, [
    Map<String, dynamic>? arguments,
  ]) async {
    try {
      final result = await _channel.invokeMethod<bool>(method, arguments);
      return result ?? false;
    } catch (e, st) {
      AppLogger.instance.error('BubbleService.$method', e, st);
      return false;
    }
  }

  Future<bool> _queryBool(String method) async {
    try {
      final result = await _channel.invokeMethod<bool>(method);
      return result ?? false;
    } on MissingPluginException {
      // 原生通道不存在（例如非 Windows 构建）：静默关闭，避免每 30 秒刷日志
      _disable();
      AppLogger.instance.log('[Bubble] 原生通道不可用，已关闭气泡功能');
      return false;
    } catch (e, st) {
      AppLogger.instance.error('BubbleService.$method', e, st);
      return false;
    }
  }
}

/// 主窗口事件监听：最小化 / 关闭到托盘 → 显示气泡；恢复 → 收起气泡。
///
/// 注意：本应用的“关闭窗口”等于隐藏到系统托盘，不能在这里释放整个服务，
/// 否则用户关一次窗口后气泡功能就会永久失效。
class _BubbleWindowListener extends WindowListener {
  @override
  void onWindowMinimize() => BubbleService.instance.onHidden();

  @override
  void onWindowRestore() => BubbleService.instance.onRestored();

  @override
  void onWindowClose() {
    // 关闭 = 隐藏到托盘（AppLifecycle.setPreventClose + hideToTray），
    // 和最小化一样把气泡放到桌面上，用户随时能点回来。
    BubbleService.instance.onHidden();
  }
}
