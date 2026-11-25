import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path/path.dart' as p;
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
// Platform boundary only: all pending-file and ZIP operations use real files.
// ignore: depend_on_referenced_packages
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:work_diary_app/services/upgrade_service.dart';

class _Paths extends PathProviderPlatform {
  _Paths(this.path);
  final String path;
  @override
  Future<String?> getApplicationSupportPath() async => path;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory root;
  late PathProviderPlatform originalPaths;
  final service = UpgradeService.instance;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('workdiary-pending-test-');
    originalPaths = PathProviderPlatform.instance;
    PathProviderPlatform.instance = _Paths(root.path);
    PackageInfo.setMockInitialValues(
      appName: 'WorkDiary',
      packageName: 'work_diary_app',
      version: '1.0.6',
      buildNumber: '7',
      buildSignature: '',
    );
    await service.init();
  });
  tearDown(() async {
    PathProviderPlatform.instance = originalPaths;
    await root.delete(recursive: true);
  });

  Future<File> pending(String version, {bool validLayout = true}) async {
    final archive = Archive();
    for (final name
        in validLayout
            ? [
                'work_diary_app.exe',
                'flutter_windows.dll',
                'data/app.so',
                'data/icudtl.dat',
                'msvcp140.dll',
                'vcruntime140.dll',
                'vcruntime140_1.dll',
              ]
            : ['readme.txt']) {
      archive.addFile(ArchiveFile.string(name, 'fixture'));
    }
    final zip = File('${root.path}/work_diary_update_$version.zip');
    await zip.writeAsBytes(ZipEncoder().encode(archive));
    await File('${root.path}/upgrade_pending.json').writeAsString(
      jsonEncode({
        'version': version,
        'download_url': '/downloads/$version.zip',
        'release_notes': 'test',
        'force_update': false,
        'file_size': await zip.length(),
        'zip_path': zip.path,
      }),
    );
    return zip;
  }

  test('already installed version is not offered again', () async {
    await pending('1.0.6');
    expect(await service.restorePending(), isFalse);
    expect(await File('${root.path}/upgrade_pending.json').exists(), isFalse);
  });

  test('unrelated ZIP is rejected before offering upgrade', () async {
    await pending('1.0.7', validLayout: false);
    expect(await service.restorePending(), isFalse);
  });

  test('damaged download is rejected when restoring pending state', () async {
    final zip = await pending('1.0.7');
    await zip.writeAsString('broken');
    expect(await service.restorePending(), isFalse);
  });

  test('same-size ZIP with a wrong CRC is rejected', () async {
    final zip = await pending('1.0.7');
    final bytes = await zip.readAsBytes();
    // Corrupt the expected checksum in a central-directory header while
    // preserving the ZIP structure, file names, payload and total size.
    for (var i = 0; i < bytes.length - 20; i++) {
      if (bytes[i] == 0x50 &&
          bytes[i + 1] == 0x4b &&
          bytes[i + 2] == 0x01 &&
          bytes[i + 3] == 0x02) {
        bytes[i + 16] ^= 0xff;
        break;
      }
    }
    await zip.writeAsBytes(bytes);
    expect(await service.restorePending(), isFalse);
  });

  test('failed upgrade keeps valid ZIP available after restart', () async {
    final zip = await pending('1.0.7');
    expect(await service.restorePending(), isTrue);
    expect(p.normalize(service.downloadedZip!.path), p.normalize(zip.path));
    expect(await service.restorePending(), isTrue);
    expect(await zip.exists(), isTrue);
  });

  test('retry uses cached ZIP without another network request', () async {
    final zip = await pending('1.0.7');
    var requests = 0;
    final updater = UpgradeService(
      clientFactory: () => MockClient((request) async {
        requests++;
        return http.Response('unexpected network request', 500);
      }),
    );
    await updater.init();
    expect(await updater.restorePending(), isTrue);
    expect(await updater.downloadUpdate(), isNotNull);
    expect(await updater.downloadUpdate(), isNotNull);
    expect(requests, 0);
    expect(await zip.exists(), isTrue);
  });

  test(
    'fresh download is saved and reused after a new service starts',
    () async {
      final zip = await pending('1.0.7');
      final payload = await zip.readAsBytes();
      await zip.delete();
      await File('${root.path}/upgrade_pending.json').delete();
      var zipRequests = 0;
      final updater = UpgradeService(
        clientFactory: () => MockClient((request) async {
          if (request.url.path == '/api/version/latest') {
            return http.Response(
              jsonEncode({
                'has_update': true,
                'version': '1.0.7',
                'download_url': '/downloads/1.0.7.zip',
                'release_notes': 'test',
                'force_update': false,
                'file_size': payload.length,
                'published_at': '2026-09-23',
              }),
              200,
            );
          }
          zipRequests++;
          return http.Response.bytes(payload, 200);
        }),
      );
      await updater.init();
      expect(await updater.checkUpdate(), isTrue);
      expect(await updater.downloadUpdate(), isNotNull);
      expect(zipRequests, 1);
      final restarted = UpgradeService();
      await restarted.init();
      expect(await restarted.restorePending(), isTrue);
      expect(await restarted.downloadUpdate(), isNotNull);
      expect(zipRequests, 1);
    },
  );

  test(
    'wrong version and normal launches cannot acknowledge an update',
    () async {
      final marker = File('${root.path}/upgrade_pending.txt');
      final updater = UpgradeService(
        executablePath: '${root.path}/work_diary_app.exe',
      );
      await updater.init();
      await marker.writeAsString(
        jsonEncode({'version': '1.0.6', 'transaction': 'abc'}),
      );
      await updater.confirmUpgradeSuccess();
      expect(await marker.exists(), isTrue);
      updater.launchArguments = ['--upgrade', '--upgrade-id=wrong'];
      await updater.confirmUpgradeSuccess();
      expect(await marker.exists(), isTrue);
      updater.launchArguments = ['--upgrade', '--upgrade-id=abc'];
      await marker.writeAsString(
        jsonEncode({'version': '1.0.7', 'transaction': 'abc'}),
      );
      await updater.confirmUpgradeSuccess();
      expect(await marker.exists(), isTrue);
      await marker.writeAsString(
        '\uFEFF${jsonEncode({'version': '1.0.6', 'transaction': 'abc'})}',
      );
      await updater.confirmUpgradeSuccess();
      expect(await marker.exists(), isFalse);
    },
  );

  test(
    'old pending marker is supported without deleting backup directories',
    () async {
      final appDir = await Directory('${root.path}/Release').create();
      final backup = await Directory('${root.path}/Release_old').create();
      final marker = File('${appDir.path}/upgrade_pending.txt');
      await marker.writeAsString('pending');
      final updater = UpgradeService(
        executablePath: '${appDir.path}/work_diary_app.exe',
      );
      updater.launchArguments = ['--upgrade'];
      await updater.init();
      await updater.confirmUpgradeSuccess();
      expect(await marker.exists(), isFalse);
      expect(await backup.exists(), isTrue);
    },
  );
}
