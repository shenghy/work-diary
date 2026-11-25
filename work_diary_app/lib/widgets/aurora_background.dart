import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../services/ambient_motion.dart';
import '../theme/glass_palette.dart';

/// 窗口底板：深色渐变 + 五团缓慢漂移的蓝紫色晕。
///
/// 色团覆盖标题栏、任务卡区和底部空白区，玻璃层会把它们整体模糊后透上来，
/// 所以卡片不用自己发光——背景在动，卡片就已经在“变色”了。
///
/// 32 秒一轮，5 团色各自走 Lissajous 轨迹（x 用 1 倍频、y 用 2 倍频），
/// 相位互相错开；循环结束时正好回到起点，不会跳帧。
class AuroraBackground extends StatefulWidget {
  const AuroraBackground({super.key});

  @override
  State<AuroraBackground> createState() => _AuroraBackgroundState();
}

class _AuroraBackgroundState extends State<AuroraBackground>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  late bool _motionEnabled;

  @override
  void initState() {
    super.initState();
    _motionEnabled = AmbientMotion.enabled.value;
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 22),
    );
    if (_motionEnabled) _controller.repeat();
    AmbientMotion.enabled.addListener(_onMotionChanged);
  }

  void _onMotionChanged() {
    final next = AmbientMotion.enabled.value;
    if (!mounted || next == _motionEnabled) return;
    setState(() => _motionEnabled = next);
    if (next) {
      _controller.repeat();
    } else {
      // 停在当前帧，不重置：关掉时画面不会突然跳一下。
      _controller.stop();
    }
  }

  @override
  void dispose() {
    AmbientMotion.enabled.removeListener(_onMotionChanged);
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return RepaintBoundary(
      child: AnimatedBuilder(
        animation: _controller,
        builder: (context, _) => CustomPaint(
          painter: _AuroraPainter(_controller.value, GlassPalette.of(context)),
          size: Size.infinite,
        ),
      ),
    );
  }
}

class _AuroraPainter extends CustomPainter {
  _AuroraPainter(this.progress, this.g);

  /// 0..1 的循环进度。
  final double progress;

  /// 当前深浅档的底板令牌：色团和迎光面都从这里取，切主题不需要另建一层。
  final GlassPalette g;

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;

    // 底板基色：深色压深海军蓝让白字立得住，浅色抬到冷白让玻璃有透光感。
    canvas.drawRect(
      rect,
      Paint()
        ..shader = LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [g.bgTop, g.bgBottom],
        ).createShader(rect),
    );

    final angle = progress * 2 * math.pi;

    // 七团色：靛蓝打底，长春花蓝/天蓝/紫罗兰/兰花粉/薄荷青提亮，
    // 再加一个跑得快一倍的小高光点，让画面“活”起来。
    // 大色团 x 用 1 倍频、y 用 2 倍频；高光点用 2/3 倍频，循环仍然无缝。
    _drawBlob(
      canvas,
      size,
      g.blobIndigo,
      x: 0.18 + 0.16 * math.sin(angle),
      y: 0.10 + 0.12 * math.sin(angle * 2 + 1.1),
      radius: 1.05,
    );
    _drawBlob(
      canvas,
      size,
      g.blobPeriwinkle,
      x: 0.16 + 0.12 * math.sin(angle + 2.2),
      y: 0.34 + 0.12 * math.sin(angle * 2 + 0.4),
      radius: 1.00,
    );
    _drawBlob(
      canvas,
      size,
      g.blobSky,
      x: 0.86 + 0.10 * math.sin(angle + 3.9),
      y: 0.30 + 0.12 * math.sin(angle * 2 + 2.1),
      radius: 0.96,
    );
    _drawBlob(
      canvas,
      size,
      g.blobViolet,
      x: 0.52 + 0.14 * math.sin(angle + 5.1),
      y: 0.64 + 0.13 * math.sin(angle * 2 + 3.3),
      radius: 0.92,
    );
    _drawBlob(
      canvas,
      size,
      g.blobOrchid,
      x: 0.82 + 0.12 * math.sin(angle + 1.4),
      y: 0.16 + 0.10 * math.sin(angle * 2 + 4.6),
      radius: 0.72,
    );
    _drawBlob(
      canvas,
      size,
      g.blobAqua,
      x: 0.42 + 0.10 * math.sin(angle + 3.2),
      y: 0.96 + 0.06 * math.sin(angle * 2 + 5.7),
      radius: 0.90,
    );
    _drawBlob(
      canvas,
      size,
      g.blobHighlight,
      x: 0.28 + 0.22 * math.sin(angle * 2 + 0.8),
      y: 0.55 + 0.18 * math.sin(angle * 3 + 2.4),
      radius: 0.32,
    );

    // 迎光面：左上角一层会轻微“呼吸”的亮，右下角只留一点压暗。
    // 浅色档的呼吸基线更高（白 90），靠 scrim 压成柔和底纹而不是死白。
    final breathe = g.auroraGlowAlpha + 6 * math.sin(angle * 2);
    canvas.drawRect(
      rect,
      Paint()
        ..shader = RadialGradient(
          center: const Alignment(-0.9, -1.0),
          radius: 1.15,
          colors: [
            g.auroraGlow.withAlpha(breathe.round()),
            g.auroraGlow.withAlpha(0),
          ],
        ).createShader(rect),
    );
    canvas.drawRect(
      rect,
      Paint()
        ..shader = RadialGradient(
          center: const Alignment(1.05, 1.05),
          radius: 1.15,
          colors: [
            g.auroraShade.withAlpha(g.auroraShadeAlpha),
            g.auroraShade.withAlpha(0),
          ],
        ).createShader(rect),
    );
  }

  void _drawBlob(
    Canvas canvas,
    Size size,
    Color color, {
    required double x,
    required double y,
    required double radius,
  }) {
    final center = Offset(size.width * x, size.height * y);
    final blobRect = Rect.fromCircle(center: center, radius: size.width * radius);
    canvas.drawRect(
      blobRect,
      Paint()
        ..shader = RadialGradient(
          colors: [color, color.withAlpha(0)],
        ).createShader(blobRect),
    );
  }

  // 切档时色团必须重画，否则新主题要等到下一帧动画才透出来。
  @override
  bool shouldRepaint(_AuroraPainter oldDelegate) =>
      oldDelegate.progress != progress || oldDelegate.g != g;
}
