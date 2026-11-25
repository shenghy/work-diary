# -*- coding: utf-8 -*-
"""双端：备忘编辑弹窗文本框加高（Windows 弹窗340->420、maxLines 6->12；Android 弹窗200->300）"""
import io

# ===== Windows =====
path = r"E:\Code\WorkDiary\work_diary_app\lib\screens\home_screen.dart"
with io.open(path, "r", encoding="utf-8") as f:
    c = f.read()
ok = []

# 1. 弹窗高度 340 -> 420（备忘编辑弹窗的 SizedBox）
old1 = """          content: SizedBox(
            width: 430,
            height: 340,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SegmentedButton<int>("""
new1 = """          content: SizedBox(
            width: 430,
            height: 420,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SegmentedButton<int>("""
if old1 in c:
    c = c.replace(old1, new1, 1)
    ok.append("弹窗高度420")
else:
    ok.append("弹窗高度 FAIL")

# 2. 备忘编辑 TextField maxLines: 12
old2 = """                          enableAutoConvert: false,
                          maxLength: 3000,
                          counterText: '',
                        )"""
new2 = """                          enableAutoConvert: false,
                          maxLength: 3000,
                          counterText: '',
                          maxLines: 12,
                        )"""
if old2 in c:
    c = c.replace(old2, new2, 1)
    ok.append("maxLines 12")
else:
    ok.append("maxLines FAIL")

with io.open(path, "w", encoding="utf-8", newline="\n") as f:
    f.write(c)
print("Windows:", ", ".join(ok))

# ===== Android =====
path2 = r"E:\Code\WorkDiary\work_diary_app_android\lib\screens\home_screen.dart"
with io.open(path2, "r", encoding="utf-8") as f:
    c2 = f.read()
ok2 = []

old3 = """                SizedBox(
                  height: 200,
                  child: tab == 0"""
new3 = """                SizedBox(
                  height: 300,
                  child: tab == 0"""
if old3 in c2:
    c2 = c2.replace(old3, new3, 1)
    ok2.append("弹窗高度300")
else:
    ok2.append("弹窗高度 FAIL")

old4 = """                          autofocus: true,
                          maxLength: 3000,
                          counterText: '',
                        )"""
new4 = """                          autofocus: true,
                          maxLength: 3000,
                          counterText: '',
                          maxLines: 12,
                        )"""
if old4 in c2:
    c2 = c2.replace(old4, new4, 1)
    ok2.append("maxLines 12")
else:
    ok2.append("maxLines FAIL")

with io.open(path2, "w", encoding="utf-8", newline="\n") as f:
    f.write(c2)
print("Android:", ", ".join(ok2))
