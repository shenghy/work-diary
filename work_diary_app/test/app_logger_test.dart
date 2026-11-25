import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
// ignore: depend_on_referenced_packages
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:work_diary_app/services/app_logger.dart';

class _TestPaths extends PathProviderPlatform {
  _TestPaths(this.path);
  final String path;

  @override
  Future<String?> getApplicationSupportPath() async => path;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('rapid consecutive log writes do not bind the sink twice', () async {
    final dir = await Directory.systemTemp.createTemp('workdiary-log-test-');
    final original = PathProviderPlatform.instance;
    PathProviderPlatform.instance = _TestPaths(dir.path);
    try {
      final logger = AppLogger.instance;
      await logger.init();
      for (var i = 0; i < 20; i++) {
        logger.log('rapid-line-$i');
      }
      final content = await File('${dir.path}/app.log').readAsString();
      for (var i = 0; i < 20; i++) {
        expect(content, contains('rapid-line-$i'));
      }
    } finally {
      PathProviderPlatform.instance = original;
    }
  });
}
