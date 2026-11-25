# -*- coding: utf-8 -*-
"""去掉备忘卡片悬停扫光效果（保留纸面/色条/阴影/上浮）"""
import io

p = r"E:\Code\WorkDiary\work_diary_app\lib\screens\home_screen.dart"
with io.open(p, "r", encoding="utf-8") as f:
    c = f.read()

# 1) 去掉 LayoutBuilder 包装（扫光不需要宽度计算了）
old1 = """    final card = LayoutBuilder(
      builder: (context, cons) {
        final w = cons.maxWidth;
        return AnimatedContainer("""
new1 = """    final card = AnimatedContainer("""
if old1 in c:
    c = c.replace(old1, new1, 1)
    print("step1: LayoutBuilder 已去掉")
else:
    print("step1 FAIL")

# 2) 删除扫光 AnimatedPositioned 块
old2 = """                // 悬停扫光：从左到右划过
                AnimatedPositioned(
                  duration: const Duration(milliseconds: 650),
                  curve: Curves.easeOut,
                  top: 0,
                  bottom: 0,
                  left: _hovered ? w : -w * 0.55,
                  width: w * 0.5,
                  child: IgnorePointer(
                    child: Transform.rotate(
                      angle: -0.15,
                      child: Container(
                        decoration: BoxDecoration(
                          gradient: LinearGradient(
                            colors: [
                              Colors.transparent,
                              Colors.white.withValues(alpha: 0.7),
                              Colors.transparent,
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
"""
if old2 in c:
    c = c.replace(old2, "", 1)
    print("step2: 扫光块已删除")
else:
    print("step2 FAIL")

# 3) 去掉 LayoutBuilder 尾部闭合（builder 收尾）
old3 = """        );
      },
    );
    // 桌面端悬停微交互；双击卡片进入编辑"""
new3 = """    );
    // 桌面端悬停微交互；双击卡片进入编辑"""
if old3 in c:
    c = c.replace(old3, new3, 1)
    print("step3: LayoutBuilder 闭合已简化")
else:
    print("step3 FAIL")

with io.open(p, "w", encoding="utf-8", newline="\n") as f:
    f.write(c)
print("saved")
