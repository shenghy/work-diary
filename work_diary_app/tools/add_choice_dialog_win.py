# -*- coding: utf-8 -*-
"""Windows：新建选择弹窗改造为方案C（胶囊引导）"""
import io

path = r"E:\Code\WorkDiary\work_diary_app\lib\screens\home_screen.dart"
with io.open(path, "r", encoding="utf-8") as f:
    c = f.read()

ok = []

# ===== 1. 替换 _showAddChoice 弹窗 =====
old = """  /// 右下角加号：先让用户选择「任务 / 备忘」
  Future<void> _showAddChoice() async {
    final choice = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('新建', style: TextStyle(fontSize: 16)),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.task_alt, color: Color(0xFF3B82F6)),
              title: const Text('新建任务', style: TextStyle(fontSize: 14)),
              subtitle: const Text('带状态、紧急度、计划时间', style: TextStyle(fontSize: 12, color: Colors.grey)),
              onTap: () => Navigator.of(context).pop('task'),
            ),
            const Divider(height: 1),
            ListTile(
              leading: const Icon(Icons.note_alt_outlined, color: Colors.orange),
              title: const Text('新建备忘', style: TextStyle(fontSize: 14)),
              subtitle: const Text('纯记录，支持搜索', style: TextStyle(fontSize: 12, color: Colors.grey)),
              onTap: () => Navigator.of(context).pop('memo'),
            ),
          ],
        ),
      ),
    );
    if (!mounted) return;
    if (choice == 'task') {
      _showAddDialog();
    } else if (choice == 'memo') {
      _showMemoEditor();
    }
  }"""
new = """  /// 右下角加号：先让用户选择「任务 / 备忘」（方案C：胶囊引导）
  Future<void> _showAddChoice() async {
    final choice = await showDialog<String>(
      context: context,
      builder: (context) => const _AddChoiceDialog(),
    );
    if (!mounted) return;
    if (choice == 'task') {
      _showAddDialog();
    } else if (choice == 'memo') {
      _showMemoEditor();
    }
  }"""
if old in c:
    c = c.replace(old, new, 1)
    ok.append("_showAddChoice 已替换")
else:
    ok.append("_showAddChoice FAIL")

