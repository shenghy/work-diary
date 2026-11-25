import 'dart:io' show Platform;

import 'package:flutter/services.dart';
import 'package:hive/hive.dart';
import 'package:hotkey_manager/hotkey_manager.dart';

import 'app_logger.dart';
import 'hotkey_router.dart';

/// 启动后的热键状态。
enum HotkeyStatus {
  /// 用户选择的热键注册成功。
  registered,

  /// 用户选择的热键被占用，已自动改用其它预设（见 [HotkeyService.activeOption]）。
  fallback,

  /// 所有预设都被占用，截图热键当前不可用。
  allUnavailable,

  /// 当前平台无法检测冲突（非 Windows），不弹冲突提示。
  unsupported,
}

/// 单个预置热键的实时可用性（选择器展示用）。
class HotkeyAvailability {
  const HotkeyAvailability(this.option, this.available);

  final HotkeyOption option;
  final bool available;
}

/// 注册结果：errorCode 为 1409（ERROR_HOTKEY_ALREADY_REGISTERED）表示被占用。
class HotkeyRegisterResult {
  const HotkeyRegisterResult(this.ok, [this.errorCode]);

  final bool ok;
  final int? errorCode;
}

/// 预置热键。
///
/// Windows 直接使用 [vk] + [winModifiers] 调用 RegisterHotKey；
/// 其它平台继续使用 [key] + [modifiers] 交给 hotkey_manager。
class HotkeyOption {
  const HotkeyOption({
    required this.id,
    required this.label,
    required this.key,
    required this.modifiers,
    required this.vk,
    required this.winModifiers,
  });

  /// 持久化用的稳定标识（如 'ctrl+alt+a'）。
  final String id;

  /// 展示用名称（如 'Ctrl+Alt+A'）。
  final String label;

  final KeyboardKey key;
  final List<HotKeyModifier> modifiers;

  /// Windows 虚拟键码（VK_A = 0x41，VK_Q = 0x51）。
  final int vk;

  /// Windows 修饰键掩码（MOD_ALT / MOD_CONTROL / MOD_SHIFT）。
  final int winModifiers;

  /// 传给原生 RegisterHotKey 的 ID：同一组合键永远得到同一个 ID。
  int get windowsId => (winModifiers << 8) | vk;
}

/// 平台注册器抽象。
///
/// Windows 走自建通道（能拿到真实注册结果），其它平台走 hotkey_manager
/// （无法检测冲突）。抽成接口是为了单元测试可以注入假实现。
abstract class HotkeyRegistrar {
  /// 绑定全局触发回调。
  void bind(void Function() onTrigger);

  Future<HotkeyRegisterResult> register(HotkeyOption option);

  Future<void> unregister(HotkeyOption option);

  /// 探测组合键当前是否可用（未被其它软件占用）。
  Future<bool> probe(HotkeyOption option);
}

/// 热键配置存储（抽出来便于测试，默认落 Hive 的 settings box）。
abstract class HotkeyStore {
  Future<String?> read(String key);

  Future<void> write(String key, String value);
}

class HiveHotkeyStore implements HotkeyStore {
  @override
  Future<String?> read(String key) async {
    final box = await Hive.openBox('settings');
    final value = box.get(key);
    return value is String ? value : null;
  }

  @override
  Future<void> write(String key, String value) async {
    final box = await Hive.openBox('settings');
    await box.put(key, value);
  }
}

/// 全局截图热键服务。
///
/// 行为约定：
/// - 启动时先尝试用户保存的热键；Windows 上如果被占用，按预设顺序自动降级，
///   并保留用户的偏好（下次启动仍会先尝试原热键，冲突软件关掉后自动恢复）。
/// - 手动换键时先探测再注册，注册失败保持原热键，不会出现“新旧都不能用”。
/// - 是否提示冲突由调用方根据 [status] 决定；[HotkeyStatus.unsupported]
///   表示当前平台无法判断，不提示。
class HotkeyService {
  HotkeyService({
    HotkeyRegistrar? registrar,
    HotkeyStore? store,
    bool? detectConflicts,
  }) : _registrar = registrar ?? _defaultRegistrar(),
       _store = store ?? HiveHotkeyStore(),
       _detectConflicts = detectConflicts ?? Platform.isWindows;

  static final HotkeyService instance = HotkeyService();

  static const String defaultHotkeyId = 'ctrl+alt+a';

