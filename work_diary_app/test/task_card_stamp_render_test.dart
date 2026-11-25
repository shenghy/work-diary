import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:work_diary_app/models/task.dart';
import 'package:work_diary_app/widgets/task_card.dart';

/// 过期图章渲染验证：
/// 渲染「过期任务 + 正常任务」两张卡片，断言图章可见、正常卡片无图章
/// （右上角红色图章「已过期」，底部标签行不再溢出）
void main() {
  testWidgets('过期图章渲染', (tester) async {
    // 加载系统中文字体，避免测试环境文字渲染成方块
    final fontBytes = File('C:/Windows/Fonts/simhei.ttf').readAsBytesSync();
    final font = FontLoader('SimHei')
      ..addFont(Future.value(ByteData.sublistView(fontBytes)));
    await font.load();

    final now = DateTime.now();
    final expired = Task(
      title: '写一篇AI大模型PK对战稿。25.64元',
      status: TaskStatus.planned,
      urgency: Urgency.normal,
      createdAt: now.subtract(const Duration(days: 3)),
      planStartAt: now.subtract(const Duration(days: 3)),
      dueAt: now.subtract(const Duration(days: 3)),
      sortOrder: 1,
      taskType: 1,
    );
    final normal = Task(
      title: '每天走路听学习内容一小时',
      status: TaskStatus.planned,
      urgency: Urgency.important,
      createdAt: now,
      planStartAt: now,
      dueAt: now.add(const Duration(hours: 2)),
      sortOrder: 2,
      taskType: 1,
    );

    Widget wrap() => MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: ThemeData(fontFamily: 'SimHei'),
      home: Scaffold(
        body: ListView(
          padding: const EdgeInsets.symmetric(vertical: 6),
          children: [
            TaskCard(
              task: expired,
              onStatusToggle: (_) {},
              onDelete: () {},
              onDoubleTap: () {},
              onEdit: () {},
            ),
            TaskCard(
              task: normal,
              onStatusToggle: (_) {},
              onDelete: () {},
              onDoubleTap: () {},
              onEdit: () {},
            ),
          ],
        ),
      ),
    );

    await tester.pumpWidget(wrap());
    // 让入场/闪烁动画走一帧，取一个中间透明度（图章可见、非全透明）
    await tester.pump(const Duration(milliseconds: 325));

    expect(find.text('已过期'), findsOneWidget, reason: '过期卡片应显示「已过期」图章');
    expect(find.text('每天走路听学习内容一小时'), findsOneWidget, reason: '正常卡片应正常渲染');
    // 正常卡片不应出现图章（全页仅过期卡片一枚）
    expect(
      find.byType(Container).evaluate().where((e) {
        final deco = (e.widget as Container).decoration;
        return deco is BoxDecoration &&
            deco.border != null &&
            deco.border!.top.width > 0 &&
            (deco.border!.top.color == const Color(0xFFF87171) ||
                deco.border!.top.color == const Color(0xB3F87171));
      }),
      isNotEmpty,
      reason: '图章红框存在（视觉核对：右上角小号方章「已过期」）',
    );
  });
}
