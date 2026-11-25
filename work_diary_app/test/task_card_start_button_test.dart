import 'dart:io';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:work_diary_app/models/task.dart';
import 'package:work_diary_app/widgets/task_card.dart';

/// 「开始」按钮首次点击失效问题回归测试。
/// 根因：卡片外层 GestureDetector(onTap+onDoubleTap) 的 DoubleTapGestureRecognizer
/// 每次点按抬起后 hold 住手势竞技场约 300ms，卡片内按钮点击被延迟；
/// 300ms 内连点还会破坏竞技场状态导致点击被吞。修复后：
/// 按钮点击应立即生效、连点不丢、卡片双击编辑保留、hover 首帧即可点击。
void main() {
  Future<void> loadFont() async {
    final fontBytes = File('C:/Windows/Fonts/simhei.ttf').readAsBytesSync();
    final font = FontLoader('SimHei')
      ..addFont(Future.value(ByteData.sublistView(fontBytes)));
    await font.load();
  }

  Task plannedTask([String title = '验证开始按钮点击']) => Task(
        title: title,
        status: TaskStatus.planned,
        urgency: Urgency.normal,
        createdAt: DateTime.now(),
        sortOrder: 1,
        taskType: 1,
      );

  Widget wrap(
    Task task, {
    required void Function(BuildContext) onStatusToggle,
    required VoidCallback onDoubleTap,
  }) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: ThemeData(fontFamily: 'SimHei'),
      home: Scaffold(
        body: ListView(
          children: [
            TaskCard(
              task: task,
              onStatusToggle: onStatusToggle,
              onDelete: () {},
              onDoubleTap: onDoubleTap,
              onEdit: () {},
            ),
          ],
        ),
      ),
    );
  }

  /// 鼠标进入按钮位置并让 hover/淡入动画稳定
  Future<TestGesture> hoverToButton(WidgetTester tester) async {
    final gesture = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await gesture.addPointer(location: Offset.zero);
    addTearDown(gesture.removePointer);
    await gesture.moveTo(tester.getCenter(find.text('开始')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    return gesture;
  }

  testWidgets('单击开始：抬起后立即生效，不再延迟 300ms', (tester) async {
    await loadFont();
    var fired = 0;
    var dblTap = 0;
    await tester.pumpWidget(wrap(plannedTask(),
        onStatusToggle: (_) => fired++, onDoubleTap: () => dblTap++));
    final g = await hoverToButton(tester);

    final pos = tester.getCenter(find.text('开始'));
    await g.down(pos);
    await g.up();
    expect(fired, 1, reason: '抬起后立即触发，不经过任何泵帧/超时');
    expect(dblTap, 0);
  });

  testWidgets('快速连点开始按钮：每次都生效，不被吞', (tester) async {
    await loadFont();
    var fired = 0;
    await tester.pumpWidget(wrap(plannedTask(),
        onStatusToggle: (_) => fired++, onDoubleTap: () {}));
    final g = await hoverToButton(tester);

    final pos = tester.getCenter(find.text('开始'));
    await g.down(pos);
    await g.up();
    await tester.pump(const Duration(milliseconds: 80));
    await g.down(pos);
    await g.up();
    expect(fired, 2, reason: '两次快速点击都应立即生效');
  });

  /// 卡片空白点：底部标签行中间（标签与按钮之间的 Spacer 区域）
  Offset cardBlankSpot(WidgetTester tester) {
    final cardRect = tester.getRect(find.byType(TaskCard));
    return Offset(cardRect.center.dx, cardRect.bottom - 22);
  }

  testWidgets('卡片空白区域双击：仍触发 onDoubleTap（打开编辑）', (tester) async {
    await loadFont();
    var fired = 0;
    var dblTap = 0;
    await tester.pumpWidget(wrap(plannedTask(),
        onStatusToggle: (_) => fired++, onDoubleTap: () => dblTap++));
    final g2 = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await g2.addPointer(location: Offset.zero);
    addTearDown(g2.removePointer);

    final spot = cardBlankSpot(tester);
    await g2.moveTo(spot);
    await g2.down(spot);
    await g2.up();
    await tester.pump(const Duration(milliseconds: 80));
    await g2.down(spot);
    await g2.up();
    await tester.pump();
    expect(dblTap, 1, reason: '卡片双击编辑功能必须保留');
    expect(fired, 0, reason: '点的是卡片空白，不应触发状态切换');
  });

  testWidgets('卡片空白区域单击：不触发双击编辑', (tester) async {
    await loadFont();
    var dblTap = 0;
    await tester.pumpWidget(wrap(plannedTask(),
        onStatusToggle: (_) {}, onDoubleTap: () => dblTap++));
    final g = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await g.addPointer(location: Offset.zero);
    addTearDown(g.removePointer);

    final spot = cardBlankSpot(tester);
    await g.moveTo(spot);
    await g.down(spot);
    await g.up();
    await tester.pump(const Duration(milliseconds: 500));
    expect(dblTap, 0);
  });

  testWidgets('hover 后第 1 帧点击开始：立即生效（不等淡入完成）', (tester) async {
    await loadFont();
    var fired = 0;
    await tester.pumpWidget(wrap(plannedTask(),
        onStatusToggle: (_) => fired++, onDoubleTap: () {}));

    final g = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await g.addPointer(location: Offset.zero);
    addTearDown(g.removePointer);
    await g.moveTo(tester.getCenter(find.text('开始')));
    await tester.pump(); // 仅 1 帧：_isHovered 生效，淡入动画尚未推进
    await g.down(tester.getCenter(find.text('开始')));
    await g.up();
    expect(fired, 1, reason: 'hover 后第 1 帧点击即应生效');
  });
}
