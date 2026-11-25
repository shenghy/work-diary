import 'dart:io';

/// Windows 开机自启管理：通过 HKCU\...\Run 注册表项实现。
///
/// 相比旧实现有三点不同：
/// 1. 写入的路径带引号（安装目录含空格，如 `C:\Program Files\...`，不加引号时
///    CreateProcess 解析命令行会有歧义，可能启动失败）；
/// 2. 附带 `--hidden`，开机时静默启动到托盘，不弹窗抢焦点；
/// 3. 状态缓存在内存里，菜单渲染不再同步起一个 `reg.exe`（旧实现用
///    `Process.runSync`，会阻塞 UI 线程，慢盘/杀软环境下能卡住几百毫秒）。
class AutoStartService {
  static const String _runKey =
      r'HKCU\Software\Microsoft\Windows\CurrentVersion\Run';
  static const String _valueName = 'WorkDiary';

  /// 开机自启时附加的参数：静默启动到托盘。
  static const String startupFlag = '--hidden';

  static bool _enabled = false;
  static String? _registeredCommand;

  /// 当前 exe 的绝对路径（开机自启指向此路径）。
  static String get exePath => Platform.resolvedExecutable;

  /// 期望写入注册表的命令行。
  static String get _desiredCommand => '"$exePath" $startupFlag';

  /// 启动时调用一次：读取注册表并缓存状态。失败按“未开启”处理。
  static Future<void> load() async {
    _registeredCommand = await _readCommand();
    _enabled = _registeredCommand != null;
  }

  /// 是否已开启开机自启（同步读取缓存，供 UI 直接使用）。
  static bool get isEnabled => _enabled;

  /// 启动时修复：安装目录被移动过（注册表里还是旧路径）就重写一次。
  static Future<void> ensureCurrent() async {
    if (!_enabled) return;
    if (_registeredCommand == _desiredCommand) return;
    await enable();
  }

  /// 开启开机自启（已存在时覆盖为当前路径）。
  static Future<bool> enable() async {
    try {
      final result = await Process.run('reg', [
        'add',
        _runKey,
        '/v',
        _valueName,
        '/t',
        'REG_SZ',
        '/d',
        _desiredCommand,
        '/f',
      ]);
      final ok = result.exitCode == 0;
      if (ok) {
        _enabled = true;
        _registeredCommand = _desiredCommand;
      }
      return ok;
    } catch (_) {
      return false;
    }
  }

  /// 关闭开机自启。
  static Future<bool> disable() async {
    try {
      final result = await Process.run('reg', [
        'delete',
        _runKey,
        '/v',
        _valueName,
        '/f',
      ]);
      // 值本来就不存在（exitCode 1）也算“已关闭”。
      final ok = result.exitCode == 0 || !(await _isRegistered());
      if (ok) {
        _enabled = false;
        _registeredCommand = null;
      }
      return ok;
    } catch (_) {
      return false;
    }
  }

  /// 切换开机自启状态，返回切换后的状态。
  static Future<bool> toggle() async {
    if (_enabled) {
      await disable();
    } else {
      await enable();
    }
    return _enabled;
  }

  static Future<bool> _isRegistered() async =>
      (await _readCommand()) != null;

  /// 读取 Run 项里当前写入的命令行；不存在或读取失败返回 null。
  static Future<String?> _readCommand() async {
    try {
      final result = await Process.run('reg', [
        'query',
        _runKey,
        '/v',
        _valueName,
      ]);
      if (result.exitCode != 0) return null;
      final stdout = result.stdout.toString();
      for (final line in stdout.split(RegExp(r'\r?\n'))) {
        final trimmed = line.trim();
        if (!trimmed.startsWith(_valueName)) continue;
        // 形如：WorkDiary    REG_SZ    "C:\...\work_diary_app.exe" --hidden
        final match = RegExp(r'REG_SZ\s+(.*)$').firstMatch(trimmed);
        if (match != null) {
          return match.group(1)?.trim();
        }
      }
      return null;
    } catch (_) {
      return null;
    }
  }
}
