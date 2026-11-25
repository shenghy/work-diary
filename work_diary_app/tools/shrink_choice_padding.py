# -*- coding: utf-8 -*-
"""缩小新建选择弹窗(C方案)的边缘padding"""
import io

jobs = [
    (
        r"E:\Code\WorkDiary\work_diary_app\lib\screens\home_screen.dart",
        "Windows",
        [
            ("titlePadding: const EdgeInsets.fromLTRB(22, 20, 22, 0),",
             "titlePadding: const EdgeInsets.fromLTRB(18, 16, 18, 0),"),
            ("contentPadding: const EdgeInsets.fromLTRB(16, 12, 16, 18),",
             "contentPadding: const EdgeInsets.fromLTRB(10, 8, 10, 12),"),
            ("padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),",
             "padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 11),"),
        ],
    ),
    (
        r"E:\Code\WorkDiary\work_diary_app_android\lib\screens\home_screen.dart",
        "Android",
        [
            ("padding: const EdgeInsets.fromLTRB(20, 18, 20, 16),",
             "padding: const EdgeInsets.fromLTRB(14, 14, 14, 12),"),
            ("padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),",
             "padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 11),"),
        ],
    ),
]

for path, name, pairs in jobs:
    with io.open(path, "r", encoding="utf-8") as f:
        c = f.read()
    res = []
    for old, new in pairs:
        if old in c:
            c = c.replace(old, new, 1)
            res.append("OK:" + old[:40])
        else:
            res.append("FAIL:" + old[:40])
    with io.open(path, "w", encoding="utf-8", newline="\n") as f:
        f.write(c)
    print(f"{name}: " + " | ".join(res))
