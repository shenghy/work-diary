import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:work_diary_app/models/stats.dart';
import 'package:work_diary_app/models/task.dart';
import 'package:work_diary_app/screens/stats_screen.dart';
import 'package:work_diary_app/utils/stats_calculator.dart';
import 'package:work_diary_app/widgets/glass_surface.dart';

/// 看板页面渲染验收：窄窗口不溢出、空态有引导、切胶囊会重算、F5 能刷新。
void main() {
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
      repeatGroupId: repeatType == 0 ? null : 'g1',
    );
  }

  /// 一份"用得起来"的数据：4 个指标都有值、循环任务有排期、时段有峰值。
  List<Task> richTasks() => [
        for (var i = 0; i < 4; i++)
          done(
            id: i,
            completed: DateTime(2026, 11, 9, 10, i * 10),
            due: DateTime(2026, 11, 9, 23),
            taskType: i.isEven ? 1 : 0,
            urgency: i == 1 ? Urgency.urgent : Urgency.normal,
          ),
        for (var d = 4; d <= 6; d++)
          done(
            id: 100 + d,
            completed: DateTime(2026, 11, d, 14, 30),
            due: DateTime(2026, 11, d, 23),
            repeatType: 1,
            instance: DateTime(2026, 11, d),
          ),
        done(
          id: 200,
          completed: DateTime(2026, 11, 9, 20),
          created: DateTime(2026, 11, 9, 19),
        ),
        // 窗口外的一条：证明胶囊确实在过滤
        done(
          id: 300,
          completed: DateTime(2026, 10, 20, 11),
          created: DateTime(2026, 10, 20, 9),
          due: DateTime(2026, 10, 20, 23),
        ),
      ];

  StatsSnapshot snapshotOf(List<Task> tasks, StatsRange range) =>
      StatsCalculator.compute(
        tasks: tasks,
        skips: const {},
        range: range,
        now: now,
      );

  Widget page(
    List<Task> tasks, {
    void Function(StatsRange)? onLoad,
    void Function()? onBack,
    int refreshTick = 0,
    AnimationController? entrance,
  }) {
    return MaterialApp(
      home: StatsScreen(
        loadSnapshot: (range) async {
          onLoad?.call(range);
          return snapshotOf(tasks, range);
        },
        onBack: onBack ?? () {},
        refreshTick: refreshTick,
        animateEntrance: entrance != null,
        entranceController: entrance,
      ),
    );
  }

  Future<void> pumpPage(
    WidgetTester tester,
    List<Task> tasks, {
    void Function(StatsRange)? onLoad,
    void Function()? onBack,
  }) async {
    await tester.binding.setSurfaceSize(const Size(1280, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(page(tasks, onLoad: onLoad, onBack: onBack));
    // 等首帧骨架 + 异步聚合落地
    await tester.pumpAndSettle();
  }

  testWidgets('数据落地后六个模块都渲染，且没有溢出', (tester) async {
    await pumpPage(tester, richTasks());

    expect(find.text('我的数据'), findsOneWidget);
    expect(find.text('已完成任务'), findsOneWidget);
    expect(find.text('连续打卡'), findsOneWidget);
    expect(find.text('平均完成耗时'), findsOneWidget);
    for (final title in [
      '任务趋势',
      '任务构成',
      '活跃热力图',
      '循环任务按期率',
      '专注时段分布',
    ]) {
      expect(find.text(title), findsOneWidget, reason: '$title 没渲染');
    }
    expect(tester.takeException(), isNull);
  });

  testWidgets('验收 8：窗口拖到 400px 宽无溢出、无报错', (tester) async {
    await tester.binding.setSurfaceSize(const Size(400, 720));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(page(richTasks()));
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(find.text('近 7 天'), findsWidgets); // 胶囊 + 页脚文案各一处
    // 窄屏时趋势图和构成卡各自独立成行
    expect(find.text('任务趋势'), findsOneWidget);
    expect(find.text('任务构成'), findsOneWidget);
    // 页面自身不出横向滚动条（热力图内部滚动不算整页）
    final horizontal = find.byWidgetPredicate((w) =>
        w is SingleChildScrollView && w.scrollDirection == Axis.horizontal);
    for (final entry in horizontal.evaluate()) {
      final widget = entry.widget as SingleChildScrollView;
      expect(widget.controller, isNotNull, reason: '横向滚动区必须可滚动且不撑破页面');
    }
  });

  testWidgets('≥900 双列并排，<900 单列堆叠', (tester) async {
    Future<Offset> cardTop(String title) async {
      final card = find.ancestor(
        of: find.text(title),
        matching: find.byType(GlassSurface),
      );
      return tester.getTopLeft(card);
    }

    await tester.binding.setSurfaceSize(const Size(1280, 900));
    await tester.pumpWidget(page(richTasks()));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    final trendWide = await cardTop('任务趋势');
    final composeWide = await cardTop('任务构成');
    // 并排：同一行、左边不同
    expect(trendWide.dy, composeWide.dy);
    expect(composeWide.dx, greaterThan(trendWide.dx));

    await tester.binding.setSurfaceSize(const Size(760, 900));
    await tester.pumpWidget(page(richTasks()));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    final trendNarrow = await cardTop('任务趋势');
    final composeNarrow = await cardTop('任务构成');
    // 堆叠：同一列、上下两行
    expect(composeNarrow.dx, trendNarrow.dx);
    expect(composeNarrow.dy, greaterThan(trendNarrow.dy));
  });

  testWidgets('空账号显示引导态而不是六个 0 值图', (tester) async {
    await pumpPage(tester, const []);
    expect(find.text('这段时间还没有记录'), findsOneWidget);
    expect(find.text('还没有足够数据，先完成几个任务吧'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('切时间范围胶囊会带上新 range 重新聚合', (tester) async {
    final requested = <StatsRange>[];
    await tester.binding.setSurfaceSize(const Size(1280, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(page(richTasks(), onLoad: requested.add));
    await tester.pumpAndSettle();
    requested.clear();

    await tester.tap(find.text('近 30 天'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('全部'));
    await tester.pumpAndSettle();

    expect(requested, [StatsRange.last30, StatsRange.all]);
    expect(tester.takeException(), isNull);
  });

  testWidgets('需求 2：选中的范围会回传给主页存成会话状态', (tester) async {
    final reported = <StatsRange>[];
    await tester.binding.setSurfaceSize(const Size(1280, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      MaterialApp(
        home: StatsScreen(
          loadSnapshot: (range) async => snapshotOf(richTasks(), range),
          onBack: () {},
          onRangeChanged: reported.add,
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('近 90 天'));
    await tester.pumpAndSettle();
    // 首帧不回调（避免 initState 里回调父组件），只有用户真的点了才回传
    expect(reported, [StatsRange.last90]);
  });

  testWidgets('返回按钮回调到主页', (tester) async {
    var backed = 0;
    await pumpPage(tester, richTasks(), onBack: () => backed++);
    await tester.tap(find.byIcon(Icons.arrow_back_rounded));
    expect(backed, 1);
  });

  testWidgets('refreshTick 变化触发重算（主页 F5 走的这条路）', (tester) async {
    var calls = 0;
    await tester.binding.setSurfaceSize(const Size(1280, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(page(richTasks(), onLoad: (_) => calls++));
    await tester.pumpAndSettle();
    calls = 0;

    await tester.pumpWidget(page(richTasks(), onLoad: (_) => calls++, refreshTick: 1));
    await tester.pumpAndSettle();
    expect(calls, 1);
  });

  testWidgets('刷新按钮重新聚合一次', (tester) async {
    var calls = 0;
    await tester.binding.setSurfaceSize(const Size(1280, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(page(richTasks(), onLoad: (_) => calls++));
    await tester.pumpAndSettle();
    calls = 0;

    await tester.tap(find.byIcon(Icons.refresh));
    await tester.pumpAndSettle();
    expect(calls, 1);
  });

  testWidgets('复用主页入场控制器：动画期间不报错', (tester) async {
    final vsync = TestVSync();
    final controller = AnimationController(vsync: vsync, duration: const Duration(milliseconds: 1000));
    addTearDown(controller.dispose);

    await tester.binding.setSurfaceSize(const Size(1280, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(page(richTasks(), entrance: controller));
    await tester.pumpAndSettle();
    controller.forward(from: 0);
    for (var i = 0; i < 5; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.text('已完成任务'), findsOneWidget);
  });

  testWidgets('验收 1：选「全部」后看板数字 == 本地已完成任务总数', (tester) async {
    final tasks = richTasks();
    await tester.binding.setSurfaceSize(const Size(1280, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(page(tasks));
    await tester.pumpAndSettle();

    await tester.tap(find.text('全部'));
    await tester.pumpAndSettle();

    // 与「已完成」tab 角标同源：同一个 repo、同一条 status==completed 过滤
    final badge = tasks.where((t) => t.status == TaskStatus.completed).length;
    final snap = snapshotOf(tasks, StatsRange.all);
    expect(snap.summary.completed, badge);
    expect(find.text('$badge'), findsWidgets);
    // 窗口内数字（近 7 天）应小于全量，证明胶囊确实在过滤
    expect(snapshotOf(tasks, StatsRange.last7).summary.completed, lessThan(badge));
  });

  testWidgets('口径说明可展开收起', (tester) async {
    await pumpPage(tester, richTasks());
    expect(find.textContaining('应完成数：到期日落在窗口内'), findsNothing);
    // 页脚在首屏之下，先滚进可视区域再点
    final toggle = find.text('了解口径');
    await tester.ensureVisible(toggle);
    await tester.pumpAndSettle();
    await tester.tap(toggle);
    await tester.pumpAndSettle();
    expect(find.textContaining('应完成数：到期日落在窗口内'), findsOneWidget);
    final collapse = find.text('收起口径');
    await tester.ensureVisible(collapse);
    await tester.pumpAndSettle();
    await tester.tap(collapse);
    await tester.pumpAndSettle();
    expect(find.textContaining('应完成数：到期日落在窗口内'), findsNothing);
  });
}
