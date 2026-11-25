import 'package:flutter/material.dart';

import '../services/ai_service.dart';
import '../theme/glass_palette.dart';

/// 额度详情对话框：显示登录用户「截图任务 / AI日报总结 / AI周报总结」的
/// 今日已用/可用 + 本月已用次数。
class QuotaDetailDialog extends StatefulWidget {
  const QuotaDetailDialog({super.key});

  @override
  State<QuotaDetailDialog> createState() => _QuotaDetailDialogState();
}

class _QuotaDetailDialogState extends State<QuotaDetailDialog> {
  AiUsage? _usage;
  String? _error;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final usage = await AiService.fetchUsage();
      if (!mounted) return;
      setState(() {
        _usage = usage;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.toString().replaceFirst('Exception: ', '');
        _loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final g = GlassPalette.of(context);
    return Dialog(
      backgroundColor: g.surface,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
      child: Container(
        width: 380,
        padding: const EdgeInsets.fromLTRB(20, 18, 20, 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.insights, size: 20, color: g.accent),
                const SizedBox(width: 8),
                Text('额度详情',
                    style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w700,
                        color: g.ink)),
                const Spacer(),
                if (_usage != null && _usage!.date.isNotEmpty)
                  Text('${_usage!.date}',
                      style: TextStyle(fontSize: 12, color: g.inkTertiary)),
                IconButton(
                  onPressed: () => Navigator.of(context).pop(),
                  icon: Icon(Icons.close, size: 18, color: g.inkTertiary),
                  padding: EdgeInsets.zero,
                  constraints:
                      const BoxConstraints(minWidth: 28, minHeight: 28),
                ),
              ],
            ),
            const SizedBox(height: 12),
            if (_loading)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 40),
                child: Center(
                  child: SizedBox(
                    width: 24,
                    height: 24,
                    child: CircularProgressIndicator(
                        strokeWidth: 2.5, color: g.accent),
                  ),
                ),
              )
            else if (_error != null)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 24),
                child: Center(
                  child: Column(
                    children: [
                      Icon(Icons.cloud_off, size: 32, color: g.inkTertiary),
                      const SizedBox(height: 10),
                      Text(_error!,
                          textAlign: TextAlign.center,
                          style: TextStyle(fontSize: 13, color: g.inkTertiary)),
                      const SizedBox(height: 12),
                      TextButton.icon(
                        onPressed: _load,
                        style: TextButton.styleFrom(foregroundColor: g.accent),
                        icon: const Icon(Icons.refresh, size: 16),
                        label: const Text('重试'),
                      ),
                    ],
                  ),
                ),
              )
            else if (_usage != null)
              ..._buildItems(),
            const SizedBox(height: 4),
          ],
        ),
      ),
    );
  }

  List<Widget> _buildItems() {
    final g = GlassPalette.of(context);
    final u = _usage!;
    return [
      _buildItem(
        icon: Icons.crop_free,
        color: g.statsPrimary,
        title: '截图任务',
        item: u.ocr,
      ),
      const SizedBox(height: 12),
      _buildItem(
        icon: Icons.today,
        color: g.accent,
        title: 'AI日报总结',
        item: u.daily,
      ),
      const SizedBox(height: 12),
      _buildItem(
        icon: Icons.date_range,
        color: g.urgencyNormal,
        title: 'AI周报总结',
        item: u.weekly,
      ),
    ];
  }

  Widget _buildItem({
    required IconData icon,
    required Color color,
    required String title,
    required UsageItem item,
  }) {
    final g = GlassPalette.of(context);
    final used = item.todayUsed;
    final limit = item.todayLimit;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        color: g.fieldBg,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: g.fieldBorder, width: 1),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 28,
                height: 28,
                decoration: BoxDecoration(
                  color: color.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(7),
                ),
                child: Icon(icon, size: 16, color: color),
              ),
              const SizedBox(width: 10),
              Text(title,
                  style: TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                      color: g.ink)),
              const Spacer(),
              Text(
                '今日 $used / $limit 次',
                style: TextStyle(
                    fontSize: 12.5,
                    fontWeight: FontWeight.w700,
                    color: used >= limit ? g.danger : g.ink),
              ),
            ],
          ),
          const SizedBox(height: 8),
          ClipRRect(
            borderRadius: BorderRadius.circular(3),
            child: LinearProgressIndicator(
              value: item.progress,
              minHeight: 5,
              backgroundColor: g.trackBg,
              valueColor:
                  AlwaysStoppedAnimation<Color>(used >= limit ? g.danger : color),
            ),
          ),
          const SizedBox(height: 6),
          Text(
            '本月已用 ${item.monthUsed} 次',
            style: TextStyle(fontSize: 11.5, color: g.inkTertiary),
          ),
        ],
      ),
    );
  }
}
