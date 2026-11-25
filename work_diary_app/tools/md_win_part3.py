# -*- coding: utf-8 -*-
"""Windows 端：_MemoCard 加 Markdown 渲染 + 搜索边框高亮"""
import io

path = r"E:\Code\WorkDiary\work_diary_app\lib\screens\home_screen.dart"
with io.open(path, "r", encoding="utf-8") as f:
    c = f.read()

ok = []

# 1. borderColor 加 keywordHit（搜索命中 Markdown -> 蓝框）
old1 = (
    "    final borderColor = _hovered ? const Color(0xFFBFD7F9) : Colors.grey.shade200;\n"
)
new1 = (
    "    // 搜索命中（Markdown 内容无法逐字高亮，改用蓝色边框提示）\n"
    "    final keywordHit = widget.keyword.isNotEmpty && widget.memo.content.contains(widget.keyword);\n"
    "    final borderColor = _hovered\n"
    "        ? const Color(0xFFBFD7F9)\n"
    "        : keywordHit\n"
    "            ? const Color(0xFF3B82F6)\n"
    "            : Colors.grey.shade200;\n"
    "    final borderWidth = keywordHit ? 1.6 : 1.0;\n"
)
if old1 in c:
    c = c.replace(old1, new1, 1)
    ok.append("边框高亮")
else:
    ok.append("边框高亮FAIL")

# 2. Border 使用 borderWidth
old2 = (
    "              top: BorderSide(color: borderColor),\n"
    "              right: BorderSide(color: borderColor),\n"
    "              bottom: BorderSide(color: borderColor),\n"
)
new2 = (
    "              top: BorderSide(color: borderColor, width: borderWidth),\n"
    "              right: BorderSide(color: borderColor, width: borderWidth),\n"
    "              bottom: BorderSide(color: borderColor, width: borderWidth),\n"
)
if old2 in c:
    c = c.replace(old2, new2, 1)
    ok.append("边框宽度")
else:
    ok.append("边框宽度FAIL")

# 3. 内容区：Markdown 分支
old3 = (
    "                // 内容：可选中复制 + 搜索关键词高亮\n"
    "                // 用 SelectionArea+Text 替代 SelectableText.rich：\n"
    "                // Flutter Windows 桌面端多个 SelectableText 同屏时第二个不渲染（已知 bug）\n"
    "                SelectionArea(\n"
    "                  child: Text.rich(\n"
    "                    TextSpan(\n"
    "                      style: const TextStyle(\n"
    "                        fontSize: 13,\n"
    "                        height: 1.5,\n"
    "                        color: Color(0xFF334155),\n"
    "                      ),\n"
    "                      children: _highlight(widget.memo.content, widget.keyword),\n"
    "                    ),\n"
    "                  ),\n"
    "                ),\n"
)
new3 = (
    "                // 内容：支持 Markdown 渲染；普通文本保留关键词逐字高亮\n"
    "                // 统一用 SelectionArea 包裹以支持鼠标选择复制\n"
    "                if (_isMarkdown(widget.memo.content))\n"
    "                  SelectionArea(\n"
    "                    child: MarkdownBody(data: widget.memo.content, styleSheet: _mdStyle(context)),\n"
    "                  )\n"
    "                else\n"
    "                  SelectionArea(\n"
    "                    child: Text.rich(\n"
    "                      TextSpan(\n"
    "                        style: const TextStyle(\n"
    "                          fontSize: 13,\n"
    "                          height: 1.5,\n"
    "                          color: Color(0xFF334155),\n"
    "                        ),\n"
    "                        children: _highlight(widget.memo.content, widget.keyword),\n"
    "                      ),\n"
    "                    ),\n"
    "                  ),\n"
)
if old3 in c:
    c = c.replace(old3, new3, 1)
    ok.append("内容分支")
else:
    ok.append("内容分支FAIL")

# 4. 加 _isMarkdown + _mdStyle 方法（插到 build 前）
old4 = "  @override\n  Widget build(BuildContext context) {"
new4 = """  /// 判断文本是否含 Markdown 特征
  bool _isMarkdown(String text) {
    if (text.isEmpty) return false;
    var md = 0;
    for (final line in text.split('\\n')) {
      final t = line.trimLeft();
      if (t.startsWith('# ') || t.startsWith('## ') || t.startsWith('### ') ||
          t.startsWith('- ') || t.startsWith('* ') || t.startsWith('> ') ||
          t.startsWith('```') || t.startsWith('---') || t.startsWith('![') ||
          t.contains('**') || t.contains('`') ||
          RegExp(r'\\[[^\\]]+\\]\\([^)]+\\)').hasMatch(t)) {
        md++;
      }
    }
    return md >= 1;
  }

  /// Markdown 渲染样式（与卡片风格统一）
  MarkdownStyleSheet _mdStyle(BuildContext context) {
    final base = MarkdownStyleSheet.fromTheme(Theme.of(context));
    return base.copyWith(
      p: const TextStyle(fontSize: 13, height: 1.5, color: Color(0xFF334155)),
      h1: const TextStyle(fontSize: 16, height: 1.4, fontWeight: FontWeight.bold, color: Color(0xFF1E293B)),
      h2: const TextStyle(fontSize: 14.5, height: 1.4, fontWeight: FontWeight.bold, color: Color(0xFF1E293B)),
      h3: const TextStyle(fontSize: 13.5, height: 1.4, fontWeight: FontWeight.w600, color: Color(0xFF1E293B)),
      h4: const TextStyle(fontSize: 13, height: 1.4, fontWeight: FontWeight.w600, color: Color(0xFF1E293B)),
      listBullet: const TextStyle(fontSize: 13, height: 1.5, color: Color(0xFF334155)),
      listBulletPadding: EdgeInsets.zero,
      listIndent: 20,
      code: const TextStyle(fontSize: 12, backgroundColor: Color(0xFFF1F5F9), color: Color(0xFFBE123C)),
      codeblockDecoration: BoxDecoration(color: Color(0xFFF1F5F9), borderRadius: BorderRadius.circular(6)),
      codeblockPadding: const EdgeInsets.all(8),
      blockquote: const TextStyle(fontSize: 13, height: 1.5, color: Color(0xFF64748B)),
      blockquoteDecoration: const BoxDecoration(
        color: Color(0xFFF8FAFC),
        border: Border(left: BorderSide(color: Color(0xFFCBD5E1), width: 3)),
      ),
      blockquotePadding: const EdgeInsets.fromLTRB(10, 0, 10, 0),
    );
  }

  @override
  Widget build(BuildContext context) {"""
if old4 in c:
    c = c.replace(old4, new4, 1)
    ok.append("样式方法")
else:
    ok.append("样式方法FAIL")

with io.open(path, "w", encoding="utf-8", newline="\n") as f:
    f.write(c)
print("Windows:", ", ".join(ok))
