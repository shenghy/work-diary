import 'package:flutter/material.dart';

import '../models/stats.dart';
import '../theme/glass_palette.dart';
import '../widgets/glass_surface.dart';
import '../widgets/stats_charts.dart';

/// 指标卡之间的缝。
const double _metricGap = 14;

/// 指标卡排几列。
///
/// 设计图那张是 400 逻辑宽的窗口，四张卡在那里就是 2×2、单卡约 175。
/// 按「单卡不小于 150」反推列数，窗口拉宽时卡片保持同样的比例，而不是被
/// 拉成一条横杠；用 floor 而不是 round，窄窗口只会退成一列，不会突然三列。
int _metricColumns(double width) =>
    ((width + _metricGap) / (150 + _metricGap)).floor().clamp(1, 4);

/// 「我的数据」看板。
///
/// 玻璃效果沿用全局那层：main.dart 已经做了整窗模糊，这里每张卡只用
/// [GlassSurface] 染色，绝不再各自套 BackdropFilter（当年就是为这个掉的帧）。
class StatsScreen extends StatefulWidget {
  const StatsScreen({
    super.key,
    required this.loadSnapshot,
    required this.onBack,
    this.animateEntrance = false,
    this.entranceController,
    this.refreshTick = 0,
    this.initialRange = StatsRange.last7,
    this.onRangeChanged,
  });

  /// 数据由外部注入：桌面端从本地任务聚合，将来换成云端响应也不用改这个页面。
  final Future<StatsSnapshot> Function(StatsRange range) loadSnapshot;
  final VoidCallback onBack;

  /// 复用主页的入场动画控制器，切 tab 和进看板的手感保持一致。
  final bool animateEntrance;
  final AnimationController? entranceController;

  /// 外部（主页 F5 / 任务变更后）想强制重算一次就把它 +1。
  final int refreshTick;

  /// 进入时的时间范围；主页把它存成会话状态，返回再进来就还是上次选的。
  final StatsRange initialRange;
  final ValueChanged<StatsRange>? onRangeChanged;

  @override
  State<StatsScreen> createState() => _StatsScreenState();
}

