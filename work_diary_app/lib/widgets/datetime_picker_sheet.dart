import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

import '../theme/glass_palette.dart';

/// 日期时间选择结果
class DateTimePickerResult {
  final DateTime? value;
  final bool isCleared;
  const DateTimePickerResult({this.value, this.isCleared = false});
}

/// 滚动行为：允许鼠标、触摸、触控板拖拽滚轮（默认桌面端鼠标拖拽不生效）
class _WheelScrollBehavior extends MaterialScrollBehavior {
  const _WheelScrollBehavior();

  @override
  Set<PointerDeviceKind> get dragDevices => const {
        PointerDeviceKind.touch,
        PointerDeviceKind.mouse,
        PointerDeviceKind.stylus,
        PointerDeviceKind.trackpad,
      };
}

/// 滚轮式日期时间选择器（底部弹窗，24小时制，一步到位）
/// 三列中文滚轮：日期 | 时 | 分，支持鼠标滚轮 + 鼠标拖拽滚动
class DateTimePickerSheet extends StatefulWidget {  final DateTime? initialDateTime;
  final DateTime? minDateTime;
  final DateTime? maxDateTime;
  final String title;

  const DateTimePickerSheet({
    super.key,
    this.initialDateTime,
    this.minDateTime,
    this.maxDateTime,
    this.title = '选择日期和时间',
  });

  /// 显示选择器，返回 null 表示取消，DateTimePickerResult 表示确定或清除
  static Future<DateTimePickerResult?> show(
    BuildContext context, {
    DateTime? initialDateTime,
    DateTime? minDateTime,
    DateTime? maxDateTime,
    String title = '选择日期和时间',
  }) {
    return showModalBottomSheet<DateTimePickerResult>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (ctx) => DateTimePickerSheet(
        initialDateTime: initialDateTime,
        minDateTime: minDateTime,
        maxDateTime: maxDateTime,
        title: title,
      ),
    );
  }

  @override
  State<DateTimePickerSheet> createState() => _DateTimePickerSheetState();
}

class _DateTimePickerSheetState extends State<DateTimePickerSheet> {
  late DateTime _selected;
  late List<DateTime> _days;
  late FixedExtentScrollController _dayCtl;
  late FixedExtentScrollController _hourCtl;
  late FixedExtentScrollController _minuteCtl;
  DateTime? _minD;
  DateTime? _maxD;

  /// 正在用代码移动滚轮：忽略由此触发的 onSelectedItemChanged，避免递归
  bool _syncingRolls = false;

  @override
  void initState() {
    super.initState();
    final now = DateTime.now();
    final init = widget.initialDateTime;
    var v = init != null && !init.isUtc
        ? init
        : (init != null && init.isUtc ? init.toLocal() : now);
    _minD = widget.minDateTime;
    _maxD = widget.maxDateTime;
    // 初始值 clamp 到允许范围（minDateTime / maxDateTime）
    if (_minD != null && v.isBefore(_minD!)) v = _minD!;
    if (_maxD != null && v.isAfter(_maxD!)) v = _maxD!;
    _selected = v;

    // 日期范围（按天）
    final min = _minD ?? now.subtract(const Duration(days: 365));
    final max = _maxD ?? now.add(const Duration(days: 365 * 3));
    _days = <DateTime>[];
    var d = DateTime(min.year, min.month, min.day);
    final last = DateTime(max.year, max.month, max.day);
    while (!d.isAfter(last)) {
      _days.add(d);
      d = DateTime(d.year, d.month, d.day + 1);
    }

    final dayIdx = _days.indexWhere(
        (x) => x.year == _selected.year && x.month == _selected.month && x.day == _selected.day);
    _dayCtl = FixedExtentScrollController(initialItem: dayIdx < 0 ? 0 : dayIdx);
    _hourCtl = FixedExtentScrollController(initialItem: _selected.hour);
    _minuteCtl = FixedExtentScrollController(initialItem: _selected.minute);
  }

