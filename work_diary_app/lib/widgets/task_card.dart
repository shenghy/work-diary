import 'package:flutter/material.dart';
import '../models/task.dart';
import '../theme/glass_palette.dart';
import '../utils/repeat_format.dart';
import '../utils/repeat_task_engine.dart';
import '../utils/subtask_parser.dart';
import 'glass_surface.dart';
import 'marquee_text.dart';
import 'shatter_effect.dart';

/// 任务列表项卡片
class TaskCard extends StatefulWidget {
  final Task task;
  final void Function(BuildContext context) onStatusToggle;

  /// 执行中卡片专属：不打开编辑页，直接把任务退回「计划中」。
  /// 为 null 时不显示该按钮（如拖拽预览卡）。
  final void Function(BuildContext context)? onBackToPlanned;
  final VoidCallback onDelete;
  /// 循环任务专属：停止循环并删除本期（彻底取消，次日不再生成）
  final VoidCallback? onStopRepeat;
  final VoidCallback onDoubleTap;
  final VoidCallback onEdit;
  final bool isDragging;
  final void Function(Task)? onSubTaskChanged;

  /// 附件条（由上层用 [AttachmentStrip] 构造好传进来，卡片不认识同步服务）
  final Widget? attachments;

  /// 卡片材质风格（设计方案对比用，默认当前纯白卡）。
  final GlassVariant glassVariant;

  /// 基准时间，仅测试注入；生产环境传 null 走真实时间。
  /// 不注入的话，底部「今天开始 / 11月13日完成」这类标签会随日期漂移，
  /// 样张基线每过几天就会无故失败。
  final DateTime? now;

  const TaskCard({
    super.key,
    required this.task,
    required this.onStatusToggle,
    required this.onDelete,
    required this.onDoubleTap,
    required this.onEdit,
    this.onBackToPlanned,
    this.isDragging = false,
    this.onSubTaskChanged,
    this.attachments,
    this.onStopRepeat,
    this.glassVariant = GlassVariant.rim,
    this.now,
  });

  @override
  State<TaskCard> createState() => _TaskCardState();

  /// 状态文案（与颜色无关，保持 const）。
  static const Map<TaskStatus, String> statusLabels = {
    TaskStatus.planned: '计划中',
    TaskStatus.executing: '执行中',
    TaskStatus.completed: '已完成',
  };

  /// 紧急度主色：原来是一张 `static const Map`，const 表只能钉死一份色值，
  /// 浅色档就没法跟着主题走，所以改成按传入令牌现取。
  static Map<Urgency, Color> urgencyColors(GlassPalette g) => {
    Urgency.normal: g.urgencyNormal,
    Urgency.urgent: g.urgencyUrgent,
    Urgency.important: g.urgencyImportant,
  };

  /// 状态主色：同上。
  static Map<TaskStatus, Color> statusColors(GlassPalette g) => {
    TaskStatus.planned: g.statusPlanned,
    TaskStatus.executing: g.statusExecuting,
    TaskStatus.completed: g.statusCompleted,
  };

  /// 紧急度选中态的浅底：同上，随主题档取值。
  static Map<Urgency, Color> urgencyBgColors(GlassPalette g) => {
    Urgency.normal: g.urgencyBgNormal,
    Urgency.urgent: g.urgencyBgUrgent,
    Urgency.important: g.urgencyBgImportant,
  };
}

class _TaskCardState extends State<TaskCard> with TickerProviderStateMixin {
  bool _isHovered = false;
  bool _isOnDragHandle = false;
  bool _expanded = false;

  late final AnimationController _shatterController;
  bool _shattering = false;

  /// 子任务进度动画：勾选/取消都从当前值平滑过渡到新值
  late final AnimationController _progressController;

  /// 过期任务闪烁动画
  late final AnimationController _expiredCtrl;

  /// 是否过期：未完成且已过预计完成时间
  bool get _isExpired =>
      widget.task.status != TaskStatus.completed &&
      widget.task.dueAt != null &&
      widget.task.dueAt!.isBefore(widget.now ?? DateTime.now());

  static const int _foldThreshold = 180;
  bool get _isLongText => widget.task.title.length > _foldThreshold;

