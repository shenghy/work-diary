import 'package:flutter/material.dart';

import '../services/upgrade_service.dart';
import '../theme/glass_palette.dart';

/// 底部升级提示条（非模态，不打断用户操作）
///
/// 两种状态：
/// - 下载中：显示"发现新版本，正在下载..." + 进度条（用户可正常使用软件）
/// - 待升级：显示新版本信息 + 「立即升级」按钮（可关闭）
class UpgradeBanner extends StatelessWidget {
  final LatestVersion version;
  final bool downloading;
  final double progress;
  final VoidCallback onUpgrade;
  final VoidCallback onDismiss;

  const UpgradeBanner({
    super.key,
    required this.version,
    this.downloading = false,
    this.progress = 0,
    required this.onUpgrade,
    required this.onDismiss,
  });

  @override
  Widget build(BuildContext context) {
    final g = GlassPalette.of(context);
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        color: g.surface,
        border: Border(top: BorderSide(color: g.cardBorder, width: 1)),
        boxShadow: [
          BoxShadow(
            color: g.shadowSoft,
            blurRadius: 8,
            offset: const Offset(0, -2),
          ),
        ],
      ),
      child: SafeArea(
        top: false,
        child: downloading ? _buildDownloading(g) : _buildReady(g),
      ),
    );
  }

  /// 下载中：图标 + 文案 + 进度条 + 关闭
  Widget _buildDownloading(GlassPalette g) {
    return Row(
      children: [
        Container(
          width: 32,
          height: 32,
          decoration: BoxDecoration(
            color: g.accent,
            borderRadius: BorderRadius.circular(8),
          ),
          child: const Icon(Icons.system_update, color: Colors.white, size: 18),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                '发现新版本 v${version.version}，正在下载...',
                style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: g.ink),
              ),
              const SizedBox(height: 5),
              ClipRRect(
                borderRadius: BorderRadius.circular(3),
                child: LinearProgressIndicator(
                  value: progress.clamp(0.0, 1.0),
                  minHeight: 4,
                  backgroundColor: g.trackBg,
                  valueColor: AlwaysStoppedAnimation<Color>(g.accent),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(width: 8),
        Text(
          '${(progress.clamp(0.0, 1.0) * 100).toStringAsFixed(0)}%',
          style: TextStyle(fontSize: 11, color: g.accent),
        ),
        const SizedBox(width: 4),
        IconButton(
          onPressed: onDismiss,
          icon: Icon(Icons.close, size: 16, color: g.accentSoft),
          padding: EdgeInsets.zero,
          constraints: const BoxConstraints(minWidth: 28, minHeight: 28),
        ),
      ],
    );
  }

  /// 下载完成：图标 + 版本信息 + 立即升级 + 关闭
  Widget _buildReady(GlassPalette g) {
    return Row(
      children: [
        Container(
          width: 32,
          height: 32,
          decoration: BoxDecoration(
            color: g.accent,
            borderRadius: BorderRadius.circular(8),
          ),
          child: const Icon(Icons.system_update, color: Colors.white, size: 18),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                '发现新版本 v${version.version}',
                style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: g.ink),
              ),
              const SizedBox(height: 2),
              Text(
                version.releaseNotes.isEmpty ? '点击立即升级到最新版本' : version.releaseNotes,
                style: TextStyle(fontSize: 11, color: g.accent),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ],
          ),
        ),
        const SizedBox(width: 8),
        TextButton(
          onPressed: onUpgrade,
          style: TextButton.styleFrom(
            backgroundColor: g.accent,
            foregroundColor: Colors.white,
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
            minimumSize: Size.zero,
            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
          ),
          child: const Text('立即升级', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600)),
        ),
        const SizedBox(width: 4),
        IconButton(
          onPressed: onDismiss,
          icon: Icon(Icons.close, size: 16, color: g.accentSoft),
          padding: EdgeInsets.zero,
          constraints: const BoxConstraints(minWidth: 28, minHeight: 28),
        ),
      ],
    );
  }
}
