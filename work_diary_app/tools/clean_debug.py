# -*- coding: utf-8 -*-
"""清理 Windows 端临时调试代码：_debugMemoLog + dart:io import + 日志调用"""
import io

path = r"E:\Code\WorkDiary\work_diary_app\lib\screens\home_screen.dart"
with io.open(path, "r", encoding="utf-8") as f:
    c = f.read()

ok = []

# 1. 删除 dart:io import（仅当它只被 _debugMemoLog 使用）
c2 = c.replace("import 'dart:io';\n", "", 1)
if c2 != c:
    c = c2
    ok.append("dart:io")

# 2. 删除 _debugMemoLog 方法定义
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
    ok.append("方法定义")
else:
    ok.append("方法定义FAIL")

# 3. 删除视图入口调用
old_v = """    _debugMemoLog('buildMemoView | _memos=${_memos.length} | keyword="$keyword"');
"""
if old_v in c:
    c = c.replace(old_v, "", 1)
    ok.append("视图调用")
else:
    ok.append("视图调用FAIL")

# 4. 删除卡片循环里的日志调用（恢复简洁 for 循环）
old_l = """                    for (var i = 0; i < memos.length; i++) ...[                      _debugMemoLog('card i=$i id=${memos[i].id} len=${memos[i].content.length}'),
                      _buildMemoCard(memos[i], i),
                    ],
"""
new_l = """                    for (var i = 0; i < memos.length; i++)
                      _buildMemoCard(memos[i], i),
"""
if old_l in c:
    c = c.replace(old_l, new_l, 1)
    ok.append("卡片循环")
else:
    ok.append("卡片循环FAIL")

with io.open(path, "w", encoding="utf-8", newline="\n") as f:
    f.write(c)
print("Windows清理:", ", ".join(ok))

# 验证没有残留
for kw in ["_debugMemoLog", "memo_debug.log"]:
    print(kw, "残留:", c.count(kw))
