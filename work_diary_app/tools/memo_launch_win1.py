# -*- coding: utf-8 -*-
"""Windows 备忘录上线前修改（第1批）：
1. remote_sync key 修复
2. _confirmDeleteMemo 无条件记录删除
3. _ImeSafeTextField 加 maxLength/counterText 参数
4. file_selector import
"""
import io

sync_path = r"E:\Code\WorkDiary\work_diary_app\lib\services\remote_sync_service.dart"
home_path = r"E:\Code\WorkDiary\work_diary_app\lib\screens\home_screen.dart"

ok = []

# ===== 1. remote_sync_service.dart: key 修复 =====
with io.open(sync_path, "r", encoding="utf-8") as f:
    s = f.read()
old = "    await box.put('memo_', {"
new = "    await box.put('memo_$localId', {"
if old in s:
    s = s.replace(old, new, 1)
    ok.append("sync key 已修")
else:
    ok.append("sync key FAIL")
with io.open(sync_path, "w", encoding="utf-8", newline="\n") as f:
    f.write(s)

# ===== 2. home_screen.dart =====
with io.open(home_path, "r", encoding="utf-8") as f:
    c = f.read()

# 2a. import file_selector
if "import 'package:file_selector/file_selector.dart';" not in c:
    c = c.replace("import 'package:flutter/services.dart';",
                  "import 'package:flutter/services.dart';\nimport 'package:file_selector/file_selector.dart';", 1)
    ok.append("import 已加")
else:
    ok.append("import 已有")

# 2b. _confirmDeleteMemo 无条件记录
old2 = """    if (AuthService.isLoggedIn && memo.remoteId != null) {
      await RemoteSyncService.recordMemoDeletion(memo.id!, memo.remoteId!);
    }"""
new2 = """    // 只要有远端 ID 就记录删除（不依赖登录状态）：未登录删除的备忘，登录后同步时也会同步删除，避免"复活"
    if (memo.remoteId != null) {
      await RemoteSyncService.recordMemoDeletion(memo.id!, memo.remoteId!);
    }"""
if old2 in c:
    c = c.replace(old2, new2, 1)
    ok.append("删除记录条件已改")
else:
    ok.append("删除记录 FAIL")

# 2c. _ImeSafeTextField 参数
old3 = """  final bool enableAutoConvert;

  const _ImeSafeTextField({
    required this.controller,
    required this.hintText,
    this.maxLines = 6,
    this.autofocus = false,
    this.enableAutoConvert = true,
  });"""
new3 = """  final bool enableAutoConvert;
  final int? maxLength;
  final String? counterText;

  const _ImeSafeTextField({
    required this.controller,
    required this.hintText,
    this.maxLines = 6,
    this.autofocus = false,
    this.enableAutoConvert = true,
    this.maxLength,
    this.counterText,
  });"""
if old3 in c:
    c = c.replace(old3, new3, 1)
    ok.append("_ImeSafeTextField 参数已加")
else:
    ok.append("_ImeSafeTextField FAIL")

# 2d. TextField 透传 maxLength + counterText
old4 = """        maxLines: widget.maxLines,
        // 关键：使用 text 而非 multiline，避免 Windows IME 组合状态 Bug
        keyboardType: TextInputType.text,
        decoration: InputDecoration(
          hintText: widget.hintText,"""
new4 = """        maxLines: widget.maxLines,
        maxLength: widget.maxLength,
        maxLengthEnforcement: widget.maxLength != null
            ? MaxLengthEnforcement.enforced
            : MaxLengthEnforcement.none,
        // 关键：使用 text 而非 multiline，避免 Windows IME 组合状态 Bug
        keyboardType: TextInputType.text,
        decoration: InputDecoration(
          hintText: widget.hintText,
          counterText: widget.counterText ?? '',"""
if old4 in c:
    c = c.replace(old4, new4, 1)
    ok.append("TextField 透传已加")
else:
    ok.append("TextField 透传 FAIL")

with io.open(home_path, "w", encoding="utf-8", newline="\n") as f:
    f.write(c)
print("第1批:", ", ".join(ok))
