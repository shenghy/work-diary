import 'package:flutter/material.dart';

import '../services/upgrade_service.dart';
import '../theme/glass_palette.dart';

/// 升级提示对话框
///
/// 显示新版本号、更新说明，提供"立即升级"/"稍后"按钮。
/// 强制升级时只有"立即升级"按钮，且不能通过点击空白或返回键关闭。
class UpgradeDialog extends StatelessWidget {
  final LatestVersion version;
  final VoidCallback onUpgrade;

  const UpgradeDialog({
    super.key,
    required this.version,
    required this.onUpgrade,
  });

  static Future<void> show(
    BuildContext context, {
    required LatestVersion version,
    required VoidCallback onUpgrade,
  }) {
    return showDialog(
      context: context,
      barrierDismissible: !version.forceUpdate, // 强制升级不能点空白关闭
      builder: (ctx) => UpgradeDialog(version: version, onUpgrade: onUpgrade),
    );
  }

  String _formatSize(int? bytes) {
    if (bytes == null) return '';
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    return '${(bytes / 1024 / 1024).toStringAsFixed(1)} MB';
  }

  @override
  Widget build(BuildContext context) {
    final force = version.forceUpdate;
    final g = GlassPalette.of(context);
    return PopScope(
      canPop: !force, // 强制升级不能按返回键关闭
      child: AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
        title: Row(
          children: [
            Container(
              width: 36,
              height: 36,
              decoration: BoxDecoration(
                color: g.accent,
                borderRadius: BorderRadius.circular(10),
              ),
              child: const Icon(Icons.system_update, color: Colors.white, size: 20),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('发现新版本', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
                  Text(
                    'v${version.version}'
                    '${version.fileSize != null ? '  ·  ${_formatSize(version.fileSize)}' : ''}'
                    '${force ? '  ·  需升级后继续使用' : ''}',
                    style: TextStyle(fontSize: 12, color: force ? g.danger : g.inkTertiary),
                  ),
                ],
              ),
            ),
          ],
        ),
        content: ConstrainedBox(
          constraints: const BoxConstraints(maxHeight: 280),
          child: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text('更新说明', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: g.ink)),
                const SizedBox(height: 8),
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: g.fieldBg,
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: g.fieldBorder),
                  ),
                  child: Text(
                    version.releaseNotes.isEmpty ? '暂无更新说明' : version.releaseNotes,
                    style: TextStyle(fontSize: 13, height: 1.6, color: g.ink),
                  ),
                ),
                if (version.publishedAt.isNotEmpty) ...[
                  const SizedBox(height: 8),
                  Text('发布时间：${version.publishedAt}', style: TextStyle(fontSize: 11, color: g.inkTertiary)),
                ],
              ],
            ),
          ),
        ),
        actions: [
          if (!force)
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: Text('稍后', style: TextStyle(fontSize: 14, color: g.inkSecondary)),
            ),
          ElevatedButton(
            onPressed: () {
              Navigator.pop(context);
              onUpgrade();
            },
            style: ElevatedButton.styleFrom(
              backgroundColor: g.accent,
              foregroundColor: Colors.white,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
            ),
            child: Text(force ? '立即升级' : '立即升级', style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
          ),
        ],
      ),
    );
  }
}
