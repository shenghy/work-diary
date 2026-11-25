import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';

import 'package:work_diary_app/main.dart';
import 'package:work_diary_app/services/app_theme.dart';
import 'package:work_diary_app/theme/glass_palette.dart';
import 'package:work_diary_app/widgets/theme_mode_switch.dart';

/// 设置面板里的外观分段开关：三档都在、换档写状态、指示块平移、档位落盘。
void main() {
  late Directory tempDir;

  setUpAll(() async {
    tempDir = await Directory.systemTemp.createTemp('work_diary_theme_');
    Hive.init(tempDir.path);
    await Hive.openBox('settings');
  });

  tearDownAll(() async {
    await Hive.close();
    await tempDir.delete(recursive: true);
  });

  setUp(() {
    AppTheme.mode.value = ThemeMode.system;
  });

  Future<void> pumpSwitch(WidgetTester tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: buildAppTheme(GlassPalette.light),
        home: const Scaffold(
          body: Center(child: ThemeModeSwitch()),
        ),
      ),
    );
  }

  /// 点一档。`AppTheme.setMode` 里的 `put` 没有 await：
  /// 留在 fake zone 里就是一个跑不完的写事务，会把收尾的 `Hive.close()` 卡死，
  /// 所以点击放到真实事件循环上执行。
  Future<void> tapMode(WidgetTester tester, String label) async {
    await tester.runAsync(() async {
      await tester.tap(find.text(label));
      await Future<void>.delayed(const Duration(milliseconds: 50));
    });
    // 换档走的是 ValueNotifier → setState，得跑一帧才反映到 widget 上。
    await tester.pump();
  }

  double indicatorLeft(WidgetTester tester) =>
      tester.widget<AnimatedPositioned>(find.byType(AnimatedPositioned)).left!;

  testWidgets('三档文案齐全，默认停在中间档', (tester) async {
    await pumpSwitch(tester);

    expect(find.text('浅'), findsOneWidget);
    expect(find.text('随'), findsOneWidget);
    expect(find.text('深'), findsOneWidget);
    expect(find.byIcon(Icons.desktop_windows_outlined), findsOneWidget);

    // 一段 34，跟随系统排在中间。
    expect(indicatorLeft(tester), 34);
  });

  testWidgets('点深色会换档，滑块滑到最右', (tester) async {
    await pumpSwitch(tester);
    await tapMode(tester, '深');

    expect(AppTheme.mode.value, ThemeMode.dark);

    final indicator =
        tester.widget<AnimatedPositioned>(find.byType(AnimatedPositioned));
    // 位移走 260ms 缓出，不是瞬间跳过去。
    expect(indicator.duration, const Duration(milliseconds: 260));
    expect(indicator.curve, Curves.easeOutCubic);
    expect(indicator.left, 68);

    await tester.pumpAndSettle();
  });

  testWidgets('点浅色后滑块回到最左，并落盘', (tester) async {
    await pumpSwitch(tester);
    await tapMode(tester, '浅');

    expect(AppTheme.mode.value, ThemeMode.light);
    expect(Hive.box('settings').get('theme_mode'), 'light');
    expect(indicatorLeft(tester), 0);

    await tester.pumpAndSettle();
  });

  testWidgets('整窗主题跟着档位走', (tester) async {
    // 和 main.dart 一样把 MaterialApp 挂在档位上，验证换档真的会重绘整窗。
    await tester.pumpWidget(
      ValueListenableBuilder<ThemeMode>(
        valueListenable: AppTheme.mode,
        builder: (context, themeMode, _) => MaterialApp(
          theme: buildAppTheme(GlassPalette.light),
          darkTheme: buildAppTheme(GlassPalette.dark),
          themeMode: themeMode,
          home: const Scaffold(
            body: Center(child: ThemeModeSwitch()),
          ),
        ),
      ),
    );
    await tapMode(tester, '深');
    // MaterialApp 外面套的是 AnimatedTheme，插值走完才是目标档。
    await tester.pumpAndSettle();

    expect(
      tester.widget<MaterialApp>(find.byType(MaterialApp)).themeMode,
      ThemeMode.dark,
    );
    expect(
      Theme.of(tester.element(find.byType(ThemeModeSwitch))).brightness,
      Brightness.dark,
    );
  });
}
