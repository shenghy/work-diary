import 'dart:io';

import 'package:flutter/material.dart';
import 'package:hive/hive.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:window_manager/window_manager.dart';

import '../theme/glass_palette.dart';

/// 自绘标题栏高度。
///
/// 必须与 windows/runner/win32_window.cpp 里的 kTitleBarHeightDip 保持一致：
/// 原生侧按这个高度区分「标题栏拖动区」和「内容区」。
const double kTitleBarHeight = 40;

/// 单个窗口按钮宽度。
///
/// 必须与 win32_window.cpp 里的 kWindowButtonsWidthDip / 按钮个数一致，
/// 否则原生把点击判成「拖动窗口」，按钮就点不动了。
const double kWindowButtonWidth = 40;

/// 应用自绘标题栏（仅 Windows）。
///
/// 系统标题栏已经在原生层（WM_NCCALCSIZE）去掉，这里负责画：
/// 应用名 + 版本号 + 置顶 / 最小化 / 关闭。
///
/// 拖动、四边缩放、双击不最大化都由原生 WM_NCHITTEST 处理，这里不写手势；
/// 按钮区正好落在原生预留的右侧 120 逻辑像素里。
class AppTitleBar extends StatefulWidget {
  const AppTitleBar({super.key});

  @override
  State<AppTitleBar> createState() => _AppTitleBarState();
}

class _AppTitleBarState extends State<AppTitleBar> {
  String _version = '';
  bool _pinned = false;

  @override
  void initState() {
    super.initState();
    _restorePin();
    _loadVersion();
  }

  /// 恢复上次的置顶状态（默认不置顶）。
  void _restorePin() {
    try {
      final box = Hive.box('settings');
      _pinned = box.get('always_on_top', defaultValue: false) as bool;
      if (_pinned) {
        windowManager.setAlwaysOnTop(true);
      }
    } catch (_) {}
  }

  Future<void> _loadVersion() async {
    try {
      final info = await PackageInfo.fromPlatform();
      if (!mounted) return;
      setState(() => _version = 'v${info.version}');
    } catch (_) {}
  }

  Future<void> _togglePin() async {
    final next = !_pinned;
    setState(() => _pinned = next);
    try {
      await windowManager.setAlwaysOnTop(next);
    } catch (_) {}
    try {
      await Hive.box('settings').put('always_on_top', next);
    } catch (_) {}
  }

  Future<void> _minimize() async {
    try {
      await windowManager.minimize();
    } catch (_) {}
  }

  /// 拖动窗口。
  ///
  /// 主路径是原生逻辑：子窗口在 WM_NCHITTEST 里把标题栏区域透传给父窗口，
  /// 系统按 HTCAPTION 处理，带 Aero Snap 和原生拖动动画。
  /// 这层兜底是给「透传没生效」的情况准备的：直接把窗口交给系统拖动。
  void _startDrag() {
    try {
      windowManager.startDragging();
    } catch (_) {}
  }

  /// 走和系统关闭按钮同一条路径：window_manager 拦截 WM_CLOSE，
  /// 由 AppLifecycle 决定「隐藏到托盘」还是真的退出。
  Future<void> _close() async {
    try {
      await windowManager.close();
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    if (!Platform.isWindows) {
      return const SizedBox.shrink();
    }
    final g = GlassPalette.of(context);
    return Material(
      color: Colors.transparent,
      child: Container(
        height: kTitleBarHeight,
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [
              g.glassEdgeColor.withAlpha(14),
              g.glassEdgeColor.withAlpha(4),
            ],
          ),
          border: Border(
            bottom: BorderSide(color: g.glassEdgeColor.withAlpha(18)),
          ),
        ),
        child: Row(
          children: [
            Expanded(
              child: Listener(
                behavior: HitTestBehavior.opaque,
                onPointerDown: (_) => _startDrag(),
                child: Padding(
                  padding: const EdgeInsets.only(left: 18),
                  child: Row(
                    children: [
                      Text(
                        '极简工作日记',
                        style: TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w500,
                          color: g.ink,
                          fontFamily: 'AlibabaPuHuiTi',
                        ),
                      ),
                      if (_version.isNotEmpty) ...[
                        const SizedBox(width: 8),
                        Text(
                          _version,
                          style: TextStyle(
                            fontSize: 11,
                            color: g.inkTertiary.withAlpha(0x7D),
                            fontFamily: 'AlibabaPuHuiTi',
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              ),
            ),
            _WindowButton(
              icon: Icons.push_pin_outlined,
              activeIcon: Icons.push_pin,
              active: _pinned,
              semanticLabel: _pinned ? '取消窗口置顶' : '窗口置顶',
              onPressed: _togglePin,
            ),
            _WindowButton(
              icon: Icons.remove,
              semanticLabel: '最小化',
              onPressed: _minimize,
            ),
            _WindowButton(
              icon: Icons.close,
              semanticLabel: '关闭到托盘',
              danger: true,
              onPressed: _close,
            ),
          ],
        ),
      ),
    );
  }
}

/// 标题栏上的方形窗口按钮：悬停浅灰底，关闭键悬停变红。
class _WindowButton extends StatefulWidget {
  const _WindowButton({
    required this.icon,
    required this.onPressed,
    required this.semanticLabel,
    this.activeIcon,
    this.active = false,
    this.danger = false,
  });

  final IconData icon;
  final IconData? activeIcon;
  final bool active;
  final bool danger;
  final String semanticLabel;
  final VoidCallback onPressed;

  @override
  State<_WindowButton> createState() => _WindowButtonState();
}

class _WindowButtonState extends State<_WindowButton> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final g = GlassPalette.of(context);
    Color background = Colors.transparent;
    Color foreground =
        widget.active ? g.accentSoft : g.inkSecondary.withAlpha(0xB8);
    if (_hover) {
      if (widget.danger) {
        // Windows 关闭键的红色是平台约定，深浅两档都用同一个红。
        background = const Color(0xFFE81123);
        foreground = Colors.white;
      } else {
        background = g.glassEdgeColor.withAlpha(20);
        foreground = g.ink;
      }
    }

    return Semantics(
      label: widget.semanticLabel,
      button: true,
      child: MouseRegion(
        onEnter: (_) => setState(() => _hover = true),
        onExit: (_) => setState(() => _hover = false),
        cursor: SystemMouseCursors.basic,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: widget.onPressed,
          child: SizedBox(
            width: kWindowButtonWidth,
            height: kTitleBarHeight,
            child: Container(
              color: background,
              alignment: Alignment.center,
              child: Icon(
                widget.active && widget.activeIcon != null
                    ? widget.activeIcon
                    : widget.icon,
                size: 16,
                color: foreground,
              ),
            ),
          ),
        ),
      ),
    );
  }
}