  @override
  void initState() {
    super.initState();
    _shatterController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 600),
    );
    _progressController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 450),
      value: _calcProgress(widget.task),
    );
    _expiredCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1150),
    );
    if (_isExpired) _expiredCtrl.repeat(reverse: true);
  }

  /// 计算子任务进度（已完成数 / 总数）
  static double _calcProgress(Task task) {
    final r = parseSubTasks(task.title);
    if (!r.hasSubTasks) return 0;
    final done = r.items.where((e) => e.done).length;
    return done / r.items.length;
  }

  @override
  void dispose() {
    _shatterController.dispose();
    _progressController.dispose();
    _expiredCtrl.dispose();
    super.dispose();
  }

  @override
  void didUpdateWidget(TaskCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    // GlobalKey 复用时，旧任务的碎裂 State 会被复用给新任务。
    // 如果 task 变了但 _shattering 还是 true，说明这个 State 是被复用的，
    // 必须重置，否则新任务会透明但占着布局高度（出现空位）。
    if (widget.task.id != oldWidget.task.id && _shattering) {
      _shattering = false;
      _shatterController.reset();
    }
    // 子任务进度变化：从当前值平滑动画到新值（勾选/取消双向）
    if (widget.task.title != oldWidget.task.title) {
      final newP = _calcProgress(widget.task);
      if (newP != _progressController.value) {
        _progressController.animateTo(newP, curve: Curves.easeInOut);
      }
    }
    // 过期闪烁启停（状态变化 / 时间跨过截止点）
    if (_isExpired) {
      if (!_expiredCtrl.isAnimating) _expiredCtrl.repeat(reverse: true);
    } else {
      if (_expiredCtrl.isAnimating) {
        _expiredCtrl.stop();
        _expiredCtrl.value = 1.0; // 归位为不透明，避免残留半透明
      }
    }
  }

  Future<void> _handleDelete() async {
    if (_shattering) return;
    final g = GlassPalette.of(context);
    // 先弹出确认对话框，用户确认后才播放删除动画
    // 循环任务提供两档删除：仅删除本期（循环继续）/ 停止循环并删除（彻底取消）
    final isRepeat = widget.task.repeatType > 0;
    final String? action;
    if (!isRepeat) {
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (dialogCtx) => AlertDialog(
          title: const Text('删除任务'),
          content: const Text('确定要删除这个任务吗？删除后不可恢复。'),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogCtx, false),
              child: const Text('取消'),
            ),
            TextButton(
              onPressed: () => Navigator.pop(dialogCtx, true),
              child: Text('删除', style: TextStyle(color: g.danger)),
            ),
          ],
        ),
      );
      if (confirmed != true || !mounted) return;
      action = 'delete';
    } else {
      final result = await showDialog<String>(
        context: context,
        builder: (dialogCtx) => AlertDialog(
          title: const Text('删除循环任务'),
          content: const Text(
            '「仅删除本期」：删除今天这一期，循环任务继续生成。\n\n'
            '「停止循环并删除」：彻底停止该循环任务，删除本期且以后不再生成。',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogCtx, 'cancel'),
              child: const Text('取消'),
            ),
            TextButton(
              onPressed: () => Navigator.pop(dialogCtx, 'delete_once'),
              child: const Text('仅删除本期'),
            ),
            TextButton(
              onPressed: () => Navigator.pop(dialogCtx, 'stop_repeat'),
              child: Text('停止循环并删除', style: TextStyle(color: g.danger)),
            ),
          ],
        ),
      );
      if (result == null || result == 'cancel' || !mounted) return;
      action = result;
    }

    setState(() => _shattering = true);
    _shatterController.forward().whenComplete(() {
      if (!mounted) return;
      if (action == 'stop_repeat') {
        widget.onStopRepeat?.call();
      } else {
        widget.onDelete();
      }
    });
  }

  String _fmt(DateTime? dt) {
    if (dt == null) return '';
    final t = dt.isUtc ? dt.toLocal() : dt;
    return '${t.month}/${t.day} ${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';
  }

  // ===== 循环任务徽章（标题行左侧，与标题同排）=====

  /// 循环徽章文案：日→每日；周→每周一、三、五；月→每月15日
  /// （与「循环任务」管理页共用同一套文案，避免两处不一致）
  String? get _repeatBadgeText {
    final t = widget.task;
    if (t.repeatType <= 0) return null;
    return repeatRuleLabel(
      repeatType: t.repeatType,
      weekDays: t.repeatWeekDays,
      monthDay: t.repeatMonthDay,
    );
  }

  /// 徽章悬浮提示：本期是哪天、下一次什么时候
  String get _repeatTooltip {
    final t = widget.task;
    final parts = <String>[];
    if (t.instanceDate != null) {
      parts.add('本期：${shortDateWithWeekday(t.instanceDate!)}');
    }
    final next = RepeatTaskEngine.nextInstanceDate(
      repeatType: t.repeatType,
      weekDays: t.repeatWeekDays,
      monthDay: t.repeatMonthDay,
      now: DateTime.now(),
      after: t.instanceDate,
    );
    if (next != null) {
      parts.add('下次：${formatDueDate(next, planStartAt: t.planStartAt)}');
    }
    return parts.isEmpty ? '循环任务' : parts.join(' · ');
  }

  /// 循环徽章：蓝色徽章效果（蓝框蓝字浅蓝底 + 循环图标），紧凑小尺寸
  Widget _buildRepeatBadge() {
    final g = GlassPalette.of(context);
    return Tooltip(
      message: _repeatTooltip,
      waitDuration: const Duration(milliseconds: 350),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
        decoration: BoxDecoration(
          color: g.repeatChipBg,
          border: Border.all(color: g.repeatChipBorder, width: 1),
          borderRadius: BorderRadius.circular(3),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.autorenew, size: 11, color: g.repeatChipIcon),
            const SizedBox(width: 2),
            Text(
              _repeatBadgeText!,
              style: TextStyle(
                fontSize: 11,
                color: g.repeatChipText,
                fontWeight: FontWeight.w500,
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// 期次日期：循环任务每一期都是"同标题的独立任务"，不标出日期的话
  /// 「每日」任务列表里今天这一期和昨天没做完的那一期长得一模一样。
  Widget _buildInstanceDateChip() {
    final g = GlassPalette.of(context);
    final d = widget.task.instanceDate!;
    return Tooltip(
      message: '本期日期：${shortDateWithWeekday(d)}',
      waitDuration: const Duration(milliseconds: 350),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
        decoration: BoxDecoration(
          color: g.chipBg,
          border: Border.all(color: g.chipBorder, width: 1),
          borderRadius: BorderRadius.circular(3),
        ),
        child: Text(
          shortDate(d),
          style: TextStyle(fontSize: 11, color: g.inkTertiary),
        ),
      ),
    );
  }

  /// 底部操作按钮（开始/完成/重开、回到计划中、修改、删除）。
  ///
  /// [compact] 为 true 时只显示图标（文字进 Tooltip），用于窄卡片，
  /// 保证和标签挤在同一行时不会被裁掉。
  Widget _buildActionButtons(bool compact, bool isDone, BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (widget.task.status == TaskStatus.executing &&
            widget.onBackToPlanned != null)
          _ActionButton(
            compact: compact,
            icon: Icons.undo,
            label: '回到计划中',
            onPressed: _isHovered
                ? () => widget.onBackToPlanned!(context)
                : null,
          ),
        _ActionButton(
          compact: compact,
          icon: isDone
              ? Icons.replay
              : widget.task.status == TaskStatus.planned
                  ? Icons.play_arrow
                  : Icons.check_circle_outline,
          label: isDone
              ? '重开'
              : widget.task.status == TaskStatus.planned
                  ? '开始'
                  : '完成',
          onPressed:
              _isHovered ? () => widget.onStatusToggle(context) : null,
        ),
        _ActionButton(
          compact: compact,
          icon: Icons.edit_outlined,
          label: '修改',
          onPressed: _isHovered ? widget.onEdit : null,
        ),
        _ActionButton(
          compact: compact,
          icon: Icons.delete_outline,
          label: '删除',
          onPressed: !_isHovered || _shattering ? null : _handleDelete,
        ),
      ],
    );
  }

  Widget _buildTitle(bool isDone, String title) {
    final g = GlassPalette.of(context);
    final style = TextStyle(
      fontSize: 15,
      height: 1.35,
      fontWeight: FontWeight.w500,
      decoration: isDone ? TextDecoration.lineThrough : null,
      decorationColor: g.inkTertiary,
      color: isDone ? g.inkFaint : g.ink,
    );
    if (!_isLongText) {
      return SelectableText(title, style: style);
    }
    final expanded = _expanded;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        AnimatedSize(
          duration: const Duration(milliseconds: 350),
          curve: Curves.easeInOut,
          alignment: Alignment.topCenter,
          child: ClipRect(
            child: Align(
              alignment: Alignment.topCenter,
              heightFactor: expanded ? 1.0 : null,
              child: expanded
                  ? SelectableText(title, style: style)
                  : ConstrainedBox(
                      constraints: const BoxConstraints(maxHeight: 80),
                      child: Text(title, style: style),
                    ),
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.only(top: 6, bottom: 2),
          child: Align(
            alignment: Alignment.centerRight,
            // 自绘的小按钮不走 Material 主题，光标得自己声明
            child: MouseRegion(
              cursor: SystemMouseCursors.click,
              child: GestureDetector(
                onTap: () => setState(() => _expanded = !_expanded),
                child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 2),
                decoration: BoxDecoration(
                  color: g.chipBg,
                  border: Border.all(color: g.chipBorder, width: 1),
                  borderRadius: BorderRadius.circular(3),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(expanded ? Icons.expand_less : Icons.expand_more,
                        size: 13, color: g.inkSecondary),
                    const SizedBox(width: 3),
                    Text(
                      expanded ? '收起' : '展开',
                      style: TextStyle(
                          fontSize: 11,
                          color: g.inkSecondary,
                          fontWeight: FontWeight.w400),
                    ),
                  ],
                ),
              ),
            ),
            ),
          ),
        ),
      ],
    );
  }

  /// 子任务进度条：标题下方 4px 高，属性色填充 + 波浪前沿，勾选/取消平滑动画
  Widget _buildProgressBar() {
    final g = GlassPalette.of(context);
    final color = TaskCard.urgencyColors(g)[widget.task.urgency]!;
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 2, 12, 0),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(2),
        child: SizedBox(
          height: 4,
          width: double.infinity,
          child: AnimatedBuilder(
            animation: _progressController,
            builder: (context, _) { 
              final pct = _progressController.value.clamp(0.0, 1.0);
              return Stack(
                fit: StackFit.expand,
                children: [
                  ColoredBox(color: g.trackBg),
                  Align(
                    alignment: Alignment.centerLeft,
                    child: FractionallySizedBox(
                      widthFactor: pct,
                      heightFactor: 1,
                      child: ClipPath(
                        clipper: const _WaveClipper(),
                        child: ColoredBox(color: color),
                      ),
                    ),
                  ),
                ],
              );
            },
          ),
        ),
      ),
    );
  }

  /// 子任务多选框列表（点击行切换完成状态）
  Widget _buildSubTaskList(SubTaskParseResult result) {
    return Padding(
      padding: const EdgeInsets.only(left: 14, right: 10, top: 2, bottom: 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (var i = 0; i < result.items.length; i++)
            _buildSubTaskRow(result, i),
        ],
      ),
    );
  }

  Widget _buildSubTaskRow(SubTaskParseResult result, int index) {
    final g = GlassPalette.of(context);
    final item = result.items[index];
    return InkWell(
      onTap: widget.onSubTaskChanged == null
          ? null
          : () => _toggleSubTask(result, index),
      // 可勾选的行要显示小手，否则用户看不出这一整行能点；
      // 没有勾选回调时保持箭头，避免"看着能点却点不动"。
      mouseCursor: widget.onSubTaskChanged == null
          ? SystemMouseCursors.basic
          : SystemMouseCursors.click,
      borderRadius: BorderRadius.circular(4),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 3),
        child: Row(
          children: [
            Icon(
              item.done
                  ? Icons.check_box
                  : Icons.check_box_outline_blank,
              size: 17,
              color: item.done
                  ? g.success
                  : g.inkTertiary,
            ),
            const SizedBox(width: 6),
            Expanded(
              child: MarqueeText(
                item.prefix != null ? '${item.prefix} ${item.text}' : item.text,
                style: TextStyle(
                  fontSize: 15,
                  color: item.done
                      ? g.inkFaint
                      : g.inkSecondary,
                  decoration:
                      item.done ? TextDecoration.lineThrough : null,
                  decorationColor: g.inkFaint,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  void _toggleSubTask(SubTaskParseResult result, int index) {
    final newTitle = setSubTaskDone(widget.task.title, index, !result.items[index].done);
    if (newTitle == widget.task.title) return;
    final updated = widget.task.copyWith(title: newTitle);
    widget.onSubTaskChanged?.call(updated);
  }

  // ===== 卡片单/双击手动识别（代替 DoubleTapGestureRecognizer，见 onTapUp 注释）=====
  DateTime? _lastCardTapAt;
  Offset? _lastCardTapPos;

  void _handleCardTapUp(TapUpDetails details) {
    final now = DateTime.now();
    final lastAt = _lastCardTapAt;
    final lastPos = _lastCardTapPos;
    _lastCardTapAt = now;
    _lastCardTapPos = details.localPosition;
    // 与框架双击判定一致：300ms 内、位移不超过 100 逻辑像素
    final isDoubleTap = lastAt != null &&
        now.difference(lastAt) < const Duration(milliseconds: 300) &&
        lastPos != null &&
        (details.localPosition - lastPos).distance < 100;
    if (isDoubleTap) {
      _lastCardTapAt = null;
      _lastCardTapPos = null;
      widget.onDoubleTap();
      return;
    }
    if (_isLongText && !_expanded) {
      setState(() => _expanded = true);
    }
  }

  @override
  Widget build(BuildContext context) {
    final g = GlassPalette.of(context);
    final isDone = widget.task.status == TaskStatus.completed;
    final borderColor = TaskCard.urgencyColors(g)[widget.task.urgency]!;
    final subResult = parseSubTasks(widget.task.title);

    return MouseRegion(
      onEnter: (_) => setState(() => _isHovered = true),
      onExit: (_) => setState(() {
        _isHovered = false;
        _isOnDragHandle = false;
      }),
      onHover: (event) {
        final dx = event.localPosition.dx;
        final onHandle = dx >= 12 && dx <= 22;
        if (onHandle != _isOnDragHandle) {
          setState(() => _isOnDragHandle = onHandle);
        }
      },
      cursor: (widget.isDragging || _isOnDragHandle)
          ? SystemMouseCursors.click
          : SystemMouseCursors.basic,
      child: GestureDetector(
        // 手动识别单/双击：不能用 onDoubleTap（DoubleTapGestureRecognizer），
        // 它会在抬起后 hold 住手势竞技场约 300ms，期间卡片内「开始/完成/修改/删除」
        // 按钮的点击全部被延迟，300ms 内连点还会被竞技场吞掉（首次点击看似失效）。
        onTapUp: _handleCardTapUp,
        child: Container(
          margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          child: Stack(
            clipBehavior: Clip.none,
            children: [
              AnimatedOpacity(
                opacity: _shattering ? 0.0 : 1.0,
                duration: const Duration(milliseconds: 80),
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 200),
                  curve: Curves.easeOut,
                  transform: Matrix4.translationValues(0, _isHovered ? -3 : 0, 0),
                  child: CustomPaint(
                    painter: CardShadowPainter(hovered: _isHovered, g: g),
                    child: GlassSurface(
                      hovered: _isHovered,
                      variant: widget.glassVariant,
                      child: Stack(
                        children: [

                      Padding(
                        padding: const EdgeInsets.only(left: 10),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            ListTile(
                              contentPadding: const EdgeInsets.symmetric(
                                  horizontal: 12, vertical: 2),
                              title: subResult.mainTitle.isEmpty
                                  ? null
                                  : Row(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.center,
                                      children: [
                                        if (_repeatBadgeText != null) ...[
                                          _buildRepeatBadge(),
                                          if (widget.task.instanceDate !=
                                              null) ...[
                                            const SizedBox(width: 3),
                                            _buildInstanceDateChip(),
                                          ],
                                          const SizedBox(width: 6),
                                        ],
                                        Expanded(
                                          child: _buildTitle(
                                              isDone, subResult.mainTitle),
                                        ),
                                      ],
                                    ),
                              subtitle: SelectableText(
                                '${TaskCard.statusLabels[widget.task.status]} · 创建 ${_fmt(widget.task.createdAt)}'
                                '${widget.task.startedAt != null ? ' · 开始 ${_fmt(widget.task.startedAt)}' : ''}'
                                '${widget.task.completedAt != null ? ' · 完成 ${_fmt(widget.task.completedAt)}' : ''}',
                                style: TextStyle(
                                    fontSize: 11,
                                    color: g.inkSecondary),
                              ),
                            ),
                            if (subResult.hasSubTasks) _buildProgressBar(),
                            if (subResult.hasSubTasks) _buildSubTaskList(subResult),
                            if (widget.attachments != null) widget.attachments!,
                            Padding(
                              padding: const EdgeInsets.only(
                                  left: 12, right: 6, bottom: 10),
                              child: LayoutBuilder(
                                builder: (context, box) {
                                  // 卡片变窄时，原来的固定 Row 会被外层 Stack 直接裁掉
                                  //（右侧按钮被切掉一半，且没有任何提示）。这里做两件事：
                                  // 1) 标签区改成 Expanded + Wrap：极端窄时换行而不是被裁；
                                  // 2) 窄于阈值时操作按钮切成纯图标 + 短文案，保证一行放得下。
                                  final compact = box.maxWidth < _kFooterCompact;
                                  return Row(
                                    children: [
                                      Expanded(
                                        child: Wrap(
                                          spacing: 6,
                                          runSpacing: 4,
                                          crossAxisAlignment:
                                              WrapCrossAlignment.center,
                                          children: [
                                            _TimeTag(
                                              text: _urgencyLabel(
                                                  widget.task.urgency),
                                              color: _urgencyColor(
                                                  widget.task.urgency, g),
                                            ),
                                            _TimeTag(
                                              text: _taskTypeLabel(
                                                  widget.task.taskType),
                                              color: _taskTypeColor(
                                                  widget.task.taskType, g),
                                            ),
                                            if (widget.task.planStartAt != null)
                                              _TimeTag(
                                                text: _dateLabel(
                                                    widget.task.planStartAt!,
                                                    '开始',
                                                    compact: compact,
                                                    now: widget.now),
                                                color: g.successSoft,
                                                icon: Icons.event_note,
                                              ),
                                            if (widget.task.dueAt != null)
                                              _TimeTag(
                                                text: _dateLabel(
                                                    widget.task.dueAt!,
                                                    '完成',
                                                    compact: compact,
                                                    now: widget.now),
                                                color: g.dangerSoft,
                                                icon: Icons.schedule,
                                              ),
                                          ],
                                        ),
                                      ),
                                      const SizedBox(width: 6),
                                      // 命中用状态开关、淡入只管视觉：
                                      // 否则淡入起始帧 RenderOpacity alpha==0 会跳过
                                      // 命中测试，hover 后立刻点击会落空。
                                      IgnorePointer(
                                        ignoring: !_isHovered,
                                        child: AnimatedOpacity(
                                          opacity: _isHovered ? 1.0 : 0.0,
                                          duration: const Duration(
                                              milliseconds: 250),
                                          curve: Curves.easeOut,
                                          child: AnimatedContainer(
                                            duration: const Duration(
                                                milliseconds: 250),
                                            curve: Curves.easeOut,
                                            transform: Matrix4.translationValues(
                                                0, _isHovered ? 0 : 2, 0),
                                            child: _buildActionButtons(
                                                compact, isDone, context),
                                          ),
                                        ),
                                      ),
                                    ],
                                  );
                                },
                              ),
                            ),
                          ],
                        ),
                      ),
                      // 紧急度色条：纯白卡保持原来的整条色块；
                      // 边缘光款改成内缩的细色条（4px + 渐变），更精致、不抢视线。
                      // 上下各让出 22px，和卡片圆角半径对齐，色条端点完全离开弧线区。
                      Positioned(
                        left: widget.glassVariant == GlassVariant.solid ? 0 : 4,
                        top: widget.glassVariant == GlassVariant.solid ? 0 : 22,
                        bottom: widget.glassVariant == GlassVariant.solid ? 0 : 22,
                        child: Container(
                          width: widget.glassVariant == GlassVariant.solid ? 10 : 4,
                          decoration: BoxDecoration(
                            color: widget.glassVariant == GlassVariant.solid
                                ? borderColor
                                : null,
                            gradient: widget.glassVariant == GlassVariant.solid
                                ? null
                                : LinearGradient(
                                    begin: Alignment.topCenter,
                                    end: Alignment.bottomCenter,
                                    colors: [borderColor, borderColor.withAlpha(150)],
                                  ),
                            borderRadius: BorderRadius.only(
                              topLeft: Radius.circular(
                                  widget.glassVariant == GlassVariant.solid ? 10 : 3),
                              bottomLeft: Radius.circular(
                                  widget.glassVariant == GlassVariant.solid ? 10 : 3),
                              topRight: Radius.circular(
                                  widget.glassVariant == GlassVariant.solid ? 0 : 3),
                              bottomRight: Radius.circular(
                                  widget.glassVariant == GlassVariant.solid ? 0 : 3),
                            ),
                          ),
                        ),
                      ),
                      // 过期印章：右上角方章（红框红字、轻微倾斜，随 _expiredCtrl 闪烁）
                      if (_isExpired)
                        Positioned(
                          top: 12,
                          right: 12,
                          child: FadeTransition(
                            opacity: _expiredCtrl.drive(
                              Tween(begin: 0.62, end: 1.0),
                            ),
                            child: Transform.rotate(
                              angle: -6 * 3.141592653589793 / 180,
                              child: Container(
                                alignment: Alignment.center,
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 6,
                                  vertical: 3,
                                ),
                                decoration: BoxDecoration(
                                  border: Border.all(
                                    color: g.overdueFg,
                                    width: 1.5,
                                  ),
                                  borderRadius: BorderRadius.circular(2),
                                ),
                                child: Text(
                                  '已过期',
                                  style: TextStyle(
                                    fontSize: 9,
                                    color: g.overdueFg,
                                    fontWeight: FontWeight.w800,
                                    letterSpacing: 1.5,
                                    height: 1.2,
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
              ),
              ),
              ),
              if (_shattering)
                Positioned.fill(
                  child: ShatterEffect(
                    animation: _shatterController,
                    accentColor: borderColor,
                    bgColor: Colors.transparent,
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 底部标签/操作区切换成"纯图标按钮"的宽度阈值。
///
/// 实测（线上字体 AlibabaPuHuiTi，四个标签全在的最坏情况，标签带日历/时钟图标）：
/// 标签 40.1 + 40.1 + 86.9 + 86.9 + 间距 18 = 272，三个文字按钮 57.1×3 = 171.3，
/// 加上中间 6px 间隔，**不带图标的最小完整布局 = 449.3px**；
/// 两个日期标签的图标（10 + 3）再要 26px，即 475.3px，取整留余量 = 476。
///
/// 可用宽度 = 窗口宽 − 24（卡片左右 margin）− 10（内容左内边距）− 18（底部内边距）：
/// - 默认窗口 530 → 478px → 「标签带图标 + 图标文字按钮」（余量 2px）
/// - 窗口 ≤ 528 → 放不下 → 先把只在 hover 时才出现的操作按钮收成纯图标，
///   常驻的标签不让步（它们才是天天看的内容）
/// - 最小窗口 420 → 368px → 短日期文案 + 图标按钮，四个标签仍在一行
const double _kFooterCompact = 476;

String _dateLabel(DateTime dt, String suffix,
    {bool compact = false, DateTime? now}) {
  final t = dt.isUtc ? dt.toLocal() : dt;
  final current = now ?? DateTime.now();
  final today = DateTime(current.year, current.month, current.day);
  final target = DateTime(t.year, t.month, t.day);
  final diff = target.difference(today).inDays;
  if (diff == 0) return '今天$suffix';
  if (diff == 1) return '明天$suffix';
  if (diff == 2) return '后天$suffix';
  // 紧凑模式用 11/2 代替 11月2日，每个标签省 2 个字宽
  return compact ? '${t.month}/${t.day}$suffix' : '${t.month}月${t.day}日$suffix';
}

String _urgencyLabel(Urgency u) {
  switch (u) {
    case Urgency.normal: return '一般';
    case Urgency.important: return '重要';
    case Urgency.urgent: return '紧急';
  }
}

Color _urgencyColor(Urgency u, GlassPalette g) {
  switch (u) {
    case Urgency.normal: return g.success;
    case Urgency.important: return g.warning;
    case Urgency.urgent: return g.danger;
  }
}

String _taskTypeLabel(int type) {
  switch (type) {
    case 0: return '个人';
    case 1:
    default: return '工作';
  }
}

Color _taskTypeColor(int type, GlassPalette g) {
  switch (type) {
    case 0: return g.success;
    case 1:
    default: return g.accentText;
  }
}

/// 底部标签的玻璃浮起胶囊。
///
/// 质感来自光影三件套而不是描边：顶部受光（语义色掺白）→ 中段语义淡染 → 底部收深，
/// 外面再压一层 1px 软投影让胶囊离开纸面；描边只勾轮廓（alpha 72/87，改造前是 190，
/// 四个标签全靠粗线撑形，看着像线框表）。
///
/// [icon] 给时间标签用：日历=计划开始，时钟=计划完成，一眼分得清两个日期谁是谁。
class _TimeTag extends StatelessWidget {
  final String text;
  final Color color;
  final IconData? icon;
  const _TimeTag({required this.text, required this.color, this.icon});

  @override
  Widget build(BuildContext context) {
    final g = GlassPalette.of(context);
    return Container(
      // 带图标时左边收 2px：图标本身自带视觉留白，不留这一档四个标签挤不进默认窗口宽
      padding: icon == null
          ? const EdgeInsets.symmetric(horizontal: 8, vertical: 2)
          : const EdgeInsets.fromLTRB(6, 2, 8, 2),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          stops: const [0, .3, 1],
          colors: [
            Color.lerp(color, g.rimTopLine, .5)!.withAlpha(58),
            color.withAlpha(38),
            color.withAlpha(20),
          ],
        ),
        border: Border.all(
          color: color.withAlpha(g.isLight ? 72 : 87),
          width: 1,
        ),
        borderRadius: BorderRadius.circular(9.5),
        boxShadow: [
          BoxShadow(
            color: g.shadow.withAlpha(26),
            blurRadius: 4,
            offset: const Offset(0, 1),
          ),
        ],
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (icon != null) ...[
            Icon(icon, size: 10, color: color),
            const SizedBox(width: 3),
          ],
          Text(
            text,
            style: TextStyle(
                fontSize: 11, color: color, fontWeight: FontWeight.w500),
          ),
        ],
      ),
    );
  }
}

class _ActionButton extends StatelessWidget {
  final IconData icon;
  final String label;

  /// 为 null 时按钮禁用：不响应点击，也不会被 Tab 聚焦
  ///（隐藏的操作按钮必须禁用，否则不可见但可点、可聚焦）
  final VoidCallback? onPressed;

  /// 窄卡片模式：只显示图标，文字放进 Tooltip（同时作为无障碍标签）
  final bool compact;

  const _ActionButton({
    required this.icon,
    required this.label,
    required this.onPressed,
    this.compact = false,
  });

  @override
  Widget build(BuildContext context) {
    final g = GlassPalette.of(context);
    final button = TextButton(
      onPressed: onPressed,
      style: TextButton.styleFrom(
        foregroundColor: g.inkSecondary,
        disabledForegroundColor: g.inkFaint,
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
        minimumSize: const Size(0, 28),
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
      ),
      // 字号/字重写在 Text 上而不是 style.textStyle 里：styleFrom 的 textStyle
      // 会整份替换按钮的 DefaultTextStyle（fontFamily 变成 null），导致这几个
      // 标签一直没跟随 App 主题字体。只覆盖字号字重即可继续继承字体。
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 14),
          if (!compact) ...[
            const SizedBox(width: 2),
            Text(
              label,
              style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w400),
            ),
          ],
        ],
      ),
    );
    if (!compact) return button;
    return Tooltip(
      message: label,
      waitDuration: const Duration(milliseconds: 300),
      child: button,
    );
  }
}

/// 进度条波浪前沿裁剪器：色块右侧边缘呈波浪形（3 段起伏）
class _WaveClipper extends CustomClipper<Path> {
  const _WaveClipper();

  static const int _waveCount = 3;
  static const double _waveWidth = 12;
  static const double _waveHeight = 1.5;

  @override
  Path getClip(Size size) {
    final path = Path()..moveTo(0, 0);
    final leftEdge = size.width - _waveCount * _waveWidth;
    path.lineTo(leftEdge < 0 ? 0 : leftEdge, 0);
    // 右侧波浪：从顶部交替峰谷向下
    var x = leftEdge < 0 ? 0.0 : leftEdge;
    var peak = true;
    while (x < size.width - 0.5) {
      final segment = (size.width - x) < _waveWidth ? (size.width - x) : _waveWidth;
      path.quadraticBezierTo(
        x + segment / 2,
        peak ? -_waveHeight : _waveHeight,
        x + segment,
        0,
      );
      x += segment;
      peak = !peak;
    }
    path.lineTo(size.width, size.height);
    path.lineTo(0, size.height);
    path.close();
    return path;
  }

  @override
  bool shouldReclip(covariant _WaveClipper oldClipper) => false;
}
