import 'package:flutter/foundation.dart';
import 'package:hive/hive.dart';

/// 动态背景开关。
///
/// 背景动画由 [AuroraBackground] 自己驱动，这里只负责“开/关”状态和持久化，
/// 让设置菜单和背景层共用一个 ValueNotifier，不需要把状态一路传进 builder。
class AmbientMotion {
  const AmbientMotion._();

  static final ValueNotifier<bool> enabled = ValueNotifier<bool>(true);

  static bool _loaded = false;

  /// 在 Hive 的 settings box 打开之后调用一次。
  static void init() {
    if (_loaded) return;
    _loaded = true;
    try {
      enabled.value = Hive.box('settings')
          .get('ambient_motion', defaultValue: true) as bool;
    } catch (_) {
      // 读不到就用默认值，不影响启动。
    }
  }

  static void setEnabled(bool value) {
    if (enabled.value == value) return;
    enabled.value = value;
    try {
      Hive.box('settings').put('ambient_motion', value);
    } catch (_) {}
  }
}
