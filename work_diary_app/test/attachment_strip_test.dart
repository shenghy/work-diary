import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show RenderParagraph;
import 'package:flutter_test/flutter_test.dart';

import 'package:work_diary_app/database/attachment_repository.dart';
import 'package:work_diary_app/models/attachment.dart';
import 'package:work_diary_app/services/attachment_store.dart';
import 'package:work_diary_app/services/attachment_sync_service.dart';
import 'package:work_diary_app/widgets/attachment_strip.dart';

/// 附件条的各个档位：本机可打开、原件在别的机器、原件失联、云端有新版、中转进行中、同步失败。
/// 关键点在于"点了会做什么"必须和显示出来的状态一致，而且中转途中不给删。
void main() {
  Attachment attachment(String name, {String uid = 'uid-1'}) => Attachment(
        uid: uid,
        parentKind: Attachment.kindTask,
        parentLocalId: 1,
        ownerDeviceId: 'host-a',
        ownerDeviceName: '办公室电脑',
        fileName: name,
        fileSize: 1234,
        sha256: 'x',
        mime: '',
        createdAt: DateTime(2026, 11, 20),
      );

  late AttachmentSyncService bus;
  late List<Attachment> opened;
  late List<Attachment> pulled;
  late List<Attachment> deleted;
  late List<AttachmentView> revealed;
  late List<AttachmentView> copied;
  late List<AttachmentView> relocated;
  late List<AttachmentView> pinned;

  setUp(() {
    bus = AttachmentSyncService(store: AttachmentStore(repository: AttachmentRepository()))
      ..resetForTest();
    opened = [];
    pulled = [];
    deleted = [];
    revealed = [];
    copied = [];
    relocated = [];
    pinned = [];
  });

  Widget strip(List<AttachmentView> items, {double width = 420}) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      home: Scaffold(
        body: SizedBox(
          width: width,
          child: AttachmentStrip(
            items: items,
            jobs: bus,
            onOpen: opened.add,
            onPull: pulled.add,
            onDelete: deleted.add,
            onReveal: revealed.add,
            onCopyPath: copied.add,
            onRelocate: relocated.add,
            onPinCopy: pinned.add,
          ),
        ),
      ),
    );
  }

  /// 鼠标移到条目上：× 只在悬停时出现，测试要先把指针放上去
  Future<void> hover(WidgetTester tester, Finder target) async {
    final pointer = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await pointer.addPointer(location: Offset.zero);
    addTearDown(pointer.removePointer);
    await pointer.moveTo(tester.getCenter(target));
    await tester.pump();
  }

  testWidgets('本机有原件：显示文件名，点击打开，可以删除', (tester) async {
    final att = attachment('周报.pdf');
    await tester.pumpWidget(strip([AttachmentView(attachment: att, local: true)]));

    expect(find.text('周报.pdf'), findsOneWidget);
    expect(find.textContaining('在其它主机'), findsNothing);
    expect(
      find.byWidgetPredicate(
          (w) => w is CustomPaint && w.painter is DashedRoundedRectPainter),
      findsNothing,
    );

    await tester.tap(find.text('周报.pdf'));
    await tester.pump();
    expect(opened.single.fileName, '周报.pdf');
    expect(pulled, isEmpty);

    // × 收在悬停里：常驻会让一行少放一条附件
    expect(find.byIcon(Icons.close), findsNothing);
    await hover(tester, find.text('周报.pdf'));
    await tester.pump();
    expect(find.byIcon(Icons.close), findsOneWidget);

    await tester.tap(find.byIcon(Icons.close));
    await tester.pump();
    expect(deleted.single.uid, att.uid);
  });

  testWidgets('一行里的条目等宽：名字短的拉长到同一格', (tester) async {
    final items = [
      AttachmentView(attachment: attachment('a.pdf', uid: 'u1'), local: true),
      AttachmentView(attachment: attachment('一个非常非常长的附件文件名用来验证省略.pdf', uid: 'u2'), local: true),
      AttachmentView(attachment: attachment('台账说明.docx', uid: 'u3'), local: false),
      AttachmentView(attachment: attachment('b.txt', uid: 'u4'), local: true),
    ];
    await tester.pumpWidget(strip(items));

    // 每个条目恰好一个 Tooltip，用它的矩形量宽度
    final chips = find.byType(Tooltip);
    expect(chips, findsNWidgets(4));
    final widths = [for (var i = 0; i < 4; i++) tester.getRect(chips.at(i)).width];
    expect(widths, List.filled(4, widths.first), reason: '四条附件宽度必须一模一样');

    // 420 宽扣掉内边距切两列：第二条排在第一行右侧
    final first = tester.getRect(chips.at(0));
    final second = tester.getRect(chips.at(1));
    expect(second.top, first.top);
    expect(second.left, greaterThan(first.right));
    expect(tester.getRect(chips.at(2)).top, greaterThan(first.bottom));
  });

  testWidgets('原件在其它主机：带出主机名，点击进入中转而不是打开', (tester) async {
    await tester.pumpWidget(strip([AttachmentView(attachment: attachment('合同.docx'), local: false)]));

    expect(find.textContaining('在其它主机'), findsOneWidget);
    // 虚线边框是"这条还开不了"的主要视觉线索
    expect(
      find.byWidgetPredicate(
          (w) => w is CustomPaint && w.painter is DashedRoundedRectPainter),
      findsOneWidget,
    );

    await tester.tap(find.textContaining('在其它主机'));
    await tester.pump();
    expect(pulled, hasLength(1));
    expect(opened, isEmpty);
  });

  testWidgets('本机图片接上原件路径，非图片只画纸片', (tester) async {
    // 用仓库里现成的图：测试环境不解码真实 IO，只验接线
    const png = 'assets/icons/tray_preview.png';

    await tester.pumpWidget(strip([
      AttachmentView(
          attachment: attachment('现场照片.png'), local: true, localPath: png),
    ]));
    await tester.pump();
    final shown = tester.widget<Image>(find.byType(Image)).image;
    expect(shown, isA<ResizeImage>()); // cacheWidth 包一层：缩略图不整份解码原图
    final resized = shown as ResizeImage;
    expect(resized.width, 96);
    expect((resized.imageProvider as FileImage).file.path, png);

    await tester.pumpWidget(strip([
      AttachmentView(
          attachment: attachment('周报.pdf'), local: true, localPath: png),
    ]));
    await tester.pump();
    expect(find.byType(Image), findsNothing);
  });

  testWidgets('上传中：显示百分比并且收起删除按钮', (tester) async {
    final att = attachment('大文件.pdf', uid: 'uid-upload');
    bus.setJobForTest(
      att.uid,
      AttachmentJob(
        phase: AttachmentPhase.uploading,
        startedAt: DateTime(2026, 11, 20),
        progress: 0.4,
      ),
    );
    await tester.pumpWidget(strip([AttachmentView(attachment: att, local: true)]));

    expect(find.textContaining('上传中 40%'), findsOneWidget);
    expect(find.byType(LinearProgressIndicator), findsOneWidget);
    await hover(tester, find.textContaining('上传中 40%'));
    await tester.pump();
    expect(find.byIcon(Icons.close), findsNothing);
  });

  testWidgets('等待源主机上传：提示写在胶囊上', (tester) async {
    final att = attachment('票据.jpg', uid: 'uid-wait');
    bus.setJobForTest(
      att.uid,
      AttachmentJob(
        phase: AttachmentPhase.waitingSource,
        startedAt: DateTime(2026, 11, 20),
        message: '已登记请求，等「办公室电脑」上线上传',
      ),
    );
    await tester.pumpWidget(strip([AttachmentView(attachment: att, local: false)]));

    expect(find.textContaining('等待主机上传'), findsOneWidget);
    expect(find.byIcon(Icons.hourglass_top), findsOneWidget);
  });

  testWidgets('失败：胶囊标红字并保留删除入口', (tester) async {
    final att = attachment('说明.txt', uid: 'uid-fail');
    bus.setJobForTest(
      att.uid,
      AttachmentJob(
        phase: AttachmentPhase.failed,
        startedAt: DateTime(2026, 11, 20),
        message: '下载中断',
      ),
    );
    await tester.pumpWidget(strip([AttachmentView(attachment: att, local: false)]));

    expect(find.textContaining('同步失败'), findsOneWidget);
    await hover(tester, find.textContaining('同步失败'));
    await tester.pump();
    expect(find.byIcon(Icons.close), findsOneWidget);
  });

  testWidgets('最窄的一格也要把状态词读完整', (tester) async {
    // 488 宽切三列，每格约 150：副行再长就会被省略号吃掉，状态词必须留得下
    final failed = attachment('说明.txt', uid: 'uid-slim-failed');
    bus.setJobForTest(
      failed.uid,
      AttachmentJob(
        phase: AttachmentPhase.failed,
        startedAt: DateTime(2026, 11, 20),
        message: '下载中断',
      ),
    );
    await tester.pumpWidget(strip([
      AttachmentView(attachment: attachment('合同扫描件.pdf', uid: 'uid-slim-remote'), local: false),
      AttachmentView(attachment: failed, local: false),
      AttachmentView(
        attachment: attachment('失联文件.docx', uid: 'uid-slim-lost').copyWith(
          contentMode: Attachment.modeLink,
          sourcePath: r'D:\a.docx',
        ),
        local: false,
        source: AttachmentSource.missingOriginal,
      ),
      AttachmentView(
        attachment: attachment(
          '旧版.xlsx',
          uid: 'uid-slim-stale',
        ).copyWith(staleCopy: true),
        local: true,
        localPath: r'C:\b.xlsx',
      ),
    ], width: 488));

    for (final label in [
      '在其它主机',
      '同步失败 · 点重试',
      '原件不在了 · 右键定位',
      '云端有新版 · 点击取回',
    ]) {
      final paragraph = tester.renderObject<RenderParagraph>(find.text(label));
      expect(paragraph.didExceedMaxLines, isFalse, reason: '「$label」在最窄一格被省略号截断');
    }
  });

  testWidgets('本机原件：右键三项，复制路径拿到的是原件路径', (tester) async {
    const path = r'C:\WorkDiary\attachments\uid-1\周报.pdf';
    await tester.pumpWidget(strip([
      AttachmentView(attachment: attachment('周报.pdf'), local: true, localPath: path),
    ]));

    await tester.tap(find.text('周报.pdf'), buttons: kSecondaryButton);
    await tester.pumpAndSettle();
    expect(find.text('默认应用打开'), findsOneWidget);
    expect(find.text('在文件资源管理器中显示'), findsOneWidget);
    expect(find.text('复制路径'), findsOneWidget);

    await tester.tap(find.text('复制路径'));
    await tester.pumpAndSettle();
    expect(copied.single.localPath, path);
    expect(revealed, isEmpty);
    expect(opened, isEmpty);
  });

  testWidgets('附件库副本：右键多一项"改为引用本机文件"', (tester) async {
    const path = r'C:\WorkDiary\attachments\uid-1\台账.docx';
    await tester.pumpWidget(strip([
      AttachmentView(attachment: attachment('台账.docx'), local: true, localPath: path),
    ]));

    await tester.tap(find.text('台账.docx'), buttons: kSecondaryButton);
    await tester.pumpAndSettle();
    expect(find.text('改为引用本机文件…'), findsOneWidget);
    expect(find.text('另存副本到本机'), findsNothing);
    await tester.tap(find.text('改为引用本机文件…'));
    await tester.pumpAndSettle();
    expect(relocated.single.localPath, path);
  });

  testWidgets('引用原件：右键给"另存副本到本机"，提示语说明是引用', (tester) async {
    final linked = attachment('需求说明.txt').copyWith(
      contentMode: Attachment.modeLink,
      sourcePath: r'D:\工作\需求说明.txt',
    );
    await tester.pumpWidget(strip([
      AttachmentView(
        attachment: linked,
        local: true,
        source: AttachmentSource.linked,
        localPath: r'D:\工作\需求说明.txt',
      ),
    ]));

    await tester.tap(find.text('需求说明.txt'), buttons: kSecondaryButton);
    await tester.pumpAndSettle();
    expect(find.text('另存副本到本机'), findsOneWidget);
    expect(find.text('改为引用本机文件…'), findsNothing);
    await tester.tap(find.text('另存副本到本机'));
    await tester.pumpAndSettle();
    expect(pinned.single.attachment.uid, linked.uid);

    await tester.tap(find.text('需求说明.txt'));
    await tester.pumpAndSettle();
    expect(opened.single.uid, linked.uid, reason: '引用模式的左键照样打开用户自己的文件');
  });

  testWidgets('原件失联：条目标"原件不在了"，右键只给重新定位', (tester) async {
    final linked = attachment('合同.pdf').copyWith(
      contentMode: Attachment.modeLink,
      sourcePath: r'D:\工作\合同.pdf',
    );
    await tester.pumpWidget(strip([
      AttachmentView(
        attachment: linked,
        local: false,
        source: AttachmentSource.missingOriginal,
      ),
    ]));

    expect(find.textContaining('原件不在了'), findsOneWidget);
    expect(find.textContaining('在其它主机'), findsNothing);
    await tester.tap(find.textContaining('原件不在了'), buttons: kSecondaryButton);
    await tester.pumpAndSettle();
    expect(find.text('重新定位原件…'), findsOneWidget);
    expect(find.text('复制路径'), findsNothing);
    await tester.tap(find.text('重新定位原件…'));
    await tester.pumpAndSettle();
    expect(relocated.single.attachment.uid, linked.uid);

    // 失联时点条目本身 = 从别的主机取一份回来
    await tester.tap(find.textContaining('原件不在了'));
    await tester.pumpAndSettle();
    expect(pulled.single.uid, linked.uid);
  });

  testWidgets('云端有新版：不再走打开，点击改成取回', (tester) async {
    final stale = attachment('周报.pdf').copyWith(staleCopy: true);
    await tester.pumpWidget(strip([
      AttachmentView(attachment: stale, local: true, localPath: r'C:\a.pdf'),
    ]));

    expect(find.textContaining('云端有新版'), findsOneWidget);
    await tester.tap(find.text('周报.pdf'));
    await tester.pumpAndSettle();
    expect(pulled.single.uid, stale.uid);
    expect(opened, isEmpty);
  });

  testWidgets('本机原件：右键走"默认应用打开"和左键同一条路', (tester) async {
    await tester.pumpWidget(strip([
      AttachmentView(attachment: attachment('周报.pdf'), local: true, localPath: r'C:\a.pdf'),
    ]));

    await tester.tap(find.text('周报.pdf'), buttons: kSecondaryButton);
    await tester.pumpAndSettle();
    await tester.tap(find.text('默认应用打开'));
    await tester.pumpAndSettle();
    expect(opened.single.fileName, '周报.pdf');
    expect(copied, isEmpty);
  });

  testWidgets('原件在别的机器：右键不弹菜单，本机没有文件可操作', (tester) async {
    await tester.pumpWidget(strip([
      AttachmentView(attachment: attachment('合同.docx'), local: false),
    ]));

    await tester.tap(find.textContaining('在其它主机'), buttons: kSecondaryButton);
    await tester.pumpAndSettle();
    expect(find.text('复制路径'), findsNothing);
    expect(find.text('在文件资源管理器中显示'), findsNothing);
    expect(revealed, isEmpty);
    expect(copied, isEmpty);
  });

  testWidgets('进度变化后胶囊自己重建，不用刷新列表', (tester) async {
    final att = attachment('方案.pptx', uid: 'uid-live');
    await tester.pumpWidget(strip([AttachmentView(attachment: att, local: true)]));
    expect(find.text('方案.pptx'), findsOneWidget);

    bus.setJobForTest(
      att.uid,
      AttachmentJob(
        phase: AttachmentPhase.downloading,
        startedAt: DateTime(2026, 11, 20),
        progress: 0.25,
      ),
    );
    await tester.pump();
    expect(find.textContaining('下载中 25%'), findsOneWidget);
  });

  testWidgets('没有附件时不占位', (tester) async {
    await tester.pumpWidget(strip(const <AttachmentView>[]));
    expect(find.byType(Wrap), findsNothing);
  });
}
