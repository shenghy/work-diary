# -*- coding: utf-8 -*-
"""删除重复插入的 _isMarkdown/_mdStyle（保留 1766-1804 第一份）"""
import io
import re

path = r"E:\Code\WorkDiary\work_diary_app\lib\screens\home_screen.dart"
with io.open(path, "r", encoding="utf-8") as f:
    lines = f.readlines()

# 找到第二份 "  /// 判断文本是否含 Markdown 特征" 的位置
first = None
second = None
for i, line in enumerate(lines):
    if "判断文本是否含 Markdown 特征" in line:
        if first is None:
            first = i
        else:
            second = i
            break
print("第一份行号:", first + 1, "第二份行号:", second + 1)

# 第二份从 second 开始，到第二份 _mdStyle 结束（找到下一个 "  @override" 或方法结束）
# _mdStyle 结束标志：下一行是 "  @override" 或类结束
start = second
end = None
depth = 0
for k in range(start, len(lines)):
    line = lines[k]
    for ch in line:
        if ch == "{":
            depth += 1
        elif ch == "}":
            depth -= 1
            if depth == 0:
                end = k
                break
    if end is not None:
        break
print("第二份结束行号:", end + 1)

# 删除 [start, end]（含）
del lines[start:end + 1]
with io.open(path, "w", encoding="utf-8", newline="\n") as f:
    f.writelines(lines)
print("OK：已删除重复方法")
