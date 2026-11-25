import 'dart:async';
import 'dart:ui';
import 'dart:io';
import 'dart:ffi';
import 'package:hive/hive.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:window_manager/window_manager.dart';
import 'package:tray_manager/tray_manager.dart';

import '../database/hive_utils.dart';
import 'auto_start_service.dart';
import 'app_logger.dart';
import 'sync_websocket.dart';

/// 托盘动作事件（供 home_screen 监听）
class TrayActions {
  /// 记一笔：打开备忘编辑器
  static const String quickMemo = 'quick_memo';

  /// 记任务：打开新建任务对话框
  static const String quickTask = 'quick_task';

  static const String showWindow = 'show';
  static const String quit = 'quit';
  static const String windowBlur = 'window_blur';
}

/// 应用生命周期管理：系统托盘 + 窗口控制 + 开机自启
///
/// - 最小化/关闭窗口 → 隐藏到系统托盘（不退出）
/// - 托盘左键 → 显示主窗口
/// - 托盘右键菜单 → 记一笔 / 打开主窗口 / 退出软件
/// - 只有点击「退出软件」才真正退出
///
/// 单实例保护在原生层完成（windows/runner/main.cpp 的命名互斥体 +
/// 广播消息），Dart 侧不再监听端口，也就不存在固定端口被占用导致
/// 应用静默退出的问题。
class AppLifecycle with WindowListener, TrayListener {
  static final AppLifecycle instance = AppLifecycle._();
  AppLifecycle._();

  final StreamController<String> _actionCtrl =
      StreamController<String>.broadcast();
  Stream<String> get onAction => _actionCtrl.stream;

  bool _initialized = false;

  /// 托盘是否初始化成功。失败时必须放弃"关闭即隐藏"，否则窗口会被隐藏
  /// 而托盘里没有图标，用户只能去任务管理器结束进程（应用"隐身"）。
  bool _trayReady = false;

  /// 恢复窗口过程中为 true，防止 onWindowMinimize 又把窗口 hide 掉
  bool _restoring = false;

  /// 初始化（在 main.dart 中调用，需先 windowManager.ensureInitialized）
  Future<void> init() async {
    if (_initialized) return;

    _initialized = true;

    // 窗口事件监听 + 关闭拦截
    try {
      windowManager.addListener(this);
      await windowManager.setPreventClose(true);
    } catch (_) {}

    // 3. 系统托盘（每步独立 try-catch，避免一步失败全盘崩）
    try {
      trayManager.addListener(this);
    } catch (_) {}
    try {
      await trayManager.setIcon('assets/icons/tray.ico');
      _trayReady = true;
    } catch (e, st) {
      AppLogger.instance.error('托盘图标初始化失败', e, st);
    }
    try {
      await trayManager.setToolTip('极简工作日记');
    } catch (_) {}
    if (!_trayReady) {
      // 没有托盘图标就不能拦截关闭：退回"点关闭即退出"，
      // 否则窗口消失且无处可恢复。
      try {
        await windowManager.setPreventClose(false);
      } catch (_) {}
      AppLogger.instance.log('托盘不可用，已回退为关闭即退出');
    }

    // 窗口标题栏带版本号（如：极简工作日记 v1.0.0）
    try {
      final info = await PackageInfo.fromPlatform();
      await windowManager.setTitle('极简工作日记 v${info.version}');
    } catch (_) {}

    try {
      await _buildTrayMenu();
    } catch (_) {}

    // 4. 恢复上次窗口位置和大小
    try {
      await _restoreWindowBounds();
    } catch (_) {}

    // 5. 开机自启：首次运行默认开启，之后完全尊重用户在设置里的开关
    //    （旧实现每次启动都强制写回注册表，用户关掉后下次启动又会被打开）
    await _initAutoStart();
  }

  /// 首次运行默认写入开机自启；之后只做路径修复，不再强制打开。
  Future<void> _initAutoStart() async {
    if (!Platform.isWindows) return;
    try {
      await AutoStartService.load();
      final box = await Hive.openBox('settings');
      final applied = box.get('autostart_default_applied', defaultValue: false);
      if (applied != true) {
        // 老版本写的是无引号、无 --hidden 的路径，这里顺手修正一次。
        await AutoStartService.enable();
        await box.put('autostart_default_applied', true);
        return;
      }
      await AutoStartService.ensureCurrent();
    } catch (_) {}
  }

