# -*- coding: utf-8 -*-
"""修复：删除错位方法，重新插入到 _MemoCardState.build 前"""
import io

path = r"E:\Code\WorkDiary\work_diary_app\lib\screens\home_screen.dart"
with io.open(path, "r", encoding="utf-8") as f:
    c = f.read()

ok = []

# 1. 删除错位插入的方法块（_isMarkdown + _mdStyle，位于任务编辑弹窗保存按钮后）
# 错位块特征：从 "  /// 判断文本是否含 Markdown 特征" 到 _mdStyle 方法结束（blockquotePadding...）
old_block = """  /// 判断文本是否含 Markdown 特征
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

"""
if old_block in c:
    c = c.replace(old_block, "", 1)
    ok.append("删除错位方法")
else:
    ok.append("错位方法未匹配")

# 2. 在 _MemoCardState.build 前插入方法
anchor = "class _MemoCardState extends State<_MemoCard> {\n  bool _hovered = false;"
new_methods = """class _MemoCardState extends State<_MemoCard> {
  bool _hovered = false;

  /// 判断文本是否含 Markdown 特征
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
"""
if anchor in c:
    c = c.replace(anchor, new_methods, 1)
    ok.append("插入_MemoCardState")
else:
    ok.append("锚点未匹配")

with io.open(path, "w", encoding="utf-8", newline="\n") as f:
    f.write(c)
print("Windows:", ", ".join(ok))