class _StatsScreenState extends State<StatsScreen>
    with SingleTickerProviderStateMixin {
  late StatsRange _range = widget.initialRange;
  StatsSnapshot? _snapshot;
  bool _loading = true;
  bool _showMethod = false;
  late final AnimationController _pulse = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 900),
  );

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _pulse.dispose();
    super.dispose();
  }

  @override
  void didUpdateWidget(covariant StatsScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.refreshTick != oldWidget.refreshTick) _load();
  }

  Future<void> _load({StatsRange? range}) async {
    if (range != null) _range = range;
    setState(() => _loading = true);
    // 骨架屏才是唯一需要呼吸动画的地方：有数据时别让它空转（耗电也占帧）。
    if (_snapshot == null) _pulse.repeat(reverse: true);
    final snapshot = await widget.loadSnapshot(_range);
    if (!mounted) return;
    _pulse.stop();
    setState(() {
      _snapshot = snapshot;
      _loading = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final wide = constraints.maxWidth >= 900;
        final padding = MediaQuery.of(context).size.width < 520 ? 14.0 : 22.0;
        final snapshot = _snapshot;
        final content = snapshot == null
            ? _Skeleton(pulse: _pulse, wide: wide)
            : _body(snapshot, wide: wide);
        return Column(
          children: [
            _header(horizontalPadding: padding),
            Expanded(
              // 切换范围时保留旧数字并压到 40% 透明度，而不是先清空再闪一次。
              child: AnimatedOpacity(
                opacity: (_loading && snapshot != null) ? 0.4 : 1,
                duration: const Duration(milliseconds: 180),
                child: SingleChildScrollView(
                  padding: EdgeInsets.fromLTRB(padding, 18, padding, 112),
                  child: Center(
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 1120),
                      child: AnimatedSwitcher(
                        duration: const Duration(milliseconds: 300),
                        switchInCurve: Curves.easeOut,
                        child: KeyedSubtree(
                          key: ValueKey('${_range.name}:$snapshot'),
                          child: content,
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ],
        );
      },
    );
  }

  Widget _body(StatsSnapshot snapshot, {required bool wide}) {
    final blocks = <Widget>[
      _metrics(snapshot),
      if (wide)
        _row(_trendCard(snapshot), _compositionCard(snapshot))
      else ...[
        _trendCard(snapshot),
        _compositionCard(snapshot),
      ],
      if (wide)
        _row(_heatmapCard(snapshot), _repeatCard(snapshot))
      else ...[
        _heatmapCard(snapshot),
        _repeatCard(snapshot),
      ],
      _hoursCard(snapshot),
      _footer(snapshot),
    ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (var i = 0; i < blocks.length; i++)
          widget.animateEntrance
              ? _Entrance(
                  controller: widget.entranceController,
                  index: i,
                  total: blocks.length,
                  child: Padding(
                    padding: EdgeInsets.only(bottom: i == blocks.length - 1 ? 0 : 14),
                    child: blocks[i],
                  ),
                )
              : Padding(
                  padding: EdgeInsets.only(bottom: i == blocks.length - 1 ? 0 : 14),
                  child: blocks[i],
                ),
      ],
    );
  }

  // ==================== 页头 ====================

  Widget _header({required double horizontalPadding}) {
    return Padding(
      padding: EdgeInsets.fromLTRB(horizontalPadding, 10, horizontalPadding, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              IconButton(
                onPressed: widget.onBack,
                icon: const Icon(Icons.arrow_back_rounded, size: 20),
                color: GlassPalette.of(context).inkSecondary,
                tooltip: '返回',
              ),
              const SizedBox(width: 4),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '我的数据',
                      style: TextStyle(
                        fontSize: 24,
                        fontWeight: FontWeight.w700,
                        color: GlassPalette.of(context).ink,
                        height: 1.2,
                      ),
                    ),
                    SizedBox(height: 2),
                    Text(
                      '让每一份努力，都成为看得见的成果',
                      style: TextStyle(
                        fontSize: 13,
                        color: GlassPalette.of(context).inkSecondary,
                      ),
                    ),
                  ],
                ),
              ),
              IconButton(
                onPressed: _loading ? null : () => _load(),
                icon: const Icon(Icons.refresh, size: 19),
                color: GlassPalette.of(context).inkSecondary,
                tooltip: '刷新（F5）',
              ),
            ],
          ),
          const SizedBox(height: 16),
          _rangePills(),
        ],
      ),
    );
  }

  Widget _rangePills() {
    return Container(
      height: 42,
      padding: const EdgeInsets.all(4),
      decoration: BoxDecoration(
        color: GlassPalette.of(context).chipBg,
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: GlassPalette.of(context).chipBorder),
      ),
      child: Row(
        children: [
          for (final range in StatsRange.values)
            Expanded(
              child: GestureDetector(
                // 命中区保持整槽（点两个字中间也要能切），只有高亮收成文字宽度。
                onTap: () {
                  // 需求 2：返回再进来还是上次选的范围 —— 由主页存，页面自己不留全局态。
                  widget.onRangeChanged?.call(range);
                  _load(range: range);
                },
                child: MouseRegion(
                  cursor: SystemMouseCursors.click,
                  child: Center(child: _rangePill(range)),
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _rangePill(StatsRange range) {
    final selected = range == _range;
    return AnimatedContainer(
      duration: const Duration(milliseconds: 200),
      curve: Curves.easeOut,
      alignment: Alignment.center,
      // 设计图里高亮只包住文字，不是把 1/4 槽位整个涂满。
      height: 32,
      padding: EdgeInsets.symmetric(horizontal: 11),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(999),
        gradient: selected
            ? LinearGradient(
                colors: [
                  GlassPalette.of(context).statsPrimarySoft,
                  GlassPalette.of(context).statsPrimary,
                ],
              )
            : null,
        boxShadow: selected
            ? [
                BoxShadow(
                  color: GlassPalette.of(context).statsPrimary,
                  blurRadius: 16,
                  offset: Offset(0, 6),
                ),
              ]
            : null,
      ),
      child: Text(
        range.label,
        style: TextStyle(
          fontSize: 14,
          fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
          color: selected ? Colors.white : GlassPalette.of(context).inkSecondary,
        ),
      ),
    );
  }

  // ==================== ① 核心指标 ====================

  Widget _metrics(StatsSnapshot snapshot) {
    final s = snapshot.summary;
    final change = s.changePercent;
    final finish = s.finishDuration;
    final cards = <_MetricData>[
      _MetricData(
        dot: GlassPalette.of(context).statsTeal,
        label: '已完成任务',
        value: '${s.completed}',
        unit: '个',
        sub: change == null
            ? '上周期暂无数据'
            : '较上周期 ${change > 0 ? '+' : ''}$change%',
        subColor: change == null
            ? null
            : (change >= 0 ? GlassPalette.of(context).success : GlassPalette.of(context).statsPink),
      ),
      _MetricData(
        dot: GlassPalette.of(context).statsPrimary,
        label: '完成率',
        value: s.completionRate == null ? '--' : '${s.completionRate}',
        unit: s.completionRate == null ? '' : '%',
        sub: '应完成 ${s.dueTotal} 个 · 未完成 ${s.undone}',
        hint: s.isSparse && s.dueTotal > 0 ? '样本较少' : null,
      ),
      _MetricData(
        dot: GlassPalette.of(context).statsAmber,
        label: '连续打卡',
        value: '${s.streakDays}',
        unit: '天',
        sub: '历史最长 ${s.streakBest} 天',
      ),
      _MetricData(
        dot: GlassPalette.of(context).statsPink,
        label: '平均完成耗时',
        value: finish.value,
        unit: finish.unit,
        sub: s.fastestMinutes == null || s.slowestDays == null
            ? '样本不足 3 条'
            : '最快 ${StatsSummary.durationText(s.fastestMinutes!.toDouble())}'
                ' · 最慢 ${StatsSummary.durationText(s.slowestDays! * 1440)}',
      ),
    ];

    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth;
        final columns = _metricColumns(width);
        final gap = _metricGap;
        final cardWidth = (width - gap * (columns - 1)) / columns;
        return Wrap(
          spacing: gap,
          runSpacing: gap,
          children: [for (final card in cards) _MetricCard(card: card, width: cardWidth)],
        );
      },
    );
  }

  // ==================== ② 任务趋势 ====================

  Widget _trendCard(StatsSnapshot snapshot) {
    final trend = snapshot.trend;
    return _GlassCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _SectionHead(
            title: '任务趋势',
            tag: snapshot.range.byWeek ? '按周聚合' : '每日新建 / 完成',
            trailing: snapshot.range.label,
          ),
          SizedBox(height: 10),
          Wrap(
            spacing: 16,
            runSpacing: 6,
            children: [
              _LegendDot(color: GlassPalette.of(context).statsPrimary, label: '新建'),
              _LegendDot(color: GlassPalette.of(context).statsTeal, label: '完成'),
              _LegendDot(color: GlassPalette.of(context).statsAmber, label: '完成率'),
            ],
          ),
          const SizedBox(height: 8),
          Stack(
            alignment: Alignment.center,
            children: [
              TrendChart(trend: trend, height: 190),
              if (trend.isEmpty)
                const Padding(
                  padding: EdgeInsets.only(bottom: 24),
                  child: _EmptyHint(text: '这段时间还没有记录'),
                ),
            ],
          ),
        ],
      ),
    );
  }

  // ==================== ③ 任务构成 ====================

  Widget _compositionCard(StatsSnapshot snapshot) {
    final total = snapshot.completedTotal;
    return _GlassCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const _SectionHead(
            title: '任务构成',
            tag: '类型 / 紧急度',
          ),
          const SizedBox(height: 14),
          Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              DonutChart(
                work: snapshot.workCount,
                personal: snapshot.personalCount,
                percent: snapshot.workShare,
              ),
              const SizedBox(width: 18),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _typeLine(GlassPalette.of(context).statsPrimary, '工作', snapshot.workCount),
                    const SizedBox(height: 8),
                    _typeLine(GlassPalette.of(context).statsTeal, '个人', snapshot.personalCount),
                    const SizedBox(height: 8),
                    _typeLine(null, '合计', total),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          for (var level = 0; level < snapshot.urgencyCounts.length; level++)
            Padding(
              padding: EdgeInsets.only(bottom: level == 2 ? 0 : 10),
              child: _urgencyBar(
                label: const ['一般', '紧急', '重要'][level],
                count: snapshot.urgencyCounts[level],
                total: total,
              ),
            ),
        ],
      ),
    );
  }

  Widget _typeLine(Color? color, String label, int count) {
    return Row(
      children: [
        if (color != null) ...[
          Container(
            width: 9,
            height: 9,
            decoration: BoxDecoration(color: color, borderRadius: BorderRadius.circular(3)),
          ),
          const SizedBox(width: 8),
        ] else
          const SizedBox(width: 17),
        Text(
          label,
          style: TextStyle(
            fontSize: 13,
            color: color == null ? GlassPalette.of(context).inkTertiary : GlassPalette.of(context).ink,
            fontWeight: color == null ? FontWeight.w400 : FontWeight.w500,
          ),
        ),
        // 设计图的数字紧跟在标签后面（三个标签都是两个字，天然对齐），
        // 用 Spacer 顶到最右反而和环形图抢宽度。
        const SizedBox(width: 18),
        Text(
          '$count',
          style: TextStyle(
            fontSize: 13,
            color: GlassPalette.of(context).ink,
            fontFeatures: [FontFeature.tabularFigures()],
          ),
        ),
      ],
    );
  }

  Widget _urgencyBar({
    required String label,
    required int count,
    required int total,
  }) {
    final share = total == 0 ? 0.0 : (count / total).clamp(0.0, 1.0);
    final colors = switch (label) {
      '紧急' => [GlassPalette.of(context).statsAmber, GlassPalette.of(context).statsAmber],
      '重要' => [GlassPalette.of(context).statsPink, GlassPalette.of(context).statsPink],
      _ => [GlassPalette.of(context).statsTeal, GlassPalette.of(context).statsPrimary],
    };
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Text(
              label,
              style: TextStyle(fontSize: 12, color: GlassPalette.of(context).inkSecondary),
            ),
            const Spacer(),
            Text(
              total == 0 ? '--' : '$count 个 · ${(share * 100).round()}%',
              style: TextStyle(
                fontSize: 12,
                color: GlassPalette.of(context).inkTertiary,
                fontFeatures: [FontFeature.tabularFigures()],
              ),
            ),
          ],
        ),
        const SizedBox(height: 6),
        LayoutBuilder(
          builder: (context, constraints) => Stack(
            children: [
              // 设计图里先铺一条通宽的槽，彩色只填到占比处——没有槽的话
              // 短条看着像被截断了，长条也读不出「离 100% 还差多少」。
              Container(
                height: 7,
                decoration: BoxDecoration(
                  color: GlassPalette.of(context).trackBg,
                  borderRadius: BorderRadius.circular(999),
                ),
              ),
              AnimatedContainer(
                duration: const Duration(milliseconds: 300),
                height: 7,
                width: (constraints.maxWidth * share).clamp(0.0, constraints.maxWidth),
                decoration: BoxDecoration(
                  gradient: LinearGradient(colors: colors),
                  borderRadius: BorderRadius.circular(999),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  // ==================== ④ 活跃热力图 ====================

  Widget _heatmapCard(StatsSnapshot snapshot) {
    return _GlassCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const _SectionHead(
            title: '活跃热力图',
            tag: '近 12 周 · 每日完成任务数',
            trailing: '悬停看当天',
          ),
          const SizedBox(height: 14),
          LayoutBuilder(
            builder: (context, constraints) {
              // 设计图里格子正好铺满卡片内宽：宽度跟着卡片走，窗口宽到一定程度
              // 就封顶再居中，别让它长成一条横杠。只有窄到装不下才横向滚动。
              const spacing = 5.0;
              final fit = (constraints.maxWidth + spacing) / StatsHeatmap.weeks - spacing;
              final cell = fit.clamp(10.0, 30.0);
              final grid = Center(
                child: HeatGrid(
                  heatmap: snapshot.heatmap,
                  cellSize: cell,
                  cellHeight: cell * 1.2,
                  spacing: spacing,
                ),
              );
              final gridWidth = StatsHeatmap.weeks * (cell + spacing) - spacing;
              if (gridWidth <= constraints.maxWidth) return grid;
              return SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: grid,
              );
            },
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Text('少',
                  style: TextStyle(fontSize: 11, color: GlassPalette.of(context).inkTertiary)),
              const SizedBox(width: 6),
              for (var level = 0; level < GlassPalette.of(context).heatScale.length; level++)
                Padding(
                  padding: const EdgeInsets.only(right: 3),
                  child: Container(
                    width: 11,
                    height: 11,
                    decoration: BoxDecoration(
                      color: GlassPalette.of(context).heatScale[level],
                      borderRadius: BorderRadius.circular(3),
                    ),
                  ),
                ),
              const SizedBox(width: 3),
              Text('多',
                  style: TextStyle(fontSize: 11, color: GlassPalette.of(context).inkTertiary)),
              const Spacer(),
              Text(
                snapshot.heatmap.isEmpty
                    ? '近 12 周还没有完成记录'
                    : '单日最高 ${snapshot.heatmap.max} 个',
                style: TextStyle(
                    fontSize: 11, color: GlassPalette.of(context).inkTertiary),
              ),
            ],
          ),
        ],
      ),
    );
  }

  // ==================== ⑤ 循环任务按期率 ====================

  Widget _repeatCard(StatsSnapshot snapshot) {
    return _GlassCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const _SectionHead(
            title: '循环任务按期率',
            tag: '本期是否按期完成',
          ),
          const SizedBox(height: 16),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              for (final item in snapshot.repeatRate)
                Expanded(child: _repeatColumn(item)),
            ],
          ),
          const SizedBox(height: 14),
          Text(
            '数据口径与「已完成」tab 角标完全一致',
            style: TextStyle(fontSize: 11, color: GlassPalette.of(context).inkFaint),
          ),
        ],
      ),
    );
  }

  Widget _repeatColumn(RepeatRateItem item) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          item.label,
          style: TextStyle(fontSize: 12, color: GlassPalette.of(context).inkSecondary),
        ),
        const SizedBox(height: 6),
        Row(
          crossAxisAlignment: CrossAxisAlignment.baseline,
          textBaseline: TextBaseline.alphabetic,
          children: [
            Text(
              item.rate == null ? '--' : '${item.rate}',
              style: TextStyle(
                fontSize: 26,
                fontWeight: FontWeight.w700,
                color: GlassPalette.of(context).ink,
                height: 1,
                fontFeatures: [FontFeature.tabularFigures()],
              ),
            ),
            if (item.rate != null)
              Padding(
                padding: EdgeInsets.only(left: 2),
                child: Text('%',
                    style: TextStyle(fontSize: 13, color: GlassPalette.of(context).inkTertiary)),
              ),
          ],
        ),
        const SizedBox(height: 4),
        Text(
          item.total == 0 ? '本期无排期' : '${item.done} / ${item.total} 期',
          style: TextStyle(
            fontSize: 11.5,
            color: GlassPalette.of(context).inkTertiary,
            fontFeatures: [FontFeature.tabularFigures()],
          ),
        ),
      ],
    );
  }

  // ==================== ⑥ 专注时段分布 ====================

  Widget _hoursCard(StatsSnapshot snapshot) {
    return _GlassCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const _SectionHead(
            title: '专注时段分布',
            tag: '按完成时刻的小时聚合',
          ),
          const SizedBox(height: 14),
          HoursChart(hours: snapshot.hours, height: 150),
          const SizedBox(height: 10),
          Text(
            _peakText(snapshot),
            style: TextStyle(
              fontSize: 12.5,
              height: 1.5,
              color: GlassPalette.of(context).inkSecondary,
            ),
          ),
        ],
      ),
    );
  }

  String _peakText(StatsSnapshot snapshot) {
    final start = snapshot.peakStartHour;
    final end = snapshot.peakEndHour;
    if (start == null || end == null) return '还没有足够数据，先完成几个任务吧';
    // 连接符用半角而不是 en dash：普惠体 3 的 cmap 里没有 U+2013，
    // 之前这里渲染成一个空洞（「早晨 08:00   10:00」）。
    final text = '${_dayPart(start)} ${_hourLabel(start)}-${_hourLabel(end)} '
        '是你完成任务最集中的时段';
    final share = snapshot.peakUrgentShare;
    if (share != null && share >= 50) {
      return '$text，这两个时段完成的紧急 / 重要任务占该时段 $share%';
    }
    return text;
  }

  static String _hourLabel(int hour) =>
      '${hour.toString().padLeft(2, '0')}:00';

  static String _dayPart(int hour) {
    if (hour < 6) return '凌晨';
    if (hour < 9) return '早晨';
    if (hour < 12) return '上午';
    if (hour < 14) return '中午';
    if (hour < 18) return '下午';
    if (hour < 22) return '晚上';
    return '深夜';
  }

  // ==================== 页脚：数据口径 ====================

  Widget _footer(StatsSnapshot snapshot) {
    return _GlassCard(
      padding: const EdgeInsets.fromLTRB(18, 14, 18, 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  '统计基于本账号所有未删除任务；完成时间以本机时间为准；'
                  '跨天任务按完成当天计入。',
                  style: TextStyle(
                    fontSize: 11.5,
                    height: 1.5,
                    color: GlassPalette.of(context).inkTertiary,
                  ),
                ),
              ),
              const SizedBox(width: 10),
              MouseRegion(
                cursor: SystemMouseCursors.click,
                child: GestureDetector(
                  onTap: () => setState(() => _showMethod = !_showMethod),
                  child: Row(
                    children: [
                      Text(
                        _showMethod ? '收起口径' : '了解口径',
                        style: TextStyle(
                            fontSize: 12, color: GlassPalette.of(context).statsPrimarySoft),
                      ),
                      Icon(
                        _showMethod
                            ? Icons.expand_less
                            : Icons.expand_more,
                        size: 16,
                        color: GlassPalette.of(context).statsPrimarySoft,
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
          if (_showMethod) ...[
            const SizedBox(height: 10),
            Text(
              _methodText,
              style: TextStyle(
                fontSize: 11.5,
                height: 1.7,
                color: GlassPalette.of(context).inkSecondary,
              ),
            ),
          ],
          const SizedBox(height: 6),
          Text(
            '统计时间 ${_formatStamp(snapshot.generatedAt)}',
            style: TextStyle(
                fontSize: 11, color: GlassPalette.of(context).inkFaint),
          ),
        ],
      ),
    );
  }

  static String _formatStamp(DateTime value) =>
      '${value.month.toString().padLeft(2, '0')}/${value.day.toString().padLeft(2, '0')} '
      '${value.hour.toString().padLeft(2, '0')}:${value.minute.toString().padLeft(2, '0')}';

  static const String _methodText =
      '已完成数：状态为「已完成」且完成时刻落在统计窗口内的任务数（不含已删除）。\n'
      '应完成数：到期日落在窗口内的任务数；没有到期日的按创建日计入。\n'
      '完成率 = 已完成数 / 应完成数，应完成数为 0 时显示 --。\n'
      '连续打卡：从今天（或昨天）往前，连续有至少 1 个完成的天数；今天还没完成不会清零。\n'
      '平均完成耗时：完成时刻减创建时刻的中位数，剔除超过 30 天的异常值；样本不足 3 条显示 --。\n'
      '环比：与上一个等长窗口比较，上一窗口没有数据时不显示。\n'
      '循环按期：本期已完成且完成时刻不晚于到期时刻记为按期；被跳过的期次与没有到期日的期次不计入分母。\n'
      '时段分布：按完成时刻的本地小时聚合，热力图固定近 12 周，不随时间范围变化。';

  // ==================== 布局小工具 ====================

  Widget _row(Widget left, Widget right) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(child: left),
        const SizedBox(width: 14),
        Expanded(child: right),
      ],
    );
  }
}

