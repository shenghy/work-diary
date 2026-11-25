import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:markdown/markdown.dart' as md;

import '../theme/glass_palette.dart';

/// 备忘 Markdown 围栏代码块：保持原有灰底/内边距/横向滚动，
/// 在块内右下角增加「复制」按钮。
class MemoCodeBlock extends StatefulWidget {
  final String code;
  final TextStyle? codeStyle;
  final Decoration? decoration;
  final EdgeInsets? padding;

  const MemoCodeBlock({
    super.key,
    required this.code,
    this.codeStyle,
    this.decoration,
    this.padding,
  });

  @override
  State<MemoCodeBlock> createState() => _MemoCodeBlockState();
}

class _MemoCodeBlockState extends State<MemoCodeBlock> {
  static const Duration _feedbackDuration = Duration(milliseconds: 1200);

  bool _copied = false;
  Timer? _resetTimer;
  Offset? _pointerDown;

  @override
  void dispose() {
    _resetTimer?.cancel();
    super.dispose();
  }

  Future<void> _copy() async {
    await Clipboard.setData(ClipboardData(text: widget.code));
    if (!mounted) return;
    setState(() => _copied = true);
    _resetTimer?.cancel();
    _resetTimer = Timer(_feedbackDuration, () {
      if (mounted) setState(() => _copied = false);
    });
  }

  @override
  Widget build(BuildContext context) {
    final g = GlassPalette.of(context);
    final padding = widget.padding ?? const EdgeInsets.all(8);
    final decoration = widget.decoration ??
        BoxDecoration(
          color: g.decoInk.withAlpha(0x14),
          borderRadius: BorderRadius.circular(6),
        );
    final codeStyle = widget.codeStyle ??
        TextStyle(fontSize: 13, height: 1.45, color: g.inkTertiary);

    return Container(
      decoration: decoration,
      padding: padding,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Text(widget.code, style: codeStyle),
          ),
          const SizedBox(height: 6),
          Align(
            alignment: Alignment.centerRight,
            child: _buildCopyChip(g),
          ),
        ],
      ),
    );
  }

  Widget _buildCopyChip(GlassPalette g) {
    final color = _copied ? g.success : g.inkSecondary;
    // 用 Listener 而不是 GestureDetector：正文包在 SelectionArea 里，
    // 文本选择的手势竞技场会吞掉按钮的 tap 事件。
    return Tooltip(
      message: '复制代码',
      waitDuration: const Duration(milliseconds: 400),
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        child: Listener(
          onPointerDown: (event) => _pointerDown = event.position,
          onPointerUp: (event) {
            final down = _pointerDown;
            _pointerDown = null;
            if (down == null || (event.position - down).distance > 8) return;
            _copy();
          },
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 2),
            decoration: BoxDecoration(
              color: g.chipBg,
              border: Border.all(color: g.chipBorder, width: 1),
              borderRadius: BorderRadius.circular(3),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(_copied ? Icons.check : Icons.copy_rounded,
                    size: 13, color: color),
                const SizedBox(width: 3),
                Text(
                  _copied ? '已复制' : '复制',
                  style: TextStyle(
                    fontSize: 11,
                    color: color,
                    fontWeight: FontWeight.w400,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// 把 Markdown 的 `pre` 元素替换成带复制按钮的 [MemoCodeBlock]。
class MemoCodeBlockBuilder extends MarkdownElementBuilder {
  final MarkdownStyleSheet styleSheet;

  MemoCodeBlockBuilder(this.styleSheet);

  @override
  bool isBlockElement() => true;

  // 返回一个占位 widget，确保 flutter_markdown 内部把这段 inline 清空；
  // 代码正文由下面的 MemoCodeBlock 整体渲染，这里不参与排版。
  @override
  Widget? visitText(md.Text text, TextStyle? preferredStyle) =>
      const SizedBox.shrink();

  @override
  Widget? visitElementAfterWithContext(
    BuildContext context,
    md.Element element,
    TextStyle? preferredStyle,
    TextStyle? parentStyle,
  ) {
    // 解析器会在围栏代码末尾补一个换行，复制时去掉。
    final code = element.textContent.replaceFirst(RegExp(r'\n$'), '');
    return MemoCodeBlock(
      code: code,
      codeStyle: styleSheet.code,
      decoration: styleSheet.codeblockDecoration,
      padding: styleSheet.codeblockPadding,
    );
  }
}
