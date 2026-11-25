# -*- coding: utf-8 -*-
"""备忘卡片方案C：现代纸卡（渐变纸面+顶部主题色条+三层阴影+悬停扫光）"""
import io

TONES = """  static const _memoTones = <List<Color>>[
    [Color(0xFF3B82F6), Color(0xFF93C5FD)], // 蓝
    [Color(0xFF8B5CF6), Color(0xFFC4B5FD)], // 紫
    [Color(0xFF10B981), Color(0xFF6EE7B7)], // 绿
    [Color(0xFFF59E0B), Color(0xFFFCD34D)], // 橙
    [Color(0xFFEF4444), Color(0xFFFCA5A5)], // 红
    [Color(0xFF06B6D4), Color(0xFF67E8F9)], // 青
  ];

  /// 按内容哈希取主题色（同一内容颜色稳定）
  List<Color> _memoToneFor(String s) {
    var h = 0;
    for (final c in s.codeUnits) {
      h = (h * 31 + c) & 0x7fffffff;
    }
    return _memoTones[h % _memoTones.length];
  }
"""

# ===================== Windows =====================
wp = r"E:\Code\WorkDiary\work_diary_app\lib\screens\home_screen.dart"
with io.open(wp, "r", encoding="utf-8") as f:
    wc = f.read()
ok = []

# 1) 色板 + 取色函数（static const _blue 后）
old_blue = "  static const _blue = Color(0xFF3B82F6);"
if old_blue in wc:
    wc = wc.replace(old_blue, old_blue + "\n" + TONES, 1)
    ok.append("win tones OK")
else:
    ok.append("win tones FAIL")

# 2) 替换 build 方法体
start = wc.index("    // 隔行换色：偶数行白色，奇数行极浅蓝灰")
child_pos = wc.index("        child: card,", start)
end = wc.index("\n    );\n  }", child_pos) + len("\n    );\n  }")
new_build = """    // 方案C：现代纸卡（渐变纸面 + 顶部主题色条 + 三层阴影 + 悬停扫光）
    final tones = _memoToneFor(widget.memo.content);
    final keywordHit =
        widget.keyword.isNotEmpty && widget.memo.content.contains(widget.keyword);
    final card = LayoutBuilder(
      builder: (context, cons) {
        final w = cons.maxWidth;
        return AnimatedContainer(
          duration: const Duration(milliseconds: 250),
          curve: Curves.easeOut,
          margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          transform: Matrix4.translationValues(0, _hovered ? -3 : 0, 0),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(16),
            gradient: const LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [Color(0xFFFDFDFE), Colors.white],
            ),
            border: keywordHit
                ? Border.all(color: const Color(0xFF3B82F6), width: 1.6)
                : null,
            boxShadow: _hovered
                ? [
                    BoxShadow(
                        color: const Color(0xFF0F172A).withValues(alpha: 0.05),
                        blurRadius: 4,
                        offset: const Offset(0, 2)),
                    BoxShadow(
                        color: const Color(0xFF0F172A).withValues(alpha: 0.10),
                        blurRadius: 24,
                        offset: const Offset(0, 10)),
                    BoxShadow(
                        color: const Color(0xFF0F172A).withValues(alpha: 0.08),
                        blurRadius: 56,
                        offset: const Offset(0, 26)),
                  ]
                : [
                    BoxShadow(
                        color: const Color(0xFF0F172A).withValues(alpha: 0.04),
                        blurRadius: 2,
                        offset: const Offset(0, 1)),
                    BoxShadow(
                        color: const Color(0xFF0F172A).withValues(alpha: 0.06),
                        blurRadius: 16,
                        offset: const Offset(0, 6)),
                    BoxShadow(
                        color: const Color(0xFF0F172A).withValues(alpha: 0.05),
                        blurRadius: 40,
                        offset: const Offset(0, 18)),
                  ],
          ),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(16),
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
                // 悬停扫光：从左到右划过
                AnimatedPositioned(
                  duration: const Duration(milliseconds: 650),
                  curve: Curves.easeOut,
                  top: 0,
                  bottom: 0,
                  left: _hovered ? w : -w * 0.55,
                  width: w * 0.5,
                  child: IgnorePointer(
                    child: Transform.rotate(
                      angle: -0.15,
                      child: Container(
                        decoration: BoxDecoration(
                          gradient: LinearGradient(
                            colors: [
                              Colors.transparent,
                              Colors.white.withValues(alpha: 0.7),
                              Colors.transparent,
                            ],
                          ),
                        ),
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
                      // 内容：支持 Markdown 渲染；普通文本保留关键词逐字高亮
                      if (_isMarkdown(widget.memo.content))
                        SelectionArea(
                          child: MarkdownBody(
                              data: widget.memo.content,
                              styleSheet: _mdStyle(context)),
                        )
                      else
                        SelectionArea(
                          child: Text.rich(
                            TextSpan(
                              style: const TextStyle(
                                fontSize: 15,
                                height: 1.5,
                                color: Color(0xFF334155),
                              ),
                              children: _highlight(
                                  widget.memo.content, widget.keyword),
                            ),
                          ),
                        ),
                      const SizedBox(height: 6),
                      Row(
                        children: [
                          Text(
                            widget.timeText,
                            style: const TextStyle(
                                fontSize: 11, color: Color(0xFF9CA3AF)),
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
                                  icon: const Icon(Icons.edit_outlined,
                                      size: 15, color: Colors.grey),
                                  padding: EdgeInsets.zero,
                                  constraints: const BoxConstraints(
                                      minWidth: 30, minHeight: 28),
                                  tooltip: '编辑',
                                  onPressed: widget.onEdit,
                                ),
                                const SizedBox(width: 4),
                                IconButton(
                                  icon: const Icon(Icons.delete_outline,
                                      size: 15, color: Colors.grey),
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
        );
      },
    );"""
