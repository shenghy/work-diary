import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../models/stats.dart';
import '../theme/glass_palette.dart';

/// 看板图表：全部 CustomPainter 手绘，不引任何图表库（安装包体积敏感）。
///
/// 配色只从 GlassPalette 的 stats* 常量取，页面里不允许再出现字面色值。

/// TextPainter 不吃 DefaultTextStyle，坐标轴不写家族就会掉回系统字体，
/// 和整页的普惠体两套字混排（测试里更直接渲染成 Ahem 方块）。
const String _labelFontFamily = 'AlibabaPuHuiTi';

/// 悬停气泡：图表通用，定位在柱子正上方，越界时自动左右收。
class ChartBubble extends StatelessWidget {
  const ChartBubble({
    super.key,
    required this.text,
    required this.anchorX,
    required this.chartWidth,
    this.top = 0,
  });

  final String text;
  final double anchorX;
  final double chartWidth;
  final double top;

  @override
  Widget build(BuildContext context) {
    final g = GlassPalette.of(context);
    const bubbleWidth = 168.0;
    final left = (anchorX - bubbleWidth / 2).clamp(0.0, (chartWidth - bubbleWidth).clamp(0.0, chartWidth));
    return Positioned(
      left: left,
      top: top,
      child: IgnorePointer(
        child: Container(
          width: bubbleWidth,
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
          decoration: BoxDecoration(
            // 悬浮气泡要压住背后的图表，用实色控件底而不是 shadow：
            // shadow 在浅色档几乎是透明的，拿它当底会让深色字压在深色上。
            color: g.opaqueControl.withAlpha(232),
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: g.statsPrimary.withAlpha(120)),
          ),
          child: Text(
            text,
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: 11.5,
              height: 1.45,
              color: g.ink,
              fontFeatures: [FontFeature.tabularFigures()],
            ),
          ),
        ),
      ),
    );
  }
}

/// 任务趋势：分组柱（新建 / 完成）+ 完成率折线（右轴 0–100%）。
class TrendChart extends StatefulWidget {
  const TrendChart({
    super.key,
    required this.trend,
    required this.height,
    this.maxBuckets = 30,
  });

  final StatsTrend trend;
  final double height;

  /// 「全部」范围按周聚合可能上百个桶，只画最近这么多根，否则柱子糊成一条线。
  final int maxBuckets;

  @override
  State<TrendChart> createState() => _TrendChartState();
}

class _TrendChartState extends State<TrendChart> {
  int _hover = -1;

  List<DateTime> get _dates => _sliced(widget.trend.dates);
  List<int> get _created => _sliced(widget.trend.created);
  List<int> get _completed => _sliced(widget.trend.completed);
  List<int?> get _rates => _sliced<int?>(widget.trend.rates);

  List<T> _sliced<T>(List<T> values) => values.length <= widget.maxBuckets
      ? values
      : values.sublist(values.length - widget.maxBuckets);

  void _onHover(Offset local, Size size) {
    if (size.width <= 0 || _dates.isEmpty) return;
    final slot = size.width / _dates.length;
    final index = (local.dx / slot).floor().clamp(0, _dates.length - 1);
    if (index == _hover) return;
    setState(() => _hover = index);
  }

  String _tooltip(int i) {
    final day = _dates[i];
    final rate = _rates[i];
    final rateText = rate == null ? '完成率 --' : '完成率 $rate%';
    return '${day.month}/${day.day} · 新建 ${_created[i]} · '
        '完成 ${_completed[i]} · $rateText';
  }

  @override
  Widget build(BuildContext context) {
    final g = GlassPalette.of(context);
    final count = _dates.length;
    return LayoutBuilder(
      builder: (context, constraints) {
        final size = Size(constraints.maxWidth, widget.height);
        return MouseRegion(
          onHover: (e) => _onHover(e.localPosition, size),
          onExit: (_) => setState(() => _hover = -1),
          child: Stack(
            children: [
              SizedBox(
                width: size.width,
                height: size.height,
                child: CustomPaint(
                  painter: _TrendPainter(
                    g: g,
                    created: _created,
                    completed: _completed,
                    rates: _rates,
                    dates: _dates,
                    hover: _hover,
                  ),
                ),
              ),
              if (_hover >= 0 && count > 0)
                ChartBubble(
                  text: _tooltip(_hover),
                  anchorX: (size.width / count) * (_hover + 0.5),
                  chartWidth: size.width,
                ),
            ],
          ),
        );
      },
    );
  }
}

