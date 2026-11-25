import 'package:flutter/material.dart';
import 'package:hive/hive.dart';

/// 深浅外观开关。
///
/// 状态放在这个 ValueNotifier 上，让 MaterialApp 和设置菜单共用一份，
/// 不用把主题状态一路往下传；持久化沿用 AmbientMotion 的写法。
class AppTheme {
  const AppTheme._();

  /// 默认跟随系统：Windows 注册表的 UseLightTheme 决定第一屏是深是浅。
  static final ValueNotifier<ThemeMode> mode =
      ValueNotifier<ThemeMode>(ThemeMode.system);

  static bool _loaded = false;

  /// 在 Hive 的 settings box 打开之后调用一次。
  static void init() {
    if (_loaded) return;
    _loaded = true;
    try {
      final saved = Hive.box('settings')
          .get('theme_mode', defaultValue: 'system') as String;
      mode.value = _decode(saved);
    } catch (_) {
      // 读不到就用默认值，不影响启动。
    }
  }

  static void setMode(ThemeMode next) {
    if (mode.value == next) return;
    mode.value = next;
    try {
      Hive.box('settings').put('theme_mode', _encode(next));
    } catch (_) {}
  }

  /// 存字符串而不是 index：以后加档位不会让老用户的存档错位。
  static ThemeMode _decode(String v) {
    switch (v) {
      case 'light':
        return ThemeMode.light;
      case 'dark':
        return ThemeMode.dark;
      default:
        return ThemeMode.system;
    }
  }

  static String _encode(ThemeMode m) {
    switch (m) {
      case ThemeMode.light:
        return 'light';
      case ThemeMode.dark:
        return 'dark';
      case ThemeMode.system:
        return 'system';
    }
  }
}
