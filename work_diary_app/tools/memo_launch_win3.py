# -*- coding: utf-8 -*-
"""Windows：备忘导出功能（头部按钮 + _exportMemos + _memosToMarkdown）"""
import io

home_path = r"E:\Code\WorkDiary\work_diary_app\lib\screens\home_screen.dart"

with io.open(home_path, "r", encoding="utf-8") as f:
    c = f.read()

ok = []

# ===== 头部：搜索框 + 导出按钮 =====
old_head = """        Padding(
          padding: const EdgeInsets.fromLTRB(12, 10, 12, 4),
          child: TextField(
            controller: _memoSearchCtrl,
            onChanged: (_) => setState(() {}),
            style: const TextStyle(fontSize: 13),
            decoration: InputDecoration(
              hintText: '搜索备忘内容…',
              hintStyle: const TextStyle(fontSize: 13, color: Colors.grey),
              isDense: true,
              prefixIcon: const Icon(Icons.search, size: 18),
              suffixIcon: _memoSearchCtrl.text.isEmpty
                  ? null
                  : IconButton(
                      icon: const Icon(Icons.clear, size: 16),
                      onPressed: () {
                        _memoSearchCtrl.clear();
                        setState(() {});
                      },
                    ),
              filled: true,
              fillColor: Colors.grey.shade50,
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(10),
                borderSide: BorderSide(color: Colors.grey.shade200),
              ),
              enabledBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(10),
                borderSide: BorderSide(color: Colors.grey.shade200),
              ),
              contentPadding: const EdgeInsets.symmetric(vertical: 8),
            ),
          ),
        ),"""
new_head = """        Padding(
          padding: const EdgeInsets.fromLTRB(12, 10, 12, 4),
          child: Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _memoSearchCtrl,
                  onChanged: (_) => setState(() {}),
                  style: const TextStyle(fontSize: 13),
                  decoration: InputDecoration(
                    hintText: '搜索备忘内容…',
                    hintStyle: const TextStyle(fontSize: 13, color: Colors.grey),
                    isDense: true,
                    prefixIcon: const Icon(Icons.search, size: 18),
                    suffixIcon: _memoSearchCtrl.text.isEmpty
                        ? null
                        : IconButton(
                            icon: const Icon(Icons.clear, size: 16),
                            onPressed: () {
                              _memoSearchCtrl.clear();
                              setState(() {});
                            },
                          ),
                    filled: true,
                    fillColor: Colors.grey.shade50,
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(10),
                      borderSide: BorderSide(color: Colors.grey.shade200),
                    ),
                    enabledBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(10),
                      borderSide: BorderSide(color: Colors.grey.shade200),
                    ),
                    contentPadding: const EdgeInsets.symmetric(vertical: 8),
                  ),
                ),
              ),
              const SizedBox(width: 2),
              IconButton(
                tooltip: '导出全部备忘',
                icon: const Icon(Icons.file_download_outlined,
                    size: 18, color: Color(0xFF3B82F6)),
                onPressed: _exportMemos,
              ),
            ],
          ),
        ),"""
if old_head in c:
    c = c.replace(old_head, new_head, 1)
    ok.append("导出按钮已加")
else:
    ok.append("导出按钮 FAIL")

# ===== 方法：_exportMemos + _memosToMarkdown（放 _addDemoMemo 前）=====
old_m = """  /// 插入一条 Markdown 示例备忘（首次体验引导）"""
new_m = """  /// 导出全部备忘为 Markdown 文件
  Future<void> _exportMemos() async {
    if (_memos.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('暂无备忘可导出')),
      );
      return;
    }
    final now = DateTime.now();
    String two(int v) => v.toString().padLeft(2, '0');
    final fileName =
        '备忘导出_${now.year}${two(now.month)}${two(now.day)}_${two(now.hour)}${two(now.minute)}.md';
    const typeGroup = XTypeGroup(label: 'Markdown', extensions: ['md']);
    final file = await getSaveLocation(
      suggestedName: fileName,
      acceptedTypeGroups: const [typeGroup],
    );
    if (file == null) return; // 用户取消
    try {
      await File(file.path).writeAsString(_memosToMarkdown(now));
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('已导出：${file.path}')),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('导出失败：$e')),
      );
    }
  }

  /// 生成 Markdown 导出内容
  String _memosToMarkdown(DateTime now) {
    final buf = StringBuffer();
    String two(int v) => v.toString().padLeft(2, '0');
    buf.writeln('# 极简工作日记 · 备忘导出');
    buf.writeln('');
    buf.writeln('导出时间：${now.year}-${two(now.month)}-${two(now.day)} '
        '${two(now.hour)}:${two(now.minute)}');
    buf.writeln('共 ${_memos.length} 条');
    for (final m in _memos) {
      buf.writeln('');
      buf.writeln('---');
      buf.writeln('');
      buf.writeln('## ${_formatMemoTime(m.createdAt)}');
      buf.writeln('');
      buf.writeln(m.content);
    }
    buf.writeln('');
    return buf.toString();
  }

  /// 插入一条 Markdown 示例备忘（首次体验引导）"""
if old_m in c:
    c = c.replace(old_m, new_m, 1)
    ok.append("导出方法已加")
else:
    ok.append("导出方法 FAIL")

with io.open(home_path, "w", encoding="utf-8", newline="\n") as f:
    f.write(c)
print("导出功能:", ", ".join(ok))
