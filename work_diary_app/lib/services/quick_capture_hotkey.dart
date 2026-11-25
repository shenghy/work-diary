import 'dart:io' show Platform;

import 'package:flutter/services.dart';
import 'package:hive/hive.dart';

import 'app_logger.dart';
import 'hotkey_router.dart';

/// 一个候选组合键（Windows 虚拟键码 + 修饰键掩码）
class QuickCaptureCombo {
  const QuickCaptureCombo(this.id, this.label, this.vk, this.modifiers);

  /// 持久化用的稳定标识，如 'ctrl+alt+n'
  final String id;

  /// 展示用名称，如 'Ctrl+Alt+N'
  final String label;

  /// Windows 虚拟键码（VK_N = 0x4E，VK_SPACE = 0x20）
  final int vk;

  /// Windows 修饰键掩码（MOD_ALT / MOD_CONTROL / MOD_SHIFT）
  final int modifiers;

  /// 传给原生 RegisterHotKey 的 ID，规则与 hotkey_channel.cpp 一致
  int get windowsId => (modifiers << 8) | vk;
}

/// 全局快速录入热键（仅 Windows）。
///
/// 任何地方按 Ctrl+Alt+N 唤起迷你录入框，不用去找托盘或气泡。
/// 与截图热键共用原生通道 `com.workdiary/hotkey`，通过 [HotkeyRouter]
/// 按热键 id 分发，两套热键互不干扰。
///
/// 行为约定与 HotkeyService 保持一致：
/// - 启动时先尝试上次用的组合键，被占用则按预置顺序降级；
/// - 全部被占用时不弹窗打扰用户，只在设置菜单里显示"未生效"。
class QuickCaptureHotkey {
  QuickCaptureHotkey._();
  static final QuickCaptureHotkey instance = QuickCaptureHotkey._();

  static const MethodChannel _channel = MethodChannel('com.workdiary/hotkey');

  // Windows 修饰键掩码
  static const int _modAlt = 0x0001;
  static const int _modControl = 0x0002;
  static const int _modShift = 0x0004;

  /// 首选 + 冲突降级顺序（与截图热键的预置项不重叠）
  static const List<QuickCaptureCombo> presets = <QuickCaptureCombo>[
    QuickCaptureCombo('ctrl+alt+n', 'Ctrl+Alt+N', 0x4E, _modControl | _modAlt),
    QuickCaptureCombo(
        'ctrl+shift+n', 'Ctrl+Shift+N', 0x4E, _modControl | _modShift),
    QuickCaptureCombo(
        'ctrl+alt+space', 'Ctrl+Alt+Space', 0x20, _modControl | _modAlt),
  ];

  static const String _settingsKey = 'quick_capture_hotkey';

  bool _inited = false;
  QuickCaptureCombo? _active;

  /// 热键触发回调（由首页设置，晚于 [init] 也没关系）
  void Function()? onTrigger;

  /// 当前实际生效的组合键；null 表示没有生效的热键
  QuickCaptureCombo? get active => _active;

  bool get isActive => _active != null;

  /// 设置菜单里显示的文案
  String get label => _active?.label ?? '未生效';

  /// 启动时调用一次（注册失败不影响其它功能）
  Future<void> init() async {
    if (_inited || !Platform.isWindows) return;
    _inited = true;

    // 上次用过的组合键优先，其次按预置顺序降级
    final candidates = <QuickCaptureCombo>[];
    final savedId = await _readSavedId();
    if (savedId != null) {
      final first = presets.firstWhere(
        (combo) => combo.id == savedId,
        orElse: () => presets.first,
      );
      candidates.add(first);
      candidates.addAll(presets.where((combo) => combo.id != first.id));
    } else {
      candidates.addAll(presets);
    }

    for (final combo in candidates) {
      if (!await _register(combo)) continue;
      _active = combo;
      // 回调里再读 onTrigger，所以首页晚一点设置也没问题
      HotkeyRouter.register(combo.windowsId, () => onTrigger?.call());
      await _persist(combo.id);
      AppLogger.instance.log('[QuickCapture] 热键已注册 ${combo.label}');
      return;
    }

    AppLogger.instance.log('[QuickCapture] 预置组合键都被占用，快速录入热键不可用');
  }

  Future<bool> _register(QuickCaptureCombo combo) async {
    try {
      final result = await _channel.invokeMethod<Map<Object?, Object?>>(
        'register',
        <String, dynamic>{
          'id': combo.windowsId,
          'vk': combo.vk,
          'modifiers': combo.modifiers,
        },
      );
      final ok = result?['ok'] == true;
      if (!ok) {
        AppLogger.instance.log(
          '[QuickCapture] ${combo.label} 注册失败 error=${result?['error']}',
        );
      }
      return ok;
    } catch (e, st) {
      AppLogger.instance.error('[QuickCapture] 注册异常', e, st);
      return false;
    }
  }

  Future<String?> _readSavedId() async {
    try {
      final box = await Hive.openBox('settings');
      final value = box.get(_settingsKey);
      return value is String ? value : null;
    } catch (_) {
      return null;
    }
  }

  Future<void> _persist(String id) async {
    try {
      final box = await Hive.openBox('settings');
      await box.put(_settingsKey, id);
    } catch (_) {}
  }
}
