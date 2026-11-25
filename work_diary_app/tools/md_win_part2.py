# -*- coding: utf-8 -*-
"""Windows 端：_showMemoEditor 改为 编辑/预览 切换"""
import io

path = r"E:\Code\WorkDiary\work_diary_app\lib\screens\home_screen.dart"
with io.open(path, "r", encoding="utf-8") as f:
    c = f.read()

old = """  /// 新建/编辑备忘弹窗
  Future<void> _showMemoEditor({Memo? memo}) async {
    final ctrl = TextEditingController(text: memo?.content ?? '');
    final saved = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(memo == null ? '新建备忘' : '编辑备忘', style: const TextStyle(fontSize: 16)),
        content: SizedBox(
          width: 360,
          child: _ImeSafeTextField(
            controller: ctrl,
            hintText: '输入备忘内容…',
            autofocus: true,
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('保存'),
          ),
        ],
      ),
    );"""

new = """  /// 新建/编辑备忘弹窗（支持 Markdown：编辑/预览切换）
  Future<void> _showMemoEditor({Memo? memo}) async {
    final ctrl = TextEditingController(text: memo?.content ?? '');
    var tab = 0; // 0=编辑 1=预览
    final saved = await showDialog<bool>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: Text(memo == null ? '新建备忘' : '编辑备忘', style: const TextStyle(fontSize: 16)),
          content: SizedBox(
            width: 430,
            height: 340,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SegmentedButton<int>(
                  segments: const [
                    ButtonSegment(
                      value: 0,
                      label: Text('编辑', style: TextStyle(fontSize: 13)),
                      icon: Icon(Icons.edit_outlined, size: 15),
                    ),
                    ButtonSegment(
                      value: 1,
                      label: Text('预览', style: TextStyle(fontSize: 13)),
                      icon: Icon(Icons.visibility_outlined, size: 15),
                    ),
                  ],
                  selected: {tab},
                  onSelectionChanged: (s) => setDialogState(() => tab = s.first),
                  showSelectedIcon: false,
                  style: ButtonStyle(
                    visualDensity: VisualDensity.compact,
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  ),
                ),
                const SizedBox(height: 8),
                const Text(
                  '支持 Markdown：# 标题、**加粗**、- 列表、`代码`、[链接](url)',
                  style: TextStyle(fontSize: 11, color: Color(0xFF9CA3AF)),
                ),
                const SizedBox(height: 8),
                Expanded(
                  child: tab == 0
                      ? _ImeSafeTextField(
                          controller: ctrl,
                          hintText: '输入备忘内容…',
                          autofocus: true,
                          // 备忘不转换子任务语法（避免与 Markdown 有序列表 1. 冲突）
                          enableAutoConvert: false,
                        )
                      : Container(
                          width: double.infinity,
                          decoration: BoxDecoration(
                            color: Colors.grey.shade50,
                            borderRadius: BorderRadius.circular(8),
                            border: Border.all(color: Colors.grey.shade200),
                          ),
                          padding: const EdgeInsets.all(10),
                          child: SelectionArea(
                            child: SingleChildScrollView(
                              child: ctrl.text.trim().isEmpty
                                  ? const Text(
                                      '输入内容后，点击「预览」查看渲染效果',
                                      style: TextStyle(color: Colors.grey, fontSize: 13),
                                    )
                                  : MarkdownBody(data: ctrl.text, styleSheet: _mdStyle(context)),
                            ),
                          ),
                        ),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(context).pop(true),
              child: const Text('保存'),
            ),
          ],
        ),
      ),
    );"""

if old not in c:
    print("FAIL：未匹配到 _showMemoEditor 开头")
    raise SystemExit(1)
c = c.replace(old, new, 1)

with io.open(path, "w", encoding="utf-8", newline="\n") as f:
    f.write(c)
print("OK：_showMemoEditor 已替换")