/// 卡片外壳：阴影画在外层，玻璃材质交给 [GlassSurface]。
class _GlassCard extends StatelessWidget {
  const _GlassCard({required this.child, this.padding = const EdgeInsets.fromLTRB(18, 16, 18, 18)});

  final Widget child;
  final EdgeInsetsGeometry padding;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(GlassStyle.radius),
        boxShadow: [
          BoxShadow(
            color: GlassPalette.of(context).shadow,
            blurRadius: 44,
            offset: Offset(0, 18),
          ),
        ],
      ),
      child: GlassSurface(
        variant: GlassVariant.lift,
        child: Padding(padding: padding, child: child),
      ),
    );
  }
}

class _SectionHead extends StatelessWidget {
  const _SectionHead({
    required this.title,
    this.tag,
    this.trailing,
  });

  final String title;
  final String? tag;
  final String? trailing;

  @override
  Widget build(BuildContext context) {
    // 标题+标签整组吃满剩余宽度，尾注靠右。之前尾注用 Spacer 和标签的
    // Flexible 抢空间，400 宽下「近 12 周 · 每日完成任务数」被挤到省略号。
    // 标题也不能给 Flexible：Row 是按 flex 份数封顶的，两个 Flexible 各拿
    // 一半，标题用不完的不会让给标签，标签照样被截。
    return Row(
      children: [
        Expanded(
          child: Row(
            children: [
              Text(
                title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 15,
                  fontWeight: FontWeight.w600,
                  color: GlassPalette.of(context).ink,
                ),
              ),
              if (tag != null) ...[
                const SizedBox(width: 8),
                Flexible(
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                    decoration: BoxDecoration(
                      color: GlassPalette.of(context).chipBg,
                      borderRadius: BorderRadius.circular(999),
                      border: Border.all(color: GlassPalette.of(context).chipBorder),
                    ),
                    child: Text(
                      tag!,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                          fontSize: 11, color: GlassPalette.of(context).inkTertiary),
                    ),
                  ),
                ),
              ],
            ],
          ),
        ),
        if (trailing != null) ...[
          const SizedBox(width: 10),
          Text(
            trailing!,
            style: TextStyle(
                fontSize: 11.5, color: GlassPalette.of(context).inkTertiary),
          ),
        ],
      ],
    );
  }
}

