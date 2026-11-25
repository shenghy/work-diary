import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:work_diary_app/widgets/title_bar.dart';

void main() {
  testWidgets('自绘标题栏：高度 40，包含置顶 / 最小化 / 关闭三个按钮', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: Column(children: [AppTitleBar()]),
        ),
      ),
    );

    expect(find.text('极简工作日记'), findsOneWidget);
    expect(find.byIcon(Icons.push_pin_outlined), findsOneWidget);
    expect(find.byIcon(Icons.remove), findsOneWidget);
    expect(find.byIcon(Icons.close), findsOneWidget);

    final size = tester.getSize(find.byType(AppTitleBar));
    expect(size.height, kTitleBarHeight);

    // 三个按钮各占 40 逻辑像素，正好等于原生侧预留的按钮区宽度
    expect(kWindowButtonWidth * 3, 120);
  });
}
