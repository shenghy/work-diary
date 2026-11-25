# -*- coding: utf-8 -*-
"""修正：getLocalRectForCaret 单参数 + 残留引用"""
import io

old = """    final caretRect = renderEditable.getLocalRectForCaret(
      TextPosition(offset: widget.controller.selection.baseOffset),
      Rect.zero,
    );
    final caretBottom = caretRect.bottom;"""
new = """    final caretRect = renderEditable.getLocalRectForCaret(
      TextPosition(offset: widget.controller.selection.baseOffset),
    );
    final caretBottom = caretRect.bottom;"""

old2 = "} else if (caretOffset.dy < pos.pixels) {\n      _scrollController.animateTo(\n        caretOffset.dy,"
new2 = "} else if (caretRect.top < pos.pixels) {\n      _scrollController.animateTo(\n        caretRect.top,"

for path, name in [
    (r"E:\Code\WorkDiary\work_diary_app\lib\screens\home_screen.dart", "Windows"),
    (r"E:\Code\WorkDiary\work_diary_app_android\lib\screens\home_screen.dart", "Android"),
]:
    with io.open(path, "r", encoding="utf-8") as f:
        c = f.read()
    ok = []
    if old in c:
        c = c.replace(old, new, 1); ok.append("rect")
    else:
        ok.append("rect-FAIL")
    if old2 in c:
        c = c.replace(old2, new2, 1); ok.append("ref")
    else:
        ok.append("ref-FAIL")
    with io.open(path, "w", encoding="utf-8", newline="\n") as f:
        f.write(c)
    print(f"{name}: {' | '.join(ok)}")
