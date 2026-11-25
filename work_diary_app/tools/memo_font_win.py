# -*- coding: utf-8 -*-
"""Windows：备忘录字体改为与任务卡一致（正文15，Markdown层级等比放大）"""
import io

path = r"E:\Code\WorkDiary\work_diary_app\lib\screens\home_screen.dart"
with io.open(path, "r", encoding="utf-8") as f:
    c = f.read()

ok = []

# 1. 普通文本卡片正文 13 -> 15（精确锚点：_MemoCard 内 Text.rich style）
old1 = """                  SelectionArea(
                    child: Text.rich(
                      TextSpan(
                        style: const TextStyle(
                          fontSize: 13,
                          height: 1.5,
                          color: Color(0xFF334155),
                        ),
                        children: _highlight(widget.memo.content, widget.keyword),
                      ),
                    ),
                  ),"""
new1 = """                  SelectionArea(
                    child: Text.rich(
                      TextSpan(
                        style: const TextStyle(
                          fontSize: 15,
                          height: 1.5,
                          color: Color(0xFF334155),
                        ),
                        children: _highlight(widget.memo.content, widget.keyword),
                      ),
                    ),
                  ),"""
if old1 in c:
    c = c.replace(old1, new1, 1)
    ok.append("普通正文 15")
else:
    ok.append("普通正文 FAIL")

# 2. _mdStyle 层级放大
old2 = """      p: const TextStyle(fontSize: 13, height: 1.5, color: Color(0xFF334155)),
      h1: const TextStyle(fontSize: 16, height: 1.4, fontWeight: FontWeight.bold, color: Color(0xFF1E293B)),
      h2: const TextStyle(fontSize: 14.5, height: 1.4, fontWeight: FontWeight.bold, color: Color(0xFF1E293B)),
      h3: const TextStyle(fontSize: 13.5, height: 1.4, fontWeight: FontWeight.w600, color: Color(0xFF1E293B)),
      h4: const TextStyle(fontSize: 13.5, height: 1.4, fontWeight: FontWeight.w600, color: Color(0xFF1E293B)),
      listBullet: const TextStyle(fontSize: 13, height: 1.5, color: Color(0xFF334155)),
      listBulletPadding: EdgeInsets.zero,
      listIndent: 20,
      code: const TextStyle(fontSize: 12, backgroundColor: Color(0xFFF1F5F9), color: Color(0xFFBE123C)),"""
new2 = """      p: const TextStyle(fontSize: 15, height: 1.5, color: Color(0xFF334155)),
      h1: const TextStyle(fontSize: 18, height: 1.4, fontWeight: FontWeight.bold, color: Color(0xFF1E293B)),
      h2: const TextStyle(fontSize: 16.5, height: 1.4, fontWeight: FontWeight.bold, color: Color(0xFF1E293B)),
      h3: const TextStyle(fontSize: 15.5, height: 1.4, fontWeight: FontWeight.w600, color: Color(0xFF1E293B)),
      h4: const TextStyle(fontSize: 15.5, height: 1.4, fontWeight: FontWeight.w600, color: Color(0xFF1E293B)),
      listBullet: const TextStyle(fontSize: 15, height: 1.5, color: Color(0xFF334155)),
      listBulletPadding: EdgeInsets.zero,
      listIndent: 20,
      code: const TextStyle(fontSize: 14, backgroundColor: Color(0xFFF1F5F9), color: Color(0xFFBE123C)),"""
if old2 in c:
    c = c.replace(old2, new2, 1)
    ok.append("mdStyle 放大")
else:
    ok.append("mdStyle FAIL")

# 3. blockquote 13 -> 15
old3 = """      blockquote: const TextStyle(fontSize: 13, height: 1.5, color: Color(0xFF64748B)),"""
new3 = """      blockquote: const TextStyle(fontSize: 15, height: 1.5, color: Color(0xFF64748B)),"""
if old3 in c:
    c = c.replace(old3, new3, 1)
    ok.append("blockquote 15")
else:
    ok.append("blockquote FAIL")

with io.open(path, "w", encoding="utf-8", newline="\n") as f:
    f.write(c)
print("Windows:", ", ".join(ok))
