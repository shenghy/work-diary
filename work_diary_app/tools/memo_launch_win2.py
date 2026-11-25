# -*- coding: utf-8 -*-
"""Windows 备忘录上线前修改（第2批）：
5. 编辑弹窗：maxLength 3000 + 下方实时字数 X/3000
6. 空状态：试试 Markdown 示例按钮 + _addDemoMemo
7. 头部：导出按钮 + _exportMemos + _memosToMarkdown
"""
import io

home_path = r"E:\Code\WorkDiary\work_diary_app\lib\screens\home_screen.dart"

with io.open(home_path, "r", encoding="utf-8") as f:
    c = f.read()

ok = []

# ===== 5. 编辑弹窗：maxLength + 字数提示 =====
# 5a. TextField 调用处传参
old5a = """                      ? _ImeSafeTextField(
                          controller: ctrl,
                          hintText: '输入备忘内容…',
                          autofocus: true,
                          // 备忘不转换子任务语法（避免与 Markdown 有序列表 1. 冲突）
                          enableAutoConvert: false,
                        )"""
new5a = """                      ? _ImeSafeTextField(
                          controller: ctrl,
                          hintText: '输入备忘内容…',
                          autofocus: true,
                          // 备忘不转换子任务语法（避免与 Markdown 有序列表 1. 冲突）
                          enableAutoConvert: false,
                          maxLength: 3000,
                          counterText: '',
                        )"""
if old5a in c:
    c = c.replace(old5a, new5a, 1)
    ok.append("编辑框 maxLength 已加")
else:
    ok.append("编辑框 maxLength FAIL")

# 5b. 字数提示：Expanded 结束后加一行
old5b = """                ),
              ],
            ),
          ),
          actions: ["""
# 定位到编辑弹窗 Column 结束（Expanded 之后）——该模式在文件里可能多处
# 用更精确的锚点：预览 Container 的结尾 + 编辑弹窗 Column 结尾
old5b2 = """                              ),
                        ),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: const Text('取消'),"""
new5b2 = """                              ),
                        ),
                ),
                const SizedBox(height: 4),
                ValueListenableBuilder<TextEditingValue>(
                  valueListenable: ctrl,
                  builder: (context, v, _) => Text(
                    '${v.text.characters.length}/3000',
                    textAlign: TextAlign.right,
                    style: const TextStyle(fontSize: 11, color: Color(0xFF9CA3AF)),
                  ),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: const Text('取消'),"""
if old5b2 in c:
    c = c.replace(old5b2, new5b2, 1)
    ok.append("字数提示已加")
else:
    ok.append("字数提示 FAIL")

# ===== 6. 空状态示例按钮 + 方法 =====
old6 = """                      const Text(
                        '还没有备忘，点击右下角 + 选择「新建备忘」',
                        style: TextStyle(color: Colors.grey, fontSize: 14),
                      ),
                    ],"""
new6 = """                      const Text(
                        '还没有备忘，点击右下角 + 选择「新建备忘」',
                        style: TextStyle(color: Colors.grey, fontSize: 14),
                      ),
                      const SizedBox(height: 10),
                      TextButton.icon(
                        onPressed: _addDemoMemo,
                        icon: const Icon(Icons.auto_awesome, size: 16),
                        label: const Text('试试 Markdown 示例'),
                        style: TextButton.styleFrom(
                          foregroundColor: const Color(0xFF3B82F6),
                          visualDensity: VisualDensity.compact,
                        ),
                      ),
                    ],"""
if old6 in c:
    c = c.replace(old6, new6, 1)
    ok.append("空状态按钮已加")
else:
    ok.append("空状态 FAIL")

# 6b. _addDemoMemo 方法（放在 _buildMemoView 前）
old6b = """  /// 备忘视图：搜索框 + 备忘卡片列表

  Widget _buildMemoView() {"""
new6b = """  /// 插入一条 Markdown 示例备忘（首次体验引导）
  Future<void> _addDemoMemo() async {
    const demo =
        '# 我的第一条备忘\\n\\n- **加粗** 重点内容\\n- 普通列表项\\n- `代码片段`\\n\\n> 引用：用 Markdown 写备忘，查看时自动排版';
    await _memoRepo.insertMemo(Memo(content: demo, createdAt: DateTime.now()));
    await _loadMemos();
    _syncAfterChange();
  }

  /// 备忘视图：搜索框 + 备忘卡片列表

  Widget _buildMemoView() {"""
if old6b in c:
    c = c.replace(old6b, new6b, 1)
    ok.append("示例方法已加")
else:
    ok.append("示例方法 FAIL")

with io.open(home_path, "w", encoding="utf-8", newline="\n") as f:
    f.write(c)
print("第2批:", ", ".join(ok))
