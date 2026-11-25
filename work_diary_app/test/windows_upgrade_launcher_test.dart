import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:work_diary_app/services/windows_upgrade_launcher.dart';

void main() {
  test('PowerShell helper actually executes and writes ready marker', () async {
    if (!Platform.isWindows) return;
    final dir = await Directory.systemTemp.createTemp('workdiary-launch-test-');
    try {
      final script = File('${dir.path}/helper.ps1');
      final config = File('${dir.path}/config.json');
      final ready = File('${dir.path}/ready');
      await script.writeAsString(r'''param([string]$ConfigPath)
Set-Content -LiteralPath (Join-Path (Split-Path -Parent $ConfigPath) 'ready') -Value 'ready'
''');
      await config.writeAsString('{}');
      final process = await launchWindowsUpgradeHelper(
        scriptPath: script.path,
        configPath: config.path,
        workingDirectory: dir.path,
      );
      expect(await process.exitCode.timeout(const Duration(seconds: 10)), 0);
      expect(await ready.readAsString(), contains('ready'));
    } finally {
      await dir.delete(recursive: true);
    }
  });
}
