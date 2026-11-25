import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../services/app_logger.dart';
import '../services/upgrade_service.dart';
import '../theme/glass_palette.dart';

/// 「关于我们」弹窗：品牌头 + 小程序码（已上线）+ 作者微信码 + 官网与协议。
///
/// 内容宽最多 452：默认窗口只有 530（windows/runner/main.cpp 的 default_size），
/// 再宽就要顶到窗口边距，两张码也会挤成竖排；窗口缩小时跟着收窄。
class AppAboutDialog extends StatelessWidget {
  const AppAboutDialog({super.key, required this.onShowAgreement});

  /// 《用户协议》《隐私政策》的正文仍在首页，这里只负责触发。
  final ValueChanged<String> onShowAgreement;

  static const String _siteUrl = 'https://work.jspang.com';

  static Future<void> show(
    BuildContext context, {
    required ValueChanged<String> onShowAgreement,
  }) {
    return showDialog(
      context: context,
      builder: (_) => AppAboutDialog(onShowAgreement: onShowAgreement),
    );
  }

  Future<void> _exportLog(BuildContext context) async {
    final path = await AppLogger.instance.exportLog();
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(path != null ? '日志已导出到桌面' : '导出失败')),
    );
    Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    final g = GlassPalette.of(context);
    // 452 是设计宽，但窗口可以缩到 420：写死就会把弹窗顶出窗口，
    // 右边的 ✕ 和说明直接被裁掉。按窗口宽收，窄窗口里两张码照样等宽。
    final available = MediaQuery.sizeOf(context).width - 16 * 2 - 20 * 2;
    final width = math.min(452.0, math.max(260.0, available));
    return AlertDialog(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      // 默认左右各 40，530 窗口只剩 450，452 的内容会被压回 410：
      // 官网胶囊和协议那一行就得折成两行。收到 16 才给够 492。
      insetPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 24),
      contentPadding: const EdgeInsets.fromLTRB(20, 18, 20, 10),
      actionsPadding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
      content: SizedBox(
        width: width,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _header(context, g),
            const SizedBox(height: 14),
            Container(height: 1, color: g.divider),
            const SizedBox(height: 14),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(child: _miniProgramCard(g)),
                const SizedBox(width: 12),
                Expanded(child: _wechatCard(g)),
              ],
            ),
            const SizedBox(height: 14),
            _linksRow(context, g),
          ],
        ),
      ),
      actions: [
        TextButton(onPressed: () => _exportLog(context), child: const Text('导出日志')),
        FilledButton(
          style: FilledButton.styleFrom(
            padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 10),
          ),
          onPressed: () => Navigator.pop(context),
          child: const Text('确定'),
        ),
      ],
    );
  }

  Widget _header(BuildContext context, GlassPalette g) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          width: 44,
          height: 44,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(12),
            boxShadow: [
              BoxShadow(
                color: g.accent.withAlpha(64),
                blurRadius: 12,
                offset: const Offset(0, 4),
              ),
            ],
          ),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(12),
            child: Image.asset(
              'assets/about/app_logo.png',
              width: 44,
              height: 44,
              fit: BoxFit.cover,
            ),
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Text(
                    '极简工作日记',
                    style: TextStyle(fontSize: 17, fontWeight: FontWeight.w700, color: g.ink),
                  ),
                  const SizedBox(width: 8),
                  _pill(
                    'v${UpgradeService.instance.currentVersion}',
                    fg: g.accentText,
                    bg: g.accent.withAlpha(28),
                    border: g.accent.withAlpha(72),
                  ),
                ],
              ),
              const SizedBox(height: 5),
              Text(
                '极简风格的任务管理工具 · 本地优先 · 云端多设备同步',
                style: TextStyle(fontSize: 12, color: g.inkTertiary),
              ),
            ],
          ),
        ),
        // 右上角关闭：和点空白、Esc 走同一个出口
        GestureDetector(
          onTap: () => Navigator.pop(context),
          child: Container(
            width: 26,
            height: 26,
            decoration: BoxDecoration(
              color: g.chipBg,
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: g.chipBorder),
            ),
            child: Icon(Icons.close, size: 13, color: g.inkTertiary),
          ),
        ),
      ],
    );
  }

  Widget _miniProgramCard(GlassPalette g) {
    return _QrCard(
      asset: 'assets/about/miniprogram_qr.png',
      title: '微信小程序',
      dot: g.success,
      badge: '已上线',
      badgeFg: g.success,
      // 不能用 g.successSoft：浅色档它是实心绿，绿字压绿底等于没写字。
      // 和版本胶囊一样用半透明染色，两档都靠基色自己拉开对比。
      badgeBg: g.success.withAlpha(28),
      badgeBorder: g.success.withAlpha(72),
      lines: [
        // 14 字：和右卡的说明同宽，再多就要在「极简工作日记」中间断行，很难看。
        Text('扫一扫或搜索「极简工作日记」', textAlign: TextAlign.center, style: _descStyle(g)),
        Text('手机随时记，与桌面端互通', textAlign: TextAlign.center, style: _descStyle(g)),
      ],
    );
  }

  Widget _wechatCard(GlassPalette g) {
    return _QrCard(
      asset: 'assets/about/wechat_qr.png',
      title: '作者微信',
      badge: '反馈入口',
      badgeFg: g.accentText,
      badgeBg: g.accent.withAlpha(28),
      badgeBorder: g.accent.withAlpha(72),
      lines: [
        Text('问题反馈、新功能建议都走这里', textAlign: TextAlign.center, style: _descStyle(g)),
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Text('扫一扫添加 ', textAlign: TextAlign.center, style: _descStyle(g)),
            // 微信号保持可选中复制（改造前的能力，不能因为换版式丢掉）
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 5),
              decoration: BoxDecoration(
                color: g.chipBg,
                borderRadius: BorderRadius.circular(5),
                border: Border.all(color: g.chipBorder),
              ),
              child: SelectableText(
                'php100',
                style: TextStyle(fontSize: 11, fontWeight: FontWeight.w700, color: g.ink),
              ),
            ),
          ],
        ),
      ],
    );
  }

  Widget _linksRow(BuildContext context, GlassPalette g) {
    return Row(
      children: [
        GestureDetector(
          onTap: () async {
            final uri = Uri.parse(_siteUrl);
            if (await canLaunchUrl(uri)) {
              await launchUrl(uri);
            }
          },
          child: Container(
            padding: const EdgeInsets.only(left: 9, right: 12, top: 5, bottom: 5),
            decoration: BoxDecoration(
              color: g.accent.withAlpha(28),
              borderRadius: BorderRadius.circular(999),
              border: Border.all(color: g.accent.withAlpha(72)),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.public, size: 14, color: g.accentText),
                const SizedBox(width: 6),
                Text(
                  'work.jspang.com',
                  style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: g.accentText),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: Wrap(
            alignment: WrapAlignment.end,
            spacing: 2,
            children: [
              Text('使用本软件即代表同意', style: TextStyle(fontSize: 11.5, color: g.inkTertiary)),
              _agreementLink(g, '《用户协议》', 'user'),
              Text('与', style: TextStyle(fontSize: 11.5, color: g.inkTertiary)),
              _agreementLink(g, '《隐私政策》', 'privacy'),
            ],
          ),
        ),
      ],
    );
  }

  Widget _agreementLink(GlassPalette g, String label, String type) {
    return GestureDetector(
      onTap: () => onShowAgreement(type),
      child: Text(
        label,
        style: TextStyle(fontSize: 11.5, color: g.accentText),
      ),
    );
  }

  TextStyle _descStyle(GlassPalette g) => TextStyle(
    fontSize: 11.5,
    height: 1.6,
    color: g.inkTertiary,
  );

  Widget _pill(String label, {required Color fg, required Color bg, required Color border}) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 1),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: border),
      ),
      child: Text(
        label,
        style: TextStyle(fontSize: 11, fontWeight: FontWeight.w700, color: fg),
      ),
    );
  }
}