# ===== 2. 添加 _AddChoiceDialog + _ChoiceRow 类（_MemoCard 前）=====
old2 = """class _MemoCard extends StatefulWidget {"""
new2 = """/// 新建选择弹窗（方案C：胶囊引导）
class _AddChoiceDialog extends StatefulWidget {
  const _AddChoiceDialog();

  @override
  State<_AddChoiceDialog> createState() => _AddChoiceDialogState();
}

class _AddChoiceDialogState extends State<_AddChoiceDialog> {
  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      titlePadding: const EdgeInsets.fromLTRB(22, 20, 22, 0),
      contentPadding: const EdgeInsets.fromLTRB(16, 12, 16, 18),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
      title: Row(
        children: [
          const Text('新建',
              style: TextStyle(fontSize: 17, fontWeight: FontWeight.w700)),
          const SizedBox(width: 8),
          Text('选择一个类型',
              style: TextStyle(fontSize: 12, color: Colors.grey.shade400)),
        ],
      ),
      content: SizedBox(
        width: 380,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            _ChoiceRow(
              deep: const Color(0xFF2563EB),
              light: const Color(0xFF60A5FA),
              icon: Icons.task_alt,
              title: '新建任务',
              subtitle: '带状态、紧急度、计划时间',
              onTap: () => Navigator.of(context).pop('task'),
            ),
            const SizedBox(height: 10),
            _ChoiceRow(
              deep: const Color(0xFFEA580C),
              light: const Color(0xFFFBBF24),
              icon: Icons.note_alt_outlined,
              title: '新建备忘',
              subtitle: '纯记录，支持搜索',
              onTap: () => Navigator.of(context).pop('memo'),
            ),
          ],
        ),
      ),
    );
  }
}

/// 胶囊选择行：悬停时主题渐变从左到右填充、文字反白、图标放大旋转、右下角「进入 →」滑出
class _ChoiceRow extends StatefulWidget {
  final Color deep;
  final Color light;
  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback onTap;

  const _ChoiceRow({
    required this.deep,
    required this.light,
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onTap,
  });

  @override
  State<_ChoiceRow> createState() => _ChoiceRowState();
}

class _ChoiceRowState extends State<_ChoiceRow> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final hovered = _hovered;
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: GestureDetector(
        onTap: widget.onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 250),
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(14),
            border: Border.all(
              color: hovered ? widget.deep : Colors.grey.shade200,
              width: 1.5,
            ),
          ),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(12),
            child: Stack(
              children: [
                // 渐变填充层：从左到右铺开
                Positioned.fill(
                  child: AnimatedFractionallySizedBox(
                    duration: const Duration(milliseconds: 450),
                    curve: Curves.easeOut,
                    alignment: Alignment.centerLeft,
                    widthFactor: hovered ? 1.0 : 0.0,
                    heightFactor: 1.0,
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(12),
                        gradient: LinearGradient(
                          begin: Alignment.centerLeft,
                          end: Alignment.centerRight,
                          colors: [widget.deep, widget.light],
                        ),
                      ),
                    ),
                  ),
                ),
                // 内容层
                Row(
                  children: [
                    AnimatedScale(
                      scale: hovered ? 1.12 : 1.0,
                      duration: const Duration(milliseconds: 300),
                      curve: Curves.easeOutBack,
                      child: AnimatedRotation(
                        turns: hovered ? -0.05 : 0.0,
                        duration: const Duration(milliseconds: 300),
                        child: Container(
                          width: 46,
                          height: 46,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            gradient: LinearGradient(
                              begin: Alignment.topLeft,
                              end: Alignment.bottomRight,
                              colors: [widget.light, widget.deep],
                            ),
                            boxShadow: [
                              BoxShadow(
                                color: widget.deep.withValues(alpha: 0.35),
                                blurRadius: 12,
                                offset: const Offset(0, 4),
                              ),
                            ],
                          ),
                          child: Icon(widget.icon, color: Colors.white, size: 22),
                        ),
                      ),
                    ),
                    const SizedBox(width: 16),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          AnimatedDefaultTextStyle(
                            duration: const Duration(milliseconds: 250),
                            style: TextStyle(
                              fontSize: 15,
                              fontWeight: FontWeight.w700,
                              color:
                                  hovered ? Colors.white : const Color(0xFF1E293B),
                            ),
                            child: Text(widget.title),
                          ),
                          const SizedBox(height: 3),
                          AnimatedDefaultTextStyle(
                            duration: const Duration(milliseconds: 250),
                            style: TextStyle(
                              fontSize: 12,
                              color: hovered
                                  ? Colors.white.withValues(alpha: 0.85)
                                  : const Color(0xFF64748B),
                            ),
                            child: Text(widget.subtitle),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(width: 8),
                    // 右下角「进入 →」滑入
                    AnimatedSlide(
                      offset: hovered ? Offset.zero : const Offset(0.4, 0),
                      duration: const Duration(milliseconds: 300),
                      curve: Curves.easeOut,
                      child: AnimatedOpacity(
                        opacity: hovered ? 1.0 : 0.0,
                        duration: const Duration(milliseconds: 200),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(
                              '进入',
                              style: TextStyle(
                                fontSize: 12.5,
                                fontWeight: FontWeight.w600,
                                color:
                                    hovered ? Colors.white : Colors.grey.shade400,
                              ),
                            ),
                            const SizedBox(width: 2),
                            Icon(
                              Icons.arrow_forward_ios,
                              size: 14,
                              color:
                                  hovered ? Colors.white : Colors.grey.shade400,
                            ),
                          ],
                        ),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _MemoCard extends StatefulWidget {"""
if old2 in c:
    c = c.replace(old2, new2, 1)
    ok.append("类已添加")
else:
    ok.append("类添加 FAIL")

with io.open(path, "w", encoding="utf-8", newline="\n") as f:
    f.write(c)
print("Windows:", ", ".join(ok))