  Future<void> _buildTrayMenu() async {
    final menu = Menu(
      items: [
        MenuItem(label: '记一笔', onClick: (_) => quickAddMemo()),
        MenuItem(label: '记任务', onClick: (_) => quickAddTask()),
        MenuItem(label: '打开主窗口', onClick: (_) => showWindow()),
        MenuItem.separator(),
        MenuItem(label: '退出软件', onClick: (_) => quit()),
      ],
    );
    await trayManager.setContextMenu(menu);
  }

  // ================= 公共操作 =================

  /// 显示主窗口并聚焦
  Future<void> showWindow() async {
    _restoring = true;
    await windowManager.restore(); // 先从最小化状态恢复，否则 show() 只让窗口可见但仍最小化
    await windowManager.show();
    await windowManager.focus();
    // 防异常：窗口位置在屏幕外（如 -32000 幽灵位置 / 未激活的第二屏）时，移回主屏可见区域
    try {
      final bounds = await windowManager.getBounds();
      if (_windowOffScreen(bounds.left, bounds.top)) {
        await windowManager.setBounds(
          Rect.fromLTWH(150, 150, bounds.width, bounds.height),
        );
      }
    } catch (_) {}
    _restoring = false;
  }

  /// 隐藏到托盘
  Future<void> hideToTray() async {
    await windowManager.hide();
  }

  /// 原生层（windows/runner/window_state.cpp）保存的窗口几何文件。
  ///
  /// 窗口尺寸/位置记忆已经下沉到原生层：创建窗口前读取、移动缩放后写盘，
  /// 这样首帧就是上次的样子，升级重启 / 强杀进程也不会丢。这里仅在升级到
  /// 本版本后的第一次启动（原生文件还不存在）时，把旧的 Hive 记录迁移过去。
  bool _nativeWindowStateExists() {
    try {
      final appData = Platform.environment['APPDATA'];
      if (appData == null || appData.isEmpty) return false;
      return File(
        '$appData\\jspang.com\\极简工作日记\\window_state.ini',
      ).existsSync();
    } catch (_) {
      return false;
    }
  }

  /// 启动时恢复上次窗口位置和大小（仅老版本 Hive 数据的一次性迁移）
  Future<void> _restoreWindowBounds() async {
    try {
      if (_nativeWindowStateExists()) return;
      final box = await Hive.openBox('settings');
      final x = box.get('window_x');
      final y = box.get('window_y');
      final w = box.get('window_w');
      final h = box.get('window_h');
      if (x == null || y == null || w == null || h == null) return;
      final width = (w as num).toDouble();
      final height = (h as num).toDouble();
      if (width < 200 || height < 200) return;

      final winLeft = (x as num).toDouble();
      final winTop = (y as num).toDouble();
      // 防异常：坐标明显在屏幕外（如 -32000 幽灵位置 / 未激活的第二屏）时忽略，用默认位置
      if (_windowOffScreen(winLeft, winTop)) return;
      await windowManager.setBounds(
        Rect.fromLTWH(winLeft, winTop, width, height),
      );
    } catch (_) {}
  }

  /// 缓存的 GetSystemMetrics。
  ///
  /// 旧实现每次调用都 DynamicLibrary.open('user32.dll') 且从不 close()，
  /// 托盘点击/每次提醒都会执行一次，句柄引用会持续增长。
  static final int Function(int) _getSystemMetrics = _loadGetSystemMetrics();

  static int Function(int) _loadGetSystemMetrics() {
    try {
      return DynamicLibrary.open('user32.dll')
          .lookupFunction<Int32 Function(Int32), int Function(int)>(
            'GetSystemMetrics',
          );
    } catch (_) {
      return (int _) => 0;
    }
  }

  static double _devicePixelRatio() {
    try {
      final views = PlatformDispatcher.instance.views;
      if (views.isEmpty) return 1;
      final ratio = views.first.devicePixelRatio;
      return ratio <= 0 ? 1 : ratio;
    } catch (_) {
      return 1;
    }
  }

