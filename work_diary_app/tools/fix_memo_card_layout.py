# -*- coding: utf-8 -*-
"""整段替换 _MemoCardState.build 方法（修复布局断言 bug）"""
import io

path = r"E:\Code\WorkDiary\work_diary_app\lib\screens\home_screen.dart"
with io.open(path, "r", encoding="utf-8") as f:
    lines = f.readlines()

# 定位 _MemoCardState 类中的 build 方法
start = None
for i, line in enumerate(lines):
    if line.strip().startswith("class _MemoCardState extends State<_MemoCard> {"):
        # 找到该类里第一个 "Widget build(BuildContext context) {"
        for j in range(i, min(i + 200, len(lines))):
            if "Widget build(BuildContext context)" in lines[j]:
                start = j
                break
        break
if start is None:
    print("FAIL：找不到 build 方法")
    raise SystemExit(1)

# build 方法结束：找 "  }" 后面跟 "}"（类结束）或下一个成员
# build 方法从 start 开始，方法体配对括号
depth = 0
end = None
in_method = False
for k in range(start, len(lines)):
    line = lines[k]
    for ch in line:
        if ch == "{":
            depth += 1
            in_method = True
        elif ch == "}":
            depth -= 1
            if depth == 0 and in_method:
                end = k  # 方法结束（含 })
                break
    if end is not None:
        break

print("build 方法范围:", start + 1, "->", end + 1)

new_build = '''  @override
  Widget build(BuildContext context) {
    // 隔行换色：偶数行白色，奇数行极浅蓝灰
    final baseColor = widget.index.isEven ? Colors.white : const Color(0xFFF8FAFD);
    final bg = _hovered ? const Color(0xFFF4F8FF) : baseColor;
    final borderColor = _hovered ? const Color(0xFFBFD7F9) : Colors.grey.shade200;
    // 注意：不能再用 Row(stretch) + 空竖条 Container(width:3)。
    // ListView 无界高度下会触发 'child.hasSize' 断言，导致后续卡片不渲染。
    // 改用外层圆角 shadow 容器 + ClipRRect 圆角 + Container 非均匀 Border(left 蓝 3px)。
    final card = Container(
      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(10),
        boxShadow: _hovered
            ? [
                BoxShadow(
                  color: _blue.withValues(alpha: 0.12),
                  blurRadius: 10,
                  offset: const Offset(0, 3),
                ),
              ]
            : null,
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(10),
        child: Container(
          decoration: BoxDecoration(
            color: bg,
            border: Border(
              left: const BorderSide(color: _blue, width: 3),
              top: BorderSide(color: borderColor),
              right: BorderSide(color: borderColor),
              bottom: BorderSide(color: borderColor),
            ),
          ),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 10, 10, 10),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // 内容：可选中复制 + 搜索关键词高亮
                // 用 SelectionArea+Text 替代 SelectableText.rich：
                // Flutter Windows 桌面端多个 SelectableText 同屏时第二个不渲染（已知 bug）
                SelectionArea(
                  child: Text.rich(
                    TextSpan(
                      style: const TextStyle(
                        fontSize: 13,
                        height: 1.5,
                        color: Color(0xFF334155),
                      ),
                      children: _highlight(widget.memo.content, widget.keyword),
                    ),
                  ),
                ),
                const SizedBox(height: 6),
                Row(
                  children: [
                    Text(
                      widget.timeText,
                      style: const TextStyle(fontSize: 11, color: Color(0xFF9CA3AF)),
                    ),
                    const Spacer(),
                    // 操作按钮：悬停时才显现
                    AnimatedOpacity(
                      opacity: _hovered ? 1.0 : 0.0,
                      duration: const Duration(milliseconds: 150),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          IconButton(
                            icon: const Icon(Icons.edit_outlined, size: 15, color: Colors.grey),
                            padding: EdgeInsets.zero,
                            constraints: const BoxConstraints(minWidth: 30, minHeight: 28),
                            tooltip: '编辑',
                            onPressed: widget.onEdit,
                          ),
                          const SizedBox(width: 4),
                          IconButton(
                            icon: const Icon(Icons.delete_outline, size: 15, color: Colors.grey),
                            padding: EdgeInsets.zero,
                            constraints: const BoxConstraints(minWidth: 30, minHeight: 28),
                            tooltip: '删除',
                            onPressed: widget.onDelete,
                          ),
                        ],
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
    // 桌面端悬停微交互
    return MouseRegion(
      cursor: SystemMouseCursors.basic,
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: card,
    );
  }
'''

new_lines = lines[:start] + [new_build] + lines[end + 1:]
with io.open(path, "w", encoding="utf-8", newline="\n") as f:
    f.writelines(new_lines)
print("OK：_MemoCardState.build 已整段替换（并恢复隔行换色）")
