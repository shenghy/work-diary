import 'package:flutter/material.dart';

import '../services/app_theme.dart';
import '../theme/glass_palette.dart';

/// 设置面板里的深浅外观分段开关：浅 / 随 / 深。
///
/// 三态而不是开关两态，因为「跟随系统」既不是浅色也不是深色，砍掉任何一档都会丢功能。
/// 选中态是一块实色小胶囊，换档时平移过去；状态读写 [AppTheme.mode]，
/// 与主题令牌、持久化共用一份。
class ThemeModeSwitch extends StatefulWidget {
  const ThemeModeSwitch({super.key});

  @override
  State<ThemeModeSwitch> createState() => _ThemeModeSwitchState();
}

class _ThemeModeSwitchState extends State<ThemeModeSwitch> {
  static const double _height = 26;
  static const double _padding = 2;
  static const double _border = 0.5;

  // 26 总高 - 上下各 2 内边距 - 上下各 0.5 描边 = 21。
  static const double _innerHeight = _height - _padding * 2 - _border * 2;

  // 一段要装下 12 的图标 + 3 的间距 + 10.5 的单字，34 是最窄不挤的宽度。
  static const double _segmentWidth = 34;

  static const List<ThemeMode> _modes = [
    ThemeMode.light,
    ThemeMode.system,
    ThemeMode.dark,
  ];

  int? _hovered;

  @override
  Widget build(BuildContext context) {
    final g = GlassPalette.of(context);
    return ValueListenableBuilder<ThemeMode>(
      valueListenable: AppTheme.mode,
      builder: (context, mode, _) {
        final selected = _modes.indexOf(mode);
        return Container(
          height: _height,
          padding: const EdgeInsets.all(_padding),
          decoration: BoxDecoration(
            color: g.fieldBg,
            borderRadius: BorderRadius.circular(_height / 2),
            border: Border.all(color: g.fieldBorder, width: _border),
          ),
          // 描边画在内边距之外，内容宽度单独给，否则 0.5×2 会挤掉 1px 导致溢出。
          child: SizedBox(
            width: _segmentWidth * _modes.length,
            child: Stack(
              children: [
                AnimatedPositioned(
                  duration: const Duration(milliseconds: 260),
                  curve: Curves.easeOutCubic,
                  left: selected * _segmentWidth,
                  top: 0,
                  width: _segmentWidth,
                  height: _innerHeight,
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      color: g.accent,
                      borderRadius: BorderRadius.circular(_innerHeight / 2),
                    ),
                  ),
                ),
                Row(
                  children: [
                    for (var i = 0; i < _modes.length; i++)
                      _buildSegment(g, i, selected: i == selected),
                  ],
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _buildSegment(GlassPalette g, int index, {required bool selected}) {
    final mode = _modes[index];
    final hovered = _hovered == index && !selected;
    final foreground = switch ((selected, hovered)) {
      (true, _) => Colors.white,
      (false, true) => g.inkSecondary,
      // 浅色档的 inkTertiary 在白底上偏重，压一层透明度更接近样张的淡灰。
      (false, false) =>
        g.isLight ? g.inkSecondary.withAlpha(150) : g.inkTertiary,
    };

    return Semantics(
      button: true,
      selected: selected,
      label: _tooltip(mode),
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        onEnter: (_) => setState(() => _hovered = index),
        onExit: (_) {
          if (_hovered == index) setState(() => _hovered = null);
        },
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: () => AppTheme.setMode(mode),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 180),
            width: _segmentWidth,
            height: _innerHeight,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: hovered
                  ? g.decoInk.withAlpha(g.isLight ? 13 : 20)
                  : Colors.transparent,
              borderRadius: BorderRadius.circular(_innerHeight / 2),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(_icon(mode), size: 12, color: foreground),
                const SizedBox(width: 3),
                Text(
                  _label(mode),
                  style: TextStyle(
                    fontSize: 10.5,
                    height: 1.0,
                    fontWeight: selected ? FontWeight.w500 : FontWeight.w400,
                    color: foreground,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  static String _label(ThemeMode mode) {
    switch (mode) {
      case ThemeMode.light:
        return '浅';
      case ThemeMode.dark:
        return '深';
      case ThemeMode.system:
        return '随';
    }
  }

  static String _tooltip(ThemeMode mode) {
    switch (mode) {
      case ThemeMode.light:
        return '浅色';
      case ThemeMode.dark:
        return '深色';
      case ThemeMode.system:
        return '跟随系统';
    }
  }

  static IconData _icon(ThemeMode mode) {
    switch (mode) {
      case ThemeMode.light:
        return Icons.light_mode_outlined;
      case ThemeMode.dark:
        return Icons.dark_mode_outlined;
      case ThemeMode.system:
        return Icons.desktop_windows_outlined;
    }
  }
}
