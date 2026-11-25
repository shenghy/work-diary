# -*- coding: utf-8 -*-
"""Windows：备忘卡片双击进入编辑"""
import io

path = r"E:\Code\WorkDiary\work_diary_app\lib\screens\home_screen.dart"
with io.open(path, "r", encoding="utf-8") as f:
    c = f.read()

old = """    // 桌面端悬停微交互
    return MouseRegion(
      cursor: SystemMouseCursors.basic,
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: card,
    );
  }
}"""
new = """    // 桌面端悬停微交互；双击卡片进入编辑
    return GestureDetector(
      onDoubleTap: widget.onEdit,
      child: MouseRegion(
        cursor: SystemMouseCursors.basic,
        onEnter: (_) => setState(() => _hovered = true),
        onExit: (_) => setState(() => _hovered = false),
        child: card,
      ),
    );
  }
}"""
if old in c:
    c = c.replace(old, new, 1)
    with io.open(path, "w", encoding="utf-8", newline="\n") as f:
        f.write(c)
    print("OK：双击进入编辑已加")
else:
    print("FAIL：锚点未匹配")