class _TrendPainter extends CustomPainter {
  const _TrendPainter({
    required this.g,
    required this.created,
    required this.completed,
    required this.rates,
    required this.dates,
    required this.hover,
  });

  /// 画布没有 context，颜色由外层 widget 解析好传进来。
  final GlassPalette g;

  final List<int> created;
  final List<int> completed;
  final List<int?> rates;
  final List<DateTime> dates;
  final int hover;

  static const double _labelBand = 20;

  @override
  void paint(Canvas canvas, Size size) {
    if (dates.isEmpty) return;
    final plotHeight = size.height - _labelBand;
    final slot = size.width / dates.length;
    // 上限取 max(新建, 完成) 向上取整到 5 的倍数，至少留 5，避免 1 条任务时柱子顶天。
    final rawMax = [created.fold(0, _max), completed.fold(0, _max)].fold(0, _max);
    final axisMax = ((rawMax / 5).ceil() * 5).clamp(5, 1 << 30).toDouble();

    _paintReferenceLines(canvas, size, plotHeight);

    if (hover >= 0 && hover < dates.length) {
      canvas.drawRect(
        Rect.fromLTWH(hover * slot, 0, slot, plotHeight),
        Paint()..color = g.decoInk.withAlpha(14),
      );
    }

    // 设计图里一天两根细柱（8px 宽、2px 缝），柱子粗了会糊成一片色块。
    final barWidth = (slot * 0.16).clamp(3.0, 11.0);
    final gap = barWidth * 0.25;
    for (var i = 0; i < dates.length; i++) {
      final center = slot * (i + 0.5);
      _paintBar(
        canvas,
        x: center - barWidth - gap / 2,
        height: plotHeight * (created[i] / axisMax),
        width: barWidth,
        bottom: plotHeight,
        top: g.statsPrimarySoft,
        bottomColor: g.statsPrimary,
      );
      _paintBar(
        canvas,
        x: center + gap / 2,
        height: plotHeight * (completed[i] / axisMax),
        width: barWidth,
        bottom: plotHeight,
        top: g.statsTeal,
        bottomColor: g.statsTeal.withAlpha(150),
      );
    }

    _paintRateLine(canvas, plotHeight, slot);
    _paintLabels(canvas, size.width, slot, plotHeight);
  }

  static int _max(int a, int b) => a > b ? a : b;

  void _paintReferenceLines(Canvas canvas, Size size, double plotHeight) {
    final paint = Paint()
      ..color = g.decoInk.withAlpha(26)
      ..strokeWidth = 1;
    // 只画两条参考线，不画刻度数字：看板要的是形状，不是读数表。
    for (final ratio in const [0.5, 1.0]) {
      final y = plotHeight * (1 - ratio);
      canvas.drawLine(Offset(0, y), Offset(size.width, y), paint);
    }
    canvas.drawLine(
      Offset(0, plotHeight),
      Offset(size.width, plotHeight),
      Paint()..color = g.decoInk.withAlpha(46),
    );
  }