  static const String _hotkeyKey = 'screenshot_hotkey';
  static const String _conflictAckKey = 'screenshot_hotkey_conflict_ack';

  // Windows 修饰键掩码
  static const int _modAlt = 0x0001;
  static const int _modControl = 0x0002;
  static const int _modShift = 0x0004;

  /// 预设备选热键列表（顺序即自动降级的顺序）。
  static const List<HotkeyOption> presetHotkeys = <HotkeyOption>[
    HotkeyOption(
      id: 'ctrl+alt+a',
      label: 'Ctrl+Alt+A',
      key: LogicalKeyboardKey.keyA,
      modifiers: <HotKeyModifier>[HotKeyModifier.control, HotKeyModifier.alt],
      vk: 0x41,
      winModifiers: _modControl | _modAlt,
    ),
    HotkeyOption(
      id: 'ctrl+shift+a',
      label: 'Ctrl+Shift+A',
      key: LogicalKeyboardKey.keyA,
      modifiers: <HotKeyModifier>[
        HotKeyModifier.control,
        HotKeyModifier.shift,
      ],
      vk: 0x41,
      winModifiers: _modControl | _modShift,
    ),
    HotkeyOption(
      id: 'ctrl+alt+q',
      label: 'Ctrl+Alt+Q',
      key: LogicalKeyboardKey.keyQ,
      modifiers: <HotKeyModifier>[HotKeyModifier.control, HotKeyModifier.alt],
      vk: 0x51,
      winModifiers: _modControl | _modAlt,
    ),
    HotkeyOption(
      id: 'ctrl+shift+q',
      label: 'Ctrl+Shift+Q',
      key: LogicalKeyboardKey.keyQ,
      modifiers: <HotKeyModifier>[
        HotKeyModifier.control,
        HotKeyModifier.shift,
      ],
      vk: 0x51,
      winModifiers: _modControl | _modShift,
    ),
  ];

  final HotkeyRegistrar _registrar;
  final HotkeyStore _store;

  /// 是否能检测冲突（Windows 为 true，其它平台交给插件、无法判断）。
  final bool _detectConflicts;

  String _desiredId = defaultHotkeyId;
  String? _activeId;
  HotkeyStatus _status = HotkeyStatus.unsupported;
  int? _lastErrorCode;

  /// 全局热键触发回调（由 home_screen 设置）。
  void Function()? onTrigger;

  /// 启动时的注册结果。
  HotkeyStatus get status => _status;

  /// 用户选择（保存）的热键；即使冲突降级了也保持为用户的偏好。
  String get desiredHotkeyId => _desiredId;

  /// 当前真正注册生效的热键；null 表示没有任何热键生效。
  String? get activeHotkeyId => _activeId;

  bool get isActive => _activeId != null;

  /// 最近一次注册失败的错误码（1409 = 被占用）。
  int? get lastErrorCode => _lastErrorCode;

  HotkeyOption get desiredOption => optionById(_desiredId);

  HotkeyOption? get activeOption =>
      _activeId == null ? null : optionById(_activeId!);

  /// 按 id 取预置项；找不到时回退到第一个（兼容旧配置里的脏数据）。
  static HotkeyOption optionById(String id) => presetHotkeys.firstWhere(
    (option) => option.id == id,
    orElse: () => presetHotkeys.first,
  );

  static HotkeyRegistrar _defaultRegistrar() => Platform.isWindows
      ? _WindowsHotkeyRegistrar()
      : _PluginHotkeyRegistrar();

  /// 启动时调用：读取配置 → 注册（Windows 上失败则自动降级）。
  Future<HotkeyStatus> init() async {
    _registrar.bind(() => onTrigger?.call());
    _desiredId = await _readSavedId();
    _status = _detectConflicts
        ? await _registerWithFallback()
        : await _registerWithoutConflictDetection();
    return _status;
  }

  /// 再探测一遍所有预设（选择器打开时用）。
  Future<List<HotkeyAvailability>> probeAll() async {
    final result = <HotkeyAvailability>[];
    for (final option in presetHotkeys) {
      if (option.id == _activeId) {
        // 自己正在用，必定“可用”。
        result.add(HotkeyAvailability(option, true));
        continue;
      }
      result.add(HotkeyAvailability(option, await _registrar.probe(option)));
    }
    return result;
  }

