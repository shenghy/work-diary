import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:work_diary_app/models/task.dart';
import 'package:work_diary_app/widgets/task_card.dart';

/// 卡片底部布局回归：
///
/// 旧实现是固定 `Row` + `Spacer`，卡片一窄，右侧操作按钮被外层 Stack 直接裁掉
///（只看到半个"删"字，且没有任何 overflow 提示）。现在：
/// - 宽度 < 阈值：操作按钮切成纯图标（文字进 Tooltip）+ 日期文案缩成 11/2；
/// - 标签区放进 Expanded + Wrap，极端窄时换行兜底，永不裁切。
void main() {
  Future<void> loadFont() async {
    final bytes = File('C:/Windows/Fonts/simhei.ttf').readAsBytesSync();
    final font = FontLoader('SimHei')
      ..addFont(Future.value(ByteData.sublistView(bytes)));
    await font.load();
  }

  /// 最坏情况：四个标签全都在（紧急度/类型/开始/完成）
  Task fullTask() {
    final now = DateTime.now();
    return Task(
      title: '本周成功减肥2斤',
      status: TaskStatus.executing,
      urgency: Urgency.normal,
      createdAt: now,
      startedAt: now,
      // 用 3/5 天后（不是今天/明天），保证走"月日"文案分支
      planStartAt: now.add(const Duration(days: 3)),
      dueAt: now.add(const Duration(days: 5)),
      taskType: 1,
    );
  }

  Widget wrap(Task task, double width) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: ThemeData(fontFamily: 'SimHei'),
      home: Scaffold(
        body: Align(
          alignment: Alignment.topLeft,
          child: SizedBox(
            width: width,
            child: TaskCard(
              task: task,
              onStatusToggle: (_) {},
              onDelete: () {},
              onDoubleTap: () {},
              onEdit: () {},
            ),
          ),
        ),
      ),
    );
  }

  testWidgets('窄卡片（360 / 420）不裁切，操作按钮切成纯图标', (tester) async {
    await loadFont();
    for (final width in <double>[360, 420]) {
      await tester.pumpWidget(wrap(fullTask(), width));
      await tester.pump();
      expect(tester.takeException(), isNull, reason: 'width=$width 出现溢出/异常');
      expect(find.text('修改'), findsNothing, reason: 'width=$width 应为图标模式');
      expect(find.byTooltip('修改'), findsOneWidget);
      expect(find.byTooltip('删除'), findsOneWidget);
      // 主操作按钮的文字同样收起
      expect(find.byTooltip('完成'), findsOneWidget);
    }
  });

  testWidgets('默认窗口宽度（530）保持原来的「图标 + 文字」', (tester) async {
    await loadFont();
    await tester.pumpWidget(wrap(fullTask(), 530));
    await tester.pump();
    expect(tester.takeException(), isNull);
    expect(find.text('修改'), findsOneWidget);
    expect(find.text('完成'), findsOneWidget);
    expect(find.byTooltip('修改'), findsNothing);
    // 日期标签带日历/时钟图标，且四个标签仍然排在同一行（没有被迫换行）
    expect(find.byIcon(Icons.event_note), findsOneWidget);
    expect(find.byIcon(Icons.schedule), findsOneWidget);
    final wrapBox = find
        .descendant(of: find.byType(TaskCard), matching: find.byType(Wrap))
        .first;
    expect(tester.getSize(wrapBox).height, lessThan(30));
  });

  testWidgets('520px 卡片（可用宽度 < 476）收成纯图标，标签仍不挤成两行', (tester) async {
    await loadFont();
    await tester.pumpWidget(wrap(fullTask(), 520));
    await tester.pump();
    expect(tester.takeException(), isNull);
    expect(find.text('修改'), findsNothing);
    expect(find.byTooltip('修改'), findsOneWidget);
  });

  testWidgets('500px 卡片（可用宽度 < 476）切成图标，不再被裁', (tester) async {
    await loadFont();
    await tester.pumpWidget(wrap(fullTask(), 500));
    await tester.pump();
    expect(tester.takeException(), isNull);
    expect(find.text('删除'), findsNothing);
    expect(find.byTooltip('删除'), findsOneWidget);
  });

  testWidgets('紧凑模式下日期文案缩成 11/2（优化1）', (tester) async {
    await loadFont();
    await tester.pumpWidget(wrap(fullTask(), 380));
    await tester.pump();
    expect(tester.takeException(), isNull);
    final d = DateTime.now().add(const Duration(days: 5));
    expect(find.text('${d.month}/${d.day}完成'), findsOneWidget);
    expect(find.text('${d.month}月${d.day}日完成'), findsNothing);
  });

  testWidgets('极窄（320）也能放下：标签换行兜底，不抛 overflow', (tester) async {
    await loadFont();
    await tester.pumpWidget(wrap(fullTask(), 320));
    await tester.pump();
    expect(tester.takeException(), isNull);
    expect(find.byTooltip('删除'), findsOneWidget);
  });
}
