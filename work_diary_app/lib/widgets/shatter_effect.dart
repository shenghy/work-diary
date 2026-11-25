import 'dart:math' as math;
import 'package:flutter/material.dart';

import '../theme/glass_palette.dart';

/// 卡片删除消失动画：粒子化 → 粒子飞散，总时长由 controller 决定（建议 600ms）。
///
/// 阶段 1（前半段）：卡片底色快速消失，表面浮出大量微小粒子，轻微向上飘。
/// 阶段 2（后半段）：粒子直接加速向下飞散 + 横向漂移 + 淡出，不再出现矩形碎片。
class ShatterEffect extends StatefulWidget {
  final Animation<double> animation;
  final Color accentColor;
  final Color bgColor;

  const ShatterEffect({
    super.key,
    required this.animation,
    required this.accentColor,
    this.bgColor = Colors.transparent,
  });

  @override
  State<ShatterEffect> createState() => _ShatterEffectState();
}

/// 粒子取色档位：0 主碎屑（深色档纯白）、1 次碎屑（近白）、2 强调色。
/// 具体颜色不在生成粒子时定死，而是绘制时按当前主题令牌取，
/// 这样主题切换时粒子颜色会跟着走，不会再出现白粒子飘在白底上看不见。
class _Particle {
  final Offset start;
  final double r;
  final int tone;
  final double riseY;
  final double fallY;
  final double driftX;
  final double delay;
  final double fallCurve;
  const _Particle({
    required this.start,
    required this.r,
    required this.tone,
    required this.riseY,
    required this.fallY,
    required this.driftX,
    required this.delay,
    required this.fallCurve,
  });
}

class _ShatterEffectState extends State<ShatterEffect> {
  late final List<_Particle> _particles;

  @override
  void initState() {
    super.initState();
    final rng = math.Random();
    _particles = List.generate(160, (_) {
      final colorRoll = rng.nextDouble();
      final tone = colorRoll < 0.7
          ? 0
          : colorRoll < 0.9
              ? 1
              : 2;
      return _Particle(
        start: Offset(rng.nextDouble(), rng.nextDouble()),
        r: 1.5 + rng.nextDouble() * 2.5,
        tone: tone,
        riseY: 8 + rng.nextDouble() * 22,
        fallY: 40 + rng.nextDouble() * 120,
        driftX: (rng.nextDouble() - 0.5) * 120,
        delay: rng.nextDouble() * 0.2,
        fallCurve: 0.6 + rng.nextDouble() * 0.6,
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    return RepaintBoundary(
      child: CustomPaint(
        size: Size.infinite,
        painter: _ShatterPainter(
          g: GlassPalette.of(context),
          particles: _particles,
          progress: widget.animation,
          accentColor: widget.accentColor,
          bgColor: widget.bgColor,
        ),
      ),
    );
  }
}

class _ShatterPainter extends CustomPainter {
  final GlassPalette g;
  final List<_Particle> particles;
  final Animation<double> progress;
  final Color accentColor;
  final Color bgColor;

  _ShatterPainter({
    required this.g,
    required this.particles,
    required this.progress,
    required this.accentColor,
    required this.bgColor,
  }) : super(repaint: progress);

  /// 粒子基色按档位从令牌取：深色档 0 就是纯白（与改造前的 Colors.white
  /// 逐字节一致），1 是近白次色；浅色档换成冷灰与深墨，碎屑才不会被白卡片吞掉。
  Color _particleColor(int tone) {
    switch (tone) {
      case 1:
        return g.inkSecondary;
      case 2:
        return accentColor;
      default:
        return g.glassEdgeColor;
    }
  }

  @override
  void paint(Canvas canvas, Size size) {
    final t = progress.value;

    // 卡片底色在前 20% 时间内快速消失
    if (t < 0.2) {
      final bgAlpha = 1.0 - t / 0.2;
      canvas.drawRect(
        Rect.fromLTWH(0, 0, size.width, size.height),
        Paint()..color = bgColor.withValues(alpha: bgAlpha),
      );
      canvas.drawRect(
        Rect.fromLTWH(0, 0, 10, size.height),
        Paint()..color = accentColor.withValues(alpha: bgAlpha),
      );
    }

    const phaseSplit = 0.5;

    for (final p in particles) {
      double local = 0.0;
      if (t > p.delay) {
        local = ((t - p.delay) / (1.0 - p.delay)).clamp(0.0, 1.0);
      }
      if (local <= 0) continue;

      double dx = 0.0;
      double dy = 0.0;
      double alpha;

      if (local < phaseSplit) {
        // 阶段1：轻微向上飘，淡入
        final k = local / phaseSplit;
        dy = -p.riseY * Curves.easeOut.transform(k);
        alpha = (k * 1.5).clamp(0.0, 1.0);
      } else {
        // 阶段2：粒子直接加速向下飞散 + 横向漂移 + 淡出
        final k = (local - phaseSplit) / (1.0 - phaseSplit);
        final ease = Curves.easeIn.transform(k);
        dy = -p.riseY + p.fallY * ease;
        dx = p.driftX * ease;
        // 后 40% 时间淡出
        alpha = k < 0.6 ? 1.0 : 1.0 - (k - 0.6) / 0.4;
      }

      final cx = p.start.dx * size.width + dx;
      final cy = p.start.dy * size.height + dy;
      canvas.drawCircle(
        Offset(cx, cy),
        p.r,
        // withValues 只换透明度：粒子基色来自令牌，淡出期间仍然保持色相。
        Paint()..color = _particleColor(p.tone).withValues(alpha: alpha),
      );
    }
  }

  @override
  bool shouldRepaint(covariant _ShatterPainter oldDelegate) =>
      oldDelegate.progress != progress || oldDelegate.g != g;
}