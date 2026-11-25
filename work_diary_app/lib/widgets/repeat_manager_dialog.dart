import 'package:flutter/material.dart';

import '../theme/glass_palette.dart';
import '../utils/repeat_family.dart';
import '../utils/repeat_format.dart';

/// 「循环任务」管理页用到的三条异步操作
typedef RepeatFamilyLoader = Future<List<RepeatFamilyInfo>> Function();
typedef RepeatFamilyAction = Future<void> Function(RepeatFamilyInfo family);

/// 「循环任务」管理对话框：集中查看 / 改规则 / 停止 / 恢复所有日、周、月任务。
///
/// 之前改循环规则必须翻到某一条实例双击进去，停止之后规则被删就再也找不到入口；
/// 现在规则会保留 stopped 状态并上云，这里就是它的统一入口。
class RepeatManagerDialog extends StatefulWidget {
  const RepeatManagerDialog({
    super.key,
    required this.load,
    required this.onEditRule,
    required this.onStop,
    required this.onResume,
    required this.onDelete,
  });

  final RepeatFamilyLoader load;
  final RepeatFamilyAction onEditRule;
  final RepeatFamilyAction onStop;
  final RepeatFamilyAction onResume;

  /// 永久删除：规则 + 该族全部期次 + 云端/其它设备。
  final RepeatFamilyAction onDelete;

  static Future<void> show(
    BuildContext context, {
    required RepeatFamilyLoader load,
    required RepeatFamilyAction onEditRule,
    required RepeatFamilyAction onStop,
    required RepeatFamilyAction onResume,
    required RepeatFamilyAction onDelete,
  }) {
    return showDialog<void>(
      context: context,
      builder: (_) => RepeatManagerDialog(
        load: load,
        onEditRule: onEditRule,
        onStop: onStop,
        onResume: onResume,
        onDelete: onDelete,
      ),
    );
  }

  @override
  State<RepeatManagerDialog> createState() => _RepeatManagerDialogState();
}

