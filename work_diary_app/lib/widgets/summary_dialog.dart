import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:docs_gee/docs_gee.dart' hide Border;
import 'package:file_selector/file_selector.dart';
import 'package:flutter/foundation.dart' show compute;
import 'package:flutter/material.dart';

import '../models/task.dart';
import '../services/ai_service.dart';
import '../theme/glass_palette.dart';

/// AI 工作日志总结对话框
/// 支持：当日 / 周 两种类型，全部 / 仅工作 / 仅个人 三种范围，
/// 生成结构化 Markdown 日志，并可导出 Markdown / Word 文件。
class SummaryDialog extends StatefulWidget {
  final String initialRange; // 'day' | 'week'
  final List<Task> allTasks; // 全部任务（含所有状态），对话框内按日期+范围过滤

  const SummaryDialog({
    super.key,
    this.initialRange = 'day',
    required this.allTasks,
  });

  @override
  State<SummaryDialog> createState() => _SummaryDialogState();

  /// 按日期与范围过滤任务
  ///
  /// 归属日期优先用完成时间：循环任务的实例是"补生成那天"创建的，用
  /// createdAt 会把昨天补出来的那期算到今天；另外"上周创建、今天完成"的
  /// 任务也应该进今天的日报。
  static List<Task> filterTasksFor(
    List<Task> all, {
    required DateTime start,
    required DateTime end,
    required String scope, // all / work / personal
  }) {
    final s = DateUtils.dateOnly(start);
    final e = DateUtils.dateOnly(end);
    return all.where((t) {
      final d = DateUtils.dateOnly(
        t.completedAt ?? t.instanceDate ?? t.createdAt,
      );
      if (d.isBefore(s) || d.isAfter(e)) return false;
      switch (scope) {
        case 'work':
          return t.taskType == 1;
        case 'personal':
          return t.taskType == 0;
        default:
          return true;
      }
    }).toList();
  }

  /// 把 Markdown 日志解析成 Word 文档字节（.docx）
  static Uint8List buildDocxFromMarkdown(String markdown) {
    final doc = DocxDocument(title: '工作日志', author: '极简工作日记');
    for (final raw in markdown.split('\n')) {
      final line = raw.trimRight();
      if (line.trim().isEmpty) {
        doc.addParagraph(DocxParagraph.text(''));
        continue;
      }
      final t = line.trim();
      if (t.startsWith('### ')) {
        doc.addParagraph(DocxParagraph.heading(t.substring(4).trim(), level: 3));
      } else if (t.startsWith('## ')) {
        doc.addParagraph(DocxParagraph.heading(t.substring(3).trim(), level: 2));
      } else if (t.startsWith('# ')) {
        doc.addParagraph(DocxParagraph.heading(t.substring(2).trim(), level: 1));
      } else if (t.startsWith('- ') || t.startsWith('* ')) {
        doc.addParagraph(DocxParagraph.bulletItem(t.substring(2).trim()));
      } else if (RegExp(r'^\d+\.\s').hasMatch(t)) {
        doc.addParagraph(DocxParagraph.numberedItem(t));
      } else {
        doc.addParagraph(DocxParagraph.text(t));
      }
    }
    final generator = DocxGenerator(fontName: '等线', fontSize: 24);
    return generator.generate(doc);
  }
}

class _SummaryDialogState extends State<SummaryDialog> {
  late String _range = widget.initialRange;
  String _scope = 'all';
  late DateTime _startDate = DateUtils.dateOnly(DateTime.now());
  late DateTime _endDate = DateUtils.dateOnly(DateTime.now());

  bool _generating = false;
  String? _summary;
  String? _error;

  static String _fmt(DateTime d) =>
      '${d.year.toString().padLeft(4, '0')}-'
      '${d.month.toString().padLeft(2, '0')}-'
      '${d.day.toString().padLeft(2, '0')}';

  static String _fmtShort(DateTime d) => '${d.month}月${d.day}日';

  /// 本周周一
  static DateTime _mondayOf(DateTime d) =>
      DateUtils.dateOnly(d).subtract(Duration(days: d.weekday - 1));

  /// 按当前日期与范围过滤任务
  List<Task> _filterTasks() =>
      SummaryDialog.filterTasksFor(widget.allTasks,
          start: _startDate, end: _endDate, scope: _scope);

  int get _dayCount => _endDate.difference(_startDate).inDays + 1;

  Future<void> _pickDate({required bool isStart}) async {
    final picked = await showDatePicker(
      context: context,
      initialDate: isStart ? _startDate : _endDate,
      firstDate: DateTime(2020),
      lastDate: DateTime.now(),
      helpText: isStart ? '选择开始日期' : '选择结束日期',
    );
    if (picked == null) return;
    setState(() {
      if (isStart) {
        _startDate = DateUtils.dateOnly(picked);
        if (_endDate.isBefore(_startDate)) _endDate = _startDate;
      } else {
        _endDate = DateUtils.dateOnly(picked);
        if (_startDate.isAfter(_endDate)) _startDate = _endDate;
      }
    });
  }

