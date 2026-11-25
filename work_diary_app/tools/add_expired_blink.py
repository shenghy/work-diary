# -*- coding: utf-8 -*-
"""task_card.dart 过期闪烁"""
import io

p = r"E:\Code\WorkDiary\work_diary_app\lib\widgets\task_card.dart"
with io.open(p, "r", encoding="utf-8") as f:
    c = f.read()

# 1. controller 字段
old = """  /// 子任务进度动画：勾选/取消都从当前值平滑过渡到新值
  late final AnimationController _progressController;
"""
new = """  /// 子任务进度动画：勾选/取消都从当前值平滑过渡到新值
  late final AnimationController _progressController;

  /// 过期任务闪烁动画
  late final AnimationController _expiredCtrl;

  /// 是否过期：未完成且已过预计完成时间
  bool get _isExpired =>
      widget.task.status != TaskStatus.completed &&
      widget.task.dueAt != null &&
      widget.task.dueAt!.isBefore(DateTime.now());
"""
assert c.count(old) == 1
c = c.replace(old, new, 1)
print("field ok")

# 2. initState 创建
old = """    _progressController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 450),
      value: _calcProgress(widget.task),
    );
  }
"""
new = """    _progressController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 450),
      value: _calcProgress(widget.task),
    );
    _expiredCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 650),
    );
    if (_isExpired) _expiredCtrl.repeat(reverse: true);
  }
"""
assert c.count(old) == 1
c = c.replace(old, new, 1)
print("init ok")

# 3. dispose
old = """    _shatterController.dispose();
    _progressController.dispose();
    super.dispose();"""
new = """    _shatterController.dispose();
    _progressController.dispose();
    _expiredCtrl.dispose();
    super.dispose();"""
assert c.count(old) == 1
c = c.replace(old, new, 1)
print("dispose ok")

# 4. didUpdateWidget 启停
old = """    // 子任务进度变化：从当前值平滑动画到新值（勾选/取消双向）
    if (widget.task.title != oldWidget.task.title) {
      final newP = _calcProgress(widget.task);
      if (newP != _progressController.value) {
        _progressController.animateTo(newP, curve: Curves.easeInOut);
      }
    }
  }
"""
new = """    // 子任务进度变化：从当前值平滑动画到新值（勾选/取消双向）
    if (widget.task.title != oldWidget.task.title) {
      final newP = _calcProgress(widget.task);
      if (newP != _progressController.value) {
        _progressController.animateTo(newP, curve: Curves.easeInOut);
      }
    }
    // 过期闪烁启停（状态变化 / 时间跨过截止点）
    if (_isExpired) {
      if (!_expiredCtrl.isAnimating) _expiredCtrl.repeat(reverse: true);
    } else {
      if (_expiredCtrl.isAnimating) {
        _expiredCtrl.stop();
        _expiredCtrl.value = 1.0; // 归位为不透明，避免残留半透明
      }
    }
  }
"""
assert c.count(old) == 1
c = c.replace(old, new, 1)
print("didUpdate ok")

# 5. 时间行插入"已过期"标签（dueAt tag 前）
old = """                                  if (widget.task.dueAt != null)
                                    _TimeTag(
                                      text: _dateLabel(
                                          widget.task.dueAt!, '完成'),
                                      color: const Color(0xFFFCA5A5),
                                      bg: const Color(0x1FFCA5A5),
                                    ),"""
new = """                                  if (_isExpired) ...[
                                    const SizedBox(width: 6),
                                    FadeTransition(
                                      opacity: _expiredCtrl
                                          .drive(Tween(begin: 0.35, end: 1.0)),
                                      child: _TimeTag(
                                        text: '已过期',
                                        color: const Color(0xFFDC2626),
                                        bg: const Color(0x33DC2626),
                                      ),
                                    ),
                                  ],
                                  if (widget.task.dueAt != null)
                                    _TimeTag(
                                      text: _dateLabel(
                                          widget.task.dueAt!, '完成'),
                                      color: const Color(0xFFFCA5A5),
                                      bg: const Color(0x1FFCA5A5),
                                    ),"""
assert c.count(old) == 1
c = c.replace(old, new, 1)
print("tag ok")

with io.open(p, "w", encoding="utf-8", newline="\n") as f:
    f.write(c)
print("task_card saved")