  @override
  void dispose() {
    _dayCtl.dispose();
    _hourCtl.dispose();
    _minuteCtl.dispose();
    super.dispose();
  }

  void _setPreset(String preset) {
    final now = DateTime.now();
    DateTime target;
    switch (preset) {
      case 'today':
        target = DateTime(now.year, now.month, now.day, _selected.hour, _selected.minute);
        break;
      case 'tomorrow':
        final t = now.add(const Duration(days: 1));
        target = DateTime(t.year, t.month, t.day, _selected.hour, _selected.minute);
        break;
      case 'nextMonday':
        final daysUntilMonday = (8 - now.weekday) % 7;
        final t = now.add(Duration(days: daysUntilMonday == 0 ? 7 : daysUntilMonday));
        target = DateTime(t.year, t.month, t.day, 9, 0);
        break;
      default:
        target = now;
    }
    final minD = _minD;
    final maxD = _maxD;
    if (minD != null && target.isBefore(minD)) target = minD;
    if (maxD != null && target.isAfter(maxD)) target = maxD;
    setState(() {
      _selected = target;
    });
    // 预设点击后直接确定并收起面板，让用户立即看到效果
    Navigator.pop(context, DateTimePickerResult(value: target));
  }

  /// 某一列滚动后合成新时间，并 clamp 到边界；被 clamp 时同步回跳相关滚轮
  void _onPartChanged(DateTime next) {
    if (_syncingRolls) return;
    var v = next;
    final minD = _minD;
    final maxD = _maxD;
    final clampedToMin = minD != null && v.isBefore(minD);
    final clampedToMax = maxD != null && v.isAfter(maxD);
    if (clampedToMin) v = minD;
    if (clampedToMax) v = maxD;
    setState(() {
      _selected = v;
    });
    if (clampedToMin || clampedToMax) {
      // 滚轮显示与 _selected 对齐。
      // 注意：这里原来写的是 !_dayCtl.hasClients —— 交互过程中控制器必然
      // 有 clients，导致日期列永远不会回跳，用户看到的日期和实际保存的
      // 日期不一致。
      final idx = _days.indexWhere(
          (x) => x.year == v.year && x.month == v.month && x.day == v.day);
      if (idx < 0) return;
      _syncingRolls = true;
      if (_dayCtl.hasClients) _dayCtl.jumpTo(idx * 40.0);
      if (_hourCtl.hasClients) _hourCtl.jumpTo(v.hour * 40.0);
      if (_minuteCtl.hasClients) _minuteCtl.jumpTo(v.minute * 40.0);
      // jumpTo 触发的回调是异步派发的，重置标志必须等一帧之后
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _syncingRolls = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final g = GlassPalette.of(context);
    return Container(
      decoration: BoxDecoration(
        color: g.surface,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(16)),
      ),
      child: SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // 顶部标题栏
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
              child: Row(
                children: [
                  TextButton(
                    onPressed: () => Navigator.pop(context),
                    child: Text('取消',
                        style: TextStyle(fontSize: 14, color: g.inkTertiary)),
                  ),
                  Expanded(
                    child: Center(
                      child: Text(widget.title,
                          style: TextStyle(
                              fontSize: 15,
                              fontWeight: FontWeight.w600,
                              color: g.ink)),
                    ),
                  ),
                  TextButton(
                    onPressed: () => Navigator.pop(context, DateTimePickerResult(value: _selected)),
                    child: Text('确定',
                        style: TextStyle(
                            fontSize: 14,
                            color: g.accent,
                            fontWeight: FontWeight.w600)),
                  ),
                ],
              ),
            ),
            // 快捷按钮
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Row(
                children: [
                  _presetButton('今天', () => _setPreset('today')),
                  const SizedBox(width: 8),
                  _presetButton('明天', () => _setPreset('tomorrow')),
                  const SizedBox(width: 8),
                  _presetButton('下周一9:00', () => _setPreset('nextMonday')),
                  const Spacer(),
                  TextButton(
                    onPressed: () => Navigator.pop(context, const DateTimePickerResult(isCleared: true)),
                    child: Text('清除',
                        style: TextStyle(fontSize: 13, color: g.danger)),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 4),
            // 三列中文滚轮（日期 | 时 | 分，支持鼠标滚轮 + 鼠标拖拽）
            _buildWheelPicker(),
            const SizedBox(height: 12),
          ],
        ),
      ),
    );
  }

  // ---------------- 滚轮区域 ----------------

  Widget _buildWheelPicker() {
    final g = GlassPalette.of(context);
    return Container(
      height: 240,
      decoration: BoxDecoration(
        color: g.fieldBg,
        border: Border.symmetric(
          horizontal: BorderSide(color: g.fieldBorder, width: 1),
        ),
      ),
      clipBehavior: Clip.hardEdge,
      child: Row(
        children: [
          Expanded(
            flex: 2,
            child: _wheelColumn(
              _buildDayWheel(),
              controller: _dayCtl,
              itemCount: _days.length,
            ),
          ),
          IgnorePointer(child: Container(width: 1, color: g.fieldBorder)),
          Expanded(
            child: _wheelColumn(
              _buildHourWheel(),
              controller: _hourCtl,
              itemCount: 24,
            ),
          ),
          IgnorePointer(child: Container(width: 1, color: g.fieldBorder)),
          Expanded(
            child: _wheelColumn(
              _buildMinuteWheel(),
              controller: _minuteCtl,
              itemCount: 60,
            ),
          ),
        ],
      ),
    );
  }

  /// 单列滚轮 + 选中高亮条 + 上下渐变遮罩
  ///
  /// 最上层再盖一个透明 Listener，用 [pointerSignalResolver] 把鼠标滚轮按
  /// “一格一项”消费掉。不能直接交给 ListWheelScrollView：Windows 上一格
  /// 滚轮的 scrollDelta.dy 是 100 逻辑像素，而这里每项只有 40 像素，
  /// 它会把像素吸附到 2~3 项之外（28 号滚一格直接到 30 号）。
  /// Listener 用 translucent，不影响下面的鼠标拖拽 / 点击。
  Widget _wheelColumn(
    Widget wheel, {
    required FixedExtentScrollController controller,
    required int itemCount,
  }) {
    final g = GlassPalette.of(context);
    return Stack(
      alignment: Alignment.center,
      clipBehavior: Clip.none,
      children: [
        wheel,
        // 中间选中高亮条（IgnorePointer：不拦截滚轮/拖拽事件）
        IgnorePointer(
          child: Container(
            height: 40,
            decoration: BoxDecoration(
              color: g.gridLine,
              border: Border.symmetric(
                horizontal: BorderSide(color: g.fieldBorder, width: 1),
              ),
            ),
          ),
        ),
        // 上渐变遮罩
        Positioned(
          top: 0, left: 0, right: 0, height: 44,
          child: IgnorePointer(
            child: DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [g.fieldBg, g.fieldBg.withValues(alpha: 0.0)],
                ),
              ),
            ),
          ),
        ),
        // 下渐变遮罩
        Positioned(
          bottom: 0, left: 0, right: 0, height: 44,
          child: IgnorePointer(
            child: DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.bottomCenter,
                  end: Alignment.topCenter,
                  colors: [g.fieldBg, g.fieldBg.withValues(alpha: 0.0)],
                ),
              ),
            ),
          ),
        ),
        // 滚轮事件拦截层：必须放在最上层（Stack 最后一个），
        // 这样它比内部 Scrollable 先进入命中测试，才能抢先注册处理器。
        Positioned.fill(
          child: Listener(
            behavior: HitTestBehavior.translucent,
            onPointerSignal: (event) =>
                _handleWheelSignal(event, controller, itemCount),
          ),
        ),
      ],
    );
  }

  /// 鼠标滚轮：一格固定移动 1 项（时、分、日期三列共用）
  ///
  /// 只接管物理鼠标滚轮；触控板/触控笔仍走 ListWheelScrollView 原来的滚动。
  void _handleWheelSignal(
    PointerSignalEvent event,
    FixedExtentScrollController controller,
    int itemCount,
  ) {
    if (event is! PointerScrollEvent) return;
    if (event.kind != PointerDeviceKind.mouse) return;
    final dy = event.scrollDelta.dy;
    if (dy == 0) return;
    GestureBinding.instance.pointerSignalResolver.register(event, (_) {
      if (!controller.hasClients) return;
      final current = controller.selectedItem;
      final step = dy > 0 ? 1 : -1;
      final next = (current + step).clamp(0, itemCount - 1);
      if (next == current) return;
      controller.animateToItem(
        next,
        duration: const Duration(milliseconds: 90),
        curve: Curves.easeOut,
      );
    });
  }

  Widget _buildDayWheel() {
    final g = GlassPalette.of(context);
    return ListWheelScrollView.useDelegate(
      controller: _dayCtl,
      itemExtent: 40,
      diameterRatio: 2.2,
      overAndUnderCenterOpacity: 0.55,
      physics: const FixedExtentScrollPhysics(),
      scrollBehavior: const _WheelScrollBehavior(),
      onSelectedItemChanged: (i) {
        final d = _days[i];
        _onPartChanged(DateTime(d.year, d.month, d.day, _selected.hour, _selected.minute));
      },
      childDelegate: ListWheelChildBuilderDelegate(
        childCount: _days.length,
        builder: (context, i) {
          final d = _days[i];
          return Center(
            child: Text(
              '${d.year.toString().substring(2)}-${d.month}-${d.day}',
              style: TextStyle(fontSize: 15, color: g.ink),
            ),
          );
        },
      ),
    );
  }

  Widget _buildHourWheel() {
    final g = GlassPalette.of(context);
    return ListWheelScrollView.useDelegate(
      controller: _hourCtl,
      itemExtent: 40,
      diameterRatio: 2.2,
      overAndUnderCenterOpacity: 0.55,
      physics: const FixedExtentScrollPhysics(),
      scrollBehavior: const _WheelScrollBehavior(),
      onSelectedItemChanged: (i) {
        _onPartChanged(DateTime(_selected.year, _selected.month, _selected.day, i, _selected.minute));
      },
      childDelegate: ListWheelChildBuilderDelegate(
        childCount: 24,
        builder: (context, i) => Center(
          child: Text('$i 时', style: TextStyle(fontSize: 15, color: g.ink)),
        ),
      ),
    );
  }

  Widget _buildMinuteWheel() {
    final g = GlassPalette.of(context);
    return ListWheelScrollView.useDelegate(
      controller: _minuteCtl,
      itemExtent: 40,
      diameterRatio: 2.2,
      overAndUnderCenterOpacity: 0.55,
      physics: const FixedExtentScrollPhysics(),
      scrollBehavior: const _WheelScrollBehavior(),
      onSelectedItemChanged: (i) {
        _onPartChanged(DateTime(_selected.year, _selected.month, _selected.day, _selected.hour, i));
      },
      childDelegate: ListWheelChildBuilderDelegate(
        childCount: 60,
        builder: (context, i) => Center(
          child: Text('$i 分', style: TextStyle(fontSize: 15, color: g.ink)),
        ),
      ),
    );
  }

  Widget _presetButton(String label, VoidCallback onTap) {
    final g = GlassPalette.of(context);
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(8),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        decoration: BoxDecoration(
          color: g.chipBg,
          borderRadius: BorderRadius.circular(8),
        ),
        child: Text(label, style: TextStyle(fontSize: 12, color: g.ink)),
      ),
    );
  }
}
