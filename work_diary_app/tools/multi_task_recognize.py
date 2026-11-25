# -*- coding: utf-8 -*-
"""截图识别多任务分流：1条进新建框，多条进识别结果列表批量创建"""
import io

# ========== 1. RecognizeResultDialog 支持传入已识别结果 ==========
p1 = r"E:\Code\WorkDiary\work_diary_app\lib\widgets\recognize_result_dialog.dart"
with io.open(p1, "r", encoding="utf-8") as f:
    c1 = f.read()

r1a_old = """  final Future<List<Task>> Function(List<RecognizedTask>) onCreateTasks;
  final bool mockMode; // 虚拟 AI 识别模式（开发中，模拟延迟和结果）

  const RecognizeResultDialog({
    super.key,
    required this.screenshot,
    required this.onCreateTasks,
    this.mockMode = false,
  });"""
r1a_new = """  final Future<List<Task>> Function(List<RecognizedTask>) onCreateTasks;
  final bool mockMode; // 虚拟 AI 识别模式（开发中，模拟延迟和结果）
  final List<RecognizedTask>? initialTasks; // 已识别结果，传入则不再重复调用 AI

  const RecognizeResultDialog({
    super.key,
    required this.screenshot,
    required this.onCreateTasks,
    this.mockMode = false,
    this.initialTasks,
  });"""
if r1a_old in c1:
    c1 = c1.replace(r1a_old, r1a_new, 1)
    print("dialog1: initialTasks 参数已加")
else:
    print("dialog1 FAIL")

r1b_old = """      if (widget.mockMode) {
        // 虚拟 AI 识别：模拟 1.5 秒延迟，返回模拟任务
        await Future.delayed(const Duration(milliseconds: 1500));
        results = [
          RecognizedTask(title: '【示例】完成项目需求文档评审', urgency: '重要'),
          RecognizedTask(title: '【示例】回复客户邮件并确认下周会议时间', urgency: '一般'),
        ];
      } else {"""
r1b_new = """      if (widget.initialTasks != null && widget.initialTasks!.isNotEmpty) {
        // 外部已识别好，直接使用（避免重复消耗 AI 额度）
        results = widget.initialTasks!;
      } else if (widget.mockMode) {
        // 虚拟 AI 识别：模拟 1.5 秒延迟，返回模拟任务
        await Future.delayed(const Duration(milliseconds: 1500));
        results = [
          RecognizedTask(title: '【示例】完成项目需求文档评审', urgency: '重要'),
          RecognizedTask(title: '【示例】回复客户邮件并确认下周会议时间', urgency: '一般'),
        ];
      } else {"""
if r1b_old in c1:
    c1 = c1.replace(r1b_old, r1b_new, 1)
    print("dialog2: 已识别结果直通已加")
else:
    print("dialog2 FAIL")

with io.open(p1, "w", encoding="utf-8", newline="\n") as f:
    f.write(c1)

# ========== 2. home_screen 截图识别分流 ==========
p2 = r"E:\Code\WorkDiary\work_diary_app\lib\screens\home_screen.dart"
with io.open(p2, "r", encoding="utf-8") as f:
    c2 = f.read()

r2_old = """      // 4. 取第一个任务（AI 已把多个任务合并成编号列表），打开新建任务对话框并自动填充
      final rt = recognized.first;
      final urgency = switch (rt.urgency) {
        '重要' => Urgency.important,
        '紧急' => Urgency.urgent,
        _ => Urgency.normal,
      };
      DateTime? planStart;
      DateTime? due;
      if (rt.planStartAt != null) {
        try {
          planStart = DateTime.parse(rt.planStartAt!);
        } catch (_) {}
      }
      if (rt.dueAt != null) {
        try {
          due = DateTime.parse(rt.dueAt!);
        } catch (_) {}
      }

      await _showAddDialog(
        initialTitle: rt.title,
        initialUrgency: urgency,
        initialPlanStartAt: planStart,
        initialDueAt: due,
      );"""
r2_new = """      // 4. 分流：1 条直接进新建对话框；多条打开识别结果列表，勾选后批量创建
      if (recognized.length == 1) {
        final rt = recognized.first;
        final urgency = switch (rt.urgency) {
          '重要' => Urgency.important,
          '紧急' => Urgency.urgent,
          _ => Urgency.normal,
        };
        DateTime? planStart;
        DateTime? due;
        if (rt.planStartAt != null) {
          try {
            planStart = DateTime.parse(rt.planStartAt!);
          } catch (_) {}
        }
        if (rt.dueAt != null) {
          try {
            due = DateTime.parse(rt.dueAt!);
          } catch (_) {}
        }

        await _showAddDialog(
          initialTitle: rt.title,
          initialUrgency: urgency,
          initialPlanStartAt: planStart,
          initialDueAt: due,
        );
      } else {
        // 多条：展示识别结果列表，用户可勾选/编辑后批量创建
        final selected = await showDialog<List<RecognizedTask>>(
          context: context,
          builder: (_) => RecognizeResultDialog(
            screenshot: cropped,
            initialTasks: recognized,
            onCreateTasks: (_) async => <Task>[],
          ),
        );
        if (selected == null || selected.isEmpty) return;

        for (final rt in selected) {
          final urgency = switch (rt.urgency) {
            '重要' => Urgency.important,
            '紧急' => Urgency.urgent,
            _ => Urgency.normal,
          };
          DateTime? planStart;
          DateTime? due;
          if (rt.planStartAt != null) {
            try {
              planStart = DateTime.parse(rt.planStartAt!);
            } catch (_) {}
          }
          if (rt.dueAt != null) {
            try {
              due = DateTime.parse(rt.dueAt!);
            } catch (_) {}
          }
          final sortOrder = await _nextSortOrder(TaskStatus.planned);
          await _repo.insertTask(
            Task(
              title: rt.title,
              urgency: urgency,
              taskType: 1,
              createdAt: DateTime.now(),
              planStartAt: planStart,
              dueAt: due,
              sortOrder: sortOrder,
            ),
          );
        }
        _loadTasks();
        _syncAfterChange();
      }"""
if r2_old in c2:
    c2 = c2.replace(r2_old, r2_new, 1)
    print("home: 分流逻辑已加")
else:
    print("home FAIL")

with io.open(p2, "w", encoding="utf-8", newline="\n") as f:
    f.write(c2)
print("saved")
