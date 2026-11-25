/// 子任务解析工具（不改数据库结构）
///
/// 约定：任务标题中，匹配 `[ ]`（未完成）/ `[x]`（已完成）/ `1. `（数字编号）/ `- `（连字符）开头的行视为子任务。
/// - 数字编号格式（`1. xxx`）渲染时保留编号：`[ ] 1. xxx` / `[x] 1. xxx`
/// - 连字符格式（`- xxx`）渲染时不保留前缀：`[ ] xxx`
/// - 旧数据中未转义的 `1. xxx` 格式同样会被识别为子任务（视为未完成，保留编号）
library;

/// 单个子任务
class SubTaskItem {
  final String text;
  final bool done;

  /// 数字编号前缀（如 `1.`），无编号时为 null
  final String? prefix;

  const SubTaskItem({required this.text, required this.done, this.prefix});
}

/// 解析结果
class SubTaskParseResult {
  final String mainTitle;
  final List<SubTaskItem> items;

  bool get hasSubTasks => items.isNotEmpty;

  const SubTaskParseResult({required this.mainTitle, required this.items});
}

/// 匹配子任务行：
/// - `[ ] xxx` / `[x] xxx` / `[X] xxx`（group1 = 勾选标记）
/// - `1. xxx` / `12. xxx`（group2 = 数字编号）
/// - `- xxx`（group3 = 文本）
/// group4 = 文本
final RegExp _subTaskRegExp =
    RegExp(r'^\s*(?:\[([ xX])\]\s*|(\d+)\.\s+|-\s+)(.+?)\s*$');

/// 从文本开头提取数字编号前缀（如 `1.`），无则 null
String? _extractNumberPrefix(String text) {
  final m = RegExp(r'^(\d+)\.\s*').firstMatch(text);
  if (m == null) return null;
  return '${m.group(1)}.';
}

/// 解析任务标题：
/// - 所有行（包括第一行）匹配子任务格式的行均视为子任务
/// - 其余行原样并入主标题（保留换行，不丢内容）
/// - 若全部行都是子任务，主标题为空
SubTaskParseResult parseSubTasks(String title) {
  final lines = title.split('\n');
  if (lines.isEmpty) {
    return const SubTaskParseResult(mainTitle: '', items: []);
  }

  final mainParts = <String>[];
  final items = <SubTaskItem>[];

  for (final line in lines) {
    final m = _subTaskRegExp.firstMatch(line);
    if (m != null) {
      final mark = m.group(1);
      final numText = m.group(2);
      var text = m.group(3)!.trimRight();
      final done = mark == 'x' || mark == 'X';

      // 提取编号前缀：优先用正则匹配的编号；`[ ] 1. xxx` 格式从文本里再提取
      String? prefix;
      if (numText != null) {
        prefix = '$numText.';
      } else {
        final p = _extractNumberPrefix(text);
        if (p != null) {
          prefix = p;
          text = text.replaceFirst(RegExp(r'^\d+\.\s*'), '');
        }
      }
      items.add(SubTaskItem(text: text.trim(), done: done, prefix: prefix));
    } else {
      // 非子任务行并入主标题
      mainParts.add(line);
    }
  }

  return SubTaskParseResult(
    mainTitle: mainParts.join('\n').trim(),
    items: items,
  );
}

/// 将某个子任务的完成状态写入标题字符串（原地替换，统一转为 `[ ]`/`[x]` 格式）
/// [index] 为子任务在 [items] 中的索引
/// - 带编号的行勾选后保留编号：`1. xxx` -> `[x] 1. xxx`
/// - 连字符行勾选后前缀消失：`- xxx` -> `[x] xxx`
String setSubTaskDone(String title, int index, bool done) {
  final lines = title.split('\n');
  var subIndex = 0;
  final buf = <String>[];
  for (final line in lines) {
    final m = _subTaskRegExp.firstMatch(line);
    if (m != null) {
      if (subIndex == index) {
        final numText = m.group(2);
        var text = m.group(3)!;
        // 提取编号（与解析一致）：正则编号优先，其次文本内编号
        String? prefix;
        if (numText != null) {
          prefix = '$numText.';
        } else {
          final p = _extractNumberPrefix(text);
          if (p != null) {
            prefix = p;
            text = text.replaceFirst(RegExp(r'^\d+\.\s*'), '');
          }
        }
        final mark = done ? '[x]' : '[ ]';
        buf.add(prefix != null ? '$mark $prefix ${text.trimRight()}' : '$mark ${text.trimRight()}');
      } else {
        // 其他行原样保留（旧数据数字/连字符格式不强制规范化）
        buf.add(line);
      }
      subIndex++;
    } else {
      buf.add(line);
    }
  }
  return buf.join('\n');
}

/// 输入框自动转义：
/// - 行首 `数字. ` -> `[ ] 数字. `（保留编号）
/// - 行首 `- ` -> `[ ] `（连字符替换为勾选框）
String autoConvertNumberedToCheckbox(String text) {
  var r = text.replaceAllMapped(RegExp(r'^(\d+)\.\s+', multiLine: true), (m) => '[ ] ${m.group(1)}. ');
  r = r.replaceAll(RegExp(r'^-\s+', multiLine: true), '[ ] ');
  return r;
}
