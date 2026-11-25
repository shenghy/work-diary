# -*- coding: utf-8 -*-
"""删除 home_screen.dart 里重复的 _debugMemoLog 方法（保留第一个）"""
import io
import re

path = r"E:\Code\WorkDiary\work_diary_app\lib\screens\home_screen.dart"
with io.open(path, "r", encoding="utf-8") as f:
    c = f.read()

method = (
    "  /// 临时调试：备忘渲染日志（定位「只显示一条」问题）\n"
    "  Widget _debugMemoLog(String msg) {\n"
    "    try {\n"
    "      final f = File(r'C:\\Users\\Administrator\\Documents\\memo_debug.log');\n"
    "      f.writeAsStringSync(\n"
    "          '${DateTime.now().toIso8601String()} | $msg\\n',\n"
    "          mode: FileMode.append);\n"
    "    } catch (_) {}\n"
    "    return const SizedBox.shrink();\n"
    "  }\n"
)

# 找到所有出现位置
positions = [m.start() for m in re.finditer(re.escape(method), c)]
print("方法出现次数:", len(positions))
if len(positions) >= 2:
    # 删除第二个（从第二个 start 到其后 method 长度）
    start = positions[1]
    c = c[:start] + c[start + len(method):]
    with io.open(path, "w", encoding="utf-8", newline="\n") as f:
        f.write(c)
    print("已删除第二份")
else:
    print("无需处理")

# 验证
print("剩余次数:", len(re.findall(re.escape(method), c)))
