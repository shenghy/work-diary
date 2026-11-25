# -*- coding: utf-8 -*-
"""Windows 任务卡片入场动画：首次显示时逐张上浮淡入"""
import io

p = r"E:\Code\WorkDiary\work_diary_app\lib\screens\home_screen.dart"
with io.open(p, "r", encoding="utf-8") as f:
    c = f.read()

# 1. State 加字段
old1 = """  bool _upgradeDownloading = false; // 是否正在下载升级包
  bool _applyingUpgrade = false;"""
new1 = """  bool _upgradeDownloading = false; // 是否正在下载升级包
  bool _applyingUpgrade = false;
  // ===== 任务卡片入场动画（打开软件首次显示时逐张上浮淡入）=====
  late final AnimationController _entranceCtrl;
  bool _entrancePlayed = false; // 是否已播放过入场动画（只播首次）"""
if old1 in c:
    c = c.replace(old1, new1, 1); print("1 ok")
else:
    print("1 FAIL")

# 2. initState 初始化 controller
old2 = """  void initState() {
    super.initState();
    _initialTaskLoad = _loadTasks();"""
new2 = """  void initState() {
    super.initState();
    _entranceCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1000),
    );
    _initialTaskLoad = _loadTasks();"""
if old2 in c:
    c = c.replace(old2, new2, 1); print("2 ok")
else:
    print("2 FAIL")

# 3. dispose
old3 = """    _traySub?.cancel();
    _hideDragOverlay();
    super.dispose();"""
new3 = """    _traySub?.cancel();
    _entranceCtrl.dispose();
    _hideDragOverlay();
    super.dispose();"""
if old3 in c:
    c = c.replace(old3, new3, 1); print("3 ok")
else:
    print("3 FAIL")

# 4. _loadTasks 首次播放
old4 = """    if (mounted) setState(() => _tasks = tasks);
  }

  /// 计算指定状态组的下一个 sortOrder"""
new4 = """    if (mounted) setState(() => _tasks = tasks);
    // 首次加载出任务后播放一次入场动画（之后增删改/同步不再重播）
    if (!_entrancePlayed && tasks.isNotEmpty) {
      _entrancePlayed = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _entranceCtrl.forward(from: 0);
      });
    }
  }

  /// 计算指定状态组的下一个 sortOrder"""
if old4 in c:
    c = c.replace(old4, new4, 1); print("4 ok")
else:
    print("4 FAIL")

# 5. itemBuilder 外层包入场动画
old5 = """                        return Column(
                          mainAxisSize: MainAxisSize.min,
                          children: ["""
new5 = """                        return _EntranceItem(
                          controller: _entranceCtrl,
                          index: i,
                          total: _tasks.length,
                          child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: ["""
if old5 in c:
    c = c.replace(old5, new5, 1); print("5 ok")
else:
    print("5 FAIL")

old6 = """                            // 拖拽中的卡片半透明 + 鼠标抓手
                            Listener("""
new6 = """                            // 拖拽中的卡片半透明 + 鼠标抓手
                            Listener("""
# 缩进包住 Column 的闭合：找到 ListView itemBuilder 里 Column 的闭合 "],\n                        );\n                      },\n                    ),"
old7 = """                          ],
                        );
                      },
                    ),
              // 左下角菜单按钮"""
new7 = """                          ],
                          ),
                        );
                      },
                    ),
              // 左下角菜单按钮"""
if old7 in c:
    c = c.replace(old7, new7, 1); print("7 ok")
else:
    print("7 FAIL")

# 6. 文件末尾加 _EntranceItem 类
if "_EntranceItem extends StatelessWidget" not in c:
    c += """

/// 任务卡片入场动画：按索引依次从下往上滑入 + 淡入（共享一个 AnimationController）
class _EntranceItem extends StatelessWidget {
  final AnimationController controller;
  final int index;
  final int total;
  final Widget child;

  const _EntranceItem({
    required this.controller,
    required this.index,
    required this.total,
    required this.child,
  });

  @override
  Widget build(BuildContext context) {
    if (total <= 1) return child;
    // 排队起点：前 55% 的时间用于依次入场，单张动画占 45%
    final start = (index / math.max(total, 1)) * 0.55;
    final end = math.min(start + 0.45, 1.0);
    return AnimatedBuilder(
      animation: controller,
      builder: (context, _) {
        final raw = controller.value <= start
            ? 0.0
            : ((controller.value - start) / (end - start)).clamp(0.0, 1.0);
        final v = Curves.easeOutCubic.transform(raw);
        return Opacity(
          opacity: v,
          child: Transform.translate(
            offset: Offset(0, 20 * (1 - v)),
            child: child,
          ),
        );
      },
    );
  }
}
"""
    print("6 ok")
else:
    print("6 exists")

with io.open(p, "w", encoding="utf-8", newline="\n") as f:
    f.write(c)
print("saved")
