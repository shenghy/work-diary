import 'dart:io' show Platform;
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:window_manager/window_manager.dart';
import 'screens/home_screen.dart';
import 'services/app_theme.dart';
import 'services/auth_service.dart';
import 'services/ambient_motion.dart';
import 'services/app_lifecycle.dart';
import 'services/app_logger.dart';
import 'services/bubble_service.dart';
import 'services/hotkey_service.dart';
import 'services/quick_capture_hotkey.dart';
import 'services/upgrade_service.dart';
import 'database/hive_bootstrap.dart';
import 'services/device_identity.dart';
import 'theme/glass_palette.dart';
import 'widgets/aurora_background.dart';
import 'widgets/title_bar.dart';

void main(List<String> args) async {
  WidgetsFlutterBinding.ensureInitialized();
  UpgradeService.instance.launchArguments = List.unmodifiable(args);
  // window_manager 必须在 runApp 前初始化
  await windowManager.ensureInitialized();

  // 初始化全局日志（必须最早，后续所有错误都能记录）
  await AppLogger.instance.init();
  // 捕获 Flutter 框架未处理异常
  FlutterError.onError = (details) {
    AppLogger.instance.error('FlutterError', details.exception, details.stack);
  };
  // 捕获 Dart 全局未处理异常
  PlatformDispatcher.instance.onError = (error, stack) {
    AppLogger.instance.error('Uncaught', error, stack);
    return true;
  };

  // 单实例由原生层拦截（windows/runner/main.cpp：命名互斥体 + 广播消息），
  // 第二个实例在这里之前就已经退出，Dart 侧不需要再做检查。
  await HiveBootstrap.ensureInitialized();
  await Hive.openBox('settings'); // 主页和窗口初始化之前打开，消除启动竞态。
  await DeviceIdentity.init(); // 附件中转要认设备，必须在同步起来之前有稳定 id
  AmbientMotion.init();
  AppTheme.init(); // 恢复深浅外观（默认跟随系统）
  await AuthService.init(); // 恢复登录状态
  // 初始化全局截图热键（注册失败自动降级提示，不影响使用）
  try {
    await HotkeyService.instance.init();
  } catch (_) {}
  // 全局快速录入热键（Ctrl+Alt+N）：与截图热键共用原生通道，按 id 分发
  try {
    await QuickCaptureHotkey.instance.init();
  } catch (_) {}
  runApp(const MyApp());
  // 窗口创建后初始化：关闭拦截 + 系统托盘 + 开机自启（失败不影响使用）
  try {
    await AppLifecycle.instance.init();
  } catch (_) {}
  // 桌面悬浮气泡：最小化 / 10 分钟不在前台时显示可拖拽气泡（Windows）
  // 开机自启走的是 --hidden（主窗口不显示），此时要主动把气泡放到桌面上。
  if (Platform.isWindows) {
    try {
      BubbleService.instance.init(startHidden: args.contains('--hidden'));
    } catch (_) {}
  }
}

/// 全局主题：一份 ThemeData 绑一档令牌（深色 / 浅色）。
///
/// 单独抽成函数，测试可以直接断言主题配置（比如按钮光标），
/// 不用为了拿主题去启动整个 HomeScreen。
ThemeData buildAppTheme(GlassPalette g) {
  // 当前 Flutter 版本里 Material 按钮默认的鼠标光标是箭头而不是小手，
  // 这里统一声明一次；WidgetStateMouseCursor.clickable 自带"禁用时回到箭头"。
  const clickable = ButtonStyle(mouseCursor: WidgetStateMouseCursor.clickable);
  return ThemeData(
    colorScheme: ColorScheme.fromSeed(
      seedColor: g.accent,
      brightness: g.isLight ? Brightness.light : Brightness.dark,
    ),
    useMaterial3: true,
    // 登录页这类不走极光底板的页面用的实色底。
    scaffoldBackgroundColor: g.bgBottom,
    fontFamily: 'AlibabaPuHuiTi',
    extensions: [g],
    textButtonTheme: const TextButtonThemeData(style: clickable),
    filledButtonTheme: const FilledButtonThemeData(style: clickable),
    outlinedButtonTheme: const OutlinedButtonThemeData(style: clickable),
    elevatedButtonTheme: const ElevatedButtonThemeData(style: clickable),
    iconButtonTheme: const IconButtonThemeData(style: clickable),
    popupMenuTheme: PopupMenuThemeData(
      color: g.surface,
      labelTextStyle: WidgetStateTextStyle.resolveWith(
        (states) => TextStyle(
          color: g.menuText,
          fontSize: 13,
          fontWeight: FontWeight.w500,
        ),
      ),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.all(Radius.circular(12)),
      ),
    ),
  );
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<ThemeMode>(
      valueListenable: AppTheme.mode,
      builder: (context, themeMode, _) => MaterialApp(
        title: '极简工作日记',
        debugShowCheckedModeBanner: false,
        locale: const Locale('zh', 'CN'),
        localizationsDelegates: const [
          GlobalMaterialLocalizations.delegate,
          GlobalWidgetsLocalizations.delegate,
          GlobalCupertinoLocalizations.delegate,
        ],
        supportedLocales: const [
          Locale('zh', 'CN'),
          Locale('en', 'US'),
        ],
        theme: buildAppTheme(GlassPalette.light),
        darkTheme: buildAppTheme(GlassPalette.dark),
        themeMode: themeMode,
        // 整窗是自定义绘制 + 一次 backdrop blur，插值期间会渲出半深半浅的糊色，
        // 所以切档直接到位。
        themeAnimationDuration: Duration.zero,
        // Windows 上窗口没有系统标题栏了，这里给所有页面统一加一条自绘标题栏。
        // 放在 builder 里而不是 HomeScreen 里：登录页、主页共用一条，切换页面不闪。
        // 底板（缓慢流动的色晕）也放在这一层，标题栏和页面内容共用同一块背景。
        builder: (context, child) {
          final content = child ?? const SizedBox.shrink();
          return Stack(
            children: [
              const Positioned.fill(child: AuroraBackground()),
              // 全窗只做这一层玻璃：模糊一次，下面的所有卡片只负责染色。
              const Positioned.fill(child: WindowGlass()),
              Positioned.fill(
                child: Column(
                  children: [
                    if (Platform.isWindows) const AppTitleBar(),
                    Expanded(child: content),
                  ],
                ),
              ),
            ],
          );
        },
        home: const HomeScreen(),
      ),
    );
  }
}

/// 全窗玻璃层：把 Aurora 底板整体模糊，再压一层 scrim。
///
/// 只做一次模糊，列表里每一张卡都不再各自开 BackdropFilter——
/// 这是 Windows 上最稳的做法（多张有界模糊会掉帧，且有已知渲染问题）。
class WindowGlass extends StatelessWidget {
  const WindowGlass();

  @override
  Widget build(BuildContext context) {
    final g = GlassPalette.of(context);
    return ClipRect(
      child: BackdropFilter(
        filter: ImageFilter.blur(
          sigmaX: 24,
          sigmaY: 24,
          tileMode: TileMode.decal,
        ),
        child: DecoratedBox(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [g.glassTop, g.glassMid, g.glassBottom],
              stops: const [0, 0.55, 1],
            ),
          ),
        ),
      ),
    );
  }
}