wc = wc[:start] + new_build + wc[end:]
with io.open(wp, "w", encoding="utf-8", newline="\n") as f:
    f.write(wc)
ok.append("win build replaced")

# ===================== Android =====================
ap = r"E:\Code\WorkDiary\work_diary_app_android\lib\screens\home_screen.dart"
with io.open(ap, "r", encoding="utf-8") as f:
    ac = f.read()

# 1) 色板 + 取色函数（_mdStyle 结束后、_buildMemoCard 前）
old_anchor = "  /// 备忘卡片：隔行换色 + 左侧主题色竖条 + Markdown 渲染 + 搜索高亮"
if old_anchor in ac:
    ac = ac.replace(old_anchor, TONES + "\n" + old_anchor, 1)
    ok.append("and tones OK")
else:
    ok.append("and tones FAIL")

# 2) 替换 _buildMemoCard 方法体
start = ac.index("  /// 备忘卡片：隔行换色")
end = ac.index("\n  }\n\n  /// 搜索关键词高亮", start) + len("\n  }")
new_card = """  /// 备忘卡片：现代纸卡（渐变纸面 + 顶部主题色条 + 三层阴影）
  Widget _buildMemoCard(Memo memo, int index) {
    final tones = _memoToneFor(memo.content);
    final keyword = _memoSearchCtrl.text.trim();
    final keywordHit = keyword.isNotEmpty && memo.content.contains(keyword);
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(16),
        gradient: const LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [Color(0xFFFDFDFE), Colors.white],
        ),
        border: keywordHit
            ? Border.all(color: const Color(0xFF3B82F6), width: 1.6)
            : null,
        boxShadow: [
          BoxShadow(
              color: const Color(0xFF0F172A).withValues(alpha: 0.04),
              blurRadius: 2,
              offset: const Offset(0, 1)),
          BoxShadow(
              color: const Color(0xFF0F172A).withValues(alpha: 0.06),
              blurRadius: 16,
              offset: const Offset(0, 6)),
          BoxShadow(
              color: const Color(0xFF0F172A).withValues(alpha: 0.05),
              blurRadius: 40,
              offset: const Offset(0, 18)),
        ],
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(16),
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
            Padding(
              padding: const EdgeInsets.fromLTRB(14, 12, 6, 10),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // Markdown 内容走渲染；普通文本保留关键词逐字高亮
                  if (_isMarkdown(memo.content))
                    SelectionArea(
                      child: MarkdownBody(
                          data: memo.content, styleSheet: _mdStyle(context)),
                    )
                  else
                    SelectionArea(
                      child: Text.rich(
                        TextSpan(
                          style: const TextStyle(
                            fontSize: 15,
                            height: 1.5,
                            color: Color(0xFF334155),
                          ),
                          children:
                              _highlightMemoKeyword(memo.content, keyword),
                        ),
                      ),
                    ),
                  const SizedBox(height: 6),
                  Row(
                    children: [
                      Text(
                        _formatMemoTime(memo.createdAt),
                        style: const TextStyle(
                            fontSize: 11, color: Color(0xFF9CA3AF)),
                      ),
                      const Spacer(),
                      IconButton(
                        icon: const Icon(Icons.edit_outlined,
                            size: 15, color: Colors.grey),
                        padding: EdgeInsets.zero,
                        constraints:
                            const BoxConstraints(minWidth: 32, minHeight: 32),
                        tooltip: '编辑',
                        onPressed: () => _showMemoEditor(memo: memo),
                      ),
                      const SizedBox(width: 4),
                      IconButton(
                        icon: const Icon(Icons.delete_outline,
                            size: 15, color: Colors.grey),
                        padding: EdgeInsets.zero,
                        constraints:
                            const BoxConstraints(minWidth: 32, minHeight: 32),
                        tooltip: '删除',
                        onPressed: () => _confirmDeleteMemo(memo),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }"""
ac = ac[:start] + new_card + ac[end:]
with io.open(ap, "w", encoding="utf-8", newline="\n") as f:
    f.write(ac)
ok.append("and build replaced")

print(" | ".join(ok))
