# -*- coding: utf-8 -*-
"""Windows 端备忘 Markdown 支持：编辑/预览 + 卡片渲染"""
import io

path = r"E:\Code\WorkDiary\work_diary_app\lib\screens\home_screen.dart"
with io.open(path, "r", encoding="utf-8") as f:
    c = f.read()

ok = []

# 1. import flutter_markdown
if "flutter_markdown" not in c:
    c = c.replace("import 'dart:io';", "import 'dart:io';\nimport 'package:flutter_markdown/flutter_markdown.dart';", 1)
    ok.append("import")

# 2. _ImeSafeTextField 加 enableAutoConvert 参数
old = (
    "class _ImeSafeTextField extends StatefulWidget {\n"
    "  final TextEditingController controller;\n"
    "  final String hintText;\n"
    "  final int maxLines;\n"
    "  final bool autofocus;\n"
    "\n"
    "  const _ImeSafeTextField({\n"
    "    required this.controller,\n"
    "    required this.hintText,\n"
    "    this.maxLines = 6,\n"
    "    this.autofocus = false,\n"
    "  });"
)
new = (
    "class _ImeSafeTextField extends StatefulWidget {\n"
    "  final TextEditingController controller;\n"
    "  final String hintText;\n"
    "  final int maxLines;\n"
    "  final bool autofocus;\n"
    "  final bool enableAutoConvert;\n"
    "\n"
    "  const _ImeSafeTextField({\n"
    "    required this.controller,\n"
    "    required this.hintText,\n"
    "    this.maxLines = 6,\n"
    "    this.autofocus = false,\n"
    "    this.enableAutoConvert = true,\n"
    "  });"
)
if old in c:
    c = c.replace(old, new, 1)
    ok.append("ImeSafe参数")
else:
    ok.append("ImeSafe参数FAIL")

old2 = (
    "    // 自动转义：输入 1. 2. 开头的行 -> [ ] 子任务\n"
    "    widget.controller.addListener(_autoConvertNumbered);"
)
new2 = (
    "    // 自动转义：输入 1. 2. 开头的行 -> [ ] 子任务\n"
    "    // 备忘编辑时关闭（避免与 Markdown 有序列表 1. 冲突）\n"
    "    if (widget.enableAutoConvert) {\n"
    "      widget.controller.addListener(_autoConvertNumbered);\n"
    "    }"
)
if old2 in c:
    c = c.replace(old2, new2, 1)
    ok.append("ImeSafe监听")
else:
    ok.append("ImeSafe监听FAIL")

with io.open(path, "w", encoding="utf-8", newline="\n") as f:
    f.write(c)
print("Windows:", ", ".join(ok))
