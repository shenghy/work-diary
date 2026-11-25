# -*- coding: utf-8 -*-
"""Windows：修复字数提示插入（精确缩进锚点）"""
import io

home_path = r"E:\Code\WorkDiary\work_diary_app\lib\screens\home_screen.dart"

with io.open(home_path, "r", encoding="utf-8") as f:
    c = f.read()

old = """                                  : MarkdownBody(data: ctrl.text, styleSheet: _mdStyle(context)),
                            ),
                          ),
                        ),
                ),
              ],
            ),
          ),
          actions: ["""
new = """                                  : MarkdownBody(data: ctrl.text, styleSheet: _mdStyle(context)),
                            ),
                          ),
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
          actions: ["""
if old in c:
    c = c.replace(old, new, 1)
    with io.open(home_path, "w", encoding="utf-8", newline="\n") as f:
        f.write(c)
    print("OK：字数提示已加")
else:
    print("FAIL：锚点未匹配")
