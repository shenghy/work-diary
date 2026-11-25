import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;

import 'package:work_diary_app/database/attachment_repository.dart';
import 'package:work_diary_app/database/hive_bootstrap.dart';
import 'package:work_diary_app/models/attachment.dart';
import 'package:work_diary_app/services/api_config.dart';
import 'package:work_diary_app/services/attachment_api.dart';
import 'package:work_diary_app/services/attachment_store.dart';
import 'package:work_diary_app/services/attachment_sync_service.dart';
import 'package:work_diary_app/services/auth_service.dart';
import 'package:work_diary_app/services/device_identity.dart';

/// 按需中转的端到端用例：连一个真实跑着的后端，把"两台主机 + 服务器只暂存"
/// 这条链路从头走到尾。
///
/// 一台机器上跑两个"主机"的办法：Hive 是进程级单例（`Hive.init` 只换路径、
/// 已开的 box 全局共享），所以两台主机轮流上场——每次上场都重开自己的数据目录
/// 并新建 store/service，上场期间把要做的事和进度断言一次做完。这样正好也验证了
/// "重启后只凭元数据就能接着中转"这条真实路径。
///
/// 前置：
/// 1. 本机起服务（连本地测试库）：`python -m uvicorn app.main:app --port 8011`
/// 2. 造测试账号：`.venv\Scripts\python.exe tests\dart_relay_fixture.py`
/// 缺 fixture 或服务器不通时整份跳过，不拖累日常 `flutter test`。
class _Host {
  _Host(this.deviceId) : dir = Directory.systemTemp.createTempSync('wd_relay_$deviceId');

  final String deviceId;
  final Directory dir;

  Future<void> dispose() async {
    try {
      dir.deleteSync(recursive: true);
    } catch (_) {}
  }
}

/// 一次"主机上线"：独立的 store + 中转状态机，用完必须 close（否则下一台
/// 主机会复用同一批已开的 box，两台机器的数据就糊在一起了）。
class _Session {
  _Session(this.store, this.service);

  final AttachmentStore store;
  final AttachmentSyncService service;

  Future<void> close() => Hive.close();
}

Future<_Session> _openHost(_Host host) async {
  await Hive.close();
  await HiveBootstrap.usePathForTest(host.dir.path);
  DeviceIdentity.resetForTest();
  // 设备 id 正常是首启随机生成；测试要钉死它，才对得上"同样是这两台机器"
  final settings = await Hive.openBox('settings');
  await settings.put('device_id', host.deviceId);
  await settings.put('device_display_name', host.deviceId);
  await DeviceIdentity.init();
  final store = AttachmentStore(repository: AttachmentRepository());
  return _Session(store, AttachmentSyncService(store: store));
}

Map<String, dynamic>? _readFixture() {
  final file = File(p.join(Directory.current.path, 'test', 'fixtures', 'attachment_relay.json'));
  if (!file.existsSync()) return null;
  try {
    final data = jsonDecode(file.readAsStringSync());
    return data is Map<String, dynamic> ? data : null;
  } catch (_) {
    return null;
  }
}

Future<bool> _serverAlive(String base) async {
  try {
    final resp = await http
        .get(Uri.parse('$base/api/health'))
        .timeout(const Duration(seconds: 5));
    return resp.statusCode == 200;
  } catch (_) {
    return false;
  }
}

