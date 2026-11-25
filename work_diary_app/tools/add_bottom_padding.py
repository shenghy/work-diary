# -*- coding: utf-8 -*-
"""任务/备忘列表底部加100px留白（防止+按钮遮挡最后一张卡片）"""
import io

jobs = [
    (
        r"E:\Code\WorkDiary\work_diary_app\lib\screens\home_screen.dart",
        "Windows",
        [
            # 任务列表（body 里 ListView.builder）
            ("                  : ListView.builder(\n                      padding: const EdgeInsets.symmetric(vertical: 8),",
             "                  : ListView.builder(\n                      padding: const EdgeInsets.only(top: 8, bottom: 108),"),
            # 备忘列表
            ("              : ListView(\n                  padding: const EdgeInsets.symmetric(vertical: 6),",
             "              : ListView(\n                  padding: const EdgeInsets.only(top: 6, bottom: 106),"),
        ],
    ),
    (
        r"E:\Code\WorkDiary\work_diary_app_android\lib\screens\home_screen.dart",
        "Android",
        [
            # 任务列表
            ("          ListView.builder(\n                  padding: const EdgeInsets.fromLTRB(0, 8, 0, 88),",
             "          ListView.builder(\n                  padding: const EdgeInsets.fromLTRB(0, 8, 0, 108),"),
            # 备忘列表
            ("              : ListView.builder(\n                  padding: const EdgeInsets.fromLTRB(0, 6, 0, 88),",
             "              : ListView.builder(\n                  padding: const EdgeInsets.fromLTRB(0, 6, 0, 108),"),
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
            res.append("OK")
        else:
            res.append("FAIL: " + old[:60])
    with io.open(path, "w", encoding="utf-8", newline="\n") as f:
        f.write(c)
    print(f"{name}: " + " | ".join(res))
