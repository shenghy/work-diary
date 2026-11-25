import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:work_diary_app/widgets/marquee_text.dart';

Widget _host(String text, {double width = 200}) {
  return MaterialApp(
    home: Scaffold(
      body: Center(
        child: SizedBox(
          width: width,
          child: MarqueeText(
            text,
            style: const TextStyle(fontSize: 15),
            speed: 200,
            pause: const Duration(milliseconds: 100),
          ),
        ),
      ),
    ),
  );
}

Finder _marqueeClips() => find.descendant(
      of: find.byType(MarqueeText),
      matching: find.byType(ClipRect),
    );

Finder _marqueeTransforms() => find.descendant(
      of: find.byType(MarqueeText),
      matching: find.byType(Transform),
    );

void main() {
  testWidgets('放得下：纯静态文本，不进入滚动分支', (tester) async {
    await tester.pumpWidget(_host('短文本'));
    expect(_marqueeClips(), findsNothing);
    expect(find.byType(Text), findsOneWidget);
  });

  testWidgets('放不下：未悬停时是省略号单行', (tester) async {
    await tester.pumpWidget(
      _host('这是一段很长的子任务标题，长度肯定超过容器宽度，用来测试跑马灯效果是否正常触发'),
    );
    expect(_marqueeClips(), findsNothing);
    final text = tester.widget<Text>(find.byType(Text));
    expect(text.maxLines, 1);
    expect(text.overflow, TextOverflow.ellipsis);
  });

  testWidgets('放不下 + 悬停：开始向左滚动', (tester) async {
    await tester.pumpWidget(
      _host('这是一段很长的子任务标题，长度肯定超过容器宽度，用来测试跑马灯效果是否正常触发'),
    );

    final gesture = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await gesture.addPointer(location: Offset.zero);
    addTearDown(gesture.removePointer);
    await gesture.moveTo(tester.getCenter(find.byType(MarqueeText)));
    await tester.pump();

    // 悬停后才有裁剪容器
    expect(_marqueeClips(), findsOneWidget);

    // 跑一段，位移应该是负的（文字整体左移）
    await tester.pump(const Duration(milliseconds: 500));
    final transform = tester.widget<Transform>(_marqueeTransforms().first);
    final dx = transform.transform.getTranslation().x;
    expect(dx, lessThan(0));

    // 移开：复位，回到省略号状态
    await gesture.moveTo(Offset.zero);
    await tester.pump();
    expect(_marqueeClips(), findsNothing);
  });
}
