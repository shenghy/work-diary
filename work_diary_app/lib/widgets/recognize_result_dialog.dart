import 'dart:typed_data';
import 'package:flutter/material.dart';
import '../models/task.dart';
import '../services/ai_service.dart';
import '../theme/glass_palette.dart';

/// AI 识别结果对话框：展示识别出的任务列表，用户可勾选/编辑，确认后批量创建
class RecognizeResultDialog extends StatefulWidget {
  final Uint8List screenshot;
  final Future<List<Task>> Function(List<RecognizedTask>) onCreateTasks;
  final bool mockMode; // 虚拟 AI 识别模式（开发中，模拟延迟和结果）
  final List<RecognizedTask>? initialTasks; // 已识别结果，传入则不再重复调用 AI

  const RecognizeResultDialog({
    super.key,
    required this.screenshot,
    required this.onCreateTasks,
    this.mockMode = false,
    this.initialTasks,
  });

  @override
  State<RecognizeResultDialog> createState() => _RecognizeResultDialogState();
}

class _RecognizeResultDialogState extends State<RecognizeResultDialog> {
  bool _loading = true;
  String? _error;
  List<_EditableTask> _tasks = [];

  @override
  void initState() {
    super.initState();
    _recognize();
  }

  Future<void> _recognize() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      List<RecognizedTask> results;

      if (widget.initialTasks != null && widget.initialTasks!.isNotEmpty) {
        // 外部已识别好，直接使用（避免重复消耗 AI 额度）
        results = widget.initialTasks!;
      } else if (widget.mockMode) {
        // 虚拟 AI 识别：模拟 1.5 秒延迟，返回模拟任务
        await Future.delayed(const Duration(milliseconds: 1500));
        results = [
          RecognizedTask(title: '【示例】完成项目需求文档评审', urgency: '重要'),
          RecognizedTask(title: '【示例】回复客户邮件并确认下周会议时间', urgency: '一般'),
        ];
      } else {
        // 真实 AI 识别：调用服务端接口
        results = await AiService.recognizeTasks(widget.screenshot);
      }

      // 识别期间对话框可能已被关闭（点空白 / 取消）
      if (!mounted) return;
      setState(() {
        _tasks = results
            .map((t) => _EditableTask(
                  title: t.title,
                  urgency: t.urgency,
                  selected: true,
                ))
            .toList();
        _loading = false;
      });
    } catch (e) {
      // 识别过程中用户可能已关闭对话框（AlertDialog 默认点空白可关）
      if (!mounted) return;
      setState(() {
        _error = e.toString().replaceAll('Exception: ', '');
        _loading = false;
      });
    }
  }

  Future<void> _confirm() async {
    final selected = _tasks.where((t) => t.selected).toList();
    if (selected.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('请至少选择一个任务')),
      );
      return;
    }
    final recognized = selected
        .map((t) => RecognizedTask(title: t.title, urgency: t.urgency))
        .toList();
    Navigator.of(context).pop(recognized);
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(
        widget.mockMode ? 'AI 识别（开发中·模拟）' : 'AI 识别结果',
        style: const TextStyle(fontSize: 16),
      ),
      content: SizedBox(
        width: 400,
        child: _buildContent(),
      ),
      actions: [
        TextButton(
          onPressed: _loading ? null : () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: (_loading || _tasks.isEmpty) ? null : _confirm,
          child: Text(_loading ? '识别中...' : '创建选中任务'),
        ),
      ],
    );
  }

  Widget _buildContent() {
    final g = GlassPalette.of(context);
    if (_loading) {
      return SizedBox(
        height: 200,
        child: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const CircularProgressIndicator(),
              const SizedBox(height: 16),
              Text(
                'AI 正在识别截图内容...',
                // 对话框属于浮层，次要文案走浮层文字令牌（深色档就是改造前的中灰）。
                style: TextStyle(fontSize: 13, color: g.menuTextFaint),
              ),
            ],
          ),
        ),
      );
    }
    if (_error != null) {
      return SizedBox(
        height: 200,
        child: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.error_outline, color: g.danger, size: 40),
              const SizedBox(height: 12),
              Text(_error!, textAlign: TextAlign.center, style: const TextStyle(fontSize: 13)),
              const SizedBox(height: 12),
              TextButton.icon(
                onPressed: _recognize,
                icon: const Icon(Icons.refresh, size: 16),
                label: const Text('重试'),
              ),
            ],
          ),
        ),
      );
    }
    if (_tasks.isEmpty) {
      return const SizedBox(
        height: 150,
        child: Center(child: Text('未识别到任务，请尝试截取更清晰的区域')),
      );
    }
    return ListView.separated(
      shrinkWrap: true,
      itemCount: _tasks.length,
      separatorBuilder: (_, __) => const Divider(height: 1),      itemBuilder: (context, index) {
        final task = _tasks[index];
        return ListTile(
          dense: true,
          contentPadding: const EdgeInsets.symmetric(horizontal: 4),
          leading: Checkbox(
            value: task.selected,
            onChanged: (v) => setState(() => task.selected = v ?? false),
          ),
          title: TextFormField(
            initialValue: task.title,
            maxLines: null,
            keyboardType: TextInputType.multiline,
            style: const TextStyle(fontSize: 13),
            decoration: const InputDecoration(
              isDense: true,
              contentPadding: EdgeInsets.symmetric(vertical: 8),
              border: InputBorder.none,
            ),
            onChanged: (v) => task.title = v,
          ),
          trailing: DropdownButton<String>(
            value: task.urgency,
            items: const [
              DropdownMenuItem(value: '一般', child: Text('一般', style: TextStyle(fontSize: 12))),
              DropdownMenuItem(value: '重要', child: Text('重要', style: TextStyle(fontSize: 12))),
              DropdownMenuItem(value: '紧急', child: Text('紧急', style: TextStyle(fontSize: 12))),
            ],
            onChanged: (v) => setState(() => task.urgency = v ?? '一般'),
          ),
        );
      },
    );
  }
}

class _EditableTask {
  String title;
  String urgency;
  bool selected;

  _EditableTask({required this.title, this.urgency = '一般', this.selected = true});
}
