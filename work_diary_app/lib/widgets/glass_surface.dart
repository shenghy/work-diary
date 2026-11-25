import 'dart:ui';

import 'package:flutter/material.dart';

import '../theme/glass_palette.dart';

/// 玻璃卡片的统一视觉参数。
///
/// 全窗的模糊只做一次（main.dart 的 _WindowGlass），这里只负责“染色 + 边光”：
/// 卡片本身不再开 BackdropFilter，滚动时没有额外 GPU 采样。
/// 颜色全部走 [GlassPalette] 令牌，这里只留和深浅无关的尺寸，
/// 免得出现「调色板改了、卡片还是老样子」的两边不一致。
class GlassStyle {
  const GlassStyle._();

  /// 圆角半径。
  static const double radius = 22;

  /// 卡片自身不再模糊；要单独调某张卡的模糊才设 >0（不推荐）。
  static const double blurSigma = 0;
}

/// 卡片材质风格。
enum GlassVariant {
  /// 纯白平卡（仅作为降级 / 对比保留）
  solid,

  /// 边缘光玻璃：半透明染色 + 顶部高光 + 底部收暗 + 斜向镜面
  rim,

  /// 提亮玻璃：卡片比背后的极光更亮，看板那套设计图用的是这一档
  lift,

  /// 薄雾玻璃：更浓的白 + 轻微模糊（不用于深色主线）
  frost,
}

/// 一块玻璃面板：半透明染色 + 白色描边 + 反光。
///
/// 阴影不能放在这里（会被 ClipRRect 裁掉），由外层 Container 负责。
class GlassSurface extends StatelessWidget {
  const GlassSurface({
    super.key,
    required this.child,
    this.radius = GlassStyle.radius,
    this.blurSigma = GlassStyle.blurSigma,
    this.intensity = 1,
    this.hovered = false,
    this.variant = GlassVariant.rim,
  });

  final Widget child;
  final double radius;
  final double blurSigma;

  /// 反光 / 白度的整体强度，0 = 完全透明。
  final double intensity;

  /// 鼠标悬停：触发反光扫过。
  final bool hovered;

  /// 材质风格，默认当前样式。
  final GlassVariant variant;

  @override
  Widget build(BuildContext context) {
    final g = GlassPalette.of(context);
    final borderRadius = BorderRadius.circular(radius);
    final isSolid = variant == GlassVariant.solid;
    final isFrost = variant == GlassVariant.frost;
    final isLift = variant == GlassVariant.lift;
    final hasRim = !isSolid;

    // 深色玻璃：彩色提亮，底色透上来；纯白款留给降级。
    final topAlpha = isSolid ? 255 : (isFrost ? 56 : g.tintTopAlpha);
    final bottomAlpha = isSolid ? 255 : (isFrost ? 28 : g.tintBottomAlpha);
    final topColor = isSolid ? Colors.white : g.tintTop;
    final bottomColor = isSolid ? Colors.white : g.tintBottom;
    // 玻璃需要先压一层底色，再把染色渐变叠上去：
    // BoxDecoration 同时给 color 和 gradient 时只会画 gradient，color 会被忽略。
    // 深色档压黑把卡片「按」进背景，浅色档压白把卡片「抬」起来；
    // 看板的提亮档再换一组基色，压什么、压多深全部由令牌决定。
    final shade = isLift
        ? g.liftBase.withAlpha((g.liftAlpha * intensity).round())
        : g.shadeColor
            .withAlpha(((isSolid ? 0 : g.shadeAlpha) * intensity).round());
    Widget background = DecoratedBox(
      decoration: BoxDecoration(
        borderRadius: borderRadius,
        color: shade,
      ),
      child: DecoratedBox(
        decoration: BoxDecoration(
          borderRadius: borderRadius,
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [
              topColor.withAlpha((topAlpha * intensity).round()),
              bottomColor.withAlpha((bottomAlpha * intensity).round()),
            ],
          ),
          border: Border.all(
            color:
                g.glassEdgeColor.withAlpha((g.edgeAlpha * intensity).round()),
            width: 1,
          ),
        ),
      ),
    );

    final sigma = isFrost ? (blurSigma > 0 ? blurSigma : 8.0) : blurSigma;
    if (sigma > 0) {
      background = BackdropFilter(
        filter: ImageFilter.blur(sigmaX: sigma, sigmaY: sigma),
        child: background,
      );
    }

    return ClipRRect(
      borderRadius: borderRadius,
      child: Stack(
        fit: StackFit.passthrough,
        children: [
          // 顺序很重要：染色 → 反光 → 内容。
          // 反光必须垫在内容下面，否则等于给文字蒙一层白纱，字就发虚了。
          Positioned.fill(child: background),
          if (hasRim)
            Positioned.fill(child: IgnorePointer(child: _RimLight(g: g))),
          Positioned.fill(
            child: IgnorePointer(
              child: _GlassSheen(
                intensity: intensity,
                hovered: hovered,
                glare: g.sheenGlare,
                alpha: g.sheenAlpha,
              ),
            ),
          ),
          child,
        ],
      ),
    );
  }
}

/// 玻璃边缘光：顶部 1px 高光、顶部柔光、底部收暗、斜向镜面。
///
/// 全部垫在内容下面，只作用在卡片背景上，不会碰文字。
class _RimLight extends StatelessWidget {
  const _RimLight({required this.g});