void main() {
  final fixture = _readFixture();
  final baseUrl = fixture?['base_url'] as String?;
  final token = fixture?['token'] as String?;
  final skipReason = fixture == null || baseUrl == null || token == null
      ? '缺少附件端到端 fixture：先跑 work_diary_server/tests/dart_relay_fixture.py'
      : null;

  final sourceBytes =
      List<int>.generate(5 * 1024 * 1024 + 777, (i) => (i * 31 + 7) % 251);

  Future<int> createRemoteTask(int localId, String title) async {
    final now = DateTime.now().toUtc().toIso8601String();
    final resp = await http.post(
      Uri.parse('$baseUrl/api/tasks/sync'),
      headers: {
        'Content-Type': 'application/json',
        'Authorization': 'Bearer $token',
      },
      body: jsonEncode({
        'tasks': [
          {
            'id': localId, 'title': title, 'status': 0, 'urgency': 0,
            'created_at': now, 'updated_at': now,
          }
        ],
        'deletions': [],
      }),
    );
    expect(resp.statusCode, 200);
    final body = jsonDecode(utf8.decode(resp.bodyBytes)) as Map<String, dynamic>;
    return (body['tasks'] as List).first['remote_id'] as int;
  }

  Future<void> deleteRemoteTask(int localId, int remoteId) async {
    await http.post(
      Uri.parse('$baseUrl/api/tasks/sync'),
      headers: {
        'Content-Type': 'application/json',
        'Authorization': 'Bearer $token',
      },
      body: jsonEncode({
        'tasks': [],
        'deletions': [
          {
            'local_id': localId, 'remote_id': remoteId,
            'deleted_at': DateTime.now().toUtc().toIso8601String(),
          }
        ],
      }),
    );
  }

  test('两台主机之间的按需中转：登记请求 → 源机分片上传 → 目标机下载校验 → 服务器删副本',
      () async {
    expect(await _serverAlive(baseUrl!), isTrue, reason: '测试服务未就绪：$baseUrl');
    AuthService.userId = fixture!['user_id'] as int;
    AuthService.token = token;
    ApiConfig.useBaseUrlForTest(baseUrl);

    final remoteTaskId = await createRemoteTask(1, '中转端到端用例');
    // 5MB 出头：按默认 2MB 分片会切成 3 片，真正走一遍续传偏移
    final expectedSha = sha256.convert(sourceBytes).toString();

    final a = _Host('e2e-host-A');
    final b = _Host('e2e-host-B');
    late String uid;
    late String fileName;
    late String mirroredPath;

    // ---------- 主机 A：把文件挂到任务上并上报元数据 ----------
    var sa = await _openHost(a);
    final sourceFile = File(p.join(a.dir.path, '大文件说明.pdf'))
      ..writeAsBytesSync(sourceBytes);
    final imported = await sa.store.importFile(sourceFile.path,
        parentKind: Attachment.kindTask, parentLocalId: 1);
    expect(imported.ok, isTrue, reason: imported.error);
    expect(imported.attachment!.sha256, expectedSha);
    uid = imported.attachment!.uid;
    fileName = imported.attachment!.fileName;
    var summaryA = await sa.service.syncMetadata(
      taskLocalToRemote: {1: remoteTaskId},
      memoLocalToRemote: const <int, int>{},
    );
    expect(summaryA.hasRejections, isFalse, reason: summaryA.rejectedNames.join(','));
    final att = (await sa.store.repository.byUid(uid))!;
    // 元数据能上报，靠的是 syncMetadata 先把本轮的本地 id → 云端 id 回填进去
    expect(att.parentRemoteId, remoteTaskId);
    expect(att.blobState, 'none');
    await sa.close();

    // ---------- 主机 B：只拿到元数据，本机没有原件 ----------
    var sb = await _openHost(b);
    final summaryB = await sb.service.syncMetadata(
      taskLocalToRemote: {1: remoteTaskId},
      memoLocalToRemote: const <int, int>{},
    );
    // 计数只断言"至少"：测试账号会被重复运行的历史数据共用，
    // 精确值要求一个全新的云端账号，反而会让用例更难跑。
    expect(summaryB.incoming, greaterThanOrEqualTo(1));
    final mirror = (await sb.store.repository.byUid(uid))!;
    expect(mirror.fileName, fileName);
    expect(mirror.ownerDeviceName, 'e2e-host-A');
    expect(mirror.blobState, 'none');
    expect(await sb.store.hasLocalCopy(mirror), isFalse);

    // 点"一键同步"：A 的 WebSocket 没连，服务器登记请求并说明在等多久
    await sb.service.pull(mirror);
    var jobB = sb.service.jobOf(uid);
    expect(jobB?.phase, AttachmentPhase.waitingSource);
    expect(jobB?.message, contains('已登记请求'));
    await sb.close();

    // ---------- A 上线应答拉取请求：作为源机分片上传 ----------
    sa = await _openHost(a);
    await sa.service.handlePush({
      'type': 'attachment_request',
      'uid': uid,
      'file_name': fileName,
      'requester_device_id': 'e2e-host-B',
      'requester_device_name': 'e2e-host-B',
    });
    expect(sa.service.jobOf(uid), isNull, reason: '上传完成后源机的进度条该收起来');
    var state = await AttachmentApi.state(uid);
    expect(state.blobState, 'ready');
    expect(state.thisDeviceRequested('e2e-host-B'), isTrue);
    expect(state.thisDeviceRequested('e2e-host-A'), isFalse);
    await sa.close();

    // ---------- B 收到就绪通知：下载、校验、落盘、确认 ----------
    sb = await _openHost(b);
    await sb.service.handlePush({'type': 'attachment_ready', 'uid': uid, 'file_name': fileName});
    expect(sb.service.jobOf(uid), isNull);
    final downloaded = File(await sb.store.pathOf(mirror));
    mirroredPath = downloaded.path;
    expect(await downloaded.exists(), isTrue);
    expect(await downloaded.readAsBytes(), sourceBytes, reason: '中转必须一字节不差');
    expect((await sb.store.repository.byUid(uid))!.parentLocalId, 1);
    // 所有请求方都确认过 → 服务器上的中转副本立刻消失（"只暂存"的硬要求）
    state = await AttachmentApi.state(uid);
    expect(state.blobState, 'taken');
    await sb.close();

    // ---------- 用户主动删附件：本机立刻删，云端打墓碑，对端跟删 ----------
    sa = await _openHost(a);
    await sa.service.deleteAttachment((await sa.store.repository.byUid(uid))!);
    expect(await sa.store.repository.byUid(uid), isNull);
    expect(await File(await sa.store.pathOf(att)).exists(), isFalse,
        reason: '删的是这个任务上的附件，本机记录和原件都要立刻消失');
    summaryA = await sa.service.syncMetadata(
      taskLocalToRemote: {1: remoteTaskId},
      memoLocalToRemote: const <int, int>{},
    );
    expect(summaryA.deleted, greaterThanOrEqualTo(1));

    // 删任务的语义相反：原件留着（只有截图任务的图直接删）
    final keep = await sa.store.importFile(sourceFile.path,
        parentKind: Attachment.kindTask, parentLocalId: 2);
    expect(keep.ok, isTrue, reason: keep.error);
    final keepPath = await sa.store.pathOf(keep.attachment!);
    await sa.service.onParentDeleted(Attachment.kindTask, 2);
    expect(await sa.store.repository.forParent(Attachment.kindTask, 2), isEmpty,
        reason: '任务没了，卡片上不该再显示这个附件');
    expect((await sa.store.repository.byUid(keep.attachment!.uid))!.orphaned, isTrue);
    expect(await File(keepPath).exists(), isTrue,
        reason: '删任务不能连带删掉用户挂上来的文档原件');
    await sa.close();

    sb = await _openHost(b);
    await sb.service.syncMetadata(
      taskLocalToRemote: {1: remoteTaskId},
      memoLocalToRemote: const <int, int>{},
    );
    expect(await sb.store.repository.byUid(uid), isNull);
    expect(await File(mirroredPath).exists(), isFalse,
        reason: '对端删掉的附件不该继续占着本机磁盘');
    await sb.close();

    // 收尾：清掉测试库里的父任务与两台主机的临时目录
    await deleteRemoteTask(1, remoteTaskId);
    await a.dispose();
    await b.dispose();
  }, skip: skipReason ?? false, timeout: const Timeout(Duration(minutes: 3)));

  test('引用原件的换版同步：A 改原件 → 云端作废旧副本重新排队 → B 取回新版',
      () async {
    expect(await _serverAlive(baseUrl!), isTrue, reason: '测试服务未就绪：$baseUrl');
    AuthService.userId = fixture!['user_id'] as int;
    AuthService.token = token;
    ApiConfig.useBaseUrlForTest(baseUrl);

    final remoteTaskId = await createRemoteTask(7, '引用原件换版用例');
    // 3MB 出头：默认 2MB 分片会切两片；两版长度不同，哈希必然不同
    final v1 = List<int>.generate(3 * 1024 * 1024 + 511, (i) => (i * 17 + 3) % 253);
    final v2 = List<int>.generate(3 * 1024 * 1024 + 899, (i) => (i * 29 + 11) % 251);
    final sha1 = sha256.convert(v1).toString();
    final sha2 = sha256.convert(v2).toString();

    final a = _Host('link-host-A');
    final b = _Host('link-host-B');
    late String uid;
    late String originalPath;
    late String mirroredPath;
    // 两台主机轮流上场（Hive 是进程级单例），先声明再开，helper 才闭包得到最新的会话
    late _Session sa;
    late _Session sb;

    Future<void> syncA() => sa.service.syncMetadata(
          taskLocalToRemote: {7: remoteTaskId},
          memoLocalToRemote: const <int, int>{},
        );
    Future<void> syncB() => sb.service.syncMetadata(
          taskLocalToRemote: {7: remoteTaskId},
          memoLocalToRemote: const <int, int>{},
        );
    Future<void> askA() => sa.service.handlePush({
          'type': 'attachment_request',
          'uid': uid,
          'file_name': '方案草稿.txt',
          'requester_device_id': 'link-host-B',
          'requester_device_name': 'link-host-B',
        });

    // ---------- A：引用模式挂载，原件留在附件目录之外 ----------
    sa = await _openHost(a);
    originalPath = p.join(a.dir.path, '桌面', '方案草稿.txt');
    File(originalPath).parent.createSync(recursive: true);
    File(originalPath).writeAsBytesSync(v1);
    final mounted = await sa.store.importFile(originalPath,
        parentKind: Attachment.kindTask, parentLocalId: 7, link: true);
    expect(mounted.ok, isTrue, reason: mounted.error);
    uid = mounted.attachment!.uid;
    expect(mounted.attachment!.isLinked, isTrue);
    expect(mounted.attachment!.sourcePath, originalPath);
    expect(mounted.attachment!.sha256, sha1);
    // 引用模式的硬要求：附件目录里不该再多出一份副本
    expect(
      Directory(p.join(await sa.store.rootDir(), AttachmentStore.sanitizeUid(uid)))
          .existsSync(),
      isFalse,
      reason: 'link 记录只记路径，不能再往附件库复制',
    );
    await syncA();
    expect((await AttachmentApi.state(uid)).blobState, 'none');
    await sa.close();

    // ---------- B：先按常规流程把 v1 拿到本机 ----------
    sb = await _openHost(b);
    await syncB();
    var mirror = (await sb.store.repository.byUid(uid))!;
    expect(mirror.ownerDeviceName, 'link-host-A');
    expect(mirror.sha256, sha1);
    expect(mirror.isLinked, isFalse, reason: '对端拿到的只能是附件库里的副本');
    await sb.service.pull(mirror);
    expect(sb.service.jobOf(uid)?.phase, AttachmentPhase.waitingSource);
    await sb.close();

    sa = await _openHost(a);
    await askA();
    expect(sa.service.jobOf(uid), isNull);
    expect((await AttachmentApi.state(uid)).blobState, 'ready');
    await sa.close();

    sb = await _openHost(b);
    await sb.service.handlePush(
        {'type': 'attachment_ready', 'uid': uid, 'file_name': '方案草稿.txt'});
    mirror = (await sb.store.repository.byUid(uid))!;
    mirroredPath = await sb.store.pathOf(mirror);
    expect(File(mirroredPath).readAsBytesSync(), v1);
    expect(mirror.staleCopy, isFalse);
    expect((await AttachmentApi.state(uid)).blobState, 'taken');
    await sb.close();

    // ---------- A：用户在原件上改出一版新内容 ----------
    // 拉开至少一秒：云端 updated_at 是秒精度 DATETIME，上报值会被截断。若 A 这次
    // 上报和 B 本机那份的 updated_at 落在同一秒，B 随后上报的旧哈希会因为
    // "比截断后的云端值更晚"被接受，把新版顶回去（详见汇报里的精度问题）。
    await Future<void>.delayed(const Duration(milliseconds: 1200));
    sa = await _openHost(a);
    File(originalPath).writeAsBytesSync(v2);
    var onA = (await sa.store.repository.byUid(uid))!;
    // 卡片加载时的那次对账（home_screen 的 _loadAttachments 走的就是它）
    expect(await sa.store.refreshLink(onA), isTrue, reason: 'mtime/大小变了要重算哈希');
    onA = (await sa.store.repository.byUid(uid))!;
    expect(onA.sha256, sha2);
    expect(onA.sourceSize, v2.length);
    await syncA();
    // 本次上线的服务端规则：哈希换了版 → 旧中转副本作废 → 已取过旧版的机器重新排队
    var state = await AttachmentApi.state(uid);
    expect(state.blobState, 'none', reason: '服务器上那份是旧内容，留着对端只会拿到旧版');
    expect(
      state.transfers.any((t) => t.deviceId == 'link-host-B' && t.status == 'pending'),
      isTrue,
      reason: 'B 已经下过旧版，不重置成 pending 它就不会再取',
    );
    await sa.close();

    // ---------- B：同步时发现自己手里这份过期了 ----------
    sb = await _openHost(b);
    await syncB();
    mirror = (await sb.store.repository.byUid(uid))!;
    expect(mirror.sha256, sha2);
    expect(mirror.staleCopy, isTrue, reason: '芯片该显示「云端有新版 · 点击取回」');
    expect(File(mirroredPath).readAsBytesSync(), v1, reason: '过期只标记，不偷偷改本机文件');
    await sb.service.pull(mirror);
    expect(sb.service.jobOf(uid)?.phase, AttachmentPhase.waitingSource,
        reason: '有旧副本但版本不对，pull 不能被本机副本短路');
    await sb.close();

    // ---------- A 应答请求：这一趟传的是新版 ----------
    sa = await _openHost(a);
    await askA();
    expect(sa.service.jobOf(uid), isNull);
    state = await AttachmentApi.state(uid);
    expect(state.blobState, 'ready');
    await sa.close();

    // ---------- B 取回新版 ----------
    sb = await _openHost(b);
    await sb.service.handlePush(
        {'type': 'attachment_ready', 'uid': uid, 'file_name': '方案草稿.txt'});
    expect(File(mirroredPath).readAsBytesSync(), v2, reason: '对端最终拿到的必须是原件最新版');
    mirror = (await sb.store.repository.byUid(uid))!;
    expect(mirror.sha256, sha2);
    expect(mirror.staleCopy, isFalse);
    expect(await sb.store.hasLocalCopy(mirror), isTrue);
    expect((await AttachmentApi.state(uid)).blobState, 'taken');
    await sb.close();

    // ---------- A 这边：同步与中转全程没写过用户的原件 ----------
    sa = await _openHost(a);
    expect(File(originalPath).readAsBytesSync(), v2, reason: '原件只能由用户自己改');
    // 删附件删的是记录：用户桌面上的文件不能跟着消失
    await sa.service.deleteAttachment((await sa.store.repository.byUid(uid))!);
    expect(await sa.store.repository.byUid(uid), isNull);
    expect(File(originalPath).existsSync(), isTrue,
        reason: '引用模式下删附件绝不该动用户自己的文件');
    await syncA();
    await sa.close();

    sb = await _openHost(b);
    await syncB();
    expect(await sb.store.repository.byUid(uid), isNull, reason: '对端记录和副本都要跟着清掉');
    expect(File(mirroredPath).existsSync(), isFalse);
    await sb.close();

    await deleteRemoteTask(7, remoteTaskId);
    await a.dispose();
    await b.dispose();
  }, skip: skipReason ?? false, timeout: const Timeout(Duration(minutes: 3)));
}