class _LegendDot extends StatelessWidget {
  const _LegendDot({required this.color, required this.label});

  final Color color;
  final String label;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 8,
          height: 8,
          decoration: BoxDecoration(color: color, shape: BoxShape.circle),
        ),
        const SizedBox(width: 5),
        Text(label,
            style: TextStyle(
                fontSize: 11.5, color: GlassPalette.of(context).inkSecondary)),
      ],
    );
  }
}

class _EmptyHint extends StatelessWidget {
  const _EmptyHint({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
      decoration: BoxDecoration(
        color: GlassPalette.of(context).shadow.withAlpha(60),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Text(
        text,
        style: TextStyle(fontSize: 12, color: GlassPalette.of(context).inkTertiary),
      ),
    );
  }
}

class _MetricData {
  const _MetricData({
    required this.dot,
    required this.label,
    required this.value,
    required this.unit,
    required this.sub,
    this.subColor,
    this.hint,
  });

  final Color dot;
  final String label;
  final String value;
  final String unit;
  final String sub;
  final Color? subColor;
  final String? hint;
}

class _MetricCard extends StatelessWidget {
  const _MetricCard({required this.card, required this.width});

  final _MetricData card;
  final double width;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: width,
      child: _GlassCard(
        padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  width: 7,
                  height: 7,
                  decoration:
                      BoxDecoration(color: card.dot, shape: BoxShape.circle),
                ),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    card.label,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                        fontSize: 12.5, color: GlassPalette.of(context).inkSecondary),
                  ),
                ),
                if (card.hint != null)
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                    decoration: BoxDecoration(
                      color: GlassPalette.of(context).chipBg,
                      borderRadius: BorderRadius.circular(999),
                    ),
                    child: Text(
                      card.hint!,
                      style: TextStyle(
                          fontSize: 10, color: GlassPalette.of(context).inkFaint),
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 8),
            Row(
              crossAxisAlignment: CrossAxisAlignment.baseline,
              textBaseline: TextBaseline.alphabetic,
              children: [
                Flexible(
                  child: FittedBox(
                    fit: BoxFit.scaleDown,
                    alignment: Alignment.centerLeft,
                    child: Text(
                      card.value,
                      style: TextStyle(
                        fontSize: 30,
                        fontWeight: FontWeight.w700,
                        color: GlassPalette.of(context).ink,
                        height: 1.1,
                        fontFeatures: [FontFeature.tabularFigures()],
                      ),
                    ),
                  ),
                ),
                if (card.unit.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(left: 4),
                    child: Text(
                      card.unit,
                      style: TextStyle(
                          fontSize: 13, color: GlassPalette.of(context).inkTertiary),
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 4),
            // 副标题宁可缩一点字号也不能截：设计图那行是全的，之前 400 宽
            // 下「最快 3 小时 · 最慢 2.4 小时」被切成了省略号。
            FittedBox(
              fit: BoxFit.scaleDown,
              alignment: Alignment.centerLeft,
              child: Text(
                card.sub,
                maxLines: 1,
                style: TextStyle(
                  fontSize: 11.5,
                  color: card.subColor ?? GlassPalette.of(context).inkTertiary,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 骨架屏：4 个指标块 + 2 个图块灰块脉冲，不用菊花。
class _Skeleton extends StatelessWidget {
  const _Skeleton({required this.pulse, required this.wide});

  final Animation<double> pulse;
  final bool wide;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        LayoutBuilder(
          builder: (context, constraints) {
            final columns = _metricColumns(constraints.maxWidth);
            final gap = _metricGap;
            final width = (constraints.maxWidth - gap * (columns - 1)) / columns;
            return Wrap(
              spacing: gap,
              runSpacing: gap,
              children: [
                for (var i = 0; i < 4; i++)
                  _SkeletonBlock(width: width, height: 96, pulse: pulse),
              ],
            );
          },
        ),
        const SizedBox(height: 14),
        if (wide)
          Row(children: [
            Expanded(child: _SkeletonBlock(pulse: pulse, height: 260)),
            const SizedBox(width: 14),
            Expanded(child: _SkeletonBlock(pulse: pulse, height: 260)),
          ])
        else
          _SkeletonBlock(pulse: pulse, height: 260),
        const SizedBox(height: 14),
        _SkeletonBlock(pulse: pulse, height: 200),
      ],
    );
  }
}

class _SkeletonBlock extends StatelessWidget {
  const _SkeletonBlock({
    this.width,
    required this.height,
    required this.pulse,
  });

  final double? width;
  final double height;
  final Animation<double> pulse;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: pulse,
      builder: (context, _) => SizedBox(
        width: width,
        height: height,
        child: GlassSurface(
          variant: GlassVariant.lift,
          child: Opacity(
            opacity: 0.35 + 0.35 * pulse.value,
            child: Container(
              decoration: BoxDecoration(
                color: GlassPalette.of(context).chipBg,
                borderRadius: BorderRadius.circular(16),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// 入场动画：与主页任务列表同一套曲线，保持切 tab 的一致手感。
class _Entrance extends StatelessWidget {
  const _Entrance({
    required this.controller,
    required this.index,
    required this.total,
    required this.child,
  });

  final AnimationController? controller;
  final int index;
  final int total;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final animation = controller;
    if (animation == null || total <= 1) return child;
    final start = (index / total) * 0.55;
    final end = start + 0.45 < 1.0 ? start + 0.45 : 1.0;
    return AnimatedBuilder(
      animation: animation,
      builder: (context, _) {
        final raw = animation.value <= start
            ? 0.0
            : ((animation.value - start) / (end - start)).clamp(0.0, 1.0);
        final value = Curves.easeOutCubic.transform(raw);
        return Opacity(
          opacity: value,
          child: Transform.translate(
            offset: Offset(0, 20 * (1 - value)),
            child: child,
          ),
        );
      },
    );
  }
}