  /// 切换热键：先探测，注册成功后才注销旧热键。
  /// 返回 false 时当前热键保持不变。
  Future<bool> setHotkey(String id) async {
    final option = optionById(id);

    if (_activeId == option.id) {
      // 已经是当前生效的热键：只更新偏好。
      _desiredId = option.id;
      await _persist(option.id);
      return true;
    }

    if (!await _registrar.probe(option)) {
      _lastErrorCode = 1409;
      AppLogger.instance.log('[Hotkey] ${option.label} 已被占用，保持原热键');
      return false;
    }

    final result = await _registrar.register(option);
    if (!result.ok) {
      _lastErrorCode = result.errorCode;
      AppLogger.instance.log(
        '[Hotkey] 切换 ${option.label} 失败，error=${result.errorCode}',
      );
      return false;
    }

    final previous = _activeId;
    _activeId = option.id;
    _desiredId = option.id;
    _lastErrorCode = null;
    if (_detectConflicts) {
      _status = HotkeyStatus.registered;
    }
    if (previous != null && previous != option.id) {
      await _registrar.unregister(optionById(previous));
    }
    await _persist(option.id);
    AppLogger.instance.log('[Hotkey] 已切换为 ${option.label}');
    return true;
  }

  /// 冲突降级后，把当前临时热键固化为用户偏好。
  Future<void> adoptActiveAsDesired() async {
    final active = _activeId;
    if (active == null) return;
    _desiredId = active;
    if (_status == HotkeyStatus.fallback) {
      _status = HotkeyStatus.registered;
    }
    await _persist(active);
    AppLogger.instance.log('[Hotkey] 固定使用 $active');
  }

  /// 这个“期望热键”的冲突提示是否已经被用户忽略过。
  Future<bool> isConflictAcknowledged() async {
    try {
      final acknowledged = await _store.read(_conflictAckKey);
      return acknowledged != null && acknowledged == _desiredId;
    } catch (_) {
      return false;
    }
  }

  /// 记录“暂不设置”，同一个热键不再重复弹窗。
  Future<void> acknowledgeConflict() async {
    try {
      await _store.write(_conflictAckKey, _desiredId);
    } catch (_) {}
  }

  /// 注销当前热键（仅在需要彻底关闭热键功能时调用）。
  Future<void> dispose() async {
    final active = _activeId;
    _activeId = null;
    if (active != null) {
      await _registrar.unregister(optionById(active));
    }
  }

  // ===== 内部实现 =====

  Future<HotkeyStatus> _registerWithoutConflictDetection() async {
    final result = await _registrar.register(desiredOption);
    if (!result.ok) {
      _lastErrorCode = result.errorCode;
      _activeId = null;
      return HotkeyStatus.unsupported;
    }
    _activeId = _desiredId;
    return HotkeyStatus.unsupported;
  }

  /// 先尝试用户的热键，失败按预设顺序降级；全部失败才算不可用。
  Future<HotkeyStatus> _registerWithFallback() async {
    final candidates = <HotkeyOption>[
      desiredOption,
      ...presetHotkeys.where((option) => option.id != _desiredId),
    ];

    for (final option in candidates) {
      final result = await _registrar.register(option);
      if (result.ok) {
        _activeId = option.id;
        _lastErrorCode = null;
        final fellBack = option.id != _desiredId;
        AppLogger.instance.log(
          fellBack
              ? '[Hotkey] ${desiredOption.label} 被占用，已自动降级为 ${option.label}'
              : '[Hotkey] 已注册 ${option.label}',
        );
        return fellBack ? HotkeyStatus.fallback : HotkeyStatus.registered;
      }
      _lastErrorCode = result.errorCode;
      AppLogger.instance.log(
        '[Hotkey] 注册 ${option.label} 失败，error=${result.errorCode}',
      );
    }

    _activeId = null;
    AppLogger.instance.log('[Hotkey] 所有预置热键都被占用，截图热键不可用');
    return HotkeyStatus.allUnavailable;
  }

  /// 写入偏好；写失败不影响已经生效的热键。
  Future<void> _persist(String id) async {
    try {
      await _store.write(_hotkeyKey, id);
    } catch (_) {}
  }

  Future<String> _readSavedId() async {
    try {
      final saved = await _store.read(_hotkeyKey);
      if (saved != null && presetHotkeys.any((option) => option.id == saved)) {
        return saved;
      }
    } catch (_) {}
    return defaultHotkeyId;
  }
}

