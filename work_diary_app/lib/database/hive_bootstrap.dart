import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:path_provider/path_provider.dart';

/// Hive 初始化入口。
///
/// 以前每个 repository 都直接调 `Hive.initFlutter()`：只要有一个晚于 main 执行，
/// 就会把已经设好的 homePath 重置回系统文档目录。统一收口到这里，只初始化一次。
///
/// `WORKDIARY_DATA_DIR` 是便携 / 隔离测试用的显式覆盖；不设置时走系统默认目录。
class HiveBootstrap {
  const HiveBootstrap._();

  static bool _initialized = false;

  /// 实际生效的数据目录（Hive box 与附件原件都在它下面）。
  static String? _dataPath;

  static Future<void> ensureInitialized() async {
    if (_initialized) return;
    final override = Platform.environment['WORKDIARY_DATA_DIR'];
    if (override != null && override.trim().isNotEmpty) {
      final dir = Directory(override);
      if (!dir.existsSync()) dir.createSync(recursive: true);
      Hive.init(override);
      _dataPath = dir.path;
    } else {
      await Hive.initFlutter();
      final docs = await getApplicationDocumentsDirectory();
      _dataPath = docs.path;
    }
    _initialized = true;
  }

  /// 数据目录：附件原件、中转缓存都放在这里，和 Hive box 同根，
  /// 这样 `WORKDIARY_DATA_DIR` 一设，双实例测试的数据与文件天然隔离。
  static Future<String> dataDir() async {
    await ensureInitialized();
    return _dataPath!;
  }

  /// 仅测试用：把数据目录钉到临时路径并标记"已初始化"。
  ///
  /// `initFlutter` 依赖 path_provider 插件，`flutter test` 的 VM 里没有，
  /// 测试只能这样注入路径（生产代码不走这里）。
  @visibleForTesting
  static Future<void> usePathForTest(String path) async {
    final dir = Directory(path);
    if (!dir.existsSync()) dir.createSync(recursive: true);
    Hive.init(path);
    _dataPath = dir.path;
    _initialized = true;
  }

  @visibleForTesting
  static void resetForTest() {
    _initialized = false;
    _dataPath = null;
  }
}
