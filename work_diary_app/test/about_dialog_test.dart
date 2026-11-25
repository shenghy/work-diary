import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show ByteData, FontLoader;
import 'package:flutter_test/flutter_test.dart';

import 'package:work_diary_app/main.dart';
import 'package:work_diary_app/theme/glass_palette.dart';
import 'package:work_diary_app/widgets/about_dialog.dart';

/// 「关于我们」弹窗回归：
/// - 两张码 + 官网 + 协议必须都在，微信号仍可复制；
/// - 版式钉死在 530 默认窗口里，宽度一变就容易把说明挤成三行或溢出；
/// - 二维码井恒白（深色档也不能染黑，否则扫不出来）。
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

    // 关窗 ✕ 和地球图标都靠 MaterialIcons 才不是豆腐块，字体由 SDK 提供。
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

  Future<void> preview(WidgetTester tester, String name, GlassPalette g,
      {double width = 530, bool golden = true}) async {
    await tester.binding.setSurfaceSize(Size(width, 760));
    final boundary = GlobalKey();
    await tester.pumpWidget(
      MaterialApp(
        theme: buildAppTheme(g),
        themeMode: ThemeMode.light,
        home: RepaintBoundary(
          key: boundary,
          child: Scaffold(
            backgroundColor: g.bgBottom,
            body: Center(
              child: AppAboutDialog(onShowAgreement: (_) {}),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 120));
    // 假时钟里 asset 通道的回包永远到不了，两张码会拍成空白井。
    // runAsync 放回真实事件循环，等图片解码完再截图，样张才代表实机。
    await tester.runAsync(() async {
      await tester.pump();
      await Future<void>.delayed(const Duration(milliseconds: 50));
      await tester.pump();
    });
    expect(tester.takeException(), isNull, reason: '$name 出现溢出/异常');

    for (final text in ['极简工作日记', '微信小程序', '已上线', '作者微信', '反馈入口', 'php100', 'work.jspang.com', '《用户协议》', '《隐私政策》', '导出日志', '确定']) {
      expect(find.text(text), findsOneWidget, reason: '$name 缺少「$text」');
    }
    // 弹窗必须整个落在窗口里：写死 452 时，475 宽的窗口会把右上角的 ✕ 裁掉。
    final close = tester.getRect(find.byIcon(Icons.close).first);
    expect(close.right, lessThan(width));
    expect(close.left, greaterThan(0));
    // 两张码卡等宽且同高起步：宽度靠 Expanded 平分，标题本身字数不同不能直接比。
    final mpCard = tester.getRect(
        find.ancestor(of: find.text('微信小程序'), matching: find.byType(Expanded)).first);
    final wxCard = tester.getRect(
        find.ancestor(of: find.text('作者微信'), matching: find.byType(Expanded)).first);
    expect((mpCard.width - wxCard.width).abs(), lessThan(1));
    expect(mpCard.top, wxCard.top);
    if (width >= 530) {
      // 内容列宽 452 + AlertDialog 内边距 20×2 = 492，
      // 必须塞进 insetPadding 收窄后的可用宽度（530 - 16×2 = 498）。
      final box = tester.getRect(find.text('极简工作日记').first);
      expect(box.left, greaterThan(0));
      expect(box.right, lessThan(width));
      // 220 = (452 - 12) / 2；被压回 410 时只有 199，这里钉住真实内容宽。
      expect(mpCard.width, greaterThanOrEqualTo(215));
      // 官网胶囊和协议必须同一行，且协议整句一行放得下；
      // 折行说明 452 的内容宽又被 AlertDialog 的 insetPadding 压掉了。
      final links = tester.getRect(find.text('work.jspang.com'));
      final agree = tester.getRect(find.text('使用本软件即代表同意'));
      final privacy = tester.getRect(find.text('《隐私政策》'));
      expect(links.top, lessThan(agree.bottom));
      expect(agree.top, lessThan(links.bottom));
      expect(privacy.top, agree.top);
    }

    if (golden) {
      await expectLater(find.byKey(boundary), matchesGoldenFile('goldens/$name.png'));
    }
    await tester.binding.setSurfaceSize(null);
  }

  testWidgets('关于弹窗样张（深色档）', (tester) async {
    await loadFonts();
    await preview(tester, 'about_dark', GlassPalette.dark);
  });

  testWidgets('关于弹窗样张（浅色档）', (tester) async {
    await loadFonts();
    await preview(tester, 'about_light', GlassPalette.light);
  });

  // 窗口拖窄到 475（实机就是这个宽）：弹窗不能溢出窗口把 ✕ 裁掉。
  testWidgets('窄窗口（475）不溢出', (tester) async {
    await loadFonts();
    await preview(tester, 'about_narrow', GlassPalette.light,
        width: 475, golden: false);
  });
}