  void _paintBar(
    Canvas canvas, {
    required double x,
    required double height,
    required double width,
    required double bottom,
    required Color top,
    required Color bottomColor,
  }) {
    if (height <= 0.5) return;
    final rect = Rect.fromLTWH(x, bottom - height, width, height);
    final radius = (width / 2).clamp(1.5, 5.0);
    final path = Path()
      ..addRRect(
        RRect.fromRectAndCorners(
          rect,
          topLeft: Radius.circular(radius),
          topRight: Radius.circular(radius),
        ),
      );
    canvas.drawPath(
      path,
      Paint()
        ..shader = LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          // 设计图的柱子是"浅到深"，底部仍然是实色；之前收在 alpha 60，
          // 半截柱子像化掉了，读不出高度。
          colors: [top, bottomColor],
        ).createShader(rect),
    );
  }

  void _paintRateLine(Canvas canvas, double plotHeight, double slot) {
    final linePaint = Paint()
      ..color = g.statsAmber
      ..strokeWidth = 2
      ..style = PaintingStyle.stroke
      ..strokeJoin = StrokeJoin.round;
    final dotPaint = Paint()..color = g.statsAmber;
    var previous = Offset.zero;
    var hasPrevious = false;
    for (var i = 0; i < rates.length; i++) {
      final value = rates[i];
      if (value == null) {
        hasPrevious = false; // 没有新建的桶不连线，避免折线凭空跨过空洞
        continue;
      }
      // 折线走右轴 0–100%；跨天完成会让桶内完成率超过 100%，按轴顶截断显示。
      final clamped = value.clamp(0, 100) / 100;
      final point = Offset(slot * (i + 0.5), plotHeight * (1 - clamped));
      if (hasPrevious) canvas.drawLine(previous, point, linePaint);
      canvas.drawCircle(point, 3, dotPaint);
      previous = point;
      hasPrevious = true;
    }
  }

  void _paintLabels(Canvas canvas, double width, double slot, double plotHeight) {
    // 桶太密时只保留部分刻度，否则标签会糊成一片。
    // 28 是「周X」两个字的宽度加一点缝：之前写 46，近 7 天 slot 45 直接
    // 被判成放不下，设计图里 7 个刻度我们只画出一半。
    final step = (28 / slot).ceil().clamp(1, dates.length);
    final weekdayStyle = dates.length <= 7;
    for (var i = 0; i < dates.length; i += step) {
      final painter = TextPainter(
        text: TextSpan(
          text: _labelFor(dates[i], weekdayStyle: weekdayStyle),
          style: TextStyle(
            fontFamily: _labelFontFamily,
            fontSize: 10.5,
            color: g.inkTertiary,
            fontFeatures: [FontFeature.tabularFigures()],
          ),
        ),
        textDirection: TextDirection.ltr,
      )..layout(maxWidth: slot * step);
      painter.paint(
        canvas,
        Offset(
          (slot * (i + 0.5) - painter.width / 2).clamp(0.0, width - painter.width),
          plotHeight + 6,
        ),
      );
    }
  }

  static String _labelFor(DateTime day, {required bool weekdayStyle}) {
    if (!weekdayStyle) return '${day.month}/${day.day}';
    return '周${const ['一', '二', '三', '四', '五', '六', '日'][day.weekday - 1]}';
  }

  @override
  bool shouldRepaint(_TrendPainter old) =>
      old.hover != hover ||
      old.dates.length != dates.length ||
      old.g != g;
}

/// 任务构成环形图：工作 / 个人两段，中心显示工作占比。
class DonutChart extends StatelessWidget {
  const DonutChart({
    super.key,
    required this.work,
    required this.personal,
    required this.percent,
    this.diameter = 116,
  });

  final int work;
  final int personal;
  final int percent;
  final double diameter;