/// Windows：走自建原生通道（能得到真实的注册结果和错误码）。
class _WindowsHotkeyRegistrar implements HotkeyRegistrar {
  static const MethodChannel _channel = MethodChannel('com.workdiary/hotkey');

  void Function()? _onTrigger;

  /// 当前由截图功能注册的热键 id（(modifiers << 8) | vk）。
  ///
  /// 原生通道只有一个方法调用处理器，但可以同时注册多个热键；按下时原生会把
  /// id 一起回传。靠这个字段区分"这次按下的是截图热键"还是别的功能的热键。
  int? _activeHotkeyId;

  @override
  void bind(void Function() onTrigger) {
    _onTrigger = onTrigger;
    _channel.setMethodCallHandler((MethodCall call) async {
      if (call.method != 'onHotkey') return;
      final raw = call.arguments;
      final hotkeyId = raw is int ? raw : null;
      // id 缺失（旧版原生）或正好是截图热键：交给截图功能；
      // 其余 id 交给 HotkeyRouter（快速录入等其它全局热键）。
      if (hotkeyId == null || hotkeyId == _activeHotkeyId) {
        _onTrigger?.call();
        return;
      }
      HotkeyRouter.dispatch(hotkeyId);
    });
  }

  @override
  Future<HotkeyRegisterResult> register(HotkeyOption option) async {
    try {
      final result = await _channel.invokeMethod<Map<Object?, Object?>>(
        'register',
        <String, dynamic>{
          'id': option.windowsId,
          'vk': option.vk,
          'modifiers': option.winModifiers,
        },
      );
      final ok = result?['ok'] == true;
      final error = result?['error'];
      if (ok) _activeHotkeyId = option.windowsId;
      return HotkeyRegisterResult(ok, error is int ? error : null);
    } catch (e, st) {
      AppLogger.instance.error('HotkeyChannel.register', e, st);
      return const HotkeyRegisterResult(false);
    }
  }

  @override
  Future<void> unregister(HotkeyOption option) async {
    try {
      await _channel.invokeMethod<bool>('unregister', <String, dynamic>{
        'id': option.windowsId,
      });
    } catch (e, st) {
      AppLogger.instance.error('HotkeyChannel.unregister', e, st);
    }
    if (_activeHotkeyId == option.windowsId) _activeHotkeyId = null;
  }

  @override
  Future<bool> probe(HotkeyOption option) async {
    try {
      final result = await _channel.invokeMethod<bool>('probe', <String, dynamic>{
        'vk': option.vk,
        'modifiers': option.winModifiers,
      });
      return result ?? false;
    } catch (e, st) {
      AppLogger.instance.error('HotkeyChannel.probe', e, st);
      return false;
    }
  }
}

/// 非 Windows：沿用 hotkey_manager（该插件无法报告注册失败）。
class _PluginHotkeyRegistrar implements HotkeyRegistrar {
  void Function()? _onTrigger;

  /// 当前由本类注册的热键 id。
  ///
  /// hotkey_manager 同一时间只保留一个全局热键，[register] 内部会先
  /// unregisterAll；因此注销旧的之前要确认它不是刚注册的那个，
  /// 否则会把新热键一起注销掉。
  String? _activeOptionId;

  @override
  void bind(void Function() onTrigger) {
    _onTrigger = onTrigger;
  }

  @override
  Future<HotkeyRegisterResult> register(HotkeyOption option) async {
    try {
      await HotKeyManager.instance.unregisterAll();
      _activeOptionId = null;
      final hotKey = HotKey(
        key: option.key,
        modifiers: option.modifiers,
        scope: HotKeyScope.system,
      );
      await HotKeyManager.instance.register(
        hotKey,
        keyDownHandler: (_) => _onTrigger?.call(),
      );
      _activeOptionId = option.id;
      return const HotkeyRegisterResult(true);
    } catch (e, st) {
      AppLogger.instance.error('HotkeyManager.register', e, st);
      _activeOptionId = null;
      return const HotkeyRegisterResult(false);
    }
  }

  @override
  Future<void> unregister(HotkeyOption option) async {
    if (_activeOptionId != option.id) return;
    try {
      await HotKeyManager.instance.unregisterAll();
    } catch (_) {}
    _activeOptionId = null;
  }

  @override
  Future<bool> probe(HotkeyOption option) async => true;
}
