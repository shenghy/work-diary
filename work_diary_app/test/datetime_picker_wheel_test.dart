import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:work_diary_app/widgets/datetime_picker_sheet.dart';

/// 回归测试：桌面端日期时间滚轮，鼠标滚一格只能移动 1 项。
///
/// 背景：Windows 一格滚轮的 scrollDelta.dy 是 100 逻辑像素，而滚轮每项只有
/// 40 像素，交给 ListWheelScrollView 默认滚动会一次跳 2~3 项（28 号滚一格
/// 直接到 30 号）。修复后由 Listener 抢先消费事件，每次固定移动 1 项。
void main() {
  testWidgets('鼠标滚轮一格只移动一项（日期 / 小时 / 分钟）', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: DateTimePickerSheet(
            initialDateTime: DateTime(2026, 10, 28, 9, 30),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final wheels =
        tester.widgetList<ListWheelScrollView>(find.byType(ListWheelScrollView));
    expect(wheels.length, 3);
    final controllers = wheels
        .map((w) => w.controller! as FixedExtentScrollController)
        .toList();

    final dayBefore = controllers[0].selectedItem;
    final hourBefore = controllers[1].selectedItem;
    final minuteBefore = controllers[2].selectedItem;

    Offset centerOf(int index) => tester.getCenter(
          find.byType(ListWheelScrollView).at(index),
        );

    final pointer = TestPointer(1, PointerDeviceKind.mouse);

    Future<void> wheel(int column, double dy) async {
      await tester.sendEventToBinding(pointer.hover(centerOf(column)));
      await tester.sendEventToBinding(pointer.scroll(Offset(0, dy)));
      await tester.pumpAndSettle();
    }

    // 日期列：一格 = 1 天，反方向同样
    await wheel(0, 100);
    expect(controllers[0].selectedItem, dayBefore + 1,
        reason: '日期列滚一格应只前进 1 天，不能跳到 +2/+3');
    await wheel(0, -100);
    expect(controllers[0].selectedItem, dayBefore);

    // 小时列：一格 = 1 小时
    await wheel(1, 100);
    expect(controllers[1].selectedItem, hourBefore + 1,
        reason: '小时列滚一格应只前进 1 小时');
    await wheel(1, -100);
    expect(controllers[1].selectedItem, hourBefore);

    // 分钟列：一格 = 1 分钟
    await wheel(2, 100);
    expect(controllers[2].selectedItem, minuteBefore + 1,
        reason: '分钟列滚一格应只前进 1 分钟');
    await wheel(2, -100);
    expect(controllers[2].selectedItem, minuteBefore);

    // 拦截层不能挡住鼠标拖拽：按住日期列往上拖仍能滚动
    final drag = await tester.startGesture(
      centerOf(0),
      kind: PointerDeviceKind.mouse,
    );
    await drag.moveBy(const Offset(0, -80));
    await drag.up();
    await tester.pumpAndSettle();
    expect(controllers[0].selectedItem, greaterThan(dayBefore),
        reason: '鼠标拖拽日期列应仍然可以滚动');
  });
}