  @override
  Widget build(BuildContext context) {
    final g = GlassPalette.of(context);
    return SizedBox(
      width: diameter,
      height: diameter,
      child: Stack(
        alignment: Alignment.center,
        children: [
          CustomPaint(
            size: Size.square(diameter),
            painter: _DonutPainter(
              g: g,
              work: work,
              personal: personal,
              // 设计图的环是粗 14 / 直径 115 ≈ 0.12，之前 0.155 加上更大的
              // 直径，环厚到中心数字快撑满洞，看着像个实心饼。
              stroke: diameter * 0.12,
            ),
          ),
          Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                work + personal == 0 ? '--' : '$percent%',
                style: TextStyle(
                  fontSize: diameter * 0.19,
                  fontWeight: FontWeight.w700,
                  color: g.ink,
                  fontFeatures: const [FontFeature.tabularFigures()],
                ),
              ),
              const SizedBox(height: 2),
              Text(
                '工作占比',
                style: TextStyle(
                  fontSize: 11,
                  color: g.inkTertiary,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _DonutPainter extends CustomPainter {
  const _DonutPainter({
    required this.g,
    required this.work,
    required this.personal,
    required this.stroke,
  });

  /// 画布没有 context，颜色由外层 widget 解析好传进来。
  final GlassPalette g;

  final int work;
  final int personal;
  final double stroke;

  @override
  void paint(Canvas canvas, Size size) {
    final total = work + personal;
    final center = size.center(Offset.zero);
    final radius = (size.shortestSide - stroke) / 2;
    if (total == 0) {
      // 空态也要有环：画一圈极淡的底，页面不会突然出现一个洞。
      canvas.drawCircle(
        center,
        radius,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = stroke
          ..color = g.decoInk.withAlpha(22),
      );
      return;
    }
    const gap = 0.16; // 两段之间留一点缝，圆头收进去才像"两段"而不是一整圈
    var start = -math.pi / 2; // 12 点方向起笔
    for (final segment in [
      (work / total, g.statsPrimary),
      (personal / total, g.statsTeal),
    ]) {
      final sweep = segment.$1 * math.pi * 2 - gap;
      if (sweep > 0.02) {
        canvas.drawArc(
          Rect.fromCircle(center: center, radius: radius),
          start + gap / 2,
          sweep,
          false,
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = stroke
            ..strokeCap = StrokeCap.round
            ..color = segment.$2,
        );
      }
      start += segment.$1 * math.pi * 2;
    }
  }

  @override
  bool shouldRepaint(_DonutPainter old) =>
      old.work != work ||
      old.personal != personal ||
      old.stroke != stroke ||
      old.g != g;
}

/// 活跃热力图：12 列（周）× 7 行（周一…周日）。
///
/// 数据范围固定近 12 周，不跟时间范围胶囊走。
/// 设计图的格子是高大于宽（23×27.5），正方形会显得太密、不像日历。
class HeatGrid extends StatefulWidget {
  const HeatGrid({
    super.key,
    required this.heatmap,
    this.cellSize = 20,
    this.cellHeight,
    this.spacing = 5,
  });

  final StatsHeatmap heatmap;
  final double cellSize;
  final double? cellHeight;
  final double spacing;

  @override
  State<HeatGrid> createState() => _HeatGridState();
}

class _HeatGridState extends State<HeatGrid> {
  int _hover = -1;

  static const _weekdayNames = ['一', '二', '三', '四', '五', '六', '日'];

  double get _pitchX => widget.cellSize + widget.spacing;
  double get _pitchY => (widget.cellHeight ?? widget.cellSize) + widget.spacing;

  void _onHover(Offset local) {
    final col = (local.dx / _pitchX).floor();
    final row = (local.dy / _pitchY).floor();
    final index = col * 7 + row;
    if (col < 0 || row < 0 || row > 6 || index >= widget.heatmap.counts.length) {
      if (_hover != -1) setState(() => _hover = -1);
      return;
    }
    if (index == _hover) return;
    setState(() => _hover = index);
  }

  String _tooltip(int index) {
    final day = widget.heatmap.dateAt(index);
    final count = widget.heatmap.counts[index];
    return '${day.month}/${day.day} 周${_weekdayNames[day.weekday - 1]} · '
        '完成 $count 个';
  }

  @override
  Widget build(BuildContext context) {
    final g = GlassPalette.of(context);
    final cellHeight = widget.cellHeight ?? widget.cellSize;
    final gridWidth = StatsHeatmap.weeks * _pitchX - widget.spacing;
    final gridHeight = 7 * _pitchY - widget.spacing;
    return MouseRegion(
      onHover: (e) => _onHover(e.localPosition),
      onExit: (_) => setState(() => _hover = -1),
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          SizedBox(
            width: gridWidth,
            height: gridHeight,
            child: CustomPaint(
              painter: _HeatPainter(
                g: g,
                heatmap: widget.heatmap,
                cellSize: widget.cellSize,
                cellHeight: cellHeight,
                spacing: widget.spacing,
                hover: _hover,
              ),
            ),
          ),
          if (_hover >= 0)
            ChartBubble(
              text: _tooltip(_hover),
              anchorX: (_hover ~/ 7 + 0.5) * _pitchX,
              chartWidth: gridWidth,
              top: -34,
            ),
        ],
      ),
    );
  }
}

class _HeatPainter extends CustomPainter {
  const _HeatPainter({
    required this.g,
    required this.heatmap,
    required this.cellSize,
    required this.cellHeight,
    required this.spacing,
    required this.hover,
  });

  /// 画布没有 context，颜色由外层 widget 解析好传进来。
  final GlassPalette g;

  final StatsHeatmap heatmap;
  final double cellSize;
  final double cellHeight;
  final double spacing;
  final int hover;

  @override
  void paint(Canvas canvas, Size size) {
    final pitchX = cellSize + spacing;
    final pitchY = cellHeight + spacing;
    for (var i = 0; i < heatmap.counts.length; i++) {
      final col = i ~/ 7;
      final row = i % 7;
      final rect = Rect.fromLTWH(
        col * pitchX,
        row * pitchY,
        cellSize,
        cellHeight,
      );
      final level = heatmap.levelFor(heatmap.counts[i]);
      canvas.drawRRect(
        RRect.fromRectAndRadius(rect, const Radius.circular(5)),
        Paint()..color = g.heatScale[level],
      );
      if (i == hover) {
        canvas.drawRRect(
          RRect.fromRectAndRadius(rect.deflate(-1.5), const Radius.circular(6)),
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = 1.5
            ..color = g.ink,
        );
      }
    }
  }

  @override
  bool shouldRepaint(_HeatPainter old) =>
      old.hover != hover ||
      old.heatmap.max != heatmap.max ||
      old.cellSize != cellSize ||
      old.cellHeight != cellHeight ||
      old.g != g;
}

/// 专注时段分布：24 根竖柱，峰值 70% 以上的时段用青色高亮。
class HoursChart extends StatefulWidget {
  const HoursChart({super.key, required this.hours, required this.height});

  final List<int> hours;
  final double height;

  @override
  State<HoursChart> createState() => _HoursChartState();
}

class _HoursChartState extends State<HoursChart> {
  int _hover = -1;

  @override
  Widget build(BuildContext context) {
    final g = GlassPalette.of(context);
    const labelBand = 18.0;
    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth;
        final slot = width / 24;
        return MouseRegion(
          onHover: (e) {
            final index = (e.localPosition.dx / slot).floor().clamp(0, 23);
            if (index == _hover) return;
            setState(() => _hover = index);
          },
          onExit: (_) => setState(() => _hover = -1),
          child: Stack(
            children: [
              SizedBox(
                width: width,
                height: widget.height,
                child: CustomPaint(
                  painter: _HoursPainter(
                    g: g,
                    hours: widget.hours,
                    hover: _hover,
                  ),
                ),
              ),
              if (_hover >= 0)
                ChartBubble(
                  text: '${_hover.toString().padLeft(2, '0')}:00 · '
                      '完成 ${widget.hours[_hover]} 个',
                  anchorX: slot * (_hover + 0.5),
                  chartWidth: width,
                  top: widget.height - labelBand,
                ),
            ],
          ),
        );
      },
    );
  }
}

class _HoursPainter extends CustomPainter {
  const _HoursPainter({required this.g, required this.hours, required this.hover});

  /// 画布没有 context，颜色由外层 widget 解析好传进来。
  final GlassPalette g;

  final List<int> hours;
  final int hover;

  static const double _labelBand = 18;

  @override
  void paint(Canvas canvas, Size size) {
    final plotHeight = size.height - _labelBand;
    final slot = size.width / 24;
    final peak = hours.isEmpty ? 0 : hours.reduce((a, b) => a > b ? a : b);
    canvas.drawLine(
      Offset(0, plotHeight),
      Offset(size.width, plotHeight),
      Paint()..color = g.decoInk.withAlpha(46),
    );
    if (peak == 0) return;

    final barWidth = (slot * 0.55).clamp(2.0, 14.0);
    // 达到峰值 70% 以上的时段才算"高峰"，换成青色让眼睛直接找到答案。
    final threshold = peak * 0.7;
    for (var h = 0; h < 24; h++) {
      final count = h < hours.length ? hours[h] : 0;
      if (count == 0) continue;
      final height = plotHeight * (count / peak);
      final rect = Rect.fromLTWH(
        slot * (h + 0.5) - barWidth / 2,
        plotHeight - height,
        barWidth,
        height,
      );
      final color = count >= threshold
          ? g.statsTeal
          : g.statsPrimary;
      canvas.drawRRect(
        RRect.fromRectAndCorners(
          rect,
          topLeft: const Radius.circular(3),
          topRight: const Radius.circular(3),
        ),
        Paint()
          ..shader = LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [
              color,
              color.withAlpha(h == hover ? 180 : 90),
            ],
          ).createShader(rect),
      );
    }

    for (var h = 0; h < 24; h += 3) {
      final painter = TextPainter(
        text: TextSpan(
          text: '$h',
          style: TextStyle(
            fontFamily: _labelFontFamily,
            fontSize: 10.5,
            color: g.inkTertiary,
            fontFeatures: [FontFeature.tabularFigures()],
          ),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      painter.paint(
        canvas,
        Offset(
          (slot * (h + 0.5) - painter.width / 2)
              .clamp(0.0, size.width - painter.width),
          plotHeight + 4,
        ),
      );
    }
  }

  @override
  bool shouldRepaint(_HoursPainter old) => old.hover != hover || old.g != g;
}
