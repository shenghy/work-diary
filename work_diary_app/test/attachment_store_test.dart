import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:path/path.dart' as p;

import 'package:work_diary_app/database/attachment_repository.dart';
import 'package:work_diary_app/database/hive_bootstrap.dart';
import 'package:work_diary_app/models/attachment.dart';
import 'package:work_diary_app/services/attachment_store.dart';
import 'package:work_diary_app/services/device_identity.dart';
import 'package:work_diary_app/utils/attachment_types.dart';

void main() {
  late Directory tempDir;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('wd_att_store_test_');
    await HiveBootstrap.usePathForTest(tempDir.path);
    DeviceIdentity.resetForTest();
    await DeviceIdentity.init();
  });

  tearDown(() async {
    await Hive.close();
    HiveBootstrap.resetForTest();
    try {
      tempDir.deleteSync(recursive: true);
    } catch (_) {}
  });

  File writeSource(String name, List<int> bytes) {
    final file = File(p.join(tempDir.path, 'src', name));
    file.parent.createSync(recursive: true);
    file.writeAsBytesSync(bytes);
    return file;
  }

  group('类型白名单', () {
    test('图片与文档允许，MIME 与服务端一致', () {
      for (final name in ['a.png', 'b.JPG', 'c.pdf', 'd.docx', 'e.md', 'f.csv']) {
        final r = checkAttachmentFile(name);
        expect(r.allowed, isTrue, reason: name);
        expect(r.mime.isNotEmpty, isTrue, reason: name);
      }
      expect(checkAttachmentFile('x.png').mime, 'image/png');
      expect(checkAttachmentFile('x.et').mime, 'application/wps-office.xlsx');
    });

    test('可执行/视频/音频/压缩包/未知类型被拒且给出原因', () {
      for (final name in ['tool.exe', 'a.msi', 'b.ps1', 'c.bat', 'd.dll', 'e.lnk']) {
        final r = checkAttachmentFile(name);
        expect(r.allowed, isFalse, reason: name);
        expect(r.reason, contains('可执行文件'));
      }
      expect(checkAttachmentFile('片.mp4').reason, contains('视频文件'));
      expect(checkAttachmentFile('song.mp3').reason, contains('音频文件'));
      expect(checkAttachmentFile('pack.zip').reason, contains('压缩包'));
      expect(checkAttachmentFile('data.xyz').reason, contains('该类型'));
      expect(checkAttachmentFile('README').reason, contains('无扩展名'));
      expect(checkAttachmentFile('a.exe').reason, contains(kAttachmentAllowedHint));
    });

    test('超过 100MB 拒绝，正好 100MB 允许', () {
      expect(checkAttachmentFile('a.pdf', sizeBytes: kAttachmentMaxBytes + 1).allowed, isFalse);
      expect(checkAttachmentFile('a.pdf', sizeBytes: kAttachmentMaxBytes).allowed, isTrue);
      expect(formatAttachmentSize(1024), '1.0 KB');
      expect(formatAttachmentSize(3 * 1024 * 1024), '3.0 MB');
      expect(formatAttachmentSize(10), '10 B');
    });
  });

  group('文件名清洗', () {
    test('去掉路径分隔符与非法字符', () {
      expect(AttachmentStore.sanitizeAttachmentFileName(r'..\..\Windows\system32\cmd.exe'),
          isNot(contains(r'\')));
      expect(AttachmentStore.sanitizeAttachmentFileName('a/b:c*d?.txt'), 'a_b_c_d_.txt');
      expect(AttachmentStore.sanitizeAttachmentFileName('报告.pdf.'), '报告.pdf');
      expect(AttachmentStore.sanitizeAttachmentFileName('   '), '附件');
      expect(AttachmentStore.sanitizeAttachmentFileName('正常文件名.docx'), '正常文件名.docx');
    });

    test('超长文件名保留扩展名', () {
      final long = '${'A' * 300}.txt';
      final out = AttachmentStore.sanitizeAttachmentFileName(long);
      expect(out.length, lessThanOrEqualTo(100));
      expect(out.endsWith('.txt'), isTrue);
      // 清洗要幂等：入库名字和落盘名字必须一致
      expect(AttachmentStore.sanitizeAttachmentFileName(out), out);
    });
  });

  group('Attachment 模型', () {
    test('Hive 落盘字段往返一致', () {
      final now = DateTime.now();
      final att = Attachment(
        uid: 'u-1', parentKind: Attachment.kindMemo, parentLocalId: 7, parentRemoteId: 11,
        ownerDeviceId: 'devA', ownerDeviceName: 'A 主机', fileName: '说明.txt',
        fileSize: 12, sha256: 'ab', mime: 'text/plain', isScreenshot: true,
        blobState: 'ready', createdAt: now,
      );
      final back = Attachment.fromMap(att.toMap());
      expect(back.uid, 'u-1');
      expect(back.parentKind, Attachment.kindMemo);
      expect(back.isTask, isFalse);
      expect(back.parentLocalId, 7);
      expect(back.parentRemoteId, 11);
      expect(back.isScreenshot, isTrue);
      expect(back.orphaned, isFalse);
      expect(back.blobState, 'ready');
      expect(back.createdAt.isAtSameMomentAs(now), isTrue);
    });

    test('损坏记录不炸：缺字段有兜底值', () {
      final back = Attachment.fromMap({'uid': 'x'});
      expect(back.parentKind, Attachment.kindTask);
      expect(back.fileSize, 0);
      expect(back.blobState, 'none');
    });

    test('上报云端用 UTC ISO，且不带你本地 id', () {
      final att = Attachment(
        uid: 'u', parentKind: Attachment.kindTask, parentLocalId: 3, parentRemoteId: 9,
        ownerDeviceId: 'd', ownerDeviceName: 'n', fileName: 'f.txt', fileSize: 1,
        sha256: 's', mime: 'text/plain', createdAt: DateTime.utc(2026, 11, 20, 3, 4, 5),
      );
      final api = att.toApi();
      expect(api['created_at'], '2026-11-20T03:04:05.000Z');
      expect(api.containsKey('parent_local_id'), isFalse);
      expect(api['parent_remote_id'], 9);
      final back = Attachment.fromApi(api);
      expect(back.uid, 'u');
      expect(back.fileName, 'f.txt');
    });
  });

  group('AttachmentRepository', () {
    test('按父记录取列表、分组、回填云端 id、标孤儿', () async {
      final repo = AttachmentRepository();
      final now = DateTime.now();
      List<Attachment> make(List<int> ids, {String kind = Attachment.kindTask}) => [
            for (final i in ids)
              Attachment(
                uid: 'u$i', parentKind: kind, parentLocalId: i, ownerDeviceId: 'd',
                ownerDeviceName: 'n', fileName: 'f$i.txt', fileSize: i, sha256: 's$i',
                mime: 'text/plain', createdAt: now.add(Duration(seconds: i)),
              )
          ];
      await repo.saveAll([...make([1, 2, 3]), ...make([4], kind: Attachment.kindMemo)]);

      expect((await repo.forParent(Attachment.kindTask, 1)).length, 1);
      expect((await repo.getAll()).length, 4);
      final grouped = await repo.groupedByParent(Attachment.kindTask);
      expect(grouped.keys.toSet(), {1, 2, 3});
      expect((await repo.groupedByParent(Attachment.kindMemo)).keys.toList(), [4]);

      await repo.backfillRemoteIds(Attachment.kindTask, {1: 101, 2: 102, 3: 103});
      expect((await repo.byUid('u1'))!.parentRemoteId, 101);
      expect((await repo.byUid('u3'))!.parentRemoteId, 103);
      // 备忘不受任务映射影响
      expect(await repo.byUid('u4'), isNotNull);
      expect((await repo.byUid('u4'))!.parentRemoteId, isNull);

      final orphaned = await repo.markOrphaned(Attachment.kindTask, 2);
      expect(orphaned.single.uid, 'u2');
      expect(await repo.forParent(Attachment.kindTask, 2), isEmpty);
      expect((await repo.byUid('u2'))!.orphaned, isTrue);

      // 对端删除：调用方按 uid 删记录（原件由 AttachmentStore 决定留不留）
      await repo.delete('u3');
      expect(await repo.byUid('u3'), isNull);
    });

    test('坏记录跳过，uid 为空的写入被忽略', () async {
      final repo = AttachmentRepository();
      await repo.save(Attachment(
        uid: '', parentKind: Attachment.kindTask, ownerDeviceId: 'd', ownerDeviceName: 'n',
        fileName: 'f.txt', fileSize: 1, sha256: 's', mime: 'text/plain',
        createdAt: DateTime.now(),
      ));
      final box = Hive.box('attachments');
      await box.put('坏记录', {'uid': ''});
      await box.put('坏记录2', 'not-a-map');
      expect(await repo.getAll(), isEmpty);
      expect(await repo.byUid('坏记录'), isNull);
    });
  });

  group('AttachmentStore 收文件进本机', () {
    test('复制落盘 + 元数据入库，源文件不受影响', () async {
      final store = AttachmentStore();
      final bytes = utf8.encode('附件内容-测试');
      final source = writeSource('需求说明.txt', bytes);
      final result = await store.importFile(source.path,
          parentKind: Attachment.kindTask, parentLocalId: 5, parentRemoteId: 55);
      expect(result.ok, isTrue, reason: result.error);
      final att = result.attachment!;
      expect(att.fileName, '需求说明.txt');
      expect(att.fileSize, bytes.length);
      expect(att.sha256, sha256.convert(bytes).toString());
      expect(att.mime, 'text/plain');
      expect(att.parentLocalId, 5);
      expect(att.parentRemoteId, 55);
      expect(att.ownerDeviceId, DeviceIdentity.id);
      expect(att.ownerDeviceName, DeviceIdentity.name);
      expect(att.blobState, 'none');

      final stored = File(await store.pathOf(att));
      expect(await stored.exists(), isTrue);
      expect(await stored.readAsBytes(), bytes);
      // 只保存不移动：用户的原文件必须还在
      expect(await source.exists(), isTrue);
      expect((await store.repository.forParent(Attachment.kindTask, 5)).single.uid, att.uid);
      expect(await store.hasLocalCopy(att), isTrue);
      expect(await store.rootDir(), p.join(tempDir.path, 'attachments'));
      // 临时 .part 不能留下
      expect(Directory(await store.dirOf(att.uid)).listSync().length, 1);
    });

    test('同名文件各存各的 uid 目录，互不覆盖', () async {
      final store = AttachmentStore();
      final a = writeSource('同名.txt', utf8.encode('第一份'));
      final b = writeSource('更深/同名.txt', utf8.encode('第二份内容'));
      final r1 = await store.importFile(a.path,
          parentKind: Attachment.kindTask, parentLocalId: 1);
      final r2 = await store.importFile(b.path,
          parentKind: Attachment.kindTask, parentLocalId: 2);
      expect(r1.ok && r2.ok, isTrue);
      expect(r1.attachment!.uid == r2.attachment!.uid, isFalse);
      expect(File(await store.pathOf(r1.attachment!)).readAsBytesSync(),
          utf8.encode('第一份'));
      expect(File(await store.pathOf(r2.attachment!)).readAsBytesSync(),
          utf8.encode('第二份内容'));
    });

    test('拒绝：类型不允许、文件不存在、超上限、内容重复', () async {
      final store = AttachmentStore();
      final missing = p.join(tempDir.path, 'nope.txt');
      expect((await store.importFile(missing,
              parentKind: Attachment.kindTask, parentLocalId: 1))
          .error, contains('不存在'));

      final exe = writeSource('工具.exe', utf8.encode('MZ fake'));
      final bad = await store.importFile(exe.path,
          parentKind: Attachment.kindTask, parentLocalId: 1);
      expect(bad.ok, isFalse);
      expect(bad.error, contains('可执行文件'));
      expect(await Directory(await store.rootDir()).exists(), isFalse);

      final txt = writeSource('重复.txt', utf8.encode('同样的内容'));
      final first = await store.importFile(txt.path,
          parentKind: Attachment.kindTask, parentLocalId: 2);
      expect(first.ok, isTrue);
      final dup = await store.importFile(txt.path,
          parentKind: Attachment.kindTask, parentLocalId: 2);
      expect(dup.error, contains('已经挂'));
      // 换一个父记录就允许：附件是各任务独立的
      final other = await store.importFile(txt.path,
          parentKind: Attachment.kindTask, parentLocalId: 3);
      expect(other.ok, isTrue);
    });

    test('一个任务最多 5 个附件，第 6 个给出提示', () async {
      final store = AttachmentStore();
      for (var i = 0; i < kAttachmentMaxPerParent; i++) {
        final f = writeSource('文件$i.txt', utf8.encode('内容 $i'));
        final r = await store.importFile(f.path,
            parentKind: Attachment.kindTask, parentLocalId: 9);
        expect(r.ok, isTrue, reason: r.error);
      }
      final sixth = writeSource('文件6.txt', utf8.encode('超出的那份'));
      final r = await store.importFile(sixth.path,
          parentKind: Attachment.kindTask, parentLocalId: 9);
      expect(r.error, contains('$kAttachmentMaxPerParent 个附件'));
      expect((await store.countForParent(Attachment.kindTask, 9)), kAttachmentMaxPerParent);
    });

    test('打开：本机没原件时提示在其它主机', () async {
      final store = AttachmentStore();
      final remote = Attachment(
        uid: 'remote-1', parentKind: Attachment.kindTask, parentLocalId: 1,
        ownerDeviceId: 'devB', ownerDeviceName: '办公室主机', fileName: '在别处.pdf',
        fileSize: 3, sha256: 'x', mime: 'application/pdf', createdAt: DateTime.now(),
      );
      expect(await store.open(remote), contains('办公室主机'));
      final anonymous = remote.copyWith(ownerDeviceName: '');
      expect(await store.open(anonymous), contains('此文件在其它主机'));
      expect(await store.hasLocalCopy(remote), isFalse);
    });

    test('打开：对端上报的恶意 uid / 文件名不会逃出数据目录', () async {
      final store = AttachmentStore();
      final evil = Attachment(
        uid: '../../evil', parentKind: Attachment.kindTask, ownerDeviceId: 'd',
        ownerDeviceName: 'n', fileName: '../../../../Windows/win.ini', fileSize: 1,
        sha256: 'x', mime: 'text/plain', createdAt: DateTime.now(),
      );
      // 原件判定阶段就拒绝：清洗后的路径可能撞上别人的目录
      expect(await store.hasLocalCopy(evil), isFalse);
      expect(await store.open(evil), contains('先同步到本机'));
      final rejected = await store.saveIncoming(attachment: evil, sourcePath: 'x');
      expect(rejected.ok, isFalse);
      expect(rejected.error, contains('不合法'));

      final normalUid = Attachment(
        uid: 'safe-uid_1', parentKind: Attachment.kindTask, ownerDeviceId: 'd',
        ownerDeviceName: 'n', fileName: '..\\..\\win.ini', fileSize: 1,
        sha256: 'x', mime: 'text/plain', createdAt: DateTime.now(),
      );
      final path = await store.pathOf(normalUid);
      expect(p.dirname(path), await store.dirOf(normalUid.uid));
      expect(p.isWithin(await store.rootDir(), path), isTrue);
      expect(p.basename(path), isNot(anyOf(contains(r'\'), contains('/'))));
      expect(AttachmentStore.sanitizeUid('ab12-_CD'), 'ab12-_CD');
      expect(AttachmentStore.sanitizeUid('a/..\\b:c'), 'abc');
      final longUid = 'A' * 100;
      expect(AttachmentStore.sanitizeUid(longUid), hasLength(64));
    });

    test('中转下载落地：校验通过才收进本机', () async {
      final store = AttachmentStore();
      final bytes = utf8.encode('从另一台机器同步过来的文件');
      final goodSha = sha256.convert(bytes).toString();
      final meta = Attachment(
        uid: 'incoming-1', parentKind: Attachment.kindMemo, ownerDeviceId: 'devB',
        ownerDeviceName: '手机', fileName: '现场照片.png', fileSize: bytes.length,
        sha256: goodSha, mime: 'image/png', createdAt: DateTime.now(),
      );

      // 同长度但内容被改坏：大小过关，哈希必须拦下
      final tampered = [...bytes];
      tampered[3] = (tampered[3] + 1) % 256;
      final wrong = File(p.join(tempDir.path, 'tmp1.png'))
        ..writeAsBytesSync(tampered);
      final bad = await store.saveIncoming(attachment: meta, sourcePath: wrong.path, parentLocalId: 4);
      expect(bad.error, contains('校验失败'));
      expect(await store.hasLocalCopy(meta), isFalse);
      expect(await wrong.exists(), isTrue); // 被拒的临时文件留在原地，不动它

      // 大小不符：拒绝
      final short = File(p.join(tempDir.path, 'tmp2.png'))..writeAsBytesSync(bytes.sublist(0, 3));
      final sizeBad = await store.saveIncoming(attachment: meta, sourcePath: short.path, parentLocalId: 4);
      expect(sizeBad.error, contains('大小不符'));

      final good = File(p.join(tempDir.path, 'tmp3.png'))..writeAsBytesSync(bytes);
      final ok = await store.saveIncoming(
          attachment: meta, sourcePath: good.path, parentLocalId: 4);
      expect(ok.ok, isTrue, reason: ok.error);
      expect(await store.hasLocalCopy(meta), isTrue);
      expect(File(await store.pathOf(meta)).readAsBytesSync(), bytes);
      expect((await store.repository.byUid('incoming-1'))!.parentLocalId, 4);
      // 临时文件已经搬走，不留垃圾
      expect(await good.exists(), isFalse);
    });

    test('删除任务：普通附件留原件，截图附件连图一起删', () async {
      final store = AttachmentStore();
      final doc = writeSource('合同.pdf', utf8.encode('合同内容'));
      final shot = writeSource('截图.png', utf8.encode('像素像素'));
      final normal = (await store.importFile(doc.path,
              parentKind: Attachment.kindTask, parentLocalId: 20))
          .attachment!;
      final screenshot = (await store.importFile(shot.path,
              parentKind: Attachment.kindTask, parentLocalId: 20, isScreenshot: true))
          .attachment!;

      await store.onParentDeleted(Attachment.kindTask, 20);

      expect(await store.repository.forParent(Attachment.kindTask, 20), isEmpty);
      expect((await store.repository.byUid(normal.uid))!.orphaned, isTrue);
      expect(await File(await store.pathOf(normal)).exists(), isTrue);
      expect(await store.repository.byUid(screenshot.uid), isNull);
      expect(await Directory(await store.dirOf(screenshot.uid)).exists(), isFalse);
    });

    test('用户主动删附件：只删记录，原件目录留给 remove(deleteOriginal)', () async {
      final store = AttachmentStore();
      final src = writeSource('删我.txt', utf8.encode('内容'));
      final att = (await store.importFile(src.path,
              parentKind: Attachment.kindMemo, parentLocalId: 1))
          .attachment!;
      await store.remove(att);
      expect(await store.repository.byUid(att.uid), isNull);
      expect(await Directory(await store.dirOf(att.uid)).exists(), isTrue);
      await store.remove(att, deleteOriginal: true);
      expect(await Directory(await store.dirOf(att.uid)).exists(), isFalse);
    });

    test('大文件流式哈希与整份读取结果一致', () async {
      final store = AttachmentStore();
      final bytes = List<int>.generate(300 * 1024, (i) => i % 251);
      final file = File(p.join(tempDir.path, 'big.bin'))..writeAsBytesSync(bytes);
      expect(await store.sha256OfFile(file.path), sha256.convert(bytes).toString());
    });
  });

  group('引用原文件（link 模式）', () {
    test('只记路径不复制，打开与定位都指原件', () async {
      final store = AttachmentStore();
      final doc = writeSource('台账.xlsx', utf8.encode('原始表格'));
      final att = (await store.importFile(doc.path,
              parentKind: Attachment.kindTask, parentLocalId: 30, link: true))
          .attachment!;
      expect(att.isLinked, isTrue);
      expect(att.sourcePath, doc.path);
      expect(att.fileName, '台账.xlsx');
      expect(await store.pathOf(att), doc.path);
      expect(await Directory(await store.dirOf(att.uid)).exists(), isFalse,
          reason: '引用模式不该把用户的文件再复制一份进附件库');
      expect(await store.hasLocalCopy(att), isTrue);
      expect(await store.locate(att), AttachmentSource.linked);
      // 本机路径只进 Hive：换台机器它毫无意义，还白泄用户的目录结构
      expect(att.toApi().containsKey('source_path'), isFalse);
      expect(att.toApi().containsKey('content_mode'), isFalse);
      final back = Attachment.fromMap(att.toMap());
      expect(back.isLinked, isTrue);
      expect(back.sourcePath, doc.path);
      expect(back.sourceMtimeMs, att.sourceMtimeMs);
    });

    test('截图必须落进附件库，哪怕开关是引用', () async {
      final store = AttachmentStore();
      final shot = writeSource('截图.png', utf8.encode('像素像素'));
      final att = (await store.importFile(shot.path,
              parentKind: Attachment.kindTask,
              parentLocalId: 31,
              isScreenshot: true,
              link: true))
          .attachment!;
      expect(att.isLinked, isFalse);
      expect(att.sourcePath, isEmpty);
      expect(await File(await store.pathOf(att)).exists(), isTrue);
    });

    test('refreshLink：改内容才重算哈希，只是重新保存就挪基准时间', () async {
      final store = AttachmentStore();
      final doc = writeSource('周报.txt', utf8.encode('第一版'));
      final att = (await store.importFile(doc.path,
              parentKind: Attachment.kindTask, parentLocalId: 32, link: true))
          .attachment!;
      expect(await store.refreshLink(att), isFalse);

      doc.setLastModifiedSync(DateTime.now().add(const Duration(minutes: 5)));
      expect(await store.refreshLink(att), isFalse, reason: '内容没变就不算变化');
      final touched = (await store.repository.byUid(att.uid))!;
      expect(touched.sourceMtimeMs, isNot(att.sourceMtimeMs));
      expect(touched.sha256, att.sha256);

      doc.writeAsStringSync('第二版内容换掉了');
      final bytes = utf8.encode('第二版内容换掉了');
      expect(await store.refreshLink(touched), isTrue);
      final edited = (await store.repository.byUid(att.uid))!;
      expect(edited.sha256, sha256.convert(bytes).toString());
      expect(edited.fileSize, bytes.length);
      expect(edited.sourceSize, bytes.length);

      doc.deleteSync();
      expect(await store.refreshLink(edited), isFalse);
      expect((await store.repository.byUid(att.uid))!.sha256, edited.sha256,
          reason: '原件不见了不算内容变化，哈希要留着等用户重新定位');
      expect(await store.locate(edited), AttachmentSource.missingOriginal);
      expect(await store.open(edited), contains('重新定位'));
    });

    test('重新定位：记录改指新文件，附件库里的旧副本删掉', () async {
      final store = AttachmentStore();
      final old = writeSource('旧位置.txt', utf8.encode('旧内容'));
      final att = (await store.importFile(old.path,
              parentKind: Attachment.kindTask, parentLocalId: 33))
          .attachment!;
      expect(att.isLinked, isFalse);
      expect(await File(await store.pathOf(att)).exists(), isTrue);

      final fresh = writeSource('新位置.txt', utf8.encode('新内容'));
      final out = await store.relocate(att, fresh.path);
      expect(out.ok, isTrue, reason: out.error);
      final saved = out.attachment!;
      expect(saved.uid, att.uid, reason: '是同一条记录换了指向，不是新加附件');
      expect(saved.isLinked, isTrue);
      expect(saved.sourcePath, fresh.path);
      expect(saved.fileName, '新位置.txt');
      expect(saved.sha256, sha256.convert(utf8.encode('新内容')).toString());
      expect(await Directory(await store.dirOf(att.uid)).exists(), isFalse,
          reason: '引用过去就不该再留一份内容不一致的"原件"');

      final exe = writeSource('坏文件.exe', utf8.encode('MZ fake'));
      final bad = await store.relocate(saved, exe.path);
      expect(bad.ok, isFalse);
      expect(bad.error, contains('可执行文件'));
      expect((await store.repository.byUid(att.uid))!.sourcePath, fresh.path);
    });

    test('另存副本：切回 copy，之后原件怎么动都不影响这条附件', () async {
      final store = AttachmentStore();
      final doc = writeSource('合同.pdf', utf8.encode('合同内容'));
      final att = (await store.importFile(doc.path,
              parentKind: Attachment.kindTask, parentLocalId: 34, link: true))
          .attachment!;
      final out = await store.pinCopy(att);
      expect(out.ok, isTrue, reason: out.error);
      final saved = out.attachment!;
      expect(saved.isLinked, isFalse);
      expect(saved.sourcePath, isEmpty);
      expect(await File(await store.pathOf(saved)).readAsBytes(),
          utf8.encode('合同内容'));
      doc.deleteSync();
      expect(await store.hasLocalCopy(saved), isTrue);
      expect(await store.locate(saved), AttachmentSource.copy);
    });

    test('另存副本：原件不在了给一句人话', () async {
      final store = AttachmentStore();
      final doc = writeSource('失联.txt', utf8.encode('内容'));
      final att = (await store.importFile(doc.path,
              parentKind: Attachment.kindTask, parentLocalId: 35, link: true))
          .attachment!;
      doc.deleteSync();
      final out = await store.pinCopy(att);
      expect(out.ok, isFalse);
      expect(out.error, contains('原件已经不在了'));
    });

    test('删附件绝不删用户磁盘上的原件', () async {
      final store = AttachmentStore();
      final doc = writeSource('重要合同.pdf', utf8.encode('合同'));
      final att = (await store.importFile(doc.path,
              parentKind: Attachment.kindTask, parentLocalId: 36, link: true))
          .attachment!;
      await store.remove(att, deleteOriginal: true);
      expect(await store.repository.byUid(att.uid), isNull);
      expect(await doc.exists(), isTrue,
          reason: '引用模式指向的是用户自己的文件，删记录不等于删文件');
    });

    test('取回云端新版：落进附件库、清掉过期标记、让开引用', () async {
      final store = AttachmentStore();
      final doc = writeSource('本机这份.txt', utf8.encode('本机版'));
      final att = (await store.importFile(doc.path,
              parentKind: Attachment.kindTask, parentLocalId: 37, link: true))
          .attachment!;
      final bytes = utf8.encode('云端新版');
      final tmp = File(p.join(tempDir.path, 'dl', 'x.part'))
        ..createSync(recursive: true)
        ..writeAsBytesSync(bytes);
      final incoming = att.copyWith(
        sha256: sha256.convert(bytes).toString(),
        fileSize: bytes.length,
        staleCopy: true,
      );
      final out = await store.saveIncoming(
        attachment: incoming,
        sourcePath: tmp.path,
        parentLocalId: 37,
      );
      expect(out.ok, isTrue, reason: out.error);
      expect(out.attachment!.staleCopy, isFalse);
      expect(out.attachment!.isLinked, isFalse,
          reason: '取回的是附件库副本，原来的引用已经指不到这份内容');
      expect(await File(await store.pathOf(out.attachment!)).readAsBytes(), bytes);
      expect(await doc.readAsBytes(), utf8.encode('本机版'),
          reason: '任何情况下都不写用户磁盘上的原件');
    });

    test('默认模式开关：settings 盒没开也按引用走', () {
      expect(AttachmentStore.linkByDefault, isTrue);
    });
  });
}
