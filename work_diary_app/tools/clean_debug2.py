# -*- coding: utf-8 -*-
"""修复：恢复 dart:io import + 继续清理 _debugMemoLog 残留调用"""
import io

path = r"E:\Code\WorkDiary\work_diary_app\lib\screens\home_screen.dart"
with io.open(path, "r", encoding="utf-8") as f:
    c = f.read()

ok = []

# 1. 恢复 dart:io（截图日志在用）
if "import 'dart:io';" not in c:
    c = c.replace("import 'dart:async';", "import 'dart:async';\nimport 'dart:io';", 1)
    ok.append("恢复dart:io")

# 2. 查看 _debugMemoLog 现状
print("_debugMemoLog 出现次数:", c.count("_debugMemoLog"))
print("memo_debug.log 出现次数:", c.count("memo_debug.log"))

# 3. 找方法定义是否还在
if "Widget _debugMemoLog(String msg)" in c:
    old_m = """  /// 临时调试：备忘渲染日志（定位「只显示一条」问题）
  Widget _debugMemoLog(String msg) {
    try {
      final f = File(r'C:\\Users\\Administrator\\Documents\\memo_debug.log');
      f.writeAsStringSync(
          '${DateTime.now().toIso8601String()} | $msg\\n',
          mode: FileMode.append);
    } catch (_) {}
    return const SizedBox.shrink();
  }

"""
    if old_m in c:
        c = c.replace(old_m, "", 1)
        ok.append("方法定义已删")
    else:
        ok.append("方法定义格式不同")

# 4. 删除调用行（视图入口 + 卡片循环）
for pattern in [
    "    _debugMemoLog('buildMemoView | _memos=${_memos.length} | keyword=\"$keyword\"');\n",
]:
    if pattern in c:
        c = c.replace(pattern, "", 1)
        ok.append("视图调用已删")

# 卡片循环里的调用（可能是压缩格式）
import re
c2 = re.sub(r"for \(var i = 0; i < memos\.length; i\+\+\) \.\.\.\[[^\]]*_debugMemoLog[^\]]*\],\n", "for (var i = 0; i < memos.length; i++)\n                      _buildMemoCard(memos[i], i),\n", c, count=1)
if c2 != c:
    c = c2
    ok.append("卡片循环已删")

with io.open(path, "w", encoding="utf-8", newline="\n") as f:
    f.write(c)
print("修复:", ", ".join(ok))
print("清理后 _debugMemoLog 残留:", c.count("_debugMemoLog"))
