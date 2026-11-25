import 'dart:io';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:work_diary_app/models/task.dart';
import 'package:work_diary_app/widgets/task_card.dart';

/// 「回到计划中」按钮回归：
/// 执行中卡片不打开编辑页即可退回计划中，按钮只在执行中且有回调时出现。
void main() {
  Future<void> loadFont() async {
    final bytes = File('C:/Windows/Fonts/simhei.ttf').readAsBytesSync();
    final font = FontLoader('SimHei')
      ..addFont(Future.value(ByteData.sublistView(bytes)));
    await font.load();
  }

  Task task(TaskStatus status) => Task(
        title: '验证回到计划中',
        status: status,
        urgency: Urgency.normal,
        createdAt: DateTime.now(),
        sortOrder: 1,
        taskType: 1,
      );

  Widget wrap(
    Task value, {
    void Function(BuildContext)? onBackToPlanned,
  }) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: ThemeData(fontFamily: 'SimHei'),
      home: Scaffold(
        body: ListView(
          children: [
            TaskCard(
              task: value,
              onStatusToggle: (_) {},
              onBackToPlanned: onBackToPlanned,
              onDelete: () {},
              onDoubleTap: () {},
              onEdit: () {},
            ),
          ],
        ),
      ),
    );
  }

  Future<TestGesture> hoverLabel(WidgetTester tester, String label) async {
    final gesture = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await gesture.addPointer(location: Offset.zero);
    addTearDown(gesture.removePointer);
    await gesture.moveTo(tester.getCenter(find.text(label)));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    return gesture;
  }

  testWidgets('执行中卡片点「回到计划中」：不打开编辑，直接触发回调', (tester) async {
    await loadFont();
    var fired = 0;
    BuildContext? received;
    await tester.pumpWidget(wrap(
      task(TaskStatus.executing),
      onBackToPlanned: (ctx) {
        fired++;
        received = ctx;
      },
    ));
    expect(find.text('回到计划中'), findsOneWidget);

    final g = await hoverLabel(tester, '回到计划中');
    final pos = tester.getCenter(find.text('回到计划中'));
    await g.down(pos);
    await g.up();

    expect(fired, 1);
    expect(received, isNotNull);
  });

  testWidgets('只有执行中卡片显示「回到计划中」', (tester) async {
    await loadFont();
    for (final status in [TaskStatus.planned, TaskStatus.completed]) {
      await tester.pumpWidget(wrap(
        task(status),
        onBackToPlanned: (_) {},
      ));
      expect(find.text('回到计划中'), findsNothing, reason: '$status 不应显示');
    }
  });

  testWidgets('没有回调（如拖拽预览）时不显示按钮', (tester) async {
    await loadFont();
    await tester.pumpWidget(wrap(task(TaskStatus.executing)));
    expect(find.text('回到计划中'), findsNothing);
  });
}
