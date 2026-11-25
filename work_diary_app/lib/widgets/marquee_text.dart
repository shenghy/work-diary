import 'package:flutter/material.dart';

/// 单行文本：放不下时显示省略号，鼠标悬停后横向滚动展示全文。
///
/// 滚动的标准跑马灯方向：文字整体向左移动，眼睛向右读。
///
/// 三点设计取舍：
/// 1. **不溢出时是纯静态 Text**，不注册动画控制器——列表里几十行文本也不会
///    因为一个用不上的动画掉帧；
/// 2. 溢出时也只在悬停期间跑，鼠标移开立即复位到开头；
/// 3. 外面套 RepaintBoundary，滚动时不让整张卡片跟着重绘。
class MarqueeText extends StatefulWidget {
  const MarqueeText(
    this.text, {
    super.key,
    required this.style,
    this.speed = 40,
    this.pause = const Duration(milliseconds: 700),
  });

  final String text;
  final TextStyle style;

  /// 滚动速度（逻辑像素 / 秒）。
  final double speed;

  /// 滚到两端后的停顿。
  final Duration pause;

  @override
  State<MarqueeText> createState() => _MarqueeTextState();
}

class _MarqueeTextState extends State<MarqueeText>
    with SingleTickerProviderStateMixin {
  /// 懒创建：文本没超出时根本不会创建，省掉一个 Ticker。
  /// 判空后再 dispose，避免"从未创建却在 dispose 里触发懒初始化"的崩溃。
  AnimationController? _controller;
  bool _hovered = false;
  double _overflow = 0;
  double _scrollMs = 0;
  double _pauseMs = 0;

  AnimationController get _c =>
      _controller ??= AnimationController(vsync: this);

  @override
  void didUpdateWidget(covariant MarqueeText oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.text != widget.text && _hovered) {
      _stop();
    }
  }

  @override
  void dispose() {
    _controller?.dispose();
    super.dispose();
  }

  void _start() {
    if (_overflow <= 0 || _hovered) return;
    setState(() => _hovered = true);
    _c.duration = Duration(
      milliseconds: (_scrollMs * 2 + _pauseMs * 2).round(),
    );
    _c.repeat();
  }

  void _stop() {
    if (!_hovered) return;
    _controller?.stop();
    _controller?.value = 0;
    setState(() => _hovered = false);
  }

  /// 把 0..1 的时间轴映射成 0..1 的位移：停顿 → 滚到底 → 停顿 → 滚回起点。
  double _progressFor(double t) {
    final elapsed = t * (_scrollMs * 2 + _pauseMs * 2);
    if (elapsed <= _pauseMs) return 0;
    if (elapsed <= _pauseMs + _scrollMs) {
      return (elapsed - _pauseMs) / _scrollMs;
    }
    if (elapsed <= _pauseMs * 2 + _scrollMs) return 1;
    final back = (elapsed - _pauseMs * 2 - _scrollMs) / _scrollMs;
    return 1 - back.clamp(0.0, 1.0);
  }

  @override
  Widget build(BuildContext context) {
    final textScaler = MediaQuery.textScalerOf(context);
    final textDirection = Directionality.of(context);

    return LayoutBuilder(
      builder: (context, constraints) {
        final painter = TextPainter(
          text: TextSpan(text: widget.text, style: widget.style),
          maxLines: 1,
          textDirection: textDirection,
          textScaler: textScaler,
        )..layout();
        final overflow = painter.width - constraints.maxWidth;

        // 放得下：静态文本，不做任何多余的事
        if (overflow <= 1) {
          _overflow = 0;
          return Text(
            widget.text,
            style: widget.style,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          );
        }

        _overflow = overflow;
        _scrollMs = (overflow / widget.speed * 1000).clamp(600, 12000).toDouble();
        _pauseMs = widget.pause.inMilliseconds.toDouble();

        if (!_hovered) {
          // 未悬停：省略号收尾，视觉上和普通单行文本一致
          return MouseRegion(
            onEnter: (_) => _start(),
            child: Text(
              widget.text,
              style: widget.style,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          );
        }

        return MouseRegion(
          onEnter: (_) => _start(),
          onExit: (_) => _stop(),
          child: RepaintBoundary(
            child: ClipRect(
              child: AnimatedBuilder(
                animation: _c,
                builder: (context, child) => Transform.translate(
                  offset: Offset(-_progressFor(_c.value) * overflow, 0),
                  child: child,
                ),
                child: Text(
                  widget.text,
                  style: widget.style,
                  maxLines: 1,
                  softWrap: false,
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}
