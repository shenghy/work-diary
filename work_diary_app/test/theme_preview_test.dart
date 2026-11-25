import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show ByteData, FontLoader;
import 'package:flutter_test/flutter_test.dart';

import 'package:work_diary_app/main.dart';
import 'package:work_diary_app/models/attachment.dart';
import 'package:work_diary_app/models/memo.dart';
import 'package:work_diary_app/models/task.dart';
import 'package:work_diary_app/services/attachment_store.dart';
import 'package:work_diary_app/services/attachment_sync_service.dart';
import 'package:work_diary_app/theme/glass_palette.dart';
import 'package:work_diary_app/widgets/attachment_strip.dart';
import 'package:work_diary_app/widgets/aurora_background.dart';
import 'package:work_diary_app/widgets/memo_card.dart';
import 'package:work_diary_app/widgets/task_card.dart';

/// 深浅两档的「组件样张」：任务列表页在真实极光 + 全窗玻璃上的样子。
///
/// 看板样张在 stats_capture_test.dart，这里守的是列表侧——卡片材质、紧急度条、
/// 过期印章、循环徽标、备忘纸面这些一换档就最容易翻车的表面。
/// 刷新基线：`flutter test test/theme_preview_test.dart --update-goldens`。
void main() {
  Future<void> loadFonts() async {
    const files = [
      'assets/fonts/AlibabaPuHuiTi-3-55-Regular.ttf',
      'assets/fonts/AlibabaPuHuiTi-3-65-Medium.ttf',
      'assets/fonts/AlibabaPuHuiTi-3-85-Bold.ttf',
    ];
    final loader = FontLoader('AlibabaPuHuiTi');
    for (final path in files) {
      loader.addFont(Future.value(ByteData.sublistView(File(path).readAsBytesSync())));
    }
    await loader.load();

    // MaterialIcons 不在项目 assets 里，由 SDK 提供；不加载的话样张里每个 Icon
    // 都是豆腐块，日历/时钟这类「画没画出来」就守不住了。
    final root = Platform.environment['FLUTTER_ROOT'] ??
        File(Platform.resolvedExecutable).parent.parent.parent.parent.parent.path;
    final iconFont =
        File('$root/bin/cache/artifacts/material_fonts/materialicons-regular.otf');
    if (iconFont.existsSync()) {
      final iconLoader = FontLoader('MaterialIcons')
        ..addFont(Future.value(ByteData.sublistView(iconFont.readAsBytesSync())));
      await iconLoader.load();
    }
  }

  final now = DateTime(2026, 11, 10, 15, 30);

  Task task({
    required int id,
    required TaskStatus status,
    Urgency urgency = Urgency.normal,
    int taskType = 1,
    int repeatType = 0,
    Duration? overdue,
    String? title,
  }) {
    return Task(
      id: id,
      title: title ??
          switch (status) {
            TaskStatus.planned => '整理季度述职材料',
            TaskStatus.executing => '本周成功减肥2斤',
            TaskStatus.completed => '发布 v1.0.19 客户端',
          },
      status: status,
      urgency: urgency,
      createdAt: now.subtract(const Duration(days: 2)),
      startedAt: status == TaskStatus.planned ? null : now.subtract(const Duration(hours: 5)),
      completedAt: status == TaskStatus.completed ? now : null,
      planStartAt: now.add(const Duration(days: 3)),
      dueAt: overdue == null
          ? now.add(const Duration(days: 5))
          : now.add(overdue),
      taskType: taskType,
      repeatType: repeatType,
      repeatGroupId: repeatType == 0 ? null : 'g$id',
    );
  }

  List<Widget> taskCards() => [
        TaskCard(
          task: task(id: 1, status: TaskStatus.executing),
          onStatusToggle: (_) {},
          onDelete: () {},
          onDoubleTap: () {},
          onEdit: () {},
          // 固定基准时间：底部日期标签不随真实日期漂移。
          now: now,
        ),
        TaskCard(
          // 过期：印章 + 红色描边，浅色档最容易糊
          task: task(
            id: 2,
            status: TaskStatus.planned,
            urgency: Urgency.urgent,
            overdue: const Duration(hours: -30),
          ),
          onStatusToggle: (_) {},
          onDelete: () {},
          onDoubleTap: () {},
          onEdit: () {},
          // 固定基准时间：底部日期标签不随真实日期漂移。
          now: now,
        ),
        TaskCard(
          // 子任务进度 + 循环徽标 + 个人类型标签
          task: task(
            id: 3,
            status: TaskStatus.completed,
            urgency: Urgency.important,
            taskType: 0,
            repeatType: 1,
            title: '发布客户端\n1. 打包\n2. 上传\n- 写更新日志',
          ),
          onStatusToggle: (_) {},
          onDelete: () {},
          onDoubleTap: () {},
          onEdit: () {},
          // 固定基准时间：底部日期标签不随真实日期漂移。
          now: now,
        ),
        TaskCard(
          task: task(id: 4, status: TaskStatus.planned, taskType: 0),
          onStatusToggle: (_) {},
          onDelete: () {},
          onDoubleTap: () {},
          onEdit: () {},
          // 固定基准时间：底部日期标签不随真实日期漂移。
          now: now,
        ),
      ];

  /// 备忘纸卡：纸面 + 顶部色条 + 外侧阴影。浅色档以前用 boxShadow，
  /// 阴影会从半透明纸面里透出来把整张卡压成近黑色，这两张样张钉住那个回归。
  List<Widget> memoCards() => [
        MemoCard(
          memo: Memo(
            id: 1,
            content: '季度述职材料记得补上「多端同步」那一页，'
                '并把浅色档的验收截图一起放进附件里。',
            createdAt: now.subtract(const Duration(days: 1)),
          ),
          index: 0,
          onEdit: () {},
          onDelete: () {},
          keyword: '浅色档',
          timeText: '1 天前',
        ),
        MemoCard(
          // Markdown 内容：标题 / 列表 / 引用，走另一套排版
          memo: Memo(
            id: 2,
            content: '## 发布 v1.0.20\n- 打包 Windows 安装包\n'
                '- 上传到服务器\n> 别忘了写更新日志',
            createdAt: now.subtract(const Duration(days: 4)),
          ),
          index: 1,
          onEdit: () {},
          onDelete: () {},
          keyword: '',
          timeText: '4 天前',
        ),
        MemoCard(
          // 超过 150 字的正文：默认折成 4 行 + 右下角「展开」按钮
          memo: Memo(
            id: 3,
            content: '这周的复盘要点：桌面端浅色档的玻璃材质已经全部换成令牌，'
                '但备忘纸卡漏掉了外侧阴影那一层，半透明的纸面会把 boxShadow '
                '透出来，整张卡压成近黑色。修法是改成只画外侧的阴影绘制器，'
                '再把浅色档的纸面令牌抬亮，让纸面接近白色但保留一点冷调。'
                '另外左下角菜单按钮的白底白杠也要一起修，否则浅色档根本看不出'
                '那里有个按钮。下周把安卓端的同步链路再压一遍延迟。',
            createdAt: now.subtract(const Duration(days: 9)),
          ),
          index: 2,
          onEdit: () {},
          onDelete: () {},
          keyword: '',
          timeText: '9 天前',
        ),
      ];

  /// 附件条样张：纸片、真缩略图、原件在别的机器、正在上传各一条。
  List<Widget> attachmentCards() {
    Attachment att(String uid, String name, {String host = '办公室电脑'}) =>
        Attachment(
          uid: uid,
          parentKind: Attachment.kindTask,
          parentLocalId: 5,
          ownerDeviceId: host,
          ownerDeviceName: host,
          fileName: name,
          fileSize: uid == 'b' ? 25 * 1024 * 1024 : 184 * 1024,
          sha256: uid,
          mime: '',
          createdAt: now.subtract(const Duration(days: 1)),
        );
    AttachmentSyncService.instance
      ..resetForTest()
      ..setJobForTest(
        'c',
        AttachmentJob(
          phase: AttachmentPhase.uploading,
          startedAt: now,
          progress: 0.62,
        ),
      );
    return [
      TaskCard(
        task: task(id: 5, status: TaskStatus.executing, title: '整理客户投诉台账'),
        onStatusToggle: (_) {},
        onDelete: () {},
        onDoubleTap: () {},
        onEdit: () {},
        now: now,
        attachments: AttachmentStrip(
          items: [
            AttachmentView(attachment: att('a', '台账说明.docx'), local: true),
            // 本机图片走真缩略图：拿仓库里现成的 png 当原件，样张才可复现
            AttachmentView(
              attachment: att('b', '现场照片.jpg'),
              local: true,
              localPath: 'assets/icons/tray_preview.png',
            ),
            AttachmentView(attachment: att('c', '录音转写.txt'), local: true),
            AttachmentView(attachment: att('e', '合同扫描件.pdf'), local: false),
          ],
          onOpen: (_) {},
          onPull: (_) {},
          onDelete: (_) {},
          onReveal: (_) {},
          onCopyPath: (_) {},
        ),
      ),
      MemoCard(
        memo: Memo(
          id: 4,
          content: '附件条在纸卡下方，一行里每条等宽铺满，长文件名省略号收尾。',
          createdAt: now.subtract(const Duration(hours: 6)),
        ),
        index: 0,
        onEdit: () {},
        onDelete: () {},
        keyword: '',
        timeText: '6 小时前',
        attachments: AttachmentStrip(
          padding: const EdgeInsets.only(bottom: 4),
          items: [
            AttachmentView(
              attachment: att('d', 'very-long-attachment-file-name-for-ellipsis-check.pdf'),
              local: true,
            ),
            // 引用模式的原件被移走：卡片要说"不在了"，而不是骗人"在本机"
            AttachmentView(
              attachment: att('f', '报价单.xlsx').copyWith(
                contentMode: Attachment.modeLink,
                sourcePath: r'D:\工作\报价单.xlsx',
              ),
              local: false,
              source: AttachmentSource.missingOriginal,
            ),
            // 别的机器改了内容：本机这份是旧版
            AttachmentView(
              attachment: att('g', '周报.docx').copyWith(staleCopy: true),
              local: true,
            ),
          ],
          onOpen: (_) {},
          onPull: (_) {},
          onDelete: (_) {},
          onReveal: (_) {},
          onCopyPath: (_) {},
        ),
      ),
    ];
  }

  Future<void> preview(WidgetTester tester, String name, GlassPalette g,
      {required List<Widget> cards}) async {
    // 530 = 真实默认窗口宽（windows/runner/main.cpp 的 default_size），
    // 样张要落在「标签带图标 + 文字按钮」这一档，才守得住新样式。
    await tester.binding.setSurfaceSize(const Size(530, 760));
    final boundary = GlobalKey();
    await tester.pumpWidget(
      MaterialApp(
        theme: buildAppTheme(g),
        themeMode: ThemeMode.light,
        home: RepaintBoundary(
          key: boundary,
          child: Scaffold(
            backgroundColor: Colors.transparent,
            body: Stack(
              children: [
                const Positioned.fill(child: AuroraBackground()),
                const Positioned.fill(child: WindowGlass()),
                Positioned.fill(
                  child: ListView(
                    padding: const EdgeInsets.fromLTRB(0, 56, 0, 24),
                    children: cards,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 120));
    // 停在固定相位截图才可复现
    await tester.pump(const Duration(seconds: 6));
    expect(tester.takeException(), isNull);
    await expectLater(find.byKey(boundary), matchesGoldenFile('goldens/$name.png'));
    await tester.binding.setSurfaceSize(null);
  }

  testWidgets('任务列表样张（深色档）', (tester) async {
    await loadFonts();
    await preview(tester, 'list_dark', GlassPalette.dark, cards: taskCards());
  });

  testWidgets('任务列表样张（浅色档）', (tester) async {
    await loadFonts();
    await preview(tester, 'list_light', GlassPalette.light, cards: taskCards());
  });

  testWidgets('备忘纸卡样张（深色档）', (tester) async {
    await loadFonts();
    await preview(tester, 'memo_dark', GlassPalette.dark, cards: memoCards());
  });

  testWidgets('备忘纸卡样张（浅色档）', (tester) async {
    await loadFonts();
    await preview(tester, 'memo_light', GlassPalette.light, cards: memoCards());
  });

  testWidgets('附件胶囊样张（深色档）', (tester) async {
    await loadFonts();
    await preview(tester, 'attachment_dark', GlassPalette.dark,
        cards: attachmentCards());
  });

  testWidgets('附件胶囊样张（浅色档）', (tester) async {
    await loadFonts();
    await preview(tester, 'attachment_light', GlassPalette.light,
        cards: attachmentCards());
  });
}