class _RepeatManagerDialogState extends State<RepeatManagerDialog> {
  List<RepeatFamilyInfo>? _families;
  bool _busy = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _reload();
  }

  Future<void> _reload() async {
    try {
      final list = await widget.load();
      if (!mounted) return;
      setState(() {
        _families = list;
        _error = null;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = '读取循环任务失败：$e');
    }
  }

  Future<void> _run(
    RepeatFamilyAction action,
    RepeatFamilyInfo family, {
    String? doneTip,
  }) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await action(family);
      if (doneTip != null && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(doneTip), duration: const Duration(seconds: 2)),
        );
      }
      await _reload();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('操作失败：$e')),
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _onSelected(RepeatFamilyInfo family, String value) async {
    final g = GlassPalette.of(context);
    switch (value) {
      case 'edit':
        await _run(widget.onEditRule, family);
        break;
      case 'stop':
        final ok = await showDialog<bool>(
          context: context,
          builder: (ctx) => AlertDialog(
            title: const Text('停止循环', style: TextStyle(fontSize: 16)),
            content: Text(
              '「${family.title}」将不再生成新一期，已经生成的期次全部保留。\n\n'
              '之后可以随时在「循环任务」里恢复。',
              style: const TextStyle(fontSize: 13, height: 1.6),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: const Text('取消'),
              ),
              TextButton(
                onPressed: () => Navigator.pop(ctx, true),
                child: Text('停止循环', style: TextStyle(color: g.danger)),
              ),
            ],
          ),
        );
        if (ok != true) return;
        await _run(widget.onStop, family, doneTip: '已停止「${family.title}」');
        break;
      case 'resume':
        await _run(widget.onResume, family, doneTip: '已恢复「${family.title}」');
        break;
    }
  }

  /// 永久删除确认：必须把「含已完成历史 / 同步所有设备 / 不可恢复」写清楚。
  Future<void> _confirmDelete(RepeatFamilyInfo family) async {
    final g = GlassPalette.of(context);
    final finished = family.total - family.unfinished;
    final title = family.title.trim().isEmpty ? '（无标题）' : family.title.trim();
    final scope = family.total == 0
        ? '这条循环规则'
        : '这条循环规则和全部 ${family.total} 期任务'
            '${finished > 0 ? '（含已完成的 $finished 期）' : ''}';
    final tail = family.total == 0
        ? '此操作不可恢复。'
        : '此操作不可恢复${finished > 0 ? '，已完成的期次也会一起删除' : ''}。';
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Row(
          children: [
            Icon(Icons.delete_forever, size: 20, color: g.danger),
            const SizedBox(width: 8),
            const Text('永久删除循环任务', style: TextStyle(fontSize: 16)),
          ],
        ),
        content: Text(
          '「$title」的$scope将被永久删除，'
          '并同步删除所有设备上的数据。\n\n$tail',
          style: const TextStyle(fontSize: 13, height: 1.6),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: TextButton.styleFrom(foregroundColor: g.danger),
            child: const Text('永久删除'),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    await _run(
      widget.onDelete,
      family,
      doneTip: '已永久删除「$title」',
    );
  }

  @override
  Widget build(BuildContext context) {
    final g = GlassPalette.of(context);
    return AlertDialog(
      title: Row(
        children: [
          Icon(Icons.autorenew, size: 18, color: g.accent),
          const SizedBox(width: 8),
          const Text('循环任务', style: TextStyle(fontSize: 16)),
          const Spacer(),
          if (_busy)
            const SizedBox(
              width: 16,
              height: 16,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
        ],
      ),
      content: SizedBox(width: 520, child: _buildContent()),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('关闭'),
        ),
      ],
    );
  }

  Widget _buildContent() {
    final g = GlassPalette.of(context);
    if (_error != null) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 24),
        child: Text(
          _error!,
          style: TextStyle(fontSize: 13, color: g.danger),
        ),
      );
    }
    final families = _families;
    if (families == null) {
      return const SizedBox(
        height: 120,
        child: Center(
          child: SizedBox(
            width: 22,
            height: 22,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
        ),
      );
    }
    if (families.isEmpty) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 28),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.repeat, size: 32, color: g.inkFaint),
            const SizedBox(height: 10),
            Text(
              '还没有循环任务',
              style: TextStyle(fontSize: 13, color: g.inkTertiary),
            ),
            const SizedBox(height: 4),
            Text(
              '新建任务时把「任务类别」选成日任务 / 周任务 / 月任务即可',
              style: TextStyle(fontSize: 11, color: g.inkTertiary),
              textAlign: TextAlign.center,
            ),
          ],
        ),
      );
    }
    return ConstrainedBox(
      constraints: const BoxConstraints(maxHeight: 420),
      child: ListView.separated(
        shrinkWrap: true,
        itemCount: families.length,
        separatorBuilder: (context, index) =>
            Divider(height: 1, color: g.divider),
        itemBuilder: (context, i) => _buildRow(families[i]),
      ),
    );
  }

  Widget _buildRow(RepeatFamilyInfo f) {
    final g = GlassPalette.of(context);
    final label = repeatRuleLabel(
      repeatType: f.repeatType,
      weekDays: f.weekDays,
      monthDay: f.monthDay,
    );
    final nextText = f.stopped
        ? '已停止，不再生成新一期'
        : f.next == null
            ? '暂无下一期'
            : '下一期：${formatDueDate(f.next!, planStartAt: f.planStartAt)}';
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: 2),
            child: Icon(
              f.stopped ? Icons.pause_circle_outline : Icons.autorenew,
              size: 18,
              color: f.stopped ? g.inkTertiary : g.accent,
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Flexible(
                      child: Text(
                        f.title.isEmpty ? '（无标题）' : f.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w500,
                          color: f.stopped ? g.inkTertiary : g.ink,
                        ),
                      ),
                    ),
                    if (f.stopped) ...[
                      const SizedBox(width: 4),
                      _pill('已停止', g.inkTertiary),
                    ],
                    if (!f.hasRule) ...[
                      const SizedBox(width: 4),
                      _pill('规则待同步', g.warning),
                    ],
                  ],
                ),
                const SizedBox(height: 3),
                Text(
                  '$label · 共 ${f.total} 期 · 未完成 ${f.unfinished} 期'
                  '${f.latest == null ? '' : ' · 最近 ${shortDate(f.latest!)}'}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 11, color: g.inkTertiary),
                ),
                const SizedBox(height: 2),
                Text(
                  nextText,
                  style: TextStyle(
                    fontSize: 11,
                    color: f.stopped ? g.inkTertiary : g.accent,
                  ),
                ),
              ],
            ),
          ),
          IconButton(
            tooltip: '永久删除循环',
            onPressed: _busy ? null : () => _confirmDelete(f),
            icon: Icon(Icons.delete_forever, size: 18, color: g.danger),
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
          ),
          PopupMenuButton<String>(
            enabled: !_busy,
            tooltip: '操作',
            icon: Icon(Icons.more_horiz, size: 18, color: g.inkTertiary),
            onSelected: (v) => _onSelected(f, v),
            itemBuilder: (_) => [
              const PopupMenuItem(
                value: 'edit',
                height: 38,
                child: Text('修改循环规则', style: TextStyle(fontSize: 13)),
              ),
              if (f.stopped)
                const PopupMenuItem(
                  value: 'resume',
                  height: 38,
                  child: Text('恢复循环', style: TextStyle(fontSize: 13)),
                )
              else
                PopupMenuItem(
                  value: 'stop',
                  height: 38,
                  child: Text(
                    '停止循环',
                    style: TextStyle(fontSize: 13, color: g.danger),
                  ),
                ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _pill(String text, Color color) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.08),
        border: Border.all(color: color.withValues(alpha: 0.5), width: 1),
        borderRadius: BorderRadius.circular(3),
      ),
      child: Text(text, style: TextStyle(fontSize: 10, color: color)),
    );
  }
}

