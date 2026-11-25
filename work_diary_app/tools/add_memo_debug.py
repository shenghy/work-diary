# -*- coding: utf-8 -*-
"""给 Windows home_screen.dart 加备忘渲染调试日志"""
import io

path = r"E:\Code\WorkDiary\work_diary_app\lib\screens\home_screen.dart"
with io.open(path, "r", encoding="utf-8") as f:
    c = f.read()

ok = []

# 1. dart:io import
if "import 'dart:io';" not in c:
    c = c.replace("import 'dart:async';", "import 'dart:async';\nimport 'dart:io';", 1)
    ok.append("dart:io")

# 2. _buildMemoView 视图日志
old2 = "  Widget _buildMemoView() {\n    final keyword = _memoSearchCtrl.text.trim();"
new2 = ("  Widget _buildMemoView() {\n"
        "    final keyword = _memoSearchCtrl.text.trim();\n"
        "    _debugMemoLog('buildMemoView | _memos=${_memos.length} | keyword=\"$keyword\"');")
if old2 in c:
    c = c.replace(old2, new2, 1)
    ok.append("视图日志")
else:
    ok.append("视图未匹配")

# 3. 列表 children 记录每张卡
old3 = ("              : ListView(\n"
        "                  padding: const EdgeInsets.symmetric(vertical: 6),\n"
        "                  // 备忘数量少，全量渲染；每条带独立 key 防止复用错乱\n"
        "                  children: [\n"
        "                    for (var i = 0; i < memos.length; i++)\n"
        "                      _buildMemoCard(memos[i], i),\n"
        "                  ],\n"
        "                ),")
new3 = ("              : ListView(\n"
        "                  padding: const EdgeInsets.symmetric(vertical: 6),\n"
        "                  // 备忘数量少，全量渲染；每条带独立 key 防止复用错乱\n"
        "                  children: [\n"
        "                    for (var i = 0; i < memos.length; i++) ...["
        "                      _debugMemoLog('card i=$i id=${memos[i].id} len=${memos[i].content.length}'),\n"
        "                      _buildMemoCard(memos[i], i),\n"
        "                    ],\n"
        "                  ],\n"
        "                ),")
if old3 in c:
    c = c.replace(old3, new3, 1)
    ok.append("卡片日志")
else:
    ok.append("卡片未匹配")

# 4. 日志方法 + 包裹 buildMemoView（放在 _buildMemoView 定义前）
old4 = "  Widget _buildMemoView() {"
new4 = ("  /// 临时调试：备忘渲染日志（定位「只显示一条」问题）\n"
        "  Widget _debugMemoLog(String msg) {\n"
        "    try {\n"
        "      final f = File(r'C:\\Users\\Administrator\\Documents\\memo_debug.log');\n"
        "      f.writeAsStringSync(\n"
        "          '${DateTime.now().toIso8601String()} | $msg\\n',\n"
        "          mode: FileMode.append);\n"
        "    } catch (_) {}\n"
        "    return const SizedBox.shrink();\n"
        "  }\n\n"
        "  Widget _buildMemoView() {")
if old4 in c:
    c = c.replace(old4, new4, 1)
    ok.append("日志方法")
else:
    ok.append("日志未匹配")

with io.open(path, "w", encoding="utf-8", newline="\n") as f:
    f.write(c)

print("Windows:", ", ".join(ok))
