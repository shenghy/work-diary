# -*- coding: utf-8 -*-
"""修复：把误插到 _FlyingBallState 的 GestureDetector 移到 _MemoCard build 结尾"""
import io

p = r"E:\Code\WorkDiary\work_diary_app\lib\screens\home_screen.dart"
with io.open(p, "r", encoding="utf-8") as f:
    c = f.read()

# 1) 删除 _FlyingBallState.build 里误插的 GestureDetector 块（第一次出现）
bad = """      },
    );
    // 桌面端悬停微交互；双击卡片进入编辑
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
good = """      },
    );
  }
}"""
idx = c.find(bad)
if idx >= 0:
    c = c[:idx] + good + c[idx + len(bad):]
    print("step1: _FlyingBall 误插块已删除")
else:
    print("step1 FAIL: bad block not found")

# 2) 把 GestureDetector 补到文件末尾（_MemoCard build 结尾，最后一次出现）
old_tail = """      },
    );
  }
}"""
new_tail = """      },
    );
    // 桌面端悬停微交互；双击卡片进入编辑
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
idx2 = c.rfind(old_tail)
if idx2 >= 0:
    c = c[:idx2] + new_tail + c[idx2 + len(old_tail):]
    print("step2: _MemoCard build 已补 GestureDetector")
else:
    print("step2 FAIL: tail not found")

with io.open(p, "w", encoding="utf-8", newline="\n") as f:
    f.write(c)
print("saved")
