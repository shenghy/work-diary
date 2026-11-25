# -*- coding: utf-8 -*-
"""Windows：入场动画加固（防竞态）+ 备忘 tab 接入动画 + 日志"""
import io

p = r"E:\Code\WorkDiary\work_diary_app\lib\screens\home_screen.dart"
with io.open(p, "r", encoding="utf-8") as f:
    c = f.read()

# A. 字段
old_a = """  bool _animateNextList = false; // 切换任务 tab 后，下次加载列表时重放入场动画"""
new_a = """  bool _animateNextList = false; // 切换任务 tab 后，下次加载列表时重放入场动画
  bool _animateNextMemo = false; // 切换备忘 tab 后，加载完成时重放入场动画
  int _loadSeq = 0; // 加载序号：只允许最后一次加载触发动画（防连续切换竞态）"""
if old_a in c:
    c = c.replace(old_a, new_a, 1); print("A ok")
else:
    print("A FAIL")

# B1. _loadTasks 开头加序号
old_b1 = """  Future<void> _loadTasks() async {
    // 首次启动：自动创建引导任务（如果从未创建过）
    await _maybeCreateWelcomeTask();

    final all = await _repo.getTasks();"""
new_b1 = """  Future<void> _loadTasks() async {
    final seq = ++_loadSeq; // 本次加载序号，用于丢弃过期的并发加载
    // 首次启动：自动创建引导任务（如果从未创建过）
    await _maybeCreateWelcomeTask();

    final all = await _repo.getTasks();"""
if old_b1 in c:
    c = c.replace(old_b1, new_b1, 1); print("B1 ok")
else:
    print("B1 FAIL")

# B2. _loadTasks 结尾：过期检查 + 播放逻辑 + 日志
old_b2 = """    final tasks = _filter == null
        ? all
        : all.where((t) => t.status == _filter).toList();
    if (mounted) setState(() => _tasks = tasks);
    // 播放任务卡片入场动画：打开软件首次加载，或切换任务 tab 后
    final shouldPlay = _animateNextList || (!_entrancePlayed && tasks.isNotEmpty);
    _animateNextList = false;
    if (shouldPlay && tasks.isNotEmpty) {
      _entrancePlayed = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _entranceCtrl.forward(from: 0);
      });
    }
  }"""
new_b2 = """    final tasks = _filter == null
        ? all
        : all.where((t) => t.status == _filter).toList();
    if (seq != _loadSeq) return; // 已被更新的加载取代，丢弃本次结果
    if (mounted) setState(() => _tasks = tasks);
    // 播放任务卡片入场动画：打开软件首次加载，或切换任务 tab 后
    final shouldPlay = _animateNextList || (!_entrancePlayed && tasks.isNotEmpty);
    _animateNextList = false;
    if (shouldPlay && tasks.isNotEmpty) {
      _entrancePlayed = true;
      AppLogger.instance.log('任务列表入场动画：tab切换/首次 ${tasks.length}条');
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _entranceCtrl.forward(from: 0);
      });
    }
  }"""
if old_b2 in c:
    c = c.replace(old_b2, new_b2, 1); print("B2 ok")
else:
    print("B2 FAIL")

# C. 备忘 tab 切换
old_c = """            if (isMemoTab) {
              setState(() {
                _showMemoView = true;
                _filter = null;
              });
            } else {"""
new_c = """            if (isMemoTab) {
              setState(() {
                _showMemoView = true;
                _filter = null;
              });
              _animateNextList = false;
              _animateNextMemo = true; // 备忘 tab：加载完成后重放入场动画
              _loadMemos();
            } else {"""
if old_c in c:
    c = c.replace(old_c, new_c, 1); print("C ok")
else:
    print("C FAIL")

# D. _loadMemos 播放逻辑
old_d = """  Future<void> _loadMemos() async {
    final memos = await _memoRepo.getMemos();
    if (mounted) setState(() => _memos = memos);
  }"""
new_d = """  Future<void> _loadMemos() async {
    final memos = await _memoRepo.getMemos();
    if (mounted) setState(() => _memos = memos);
    // 切换备忘 tab 后播放入场动画（只播一次；搜索/增删改不重播）
    final playMemo = _animateNextMemo;
    _animateNextMemo = false;
    if (playMemo && memos.isNotEmpty) {
      _entrancePlayed = true;
      AppLogger.instance.log('备忘列表入场动画：tab切换 ${memos.length}条');
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _entranceCtrl.forward(from: 0);
      });
    }
  }"""
if old_d in c:
    c = c.replace(old_d, new_d, 1); print("D ok")
else:
    print("D FAIL")

# E. 备忘卡片包入场动画
old_e = """                  children: [
                    for (var i = 0; i < memos.length; i++)
                      _buildMemoCard(memos[i], i),
                  ],"""
new_e = """                  children: [
                    for (var i = 0; i < memos.length; i++)
                      _EntranceItem(
                        controller: _entranceCtrl,
                        index: i,
                        total: memos.length,
                        child: _buildMemoCard(memos[i], i),
                      ),
                  ],"""
if old_e in c:
    c = c.replace(old_e, new_e, 1); print("E ok")
else:
    print("E FAIL")

with io.open(p, "w", encoding="utf-8", newline="\n") as f:
    f.write(c)
print("saved")