  final GlassPalette g;

  @override
  Widget build(BuildContext context) {
    return Stack(
      fit: StackFit.expand,
      children: [
        // 顶部 1px 高光（两头渐隐，像光的切线）
        Align(
          alignment: Alignment.topCenter,
          child: Container(
            height: 1,
            decoration: BoxDecoration(
              gradient: LinearGradient(
                colors: [
                  g.rimTopLine.withAlpha(0),
                  g.rimTopLine,
                  g.rimTopLine.withAlpha(0),
                ],
                stops: const [0.05, 0.5, 0.95],
              ),
            ),
          ),
        ),
        // 顶部柔和内发光：模拟玻璃上沿的反光带
        Align(
          alignment: Alignment.topCenter,
          child: Container(
            height: 26,
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [g.rimGlowTop, g.rimGlowTop.withAlpha(0)],
              ),
            ),
          ),
        ),
        // 底部 1px 收暗：做出"厚度"。深色压黑，浅色压冷灰——白底上一条黑线太重。
        Align(
          alignment: Alignment.bottomCenter,
          child: Container(height: 1, color: g.rimBottomLine),
        ),
        // 左上角柔光：玻璃迎光面，压在内容下面
        Positioned.fill(
          child: DecoratedBox(
            decoration: BoxDecoration(
              gradient: RadialGradient(
                center: const Alignment(-0.72, -1.15),
                radius: 1.15,
                colors: [g.rimCornerGlow, g.rimCornerGlow.withAlpha(0)],
                stops: const [0, 0.62],
              ),
            ),
          ),
        ),
        // 斜向镜面：很淡的一道，让平面看起来是弧面
        DecoratedBox(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: const Alignment(-1, -1),
              end: const Alignment(0.7, 1),
              stops: const [0, 0.42, 0.72],
              colors: [
                g.rimDiagonal,
                g.rimDiagonal.withAlpha(0),
                g.rimDiagonal.withAlpha(0),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

/// 悬停时扫过卡片的一道反光。
///
/// 它垫在内容下面，不会影响任何可读性。
class _GlassSheen extends StatelessWidget {
  const _GlassSheen({
    required this.intensity,
    required this.hovered,
    required this.glare,
    required this.alpha,
  });

  final double intensity;
  final bool hovered;

  /// 光带基色与强度。浅色档要偏冷、更实，否则在近白的卡面上扫不出来。
  final Color glare;
  final int alpha;

  @override
  Widget build(BuildContext context) {
    return ClipRect(
      child: AnimatedSlide(
        offset: Offset(hovered ? 1.9 : -1.9, 0),
        duration: const Duration(milliseconds: 640),
        curve: Curves.easeOutCubic,
        child: DecoratedBox(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.centerLeft,
              end: Alignment.centerRight,
              colors: [
                glare.withAlpha(0),
                glare.withAlpha((alpha * intensity).round()),
                glare.withAlpha(0),
              ],
              stops: const [0.32, 0.5, 0.68],
            ),
          ),
        ),
      ),
    );
  }
}

/// 只画卡片外侧的阴影：先画圆角矩形的模糊影，再把卡片内部挖掉。
///
/// 卡片材质是半透明的，用 BoxDecoration.boxShadow 时阴影会从卡片内部透出来，
/// 深色档看不出来，浅色档直接把纸面压成近黑色——任务卡和备忘卡都踩过这个坑，
/// 所以阴影统一走这里，任何半透明表面都不要再写 boxShadow。
class CardShadowPainter extends CustomPainter {
  const CardShadowPainter({
    required this.hovered,
    required this.g,
    this.radius = GlassStyle.radius,
  });

  final bool hovered;

  /// 阴影 / 光晕的基色都来自令牌：深色档 RGB 就是纯黑与 3B82F6，
  /// 和改造前逐字节一致；浅色档才换成冷灰蓝。
  final GlassPalette g;

  /// 卡片圆角，需要和卡片材质那层保持一致，否则挖出来的洞对不上边。
  final double radius;

  @override
  void paint(Canvas canvas, Size size) {
    final rrect = RRect.fromRectAndRadius(
      Offset.zero & size,
      Radius.circular(radius),
    );
    final bounds = Rect.fromLTRB(-48, -48, size.width + 48, size.height + 48);
    canvas.saveLayer(bounds, Paint());
    // 贴地接触影：很轻，只负责“落地”。
    canvas.drawRRect(
      rrect.shift(Offset(0, hovered ? 4 : 3)),
      Paint()
        ..color = g.shadow.withValues(alpha: hovered ? 0.30 : 0.22)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 5),
    );
    // 环境光：淡蓝色光晕，不再是黑色大团。
    canvas.drawRRect(
      rrect.shift(Offset(0, hovered ? 14 : 10)),
      Paint()
        ..color = g.accent.withValues(alpha: hovered ? 0.28 : 0.18)
        ..maskFilter = MaskFilter.blur(BlurStyle.normal, hovered ? 36 : 28),
    );
    // 从阴影层里挖掉卡片内部，阴影只留在外面。
    canvas.drawRRect(rrect, Paint()..blendMode = BlendMode.clear);
    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant CardShadowPainter oldDelegate) =>
      oldDelegate.hovered != hovered ||
      oldDelegate.g != g ||
      oldDelegate.radius != radius;
}
