# -*- coding: utf-8 -*-
"""Windows：切换任务 tab 时任务列表重放入场动画"""
import io

p = r"E:\Code\WorkDiary\work_diary_app\lib\screens\home_screen.dart"
with io.open(p, "r", encoding="utf-8") as f:
    c = f.read()

# 1. 加字段
old1 = """  late final AnimationController _entranceCtrl;
  bool _entrancePlayed = false; // 是否已播放过入场动画（只播首次）"""
new1 = """  late final AnimationController _entranceCtrl;
  bool _entrancePlayed = false; // 是否已播放过入场动画（只播首次）
  bool _animateNextList = false; // 切换任务 tab 后，下次加载列表时重放入场动画"""
if old1 in c:
    c = c.replace(old1, new1, 1); print("1 ok")
else:
    print("1 FAIL")

# 2. tab 切换置标志
old2 = """            } else {
              setState(() {
                _showMemoView = false;
                _filter = status;
              });
              _loadTasks();
            }"""
new2 = """            } else {
              setState(() {
                _showMemoView = false;
                _filter = status;
              });
              _animateNextList = true; // 切换任务 tab 后重放入场动画
              _loadTasks();
            }"""
if old2 in c:
    c = c.replace(old2, new2, 1); print("2 ok")
else:
    print("2 FAIL")

# 3. _loadTasks 播放逻辑
old3 = """    if (mounted) setState(() => _tasks = tasks);
    // 首次加载出任务后播放一次入场动画（之后增删改/同步不再重播）
    if (!_entrancePlayed && tasks.isNotEmpty) {
      _entrancePlayed = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _entranceCtrl.forward(from: 0);
      });
    }"""
new3 = """    if (mounted) setState(() => _tasks = tasks);
    // 播放任务卡片入场动画：打开软件首次加载，或切换任务 tab 后
    final shouldPlay = _animateNextList || (!_entrancePlayed && tasks.isNotEmpty);
    _animateNextList = false;
    if (shouldPlay && tasks.isNotEmpty) {
      _entrancePlayed = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _entranceCtrl.forward(from: 0);
      });
    }"""
if old3 in c:
    c = c.replace(old3, new3, 1); print("3 ok")
else:
    print("3 FAIL")

with io.open(p, "w", encoding="utf-8", newline="\n") as f:
    f.write(c)
print("saved")