  /// 判断窗口坐标是否完全不在当前任意屏幕的可视区域内（虚拟屏幕范围）
  /// 覆盖两种异常：-32000 幽灵位置、窗口落在未激活/断开的显示器上
  bool _windowOffScreen(double left, double top) {
    try {
      // GetSystemMetrics 返回物理像素，windowManager.getBounds 返回逻辑像素，
      // 高 DPI 下直接比较会误判，这里统一换算成逻辑像素。
      final dpr = _devicePixelRatio();
      final vLeft = _getSystemMetrics(76) / dpr; // SM_XVIRTUALSCREEN
      final vTop = _getSystemMetrics(77) / dpr; // SM_YVIRTUALSCREEN
      final vW = _getSystemMetrics(78) / dpr; // SM_CXVIRTUALSCREEN
      final vH = _getSystemMetrics(79) / dpr; // SM_CYVIRTUALSCREEN
      if (vW <= 0 || vH <= 0) return false; // 取不到就保守放行
      // 窗口至少要有 100px 落在虚拟屏幕范围内才算可见
      if (left + 100 < vLeft || left > vLeft + vW - 100) return true;
      if (top + 100 < vTop || top > vTop + vH - 100) return true;
      return false;
    } catch (_) {
      // 失败时保守处理：不拦截
      return false;
    }
  }

  /// 记一笔：打开备忘编辑器（托盘菜单与气泡右键菜单共用）
  Future<void> quickAddMemo() => _quickAdd(TrayActions.quickMemo);

  /// 记任务：打开新建任务对话框
  Future<void> quickAddTask() => _quickAdd(TrayActions.quickTask);

  /// 先显示窗口再发事件：对话框在隐藏/最小化的窗口里弹出时输入框拿不到光标。
  Future<void> _quickAdd(String action) async {
    try {
      await showWindow();
    } catch (_) {}
    _actionCtrl.add(action);
  }

  /// 真正退出：清理托盘 + 销毁窗口 + 退出进程
  Future<void> quit() async {
    // 窗口几何由原生层在 WM_DESTROY 时落盘，这里只需要处理数据写盘。
    // 本地数据保存有 1 秒防抖，exit(0) 会把这段时间里的修改和未完成的同步
    // 一起丢掉（"改完任务立刻点退出"就会丢）。退出前统一 flush 一次。
    try {
      SyncWebSocket.instance.disconnect();
    } catch (_) {}
    try {
      await flushOpenHiveBoxes();
    } catch (e, st) {
      AppLogger.instance.error('退出前写盘失败', e, st);
    }
    try {
      await trayManager.destroy();
    } catch (_) {}
    try {
      await windowManager.destroy();
    } catch (_) {}
    exit(0);
  }

  // ================= WindowListener =================

  @override
  void onWindowClose() {
    if (!_trayReady) {
      // 托盘不可用：放行关闭（setPreventClose 已关闭），避免应用"隐身"
      return;
    }
    hideToTray();
  }

  @override
  void onWindowMinimize() {
    // 不再隐藏到托盘：让窗口正常最小化到任务栏，
    // 这样点任务栏图标能按 Windows 标准行为恢复，不会直接消失。
    // 隐藏到托盘只由关闭按钮（onWindowClose）触发。
  }

  /// 窗口失去焦点（用户点击了窗口外区域）：通知 home_screen 收起菜单
  @override
  void onWindowBlur() {
    _actionCtrl.add(TrayActions.windowBlur);
  }

  // ================= TrayListener =================
  // 注意：
  // 1. tray_manager 0.2.4 在 Windows 上只有 MouseDown 事件能触发，MouseUp 不触发
  // 2. 菜单项点击已通过 MenuItem.onClick 处理，不再重写 onTrayMenuItemClick，
  //    避免 tray_manager 同时调用 onClick 和 onTrayMenuItemClick 导致双重触发

  @override
  void onTrayIconMouseDown() {
    showWindow();
  }

  @override
  void onTrayIconRightMouseDown() {
    trayManager.popUpContextMenu();
  }

  // ================= 开机自启 =================
  // 具体读写见 services/auto_start_service.dart（唯一实现，避免两套逻辑互相覆盖）。
}
