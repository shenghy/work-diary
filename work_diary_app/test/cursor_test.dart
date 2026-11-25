import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:work_diary_app/main.dart';
import 'package:work_diary_app/models/task.dart';
import 'package:work_diary_app/theme/glass_palette.dart';
import 'package:work_diary_app/widgets/task_card.dart';

Task _longTask() => Task(
      title: '【Trea商单】上线日期：11月5日\n'
          '[x] 10月30日：产品试用和确定选题，下午提交选题，并确认选题。\n'
          '[ ] 11月02日：逐字稿提交甲方审核，根据甲方要求修改逐字稿。\n'
          '这是一段很长很长的正文，用来把卡片撑成需要展开的长文本状态，'
          '这样才会出现展开/收起按钮，也才能顺带验证它的光标。'
          '为了保证长度超过 180 个字符的折叠阈值，这里再多写一些说明文字，'
          '包括项目背景、验收标准和交付时间等细节内容，确保卡片一定处于可折叠状态。',
      createdAt: DateTime(2026, 11, 1, 6, 42),
      urgency: Urgency.important,
    );

Widget _host() => MaterialApp(
      theme: ThemeData(
        useMaterial3: true,
        // 与线上一致：按钮光标由主题统一声明
        textButtonTheme: const TextButtonThemeData(
          style: ButtonStyle(mouseCursor: WidgetStateMouseCursor.clickable),
        ),
      ),
      home: Scaffold(
        body: Center(
          child: SizedBox(
            // 560 而不是 500：卡片底部完整布局最少需要 451px 可用宽度
            //（500 的卡只有 448，会切成纯图标模式，文字按钮就不存在了，
            //  见 task_card_footer_layout_test.dart）。这里只验证光标。
            width: 560,
            child: TaskCard(
              task: _longTask(),
              onStatusToggle: (_) {},
              onDelete: () {},
              onDoubleTap: () {},
              onEdit: () {},
              onSubTaskChanged: (_) {},
            ),
          ),
        ),
      ),
    );

void main() {
  testWidgets('操作按钮 / 展开按钮 / 子任务行 都是小手光标', (tester) async {
    await tester.pumpWidget(_host());

    final gesture = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await gesture.addPointer(location: Offset.zero);
    addTearDown(gesture.removePointer);

    // 先把鼠标移进卡片，让操作按钮淡入并启用
    await gesture.moveTo(tester.getCenter(find.byType(TaskCard)));
    await tester.pump(const Duration(milliseconds: 400));

    Future<MouseCursor?> cursorAt(Finder finder) async {
      await gesture.moveTo(tester.getCenter(finder));
      await tester.pump(const Duration(milliseconds: 120));
      return RendererBinding.instance.mouseTracker.debugDeviceActiveCursor(1);
    }

    expect(await cursorAt(find.text('修改')), SystemMouseCursors.click);
    expect(await cursorAt(find.text('删除')), SystemMouseCursors.click);
    expect(await cursorAt(find.text('开始')), SystemMouseCursors.click);
    expect(await cursorAt(find.text('展开')), SystemMouseCursors.click);
    expect(
      await cursorAt(find.textContaining('10月30日')),
      SystemMouseCursors.click,
    );

    // 卡片空白区仍是箭头
    final cardRect = tester.getRect(find.byType(TaskCard));
    await gesture.moveTo(Offset(cardRect.left + 4, cardRect.top + 4));
    await tester.pump(const Duration(milliseconds: 120));
    expect(
      RendererBinding.instance.mouseTracker.debugDeviceActiveCursor(1),
      SystemMouseCursors.basic,
    );
  });

  testWidgets('WidgetStateMouseCursor.clickable 在禁用态回到箭头', (tester) async {
    expect(
      WidgetStateMouseCursor.clickable.resolve(<WidgetState>{}),
      SystemMouseCursors.click,
    );
    expect(
      WidgetStateMouseCursor.clickable
          .resolve(<WidgetState>{WidgetState.disabled}),
      SystemMouseCursors.basic,
    );
  });

  test('线上主题确实设置了按钮光标', () {
    final theme = buildAppTheme(GlassPalette.dark);
    expect(
      theme.textButtonTheme.style?.mouseCursor?.resolve(<WidgetState>{}),
      SystemMouseCursors.click,
    );
  });

  test('深浅两档各自挂上令牌，取色不会串档', () {
    expect(
      buildAppTheme(GlassPalette.light).extension<GlassPalette>(),
      isA<GlassPalette>(),
    );
    expect(
      buildAppTheme(GlassPalette.light)
          .extension<GlassPalette>()!
          .isLight,
      isTrue,
    );
    expect(
      buildAppTheme(GlassPalette.dark).extension<GlassPalette>()!.isLight,
      isFalse,
    );
  });
}
