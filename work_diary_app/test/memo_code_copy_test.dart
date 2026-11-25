import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:work_diary_app/models/memo.dart';
import 'package:work_diary_app/widgets/memo_card.dart';

/// 备忘代码块「复制」按钮回归：
/// 围栏代码块内出现复制按钮，复制内容不含 ```、保留缩进，多个代码块互不串。
void main() {
  Future<void> loadFont() async {
    final bytes = File('C:/Windows/Fonts/simhei.ttf').readAsBytesSync();
    final font = FontLoader('SimHei')
      ..addFont(Future.value(ByteData.sublistView(bytes)));
    await font.load();
  }

  late String? copied;

  setUp(() {
    copied = null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'Clipboard.setData') {
        copied = (call.arguments as Map)['text'] as String?;
      }
      return null;
    });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, null);
  });

  Widget wrap(String content) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: ThemeData(fontFamily: 'SimHei'),
      home: Scaffold(
        body: ListView(
          children: [
            MemoCard(
              memo: Memo(content: content, createdAt: DateTime(2026, 11, 18)),
              index: 0,
              onEdit: () {},
              onDelete: () {},
              keyword: '',
              timeText: '11-18 10:00',
            ),
          ],
        ),
      ),
    );
  }

  const code = '第一行\n  第二行（缩进）\n第三行';

  testWidgets('围栏代码块显示复制按钮，复制内容不含围栏、保留缩进', (tester) async {
    await loadFont();
    await tester.pumpWidget(wrap('代码示例：\n\n```\n$code\n```\n\n说明文字'));
    await tester.pumpAndSettle();

    expect(find.text('复制'), findsOneWidget);
    await tester.tap(find.text('复制'));
    await tester.pump();

    expect(find.text('已复制'), findsOneWidget);
    expect(copied, code);

    await tester.pump(const Duration(milliseconds: 1300));
    expect(find.text('复制'), findsOneWidget);
    expect(find.text('已复制'), findsNothing);
  });

  testWidgets('多个代码块各有按钮，只复制自己那一段', (tester) async {
    await loadFont();
    await tester.pumpWidget(wrap(
      '第一段：\n\n```\nAAA\n```\n\n第二段：\n\n```\nBBB\nCCC\n```',
    ));
    await tester.pumpAndSettle();

    expect(find.text('复制'), findsNWidgets(2));

    await tester.tap(find.text('复制').first);
    await tester.pump();
    expect(copied, 'AAA');
    expect(find.text('已复制'), findsOneWidget);
    expect(find.text('复制'), findsOneWidget);

    await tester.tap(find.text('复制'));
    await tester.pump();
    expect(copied, 'BBB\nCCC');

    await tester.pump(const Duration(milliseconds: 1300));
  });

  testWidgets('行内 code 不出现复制按钮', (tester) async {
    await loadFont();
    await tester.pumpWidget(wrap('只有行内 `code` 和 **加粗**，没有围栏代码块。'));
    await tester.pumpAndSettle();
    expect(find.text('复制'), findsNothing);
  });
}