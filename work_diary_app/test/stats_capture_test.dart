import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart' show ByteData, FontLoader;
import 'package:flutter_test/flutter_test.dart';

import 'package:work_diary_app/main.dart';
import 'package:work_diary_app/models/task.dart';
import 'package:work_diary_app/screens/stats_screen.dart';
import 'package:work_diary_app/theme/glass_palette.dart';
import 'package:work_diary_app/utils/stats_calculator.dart';
import 'package:work_diary_app/widgets/aurora_background.dart';

/// 把看板整页渲染成 PNG，用来和设计图逐区块对色值/间距。
///
/// goldens/ 下那三张就是截图产物，同时充当视觉回归基线：改了看板排版后
/// `flutter test test/stats_capture_test.dart` 会报差异，确认过设计图再用
/// `--update-goldens` 刷新基线。跑法与 test/task_card_footer_layout_test.dart
/// 一样，需要在包目录下执行（字体是相对路径读的）。
void main() {
  // flutter test 默认用 Ahem（方块字），字号量不出来。这里显式装上真实字体，
  // 截出来的排版才能和设计图对。rootBundle 在测试里拿不到项目资源，直接读盘；
  // 而且必须逐条用例加载——binding 每个 test 会重置字体注册表，setUpAll 里装的到截图时就没了。
  Future<void> loadFonts() async {
    const files = [
      'assets/fonts/AlibabaPuHuiTi-3-55-Regular.ttf',
      'assets/fonts/AlibabaPuHuiTi-3-65-Medium.ttf',
      'assets/fonts/AlibabaPuHuiTi-3-85-Bold.ttf',
    ];
    final loader = FontLoader('AlibabaPuHuiTi');
    for (final path in files) {
      final bytes = File(path).readAsBytesSync();
      loader.addFont(Future.value(ByteData.sublistView(bytes)));
    }
    await loader.load();
  }

  final now = DateTime(2026, 11, 10, 15, 30);

  Task done({
    required int id,
    required DateTime completed,
    DateTime? created,
    DateTime? due,
    int taskType = 1,
    Urgency urgency = Urgency.normal,
    int repeatType = 0,
    DateTime? instance,
  }) {
    return Task(
      id: id,
      title: '任务$id',
      status: TaskStatus.completed,
      urgency: urgency,
      createdAt: created ?? completed.subtract(const Duration(hours: 3)),
      completedAt: completed,
      dueAt: due,
      taskType: taskType,
      repeatType: repeatType,
      instanceDate: instance,
      repeatGroupId: repeatType == 0 ? null : 'g$id',
    );
  }

  /// 造一份量级接近设计图的数据：完成率、环比、时段峰值都有值。
  List<Task> mockTasks() {
    final out = <Task>[];
    var id = 1000;
    for (var d = 0; d < 84; d++) {
      final day = DateTime(2026, 11, 10).subtract(Duration(days: d));
      final perDay = (d % 7 == 5 || d % 7 == 6) ? 1 : (d % 3) + 1;
      for (var k = 0; k < perDay; k++) {
        id++;
        out.add(done(
          id: id,
          completed: DateTime(day.year, day.month, day.day, 9 + k * 3, 10 * k),
          due: DateTime(day.year, day.month, day.day, 23),
          taskType: (id % 5 == 0) ? 0 : 1,
          urgency: k == 0
              ? Urgency.urgent
              : (k == 1 ? Urgency.important : Urgency.normal),
        ));
      }
    }
    for (var d = 1; d <= 12; d++) {
      final day = DateTime(2026, 11, 10).subtract(Duration(days: d));
      id++;
      out.add(done(
        id: id,
        completed: DateTime(day.year, day.month, day.day, 8, 30),
        due: DateTime(day.year, day.month, day.day, 23),
        repeatType: 1,
        instance: day,
      ));
    }
    // 周/月循环也要有落在窗口内的期次，否则截图里「循环任务按期率」的
    // 后两张卡永远是 --，对不上设计图那种三列都有值的排布。
    for (final d in const [1, 3, 5]) {
      final day = DateTime(2026, 11, 10).subtract(Duration(days: d));
      id++;
      out.add(done(
        id: id,
        completed: DateTime(day.year, day.month, day.day, 9),
        due: DateTime(day.year, day.month, day.day, 23),
        repeatType: 2,
        instance: day,
      ));
    }
    for (final (days, lateBy) in const [(2, 0), (4, 1)]) {
      final day = DateTime(2026, 11, 10).subtract(Duration(days: days));
      id++;
      out.add(done(
        id: id,
        // 一期按期、一期拖到次日，这样月任务那列既不是 100% 也不是 0%。
        completed: DateTime(day.year, day.month, day.day + lateBy, 9),
        due: DateTime(day.year, day.month, day.day, 23),
        repeatType: 3,
        instance: day,
      ));
    }
    return out;
  }

  Future<void> capture(
    WidgetTester tester,
    String name,
    Size size,
    GlassPalette palette,
  ) async {
    await tester.binding.setSurfaceSize(size);
    final tasks = mockTasks();
    final boundary = GlobalKey();
    await tester.pumpWidget(
      MaterialApp(
        // 和真实运行同一份 ThemeData：令牌、字体、实色底都从 palette 来。
        // 显式钉住档位，golden 基线不能跟着机器的系统主题漂。
        theme: buildAppTheme(palette),
        themeMode: ThemeMode.light,
        // 和 main.dart 的 builder 同一套底板：真实 Aurora + 全窗玻璃。
        // 少了这两层，截图会比实际运行暗一大截，色值就没法对。
        // RepaintBoundary 必须套在整棵 home 外面：套在页面那一层的话，
        // 截图只有一张透明底，Aurora 和玻璃全丢了，色值会整体偏黑。
        // Scaffold 也不能省：主页就是 Scaffold 起的，没有 Material 祖先时
        // Text 不会继承 theme.textTheme，字体家族掉回 Ahem，方块字量不出排版。
        home: RepaintBoundary(
          key: boundary,
          child: Scaffold(
            backgroundColor: Colors.transparent,
            body: Stack(
              children: [
                const Positioned.fill(child: AuroraBackground()),
                const Positioned.fill(child: WindowGlass()),
                Positioned.fill(child: StatsScreen(
                  loadSnapshot: (range) async => StatsCalculator.compute(
                    tasks: tasks,
                    skips: const {},
                    range: range,
                    now: now,
                  ),
                  onBack: () {},
                )),
              ],
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 120));
    // Aurora 是 22 秒一轮的循环动画，停在固定相位截图才可复现
    await tester.pump(const Duration(seconds: 6));
    expect(tester.takeException(), isNull);

    final ro = boundary.currentContext?.findRenderObject();
    expect(ro, isA<RenderRepaintBoundary>());
    // Layer.toImage 是 flutter test 里唯一能出图的通道（RenderRepaintBoundary
    // .toImage 在测试绑定下永远不 complete），所以走 matchesGoldenFile。
    await expectLater(
      find.byKey(boundary),
      matchesGoldenFile('goldens/$name.png'),
    );
    await tester.binding.setSurfaceSize(null);
  }

  testWidgets('400 宽整页截图（设计图就是这个逻辑宽度的 2 倍导出）', (tester) async {
    await loadFonts();
    await capture(tester, 'stats_400', const Size(400, 2400), GlassPalette.dark);
  });

  testWidgets('800 宽整页截图', (tester) async {
    await loadFonts();
    await capture(tester, 'stats_800', const Size(800, 3400), GlassPalette.dark);
  });

  testWidgets('1180 宽整页截图（双列布局）', (tester) async {
    await loadFonts();
    await capture(
        tester, 'stats_1180', const Size(1180, 2200), GlassPalette.dark);
  });

  // 浅色档各录一张：深色那三张守「改造后不许变」，这两张守「浅色别再被改回深色」。
  testWidgets('400 宽整页截图（浅色档）', (tester) async {
    await loadFonts();
    await capture(
        tester, 'stats_400_light', const Size(400, 2400), GlassPalette.light);
  });

  testWidgets('1180 宽整页截图（浅色档，双列布局）', (tester) async {
    await loadFonts();
    await capture(
        tester, 'stats_1180_light', const Size(1180, 2200), GlassPalette.light);
  });
}
