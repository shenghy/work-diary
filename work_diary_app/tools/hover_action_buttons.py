# -*- coding: utf-8 -*-
"""任务卡片：操作按钮组 hover 淡入淡出（占位保留，无布局跳动）"""
import io

p = r"E:\Code\WorkDiary\work_diary_app\lib\widgets\task_card.dart"
with io.open(p, "r", encoding="utf-8") as f:
    c = f.read()

# 1) 在 Spacer 后包一层 AnimatedOpacity > AnimatedContainer > Row(min)
anchor1 = """                                  const Spacer(),
                                  _ActionButton(
                                    icon: isDone"""
new1 = """                                  const Spacer(),
                                  AnimatedOpacity(
                                    opacity: _isHovered ? 1.0 : 0.0,
                                    duration: const Duration(milliseconds: 250),
                                    curve: Curves.easeOut,
                                    child: AnimatedContainer(
                                      duration:
                                          const Duration(milliseconds: 250),
                                      curve: Curves.easeOut,
                                      transform: Matrix4.translationValues(
                                          0, _isHovered ? 0 : 2, 0),
                                      child: Row(
                                        mainAxisSize: MainAxisSize.min,
                                        children: [
                                  _ActionButton(
                                    icon: isDone"""
if anchor1 in c:
    c = c.replace(anchor1, new1, 1)
    print("step1: 按钮组已包 AnimatedOpacity")
else:
    print("step1 FAIL")

# 2) 删除按钮后闭合内层 Row / AnimatedContainer / AnimatedOpacity
anchor2 = """                                  _ActionButton(
                                    icon: Icons.delete_outline,
                                    label: '删除',
                                    onPressed:
                                        _shattering ? () {} : _handleDelete,
                                  ),
                                ],"""
new2 = """                                          _ActionButton(
                                            icon: Icons.delete_outline,
                                            label: '删除',
                                            onPressed: _shattering
                                                ? () {}
                                                : _handleDelete,
                                          ),
                                        ],
                                      ),
                                    ),
                                  ),
                                ],"""
if anchor2 in c:
    c = c.replace(anchor2, new2, 1)
    print("step2: 闭合已补齐")
else:
    print("step2 FAIL")

with io.open(p, "w", encoding="utf-8", newline="\n") as f:
    f.write(c)
print("saved")
