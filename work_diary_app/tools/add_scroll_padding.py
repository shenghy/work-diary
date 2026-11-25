# -*- coding: utf-8 -*-
"""输入框增加光标滚动保护 scrollPadding，最后一行不被弹窗底部按钮遮挡"""
import io

jobs = [
    (
        r"E:\Code\WorkDiary\work_diary_app\lib\screens\home_screen.dart",
        "Windows",
        [
            # 1) 字段声明
            ("  final bool enableAutoConvert;\n  final int? maxLength;\n  final String? counterText;\n",
             "  final bool enableAutoConvert;\n  final int? maxLength;\n  final String? counterText;\n  final EdgeInsets scrollPadding;\n"),
            # 2) 构造参数
            ("    this.maxLength,\n    this.counterText,\n  });",
             "    this.maxLength,\n    this.counterText,\n    this.scrollPadding = const EdgeInsets.only(bottom: 140),\n  });"),
            # 3) TextField 使用
            ("      child: TextField(\n        controller: widget.controller,\n        focusNode: _focusNode,\n        autofocus: widget.autofocus,",
             "      child: TextField(\n        controller: widget.controller,\n        focusNode: _focusNode,\n        scrollPadding: widget.scrollPadding,\n        autofocus: widget.autofocus,"),
        ],
    ),
    (
        r"E:\Code\WorkDiary\work_diary_app_android\lib\screens\home_screen.dart",
        "Android",
        [
            # 1) 字段声明（Android 无 enableAutoConvert）
            ("  final int? maxLength;\n  final String? counterText;\n\n  const _ImeSafeTextField({",
             "  final int? maxLength;\n  final String? counterText;\n  final EdgeInsets scrollPadding;\n\n  const _ImeSafeTextField({"),
            # 2) 构造参数
            ("    this.maxLength,\n    this.counterText,\n  });",
             "    this.maxLength,\n    this.counterText,\n    this.scrollPadding = const EdgeInsets.only(bottom: 140),\n  });"),
            # 3) TextField 使用
            ("      child: TextField(\n        controller: widget.controller,\n        focusNode: _focusNode,\n        autofocus: widget.autofocus,",
             "      child: TextField(\n        controller: widget.controller,\n        focusNode: _focusNode,\n        scrollPadding: widget.scrollPadding,\n        autofocus: widget.autofocus,"),
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
            res.append("FAIL: " + old[:50])
    with io.open(path, "w", encoding="utf-8", newline="\n") as f:
        f.write(c)
    print(f"{name}: " + " | ".join(res))
