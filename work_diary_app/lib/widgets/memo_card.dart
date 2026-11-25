import 'package:flutter/material.dart';
import 'package:flutter_markdown/flutter_markdown.dart';

import '../models/memo.dart';
import '../theme/glass_palette.dart';
import 'glass_surface.dart';
import 'memo_code_block.dart';

/// 备忘纸卡：渐变纸面 + 顶部主题色条 + 外侧阴影 + 悬停上浮。
///
/// 色相按内容哈希取 [GlassPalette.memoTones]，同一条备忘的颜色保持稳定；
/// 纸面明暗由当前档的 memoPaperTop / memoPaperBottom 决定。
class MemoCard extends StatefulWidget {
  final Memo memo;
  final int index;
  final VoidCallback onEdit;
  final VoidCallback onDelete;
  final String keyword;
  final String timeText;

  /// 附件条（同 TaskCard：卡片不认识同步服务，只负责排版）
  final Widget? attachments;

  const MemoCard({
    super.key,
    required this.memo,
    required this.index,
    required this.onEdit,
    required this.onDelete,
    required this.keyword,
    required this.timeText,
    this.attachments,
  });

  @override
  State<MemoCard> createState() => _MemoCardState();
}

class _MemoCardState extends State<MemoCard> {
  bool _hovered = false;
  bool _expanded = false;

  /// 正文超过这个字数就折叠。按原始字符数算，Markdown 符号也计入。
  static const int _foldThreshold = 150;

  /// 折叠后可见的高度：15px 字号 × 1.5 行高 × 4 行。
  static const double _foldedHeight = 90;

  bool get _isLongContent => widget.memo.content.length > _foldThreshold;

  /// 搜索时强制展开：命中的字可能正好落在裁切区里，折着就等于搜不到。
  bool get _folded =>
      _isLongContent && !_expanded && widget.keyword.isEmpty;

  /// 判断文本是否含 Markdown 特征
  bool _isMarkdown(String text) {
    if (text.isEmpty) return false;
    var md = 0;
    for (final line in text.split('\n')) {
      final t = line.trimLeft();
      if (t.startsWith('# ') || t.startsWith('## ') || t.startsWith('### ') ||
          t.startsWith('- ') || t.startsWith('* ') || t.startsWith('> ') ||
          t.startsWith('```') || t.startsWith('---') || t.startsWith('![') ||
          t.contains('**') || t.contains('`') ||
          RegExp(r'\[[^\]]+\]\([^)]+\)').hasMatch(t)) {
        md++;
      }
    }
    return md >= 1;
  }

  /// Markdown 渲染样式（与卡片风格统一）
  MarkdownStyleSheet _mdStyle(BuildContext context) {
    final base = MarkdownStyleSheet.fromTheme(Theme.of(context));
    final g = GlassPalette.of(context);
    return base.copyWith(
      p: TextStyle(fontSize: 15, height: 1.5, color: g.inkSecondary),
      a: TextStyle(
        color: g.accentSoft,
        decoration: TextDecoration.underline,
        decorationColor: g.accentSoft.withAlpha(0x66),
      ),
      h1: TextStyle(fontSize: 18, height: 1.4, fontWeight: FontWeight.bold, color: g.ink),
      h2: TextStyle(fontSize: 16.5, height: 1.4, fontWeight: FontWeight.bold, color: g.ink),
      h3: TextStyle(fontSize: 15.5, height: 1.4, fontWeight: FontWeight.w600, color: g.ink),
      h4: TextStyle(fontSize: 15.5, height: 1.4, fontWeight: FontWeight.w600, color: g.ink),
      listBullet: TextStyle(fontSize: 15, height: 1.5, color: g.inkSecondary),
      listBulletPadding: EdgeInsets.zero,
      listIndent: 20,
      // 代码是次要信息：比正文小一档、用弱化的灰，避免红字抢走视线。
      // 不能给 code 加底色：代码块内部也是用这个样式排的，再叠一层就会在
      // 块里出现一条条深浅不一的文字底纹。
      code: TextStyle(
          fontSize: 13,
          height: 1.45,
          color: g.inkTertiary),
      codeblockDecoration: BoxDecoration(color: g.decoInk.withAlpha(0x14), borderRadius: BorderRadius.circular(6)),
      codeblockPadding: const EdgeInsets.all(8),
      blockquote: TextStyle(fontSize: 15, height: 1.5, color: g.decoInk.withAlpha(0x99)),
      blockquoteDecoration: BoxDecoration(
        color: g.decoInk.withAlpha(0x0F),
        border: Border(left: BorderSide(color: g.decoInk.withAlpha(0x33), width: 3)),
      ),
      blockquotePadding: const EdgeInsets.fromLTRB(10, 0, 10, 0),
    );
  }

