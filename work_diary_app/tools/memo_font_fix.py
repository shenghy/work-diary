# -*- coding: utf-8 -*-
"""重新执行字体修复（输出用 print flush）"""
import sys

old = """      p: const TextStyle(fontSize: 13, height: 1.5, color: Color(0xFF334155)),
      h1: const TextStyle(fontSize: 16, height: 1.4, fontWeight: FontWeight.bold, color: Color(0xFF1E293B)),
      h2: const TextStyle(fontSize: 14.5, height: 1.4, fontWeight: FontWeight.bold, color: Color(0xFF1E293B)),
      h3: const TextStyle(fontSize: 13.5, height: 1.4, fontWeight: FontWeight.w600, color: Color(0xFF1E293B)),
      h4: const TextStyle(fontSize: 13, height: 1.4, fontWeight: FontWeight.w600, color: Color(0xFF1E293B)),
      listBullet: const TextStyle(fontSize: 13, height: 1.5, color: Color(0xFF334155)),
      listBulletPadding: EdgeInsets.zero,
      listIndent: 20,
      code: const TextStyle(fontSize: 12, backgroundColor: Color(0xFFF1F5F9), color: Color(0xFFBE123C)),"""
new = """      p: const TextStyle(fontSize: 15, height: 1.5, color: Color(0xFF334155)),
      h1: const TextStyle(fontSize: 18, height: 1.4, fontWeight: FontWeight.bold, color: Color(0xFF1E293B)),
      h2: const TextStyle(fontSize: 16.5, height: 1.4, fontWeight: FontWeight.bold, color: Color(0xFF1E293B)),
      h3: const TextStyle(fontSize: 15.5, height: 1.4, fontWeight: FontWeight.w600, color: Color(0xFF1E293B)),
      h4: const TextStyle(fontSize: 15.5, height: 1.4, fontWeight: FontWeight.w600, color: Color(0xFF1E293B)),
      listBullet: const TextStyle(fontSize: 15, height: 1.5, color: Color(0xFF334155)),
      listBulletPadding: EdgeInsets.zero,
      listIndent: 20,
      code: const TextStyle(fontSize: 14, backgroundColor: Color(0xFFF1F5F9), color: Color(0xFFBE123C)),"""

old_bq = "      blockquote: const TextStyle(fontSize: 13, height: 1.5, color: Color(0xFF64748B)),"
new_bq = "      blockquote: const TextStyle(fontSize: 15, height: 1.5, color: Color(0xFF64748B)),"

paths = [
    (r"E:\Code\WorkDiary\work_diary_app\lib\screens\home_screen.dart", "Windows"),
    (r"E:\Code\WorkDiary\work_diary_app_android\lib\screens\home_screen.dart", "Android"),
]
for path, name in paths:
    with open(path, "r", encoding="utf-8") as f:
        c = f.read()
    n1 = c.count(old)
    c = c.replace(old, new)
    n2 = c.count(old_bq)
    c = c.replace(old_bq, new_bq)
    with open(path, "w", encoding="utf-8", newline="\n") as f:
        f.write(c)
    sys.stdout.write(f"{name}: 主段{n1}处, blockquote剩余{n2}处\n")
    sys.stdout.flush()
