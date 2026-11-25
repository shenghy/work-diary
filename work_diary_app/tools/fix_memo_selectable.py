# -*- coding: utf-8 -*-
"""替换 SelectableText.rich -> SelectionArea+Text（容错处理换行符）"""
import io

path = r"E:\Code\WorkDiary\work_diary_app\lib\screens\home_screen.dart"
with io.open(path, "r", encoding="utf-8") as f:
    c = f.read()

# 检测换行风格
crlf = "\r\n" in c
print("CRLF:", crlf)

nl = "\r\n" if crlf else "\n"

old = (
    "// 内容：可选中复制 + 搜索关键词高亮" + nl +
    "SelectableText.rich(" + nl +
    "TextSpan(" + nl +
    "style: const TextStyle(" + nl +
    "fontSize: 13," + nl +
    "height: 1.5," + nl +
    "color: Color(0xFF334155)," + nl +
    ")," + nl +
    "children: _highlight(widget.memo.content, widget.keyword)," + nl +
    ")," + nl +
    "),"
)

new = (
    "// 内容：可选中复制 + 搜索关键词高亮" + nl +
    "// 用 SelectionArea+Text 替代 SelectableText.rich：" + nl +
    "// Flutter Windows 桌面端多个 SelectableText 同屏时第二个不渲染（已知 bug）" + nl +
    "SelectionArea(" + nl +
    "child: Text.rich(" + nl +
    "TextSpan(" + nl +
    "style: const TextStyle(" + nl +
    "fontSize: 13," + nl +
    "height: 1.5," + nl +
    "color: Color(0xFF334155)," + nl +
    ")," + nl +
    "children: _highlight(widget.memo.content, widget.keyword)," + nl +
    ")," + nl +
    ")," + nl +
    "),"
)

if old in c:
    c = c.replace(old, new, 1)
    with io.open(path, "w", encoding="utf-8", newline="" if crlf else "\n") as f:
        f.write(c)
    print("OK：已替换")
else:
    print("FAIL：仍未匹配，输出周围文本排查")
    idx = c.find("SelectableText.rich")
    if idx >= 0:
        print(repr(c[idx-120:idx+160]))