/// 规则编辑结果
class RepeatRuleDraft {
  const RepeatRuleDraft({
    required this.repeatType,
    required this.weekDays,
    required this.monthDay,
  });

  final int repeatType;
  final List<int> weekDays;
  final int monthDay;
}

/// 只改「循环规则」的小编辑框（日/周/月 + 星期 / 每月几号）。
///
/// 与任务编辑框分开：那边改的是"这一期"的标题/时间/状态，这边改的是"规则"，
/// 语义更清楚，也不会误改到手头这一条实例。
Future<RepeatRuleDraft?> showRepeatRuleEditor(
  BuildContext context, {
  required String title,
  required RepeatRuleDraft initial,
  bool wasStopped = false,
}) {
  return showDialog<RepeatRuleDraft>(
    context: context,
    builder: (dialogCtx) {
      var repeatType = initial.repeatType > 0 ? initial.repeatType : 1;
      var weekDays = initial.weekDays.isEmpty
          ? <int>[DateTime.monday]
          : List<int>.of(initial.weekDays);
      // DropdownButton 的 value 必须在 items 里，越界值一律回落到 1 号
      var monthDay =
          (initial.monthDay >= 1 && initial.monthDay <= 31) ? initial.monthDay : 1;
      final g = GlassPalette.of(dialogCtx);
      return StatefulBuilder(
        builder: (dialogCtx, setDialogState) => AlertDialog(
          title: const Text('修改循环规则', style: TextStyle(fontSize: 16)),
          content: SizedBox(
            width: 360,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (title.isNotEmpty) ...[
                  Text(
                    title,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 12, color: g.inkTertiary),
                  ),
                  const SizedBox(height: 12),
                ],
                Row(
                  children: [1, 2, 3].map((rt) {
                    final selected = repeatType == rt;
                    final label =
                        rt == 1 ? '日任务' : (rt == 2 ? '周任务' : '月任务');
                    return Expanded(
                      child: GestureDetector(
                        onTap: () => setDialogState(() => repeatType = rt),
                        child: Container(
                          margin: const EdgeInsets.symmetric(horizontal: 3),
                          padding: const EdgeInsets.symmetric(vertical: 8),
                          decoration: BoxDecoration(
                            color: selected
                                ? g.accent.withValues(alpha: 0.15)
                                : g.fieldBg,
                            borderRadius: BorderRadius.circular(8),
                            border: Border.all(
                              color: selected ? g.accent : g.fieldBorder,
                              width: selected ? 1.5 : 1,
                            ),
                          ),
                          child: Center(
                            child: Text(
                              label,
                              style: TextStyle(
                                fontSize: 12,
                                color:
                                    selected ? g.ink : g.inkTertiary,
                              ),
                            ),
                          ),
                        ),
                      ),
                    );
                  }).toList(),
                ),
                if (repeatType == 2) ...[
                  const SizedBox(height: 12),
                  Text(
                    '每周重复（可多选）',
                    style: TextStyle(fontSize: 12, color: g.inkTertiary),
                  ),
                  const SizedBox(height: 6),
                  Wrap(
                    spacing: 6,
                    runSpacing: 6,
                    children: [1, 2, 3, 4, 5, 6, 7].map((wd) {
                      final selected = weekDays.contains(wd);
                      return GestureDetector(
                        onTap: () => setDialogState(() {
                          if (selected) {
                            weekDays = List.of(weekDays)..remove(wd);
                            // 至少保留一天，否则规则会退化成"每周一"
                            if (weekDays.isEmpty) weekDays = [wd];
                          } else {
                            weekDays = List.of(weekDays)..add(wd);
                            weekDays.sort();
                          }
                        }),
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 10,
                            vertical: 5,
                          ),
                          decoration: BoxDecoration(
                            color: selected
                                ? g.accent.withValues(alpha: 0.15)
                                : g.fieldBg,
                            borderRadius: BorderRadius.circular(6),
                            border: Border.all(
                              color: selected ? g.accent : g.fieldBorder,
                              width: selected ? 1.5 : 1,
                            ),
                          ),
                          child: Text(
                            '周${weekdayShort(wd)}',
                            style: TextStyle(
                              fontSize: 11,
                              color: selected
                                  ? g.accentText
                                  : g.inkTertiary,
                            ),
                          ),
                        ),
                      );
                    }).toList(),
                  ),
                ],
                if (repeatType == 3) ...[
                  const SizedBox(height: 12),
                  Row(
                    children: [
                      Text(
                        '每月',
                        style: TextStyle(fontSize: 12, color: g.inkTertiary),
                      ),
                      DropdownButton<int>(
                        value: monthDay,
                        style: TextStyle(
                          fontSize: 12,
                          color: g.ink,
                        ),
                        items: [
                          for (var i = 1; i <= 31; i++)
                            DropdownMenuItem(
                              value: i,
                              child: Text(
                                '$i 号',
                                style: TextStyle(fontSize: 12, color: g.ink),
                              ),
                            ),
                        ],
                        onChanged: (v) =>
                            setDialogState(() => monthDay = v ?? 1),
                      ),
                    ],
                  ),
                  Padding(
                    padding: const EdgeInsets.only(top: 4, left: 2),
                    child: Text(
                      '提示：小月（2/4/6/9/11）没有这一天时，自动取当月最后一天。',
                      style: TextStyle(fontSize: 11, color: g.inkTertiary),
                    ),
                  ),
                ],
                const SizedBox(height: 14),
                Text(
                  '修改规则后，未完成的期次会同步成新规则；已完成的期次保持原样。',
                  style: TextStyle(fontSize: 11, color: g.inkTertiary),
                ),
                if (wasStopped) ...[
                  const SizedBox(height: 6),
                  Text(
                    '该循环当前已停止，保存后会重新开始生成新一期。',
                    style: TextStyle(fontSize: 11, color: g.warning),
                  ),
                ],
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogCtx),
              child: const Text('取消'),
            ),
            ElevatedButton(
              onPressed: () => Navigator.pop(
                dialogCtx,
                RepeatRuleDraft(
                  repeatType: repeatType,
                  weekDays: List<int>.of(weekDays)..sort(),
                  monthDay: monthDay,
                ),
              ),
              style: ElevatedButton.styleFrom(
                backgroundColor: g.accent,
                foregroundColor: Colors.white,
              ),
              child: const Text('保存'),
            ),
          ],
        ),
      );
    },
  );
}