  /// 按内容哈希取主题色（同一内容颜色稳定）
  List<Color> _memoToneFor(String s) {
    var h = 0;
    for (final c in s.codeUnits) {
      h = (h * 31 + c) & 0x7fffffff;
    }
    final tones = GlassPalette.memoTones;
    return tones[h % tones.length];
  }

  /// 搜索关键词高亮 -> TextSpan 列表
  List<TextSpan> _highlight(String text, String keyword) {
    if (keyword.isEmpty) return [TextSpan(text: text)];
    final spans = <TextSpan>[];
    var start = 0;
    while (true) {
      final idx = text.indexOf(keyword, start);
      if (idx < 0) {
        if (start < text.length) spans.add(TextSpan(text: text.substring(start)));
        break;
      }
      if (idx > start) spans.add(TextSpan(text: text.substring(start, idx)));
      spans.add(TextSpan(
        text: keyword,
        style: TextStyle(
          color: GlassPalette.of(context).repeatChipText,
          fontWeight: FontWeight.w600,
          backgroundColor: GlassPalette.of(context).accent.withAlpha(0x33),
        ),
      ));
      start = idx + keyword.length;
    }
    if (spans.isEmpty) spans.add(TextSpan(text: text));
    return spans;
  }

  /// 正文：Markdown 走 MarkdownBody，普通文本走带关键词高亮的富文本。
  Widget _buildBody(BuildContext context, GlassPalette g) {
    final content = widget.memo.content;
    if (_isMarkdown(content)) {
      final mdStyle = _mdStyle(context);
      return SelectionArea(
        child: MarkdownBody(
          data: content,
          styleSheet: mdStyle,
          builders: {'pre': MemoCodeBlockBuilder(mdStyle)},
        ),
      );
    }
    return SelectionArea(
      child: Text.rich(
        TextSpan(
          style: TextStyle(fontSize: 15, height: 1.5, color: g.inkSecondary),
          children: _highlight(content, widget.keyword),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final g = GlassPalette.of(context);
    final tones = _memoToneFor(widget.memo.content);
    final keywordHit =
        widget.keyword.isNotEmpty && widget.memo.content.contains(widget.keyword);
    final card = AnimatedContainer(
      duration: const Duration(milliseconds: 250),
      curve: Curves.easeOut,
      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      transform: Matrix4.translationValues(0, _hovered ? -3 : 0, 0),
      // 阴影不能写在 decoration 里：纸面是半透明的，boxShadow 会透进来把卡片
      // 压成深色，浅色档尤其明显。改成只画外侧的 CardShadowPainter。
      child: CustomPaint(
        painter: CardShadowPainter(hovered: _hovered, g: g, radius: 20),
        child: DecoratedBox(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(20),
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [g.memoPaperTop, g.memoPaperBottom],
            ),
            border: Border.all(
              color: keywordHit ? g.accentText : g.cardBorder,
              width: keywordHit ? 1.6 : 1,
            ),
          ),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(20),
            child: Stack(
              children: [
                // 顶部 3px 主题色渐变细条
                Positioned(
                  top: 0,
                  left: 0,
                  right: 0,
                  height: 3,
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        begin: Alignment.centerLeft,
                        end: Alignment.centerRight,
                        colors: [tones[0], tones[1]],
                      ),
                    ),
                  ),
                ),
                // 内容
                Padding(
                  padding: const EdgeInsets.fromLTRB(14, 12, 10, 10),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      // 长正文折叠：和任务卡同一套 AnimatedSize + 硬裁切。
                      // Markdown 块没法逐行加省略号，所以不做 ...
                      AnimatedSize(
                        duration: const Duration(milliseconds: 350),
                        curve: Curves.easeInOut,
                        alignment: Alignment.topCenter,
                        child: _folded
                            ? Stack(
                                children: [
                                  // 用滚动视图量高度：子节点按自然高度排版，
                                  // 视图只取 min(内容, 90px)，不会触发 Column
                                  // 溢出断言（MarkdownBody 内部就是个 Column）。
                                  ConstrainedBox(
                                    constraints: const BoxConstraints(
                                        maxHeight: _foldedHeight),
                                    child: SizedBox(
                                      width: double.infinity,
                                      child: SingleChildScrollView(
                                        physics:
                                            const NeverScrollableScrollPhysics(),
                                        child: _buildBody(context, g),
                                      ),
                                    ),
                                  ),
                                  // 折叠时压一层点击层：SelectionArea 会把单击
                                  // 手势留在自己身上，外层 GestureDetector 收
                                  // 不到，点正文就展不开了。
                                  Positioned.fill(
                                    child: GestureDetector(
                                      behavior: HitTestBehavior.opaque,
                                      onTap: () =>
                                          setState(() => _expanded = true),
                                    ),
                                  ),
                                ],
                              )
                            : _buildBody(context, g),
                      ),
                      if (_isLongContent && widget.keyword.isEmpty)
                        Padding(
                          padding: const EdgeInsets.only(top: 6, bottom: 2),
                          child: Align(
                            alignment: Alignment.centerRight,
                            child: MouseRegion(
                              cursor: SystemMouseCursors.click,
                              child: GestureDetector(
                                onTap: () =>
                                    setState(() => _expanded = !_expanded),
                                child: Container(
                                  padding: const EdgeInsets.symmetric(
                                      horizontal: 10, vertical: 2),
                                  decoration: BoxDecoration(
                                    color: g.chipBg,
                                    border:
                                        Border.all(color: g.chipBorder, width: 1),
                                    borderRadius: BorderRadius.circular(3),
                                  ),
                                  child: Row(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      Icon(
                                          _expanded
                                              ? Icons.expand_less
                                              : Icons.expand_more,
                                          size: 13,
                                          color: g.inkSecondary),
                                      const SizedBox(width: 3),
                                      Text(
                                        _expanded ? '收起' : '展开',
                                        style: TextStyle(
                                            fontSize: 11,
                                            color: g.inkSecondary,
                                            fontWeight: FontWeight.w400),
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ),
                      if (widget.attachments != null) widget.attachments!,
                      const SizedBox(height: 6),
                      Row(
                        children: [
                          Text(
                            widget.timeText,
                            style: TextStyle(
                                fontSize: 11, color: g.inkTertiary),
                          ),
                          const Spacer(),
                          // 操作按钮：悬停时才显现
                          AnimatedOpacity(
                            opacity: _hovered ? 1.0 : 0.0,
                            duration: const Duration(milliseconds: 150),
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                IconButton(
                                  icon: Icon(Icons.edit_outlined,
                                      size: 15, color: g.inkSecondary),
                                  padding: EdgeInsets.zero,
                                  constraints: const BoxConstraints(
                                      minWidth: 30, minHeight: 28),
                                  tooltip: '编辑',
                                  onPressed: widget.onEdit,
                                ),
                                const SizedBox(width: 4),
                                IconButton(
                                  icon: Icon(Icons.delete_outline,
                                      size: 15, color: g.inkSecondary),
                                  padding: EdgeInsets.zero,
                                  constraints: const BoxConstraints(
                                      minWidth: 30, minHeight: 28),
                                  tooltip: '删除',
                                  onPressed: widget.onDelete,
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
    // 桌面端悬停微交互；双击卡片进入编辑
    return GestureDetector(
      onDoubleTap: widget.onEdit,
      child: MouseRegion(
        cursor: SystemMouseCursors.basic,
        onEnter: (_) => setState(() => _hovered = true),
        onExit: (_) => setState(() => _hovered = false),
        child: card,
      ),
    );
  }
}