  Future<void> _generate() async {
    if (_generating) return;
    setState(() {
      _generating = true;
      _error = null;
      _summary = null;
    });
    final tasks = _filterTasks();
    try {
      final summary = await AiService.summarizeTasks(
        range: _range,
        scope: _scope,
        startDate: _fmt(_startDate),
        endDate: _fmt(_endDate),
        tasks: tasks.map((t) => SummarizeTaskItem(
              title: t.title,
              status: t.status.index,
              urgency: t.urgency.index,
              taskType: t.taskType,
              createdAt: t.createdAt.toIso8601String(),
              startedAt: t.startedAt?.toIso8601String(),
              completedAt: t.completedAt?.toIso8601String(),
            )).toList(),
      );
      if (!mounted) return;
      setState(() {
        _summary = summary;
        _generating = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.toString().replaceFirst('Exception: ', '');
        _generating = false;
      });
    }
  }

  String _defaultName() {
    final s = _fmt(_startDate);
    final e = _fmt(_endDate);
    return _range == 'day' ? '工作日志_$s' : '工作日志_${s}至$e';
  }

  void _showSaved(String path) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('已保存：$path')),
    );
  }

  Future<void> _exportMarkdown() async {
    final location = await getSaveLocation(
      suggestedName: '${_defaultName()}.md',
      acceptedTypeGroups: [
        const XTypeGroup(label: 'Markdown', extensions: ['md']),
      ],
    );
    if (location == null) return; // 用户取消
    var path = location.path;
    if (!path.toLowerCase().endsWith('.md')) path += '.md';
    try {
      await File(path).writeAsBytes(utf8.encode(_summary ?? ''), flush: true);
      _showSaved(path);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('保存失败：$e')),
      );
    }
  }

  Future<void> _exportWord() async {
    final location = await getSaveLocation(
      suggestedName: '${_defaultName()}.docx',
      acceptedTypeGroups: [
        const XTypeGroup(label: 'Word 文档', extensions: ['docx']),
      ],
    );
    if (location == null) return; // 用户取消
    var path = location.path;
    if (!path.toLowerCase().endsWith('.docx')) path += '.docx';
    try {
      // docx 生成是纯 CPU 工作，放 isolate 里避免卡住界面
      final bytes = await compute(
        SummaryDialog.buildDocxFromMarkdown,
        _summary ?? '',
      );
      await File(path).writeAsBytes(bytes, flush: true);
      _showSaved(path);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('保存失败：$e')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final g = GlassPalette.of(context);
    final taskCount = _filterTasks().length;
    final hasSummary = _summary != null && _summary!.isNotEmpty;

    return Dialog(
      backgroundColor: g.surface,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 500, maxHeight: 620),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // 标题栏
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 16, 12, 8),
              child: Row(
                children: [
                  Icon(Icons.auto_awesome, size: 20, color: g.accent),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      'AI 工作日志总结',
                      style: TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.bold,
                          color: g.ink),
                    ),
                  ),
                  IconButton(
                    icon: Icon(Icons.close, size: 18, color: g.inkSecondary),
                    onPressed: () => Navigator.pop(context),
                    tooltip: '关闭',
                  ),
                ],
              ),
            ),
            Divider(height: 1, color: g.divider),

            Flexible(
              child: SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(20, 12, 20, 16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // 1. 类型
                    Text('总结类型',
                        style: TextStyle(
                            fontSize: 13,
                            fontWeight: FontWeight.w600,
                            color: g.ink)),
                    const SizedBox(height: 6),
                    SegmentedButton<String>(
                      segments: const [
                        ButtonSegment(value: 'day', label: Text('当日')),
                        ButtonSegment(value: 'week', label: Text('周')),
                      ],
                      selected: {_range},
                      onSelectionChanged: (s) => setState(() {
                        _range = s.first;
                        _startDate = _endDate = DateUtils.dateOnly(DateTime.now());
                        if (_range == 'week') _startDate = _mondayOf(_startDate);
                      }),
                    ),
                    const SizedBox(height: 12),

                    // 2. 日期范围
                    Text('日期范围',
                        style: TextStyle(
                            fontSize: 13,
                            fontWeight: FontWeight.w600,
                            color: g.ink)),
                    const SizedBox(height: 6),
                    if (_range == 'day')
                      _dateButton(
                        label: '日期',
                        value: _fmt(_startDate),
                        onTap: () => _pickDate(isStart: true),
                      )
                    else
                      Row(
                        children: [
                          Expanded(
                            child: _dateButton(
                              label: '开始',
                              value: _fmtShort(_startDate),
                              onTap: () => _pickDate(isStart: true),
                            ),
                          ),
                          Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 8),
                            child: Text('至',
                                style: TextStyle(fontSize: 13, color: g.inkTertiary)),
                          ),
                          Expanded(
                            child: _dateButton(
                              label: '结束',
                              value: _fmtShort(_endDate),
                              onTap: () => _pickDate(isStart: false),
                            ),
                          ),
                        ],
                      ),
                    if (_range == 'week')
                      Padding(
                        padding: const EdgeInsets.only(top: 6),
                        child: Text(
                          '共 $_dayCount 天',
                          style: TextStyle(fontSize: 12, color: g.inkTertiary),
                        ),
                      ),
                    const SizedBox(height: 12),

                    // 3. 总结范围
                    Text('总结范围',
                        style: TextStyle(
                            fontSize: 13,
                            fontWeight: FontWeight.w600,
                            color: g.ink)),
                    const SizedBox(height: 6),
                    SegmentedButton<String>(
                      segments: const [
                        ButtonSegment(value: 'all', label: Text('全部')),
                        ButtonSegment(value: 'work', label: Text('仅工作')),
                        ButtonSegment(value: 'personal', label: Text('仅个人')),
                      ],
                      selected: {_scope},
                      onSelectionChanged: (s) => setState(() => _scope = s.first),
                      style: const ButtonStyle(
                        visualDensity: VisualDensity.compact,
                      ),
                    ),
                    const SizedBox(height: 10),
                    Text(
                      '已选任务：$taskCount 条',
                      style: TextStyle(fontSize: 12, color: g.inkTertiary),
                    ),
                    const SizedBox(height: 12),

                    // 4. 生成按钮
                    SizedBox(
                      width: double.infinity,
                      height: 38,
                      child: FilledButton.icon(
                        onPressed: _generating ? null : _generate,
                        icon: _generating
                            ? const SizedBox(
                                width: 16,
                                height: 16,
                                child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                              )
                            : const Icon(Icons.auto_awesome, size: 16),
                        label: Text(_generating ? 'AI 生成中...' : '生成日志'),
                      ),
                    ),

                    // 5. 错误
                    if (_error != null)
                      Padding(
                        padding: const EdgeInsets.only(top: 10),
                        child: Container(
                          width: double.infinity,
                          padding: const EdgeInsets.all(10),
                          decoration: BoxDecoration(
                            color: g.overdueFill,
                            borderRadius: BorderRadius.circular(8),
                            border: Border.all(color: g.overdueBorder),
                          ),
                          child: Text(
                            _error!,
                            style: TextStyle(fontSize: 12, color: g.overdueFg),
                          ),
                        ),
                      ),

                    // 6. 结果
                    if (hasSummary)
                      Padding(
                        padding: const EdgeInsets.only(top: 12),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              '生成结果（可复制编辑）',
                              style: TextStyle(
                                  fontSize: 13,
                                  fontWeight: FontWeight.w600,
                                  color: g.ink),
                            ),
                            const SizedBox(height: 6),
                            Container(
                              width: double.infinity,
                              constraints: const BoxConstraints(maxHeight: 280),
                              padding: const EdgeInsets.all(10),
                              decoration: BoxDecoration(
                                color: g.fieldBg,
                                borderRadius: BorderRadius.circular(8),
                                border: Border.all(color: g.fieldBorder),
                              ),
                              child: SingleChildScrollView(
                                child: SelectableText(
                                  _summary!,
                                  style: TextStyle(
                                      fontSize: 13, height: 1.5, color: g.ink),
                                ),
                              ),
                            ),
                            const SizedBox(height: 10),
                            Row(
                              children: [
                                Expanded(
                                  child: OutlinedButton.icon(
                                    onPressed: _exportMarkdown,
                                    icon: const Icon(Icons.description_outlined, size: 16),
                                    label: const Text('导出 Markdown'),
                                  ),
                                ),
                                const SizedBox(width: 10),
                                Expanded(
                                  child: OutlinedButton.icon(
                                    onPressed: _exportWord,
                                    icon: const Icon(Icons.article_outlined, size: 16),
                                    label: const Text('导出 Word'),
                                  ),
                                ),
                              ],
                            ),
                          ],
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _dateButton({
    required String label,
    required String value,
    required VoidCallback onTap,
  }) {
    final g = GlassPalette.of(context);
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(8),
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        decoration: BoxDecoration(
          border: Border.all(color: g.fieldBorder),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text('$label：$value',
                style: TextStyle(fontSize: 13, color: g.ink)),
            Icon(Icons.calendar_today, size: 14, color: g.inkTertiary),
          ],
        ),
      ),
    );
  }
}
