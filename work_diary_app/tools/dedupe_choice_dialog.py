# -*- coding: utf-8 -*-
"""双端：删除重复添加的 _AddChoiceDialog/_ChoiceRow（保留第一份）"""
import io

jobs = [
    (
        r"E:\Code\WorkDiary\work_diary_app\lib\screens\home_screen.dart",
        "/// 新建选择弹窗（方案C：胶囊引导）",
        "class _MemoCard extends StatefulWidget {",
        "Windows",
    ),
    (
        r"E:\Code\WorkDiary\work_diary_app_android\lib\screens\home_screen.dart",
        "/// 胶囊选择行：悬停时主题渐变从左到右填充",
        "class _ImeSafeTextField extends StatefulWidget {",
        "Android",
    ),
]

for path, marker, anchor, name in jobs:
    with io.open(path, "r", encoding="utf-8") as f:
        c = f.read()

    # 第一个 marker 位置
    idx1 = c.find(marker)
    if idx1 < 0:
        print(f"{name}: marker 未找到")
        continue
    # 第二个 marker 位置（从 idx1+len 之后找）
    idx2 = c.find(marker, idx1 + len(marker))
    if idx2 < 0:
        print(f"{name}: 无重复（只有一份）")
        continue
    # anchor（class _MemoCard / _ImeSafeTextField）位置
    apos = c.find(anchor, idx2)
    if apos < 0:
        print(f"{name}: anchor 未找到")
        continue
    # 删除 idx2 -> apos（不含 anchor）
    c2 = c[:idx2] + c[apos:]
    with io.open(path, "w", encoding="utf-8", newline="\n") as f:
        f.write(c2)
    print(f"{name}: 已删除重复块 {apos - idx2} 字符")