/// 一张码：白底井 + 标题（可带在线状态点与徽章）+ 两行说明。
///
/// 井必须恒白：深色档把底染黑，二维码就扫不出来了。
class _QrCard extends StatelessWidget {
  const _QrCard({
    required this.asset,
    required this.title,
    required this.lines,
    required this.badge,
    required this.badgeFg,
    required this.badgeBg,
    required this.badgeBorder,
    this.dot,
  });

  final String asset;
  final String title;
  final List<Widget> lines;
  final String badge;
  final Color badgeFg;
  final Color badgeBg;
  final Color badgeBorder;
  final Color? dot;

  @override
  Widget build(BuildContext context) {
    final g = GlassPalette.of(context);
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 14, 12, 12),
      decoration: BoxDecoration(
        color: g.chipBg,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: g.chipBorder),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Center(
            child: Container(
              width: 122,
              height: 122,
              padding: const EdgeInsets.all(6),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: g.chipBorder),
                boxShadow: [
                  BoxShadow(
                    color: g.shadow.withAlpha(36),
                    blurRadius: 10,
                    offset: const Offset(0, 2),
                  ),
                ],
              ),
              child: Image.asset(asset, width: 108, height: 108, fit: BoxFit.contain),
            ),
          ),
          const SizedBox(height: 9),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              if (dot != null) ...[
                Container(
                  width: 5,
                  height: 5,
                  decoration: BoxDecoration(
                    color: dot,
                    shape: BoxShape.circle,
                    boxShadow: [BoxShadow(color: dot!.withAlpha(40), blurRadius: 0, spreadRadius: 2.5)],
                  ),
                ),
                const SizedBox(width: 6),
              ],
              Text(
                title,
                style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700, color: g.ink),
              ),
              const SizedBox(width: 6),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 6),
                decoration: BoxDecoration(
                  color: badgeBg,
                  borderRadius: BorderRadius.circular(999),
                  border: Border.all(color: badgeBorder),
                ),
                child: Text(
                  badge,
                  style: TextStyle(fontSize: 10, fontWeight: FontWeight.w700, color: badgeFg, height: 1.7),
                ),
              ),
            ],
          ),
          const SizedBox(height: 5),
          ...lines,
        ],
      ),
    );
  }
}
