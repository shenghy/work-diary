import 'dart:io';
import 'dart:ui' show lerpDouble;

import 'package:flutter/material.dart';

import '../models/attachment.dart';
import '../services/attachment_store.dart';
import '../services/attachment_sync_service.dart';
import '../theme/glass_palette.dart';
import '../utils/attachment_types.dart';

/// 一条附件 + "原件在不在本机、不在是因为什么"。
///
/// 原件判定要读盘（`File.exists`/stat），放在卡片每次 build 里做会拖慢列表，
/// 所以由上层加载附件时一次算好一起传进来。
@immutable
class AttachmentView {
  const AttachmentView({
    required this.attachment,
    required this.local,
    this.localPath,
    this.source,
  });

  final Attachment attachment;
  final bool local;

  /// 本机原件路径，只有 [local] 为真时才有：缩略图直接读这个文件。
  /// 上层用 `hasLocalCopy` 判过存在（含 uid 清洗），这里不再二次校验。
  final String? localPath;

  /// 本机拿不到内容的原因，由上层 stat 完传下来
  final AttachmentSource? source;

  /// 没传 [source] 时按"有没有 + 引用还是副本"粗判，够卡片画状态用
  AttachmentSource get resolvedSource => source ??
      (local
          ? (attachment.isLinked
              ? AttachmentSource.linked
              : AttachmentSource.copy)
          : attachment.isLinked
              ? AttachmentSource.missingOriginal
              : AttachmentSource.otherDevice);
}

/// 任务/备忘卡片上的附件条：一条 = 一个文件，做成资源管理器那种"纸片 + 名称 + 大小"。
///
/// 类型靠角标一眼可辨（DOCX/XLSX/PDF…用 Windows 的习惯色），本机图片直接显示缩略图；
/// 原件在别的机器时没有缩略图可画，退化成纸片 + ☁，反而更容易看出"这个还开不了"。
/// 点了就分情况：本机有原件 → 用系统默认程序打开；原件在别的机器 → 发起按需中转；
/// 中转进行中 → 条目顶部一条进度带，并且收起 ×（管道里的文件删了，另一边拿到半截件）。
///
/// 一行里所有条目等宽：名字短的拉齐到同一格，卡片右侧不留参差的尾巴。
///
/// 本机有原件时右键给三项：默认应用打开 / 在文件资源管理器中显示 / 复制路径——
/// 手机上没有"这个文件到底在哪台机器"的困惑，电脑上用户下一步就是要拿它干活。
/// 引用原件的那条多给"另存副本到本机"，原件失联的给"重新定位原件"，
/// 附件库副本给"改为引用本机文件"：三种状态都有出路，不用重删重加。
class AttachmentStrip extends StatelessWidget {
  const AttachmentStrip({
    required this.items,
    required this.onOpen,
    required this.onPull,
    required this.onDelete,
    required this.onReveal,
    required this.onCopyPath,
    this.onRelocate,
    this.onPinCopy,
    this.jobs,
    this.padding = const EdgeInsets.only(left: 12, right: 6, bottom: 8),
    super.key,
  });

  final List<AttachmentView> items;
  final void Function(Attachment attachment) onOpen;
  final void Function(Attachment attachment) onPull;
  final void Function(Attachment attachment) onDelete;

  /// 定位与复制路径都要用原件路径，所以交出去的是整条视图而不只是记录
  final void Function(AttachmentView item) onReveal;
  final void Function(AttachmentView item) onCopyPath;

  /// 引用失联时"重新定位原件"、副本时"改为引用本机文件"，都指向用户新选的那个文件；
  /// 引用模式下的"另存副本到本机"把原件收进附件库。不传就不给这一项。
  final void Function(AttachmentView item)? onRelocate;
  final void Function(AttachmentView item)? onPinCopy;

  /// 进度来源（同时是 Listenable）；不传就用全局那份，测试可传独立实例
  final AttachmentSyncService? jobs;

  /// 任务卡自己没留内边距，备忘卡有：外边距交给调用方对齐
  final EdgeInsets padding;

  @override
  Widget build(BuildContext context) {
    if (items.isEmpty) return const SizedBox.shrink();
    final bus = jobs ?? AttachmentSyncService.instance;
    final relocate = onRelocate;
    final pinCopy = onPinCopy;
    return ListenableBuilder(
      listenable: bus,
      builder: (context, _) {
        return Padding(
          padding: padding,
          child: LayoutBuilder(
            builder: (context, box) {
              final width = _uniformItemWidth(box.maxWidth);
              return Wrap(
                spacing: _spacing,
                runSpacing: 6,
                children: [
                  for (final item in items)
                    SizedBox(
                      width: width,
                      child: _AttachmentItem(
                        item: item,
                        job: bus.jobOf(item.attachment.uid),
                        onOpen: () => onOpen(item.attachment),
                        onPull: () => onPull(item.attachment),
                        onDelete: () => onDelete(item.attachment),
                        onReveal: () => onReveal(item),
                        onCopyPath: () => onCopyPath(item),
                        onRelocate:
                            relocate == null ? null : () => relocate(item),
                        onPinCopy: pinCopy == null ? null : () => pinCopy(item),
                      ),
                    ),
                ],
              );
            },
          ),
        );
      },
    );
  }
}

/// 条目横向间隔，同时也是等宽切列时的一行余量
const _spacing = 8.0;

/// 一格的目标宽度：208 是短名字的舒适上限，也是长名字的省略号起点
const _targetWidth = 208.0;

/// 再窄名字就没法看了，宁可少切一列
const _minWidth = 150.0;

/// 把可用宽度均分给一行：列数按目标宽度取整，格子不低于 [_minWidth]。
/// 结果是同一行条目一模一样宽，最后一行也不会因为名字短就缩成一小块。
double _uniformItemWidth(double available) {
  if (!available.isFinite || available <= 0) return _targetWidth;
  var cols = ((available + _spacing) / (_targetWidth + _spacing)).round();
  if (cols < 1) cols = 1;
  while (cols > 1 && (available - _spacing * (cols - 1)) / cols < _minWidth) {
    cols--;
  }
  return (available - _spacing * (cols - 1)) / cols;
}

/// 条目外观：副行文案、边框强调色、虚线、右上圆形角标、顶部进度带、能不能删。
@immutable
class _Look {
  const _Look({
    required this.sub,
    required this.accent,
    this.dashed = false,
    this.overlay,
    this.progress,
    required this.removable,
  });

  final String sub;
  final Color accent;
  final bool dashed;
  final IconData? overlay;
  final double? progress;
  final bool removable;
}

class _AttachmentItem extends StatefulWidget {
  const _AttachmentItem({
    required this.item,
    required this.job,
    required this.onOpen,
    required this.onPull,
    required this.onDelete,
    required this.onReveal,
    required this.onCopyPath,
    this.onRelocate,
    this.onPinCopy,
  });

  final AttachmentView item;
  final AttachmentJob? job;
  final VoidCallback onOpen;
  final VoidCallback onPull;
  final VoidCallback onDelete;
  final VoidCallback onReveal;
  final VoidCallback onCopyPath;
  final VoidCallback? onRelocate;
  final VoidCallback? onPinCopy;

  @override
  State<_AttachmentItem> createState() => _AttachmentItemState();
}

class _AttachmentItemState extends State<_AttachmentItem> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final g = GlassPalette.of(context);
    final attachment = widget.item.attachment;
    final job = widget.job;
    final look = _lookOf(g, widget.item, job);
    final source = widget.item.resolvedSource;
    // 云端换版了就不是"点开本机这份"，而是取回新版；引用失联同样只剩中转这条路
    final opens = widget.item.local && !attachment.staleCopy && job == null;

    // 提示语要说清"这个文件现在在哪、点了会怎样"，否则用户只会看到一个陌生文件名
    final tip = StringBuffer(attachment.fileName);
    tip.write('\n${formatAttachmentSize(attachment.fileSize)}');
    if (source == AttachmentSource.missingOriginal) {
      tip.write(' · 本机原件不在了');
    } else if (widget.item.local || job?.phase == AttachmentPhase.downloading) {
      tip.write(attachment.isLinked ? ' · 引用本机原件' : ' · 在本机');
    } else {
      final owner = attachment.ownerDeviceName.trim();
      tip.write(' · 原件在${owner.isEmpty ? '其它主机' : '「$owner」'}');
    }
    if (attachment.staleCopy && job == null) {
      tip.write('\n云端已有一份更新的内容，点击取回（本机文件不会被改动）');
    }
    if (job != null && job.message.isNotEmpty) tip.write('\n${job.message}');
    tip.write(opens
        ? '\n点击打开，右键更多操作，点 × 从这条记录上移除'
        : '\n点击从其它主机同步过来');

    return MouseRegion(
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: Tooltip(
        message: tip.toString(),
        child: Stack(
          clipBehavior: Clip.none,
          children: [
            GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: opens ? widget.onOpen : widget.onPull,
              onSecondaryTapUp: (d) => _showMenu(d.globalPosition),
              child: _frame(
                g: g,
                look: look,
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    _glyph(g, attachment, widget.item),
                    const SizedBox(width: 9),
                    Flexible(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            attachment.fileName,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 12,
                              color: g.ink,
                              fontWeight: FontWeight.w600,
                              height: 1.35,
                            ),
                          ),
                          Text(
                            look.sub,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 10,
                              color: look.overlay == null && !look.dashed
                                  ? g.inkTertiary
                                  : look.accent,
                              height: 1.3,
                            ),
                          ),
                        ],
                      ),
                    ),
                    // × 只在 hover 时出现：常驻会白占 20px，一行少放一条附件
                    SizedBox(
                      width: 16,
                      child: look.removable && _hovered
                          ? InkWell(
                              onTap: widget.onDelete,
                              child: Icon(
                                Icons.close,
                                size: 12,
                                color: g.inkTertiary,
                              ),
                            )
                          : null,
                    ),
                  ],
                ),
              ),
            ),
            if (look.progress != null)
              Positioned(
                left: 8,
                right: 8,
                top: 2,
                child: _progressBar(g, look),
              ),
            if (look.overlay != null)
              Positioned(right: -5, top: -5, child: _overlayBadge(g, look)),
          ],
        ),
      ),
    );
  }

  /// 本机有原件时给"打开/定位/复制路径"三项，和 Windows 里右键一个文件一样；
  /// 引用模式再多两项：把原件收进附件库、或改指另一个文件。
  void _showMenu(Offset at) {
    final source = widget.item.resolvedSource;
    final path = widget.item.localPath;
    final hasOriginal = path != null && path.isNotEmpty &&
        (source == AttachmentSource.linked || source == AttachmentSource.copy);
    final items = <PopupMenuItem<void>>[];
    if (hasOriginal) {
      items
        ..add(_menuItem(Icons.open_in_new, '默认应用打开', widget.onOpen))
        ..add(_menuItem(Icons.folder_open, '在文件资源管理器中显示', widget.onReveal))
        ..add(_menuItem(Icons.link, '复制路径', widget.onCopyPath));
    }
    final pinCopy = widget.onPinCopy;
    if (source == AttachmentSource.linked && pinCopy != null) {
      items.add(_menuItem(Icons.folder_copy, '另存副本到本机', pinCopy));
    }
    final relocate = widget.onRelocate;
    if (relocate != null &&
        (source == AttachmentSource.missingOriginal ||
            source == AttachmentSource.copy)) {
      items.add(_menuItem(
        Icons.find_in_page,
        source == AttachmentSource.missingOriginal ? '重新定位原件…' : '改为引用本机文件…',
        relocate,
      ));
    }
    if (items.isEmpty) return;
    showMenu<void>(
      context: context,
      position: RelativeRect.fromLTRB(at.dx, at.dy, at.dx, at.dy),
      items: items,
    );
  }

  PopupMenuItem<void> _menuItem(
      IconData icon, String label, VoidCallback onTap) {
    return PopupMenuItem<void>(
      onTap: onTap,
      child: Row(
        children: [
          Icon(icon, size: 16, color: GlassPalette.of(context).inkSecondary),
          const SizedBox(width: 10),
          Text(label, style: const TextStyle(fontSize: 13)),
        ],
      ),
    );
  }

  Widget _frame({
    required GlassPalette g,
    required _Look look,
    required Widget child,
  }) {
    final box = Container(
      height: 42,
      padding: const EdgeInsets.symmetric(horizontal: 6),
      decoration: BoxDecoration(
        color: g.chipBg,
        borderRadius: BorderRadius.circular(9),
        // 虚线态把边框让给下面那圈短划，免得实线把虚线糊掉
        border: look.dashed
            ? null
            : Border.all(color: look.accent.withAlpha(190), width: 1),
      ),
      child: child,
    );
    if (!look.dashed) return box;
    return Stack(
      children: [
        box,
        Positioned.fill(
          child: IgnorePointer(
            child: CustomPaint(
              painter: DashedRoundedRectPainter(
                color: look.accent.withAlpha(190),
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _progressBar(GlassPalette g, _Look look) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(2),
      child: SizedBox(
        height: 3,
        child: LinearProgressIndicator(
          value: look.progress,
          minHeight: 3,
          backgroundColor: g.ink.withAlpha(22),
          valueColor: AlwaysStoppedAnimation<Color>(look.accent),
        ),
      ),
    );
  }

  Widget _overlayBadge(GlassPalette g, _Look look) {
    return Container(
      width: 18,
      height: 18,
      decoration: BoxDecoration(
        color: g.isLight ? Colors.white : const Color(0xFF1B2338),
        shape: BoxShape.circle,
        border: Border.all(color: look.accent.withAlpha(150), width: 1),
      ),
      // 18px 的圆里放线性图标糊成一团，状态角标一律用实心款
      child: Icon(look.overlay, size: 11, color: look.accent),
    );
  }
}

/// 左侧 26×32 图标：本机图片用真缩略图，其它一律折角纸片 + 类型角标。
Widget _glyph(GlassPalette g, Attachment attachment, AttachmentView item) {
  final ext = attachmentExtOf(attachment.fileName);
  final isImage = kImageExts.contains(ext);
  final path = item.localPath;
  final sheet = _Sheet(g: g, badge: _badgeOf(ext), lines: true);
  if (!isImage || path == null) return sheet;
  return _Sheet(
    g: g,
    badge: _badgeOf(ext),
    fill: Image.file(
      File(path),
      width: _Sheet.w,
      height: _Sheet.h,
      fit: BoxFit.cover,
      cacheWidth: 96,
      filterQuality: FilterQuality.low,
      gaplessPlayback: true,
      errorBuilder: (context, error, stack) => const SizedBox.shrink(),
    ),
  );
}

/// 折角纸片：纸面 + 右上折角 + 底部类型角标。
class _Sheet extends StatelessWidget {
  const _Sheet({
    required this.g,
    required this.badge,
    this.fill,
    this.lines = false,
  });

  static const double w = 26;
  static const double h = 32;
  static const double fold = 7;

  final GlassPalette g;
  final _Badge badge;
  final Widget? fill;
  final bool lines;

  @override
  Widget build(BuildContext context) {
    final paper = g.isLight ? Colors.white : const Color(0xFFE9EEF7);
    final stroke = g.glassEdgeColor.withAlpha(g.isLight ? 140 : 90);
    final edge = g.glassEdgeColor.withAlpha(g.isLight ? 200 : 130);
    return SizedBox(
      width: w,
      height: h,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          // 纸面先铺一层，缩略图再盖在上面：原件读不出来时也不会空成一块透明
          ClipPath(
            clipper: _SheetClipper(fold),
            child: ColoredBox(
              color: paper,
              child: lines
                  ? Padding(
                      padding: const EdgeInsets.only(
                        left: 4,
                        right: 4,
                        top: 12,
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          _rule(stroke, 1),
                          const SizedBox(height: 3),
                          _rule(stroke, .7),
                        ],
                      ),
                    )
                  : null,
            ),
          ),
          if (fill != null) ClipPath(clipper: _SheetClipper(fold), child: fill),
          // 描边：浅色档纸面接近白，没有一圈线就看不出这是一张纸
          Positioned.fill(
            child: CustomPaint(painter: _SheetOutlinePainter(edge, fold)),
          ),
          Positioned(
            right: 0,
            top: 0,
            child: CustomPaint(
              size: const Size(fold, fold),
              painter: _FoldPainter(paper, stroke),
            ),
          ),
          Positioned(
            left: 0,
            bottom: -1,
            child: Container(
              height: 13,
              padding: const EdgeInsets.symmetric(horizontal: 3),
              decoration: BoxDecoration(
                color: badge.color,
                borderRadius: BorderRadius.circular(3),
              ),
              alignment: Alignment.center,
              child: Text(
                badge.label,
                style: const TextStyle(
                  fontSize: 8,
                  height: 1,
                  color: Colors.white,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _rule(Color color, double fraction) {
    return Container(
      height: 2,
      width: (w - 8) * fraction,
      decoration: BoxDecoration(
        color: color.withAlpha(120),
        borderRadius: BorderRadius.circular(1),
      ),
    );
  }
}

class _SheetClipper extends CustomClipper<Path> {
  const _SheetClipper(this.fold);
  final double fold;

  @override
  Path getClip(Size size) {
    return Path()
      ..moveTo(0, 0)
      ..lineTo(size.width - fold, 0)
      ..lineTo(size.width, fold)
      ..lineTo(size.width, size.height)
      ..lineTo(0, size.height)
      ..close();
  }

  @override
  bool shouldReclip(covariant _SheetClipper old) => old.fold != fold;
}

/// 纸片描边：ClipPath 只裁不画，纸面接近白时必须再描一圈才看得出轮廓。
class _SheetOutlinePainter extends CustomPainter {
  const _SheetOutlinePainter(this.edge, this.fold);
  final Color edge;
  final double fold;

  @override
  void paint(Canvas canvas, Size size) {
    final path = Path()
      ..moveTo(.5, .5)
      ..lineTo(size.width - fold, .5)
      ..lineTo(size.width - .5, fold + .5)
      ..lineTo(size.width - .5, size.height - .5)
      ..lineTo(.5, size.height - .5)
      ..close();
    canvas.drawPath(
      path,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1
        ..color = edge,
    );
  }

  @override
  bool shouldRepaint(covariant _SheetOutlinePainter old) =>
      old.edge != edge || old.fold != fold;
}

class _FoldPainter extends CustomPainter {
  const _FoldPainter(this.paper, this.stroke);
  final Color paper;
  final Color stroke;

  @override
  void paint(Canvas canvas, Size size) {
    final path = Path()
      ..moveTo(0, 0)
      ..lineTo(size.width, size.height)
      ..lineTo(0, size.height)
      ..close();
    canvas.drawPath(
      path,
      Paint()
        ..color = Color.alphaBlend(paper.withAlpha(120), stroke.withAlpha(60)),
    );
    canvas.drawPath(
      path,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = .6
        ..color = stroke,
    );
  }

  @override
  bool shouldRepaint(covariant _FoldPainter old) =>
      old.paper != paper || old.stroke != stroke;
}

@immutable
class _Badge {
  const _Badge(this.label, this.color);
  final String label;
  final Color color;
}

_Badge _badgeOf(String ext) {
  final label = ext.isEmpty ? '文件' : ext.replaceFirst('.', '').toUpperCase();
  return _Badge(label, _badgeColor(ext));
}

/// 角标底色沿用 Windows 资源管理器里各类文件的习惯色，两端（桌面/小程序）必须取同一组值。
Color _badgeColor(String ext) {
  switch (ext) {
    case '.doc':
    case '.docx':
    case '.rtf':
      return const Color(0xFF2B579A);
    case '.xls':
    case '.xlsx':
    case '.et':
    case '.csv':
      return const Color(0xFF217346);
    case '.ppt':
    case '.pptx':
    case '.dps':
      return const Color(0xFFD24726);
    case '.pdf':
      return const Color(0xFFD9191E);
    case '.ofd':
      return const Color(0xFF8B5E34);
    case '.wps':
      return const Color(0xFFE8632B);
    case '.txt':
    case '.md':
      return const Color(0xFF5B6B86);
    case '.jpg':
    case '.jpeg':
    case '.png':
    case '.gif':
    case '.webp':
    case '.bmp':
      return const Color(0xFF0E7C86);
    default:
      return const Color(0xFF5B6B86);
  }
}

String _kindOf(String ext) {
  if (kImageExts.contains(ext)) return '图片';
  switch (ext) {
    case '.pdf':
      return 'PDF';
    case '.doc':
    case '.docx':
    case '.wps':
    case '.rtf':
    case '.ofd':
      return '文档';
    case '.xls':
    case '.xlsx':
    case '.et':
    case '.csv':
      return '表格';
    case '.ppt':
    case '.pptx':
    case '.dps':
      return '演示';
    default:
      return '文本';
  }
}

_Look _lookOf(GlassPalette g, AttachmentView item, AttachmentJob? job) {
  final size = formatAttachmentSize(item.attachment.fileSize);
  final kind = _kindOf(attachmentExtOf(item.attachment.fileName));
  final phase = job?.phase;

  if (phase == AttachmentPhase.failed) {
    return _Look(
      // 副行要能在最窄的一格里读完，所以只留状态和动作：大小、主机名都在提示语里
      sub: '同步失败 · 点重试',
      accent: g.urgencyImportant,
      overlay: Icons.priority_high,
      removable: true,
    );
  }
  if (phase == AttachmentPhase.uploading) {
    return _Look(
      sub: '上传中 ${_percent(job)}',
      accent: g.accentSoft,
      progress: _fraction(job),
      removable: false,
    );
  }
  if (phase == AttachmentPhase.downloading) {
    return _Look(
      sub: '下载中 ${_percent(job)}',
      accent: g.accentSoft,
      progress: _fraction(job),
      removable: false,
    );
  }
  if (phase == AttachmentPhase.waitingSource) {
    return _Look(
      // 条目上只放一句状态，具体"等谁、发生了什么"留给提示语，否则窄卡片会被长消息挤爆
      sub: '等待主机上传',
      accent: g.inkSecondary,
      overlay: Icons.hourglass_top,
      removable: false,
    );
  }
  if (item.resolvedSource == AttachmentSource.missingOriginal) {
    return _Look(
      // 引用型附件的原件被移动/改名/删了：本机什么都没了，但记录知道它该在哪
      sub: '原件不在了 · 右键定位',
      accent: g.urgencyImportant,
      dashed: true,
      overlay: Icons.link_off,
      removable: true,
    );
  }
  if (!item.local) {
    return _Look(
      sub: '在其它主机',
      accent: g.accentSoft,
      dashed: true,
      overlay: Icons.cloud_download,
      removable: true,
    );
  }
  if (item.attachment.staleCopy) {
    return _Look(
      sub: '云端有新版 · 点击取回',
      accent: g.accentSoft,
      overlay: Icons.system_update_alt,
      removable: true,
    );
  }
  return _Look(sub: '$size · $kind', accent: g.chipBorder, removable: true);
}

String _percent(AttachmentJob? job) {
  final progress = job?.progress;
  return progress == null ? '…' : '${(progress * 100).clamp(0, 100).round()}%';
}

double? _fraction(AttachmentJob? job) {
  final progress = job?.progress;
  if (progress == null) return null;
  return lerpDouble(0, 1, progress.clamp(0, 1).toDouble());
}

/// 虚线边框：Flutter 没有内置虚线 Border，这里按圆角矩形画一圈短划。
class DashedRoundedRectPainter extends CustomPainter {
  const DashedRoundedRectPainter({
    required this.color,
    this.dash = 4,
    this.gap = 3,
    this.radius = 9,
  });

  final Color color;
  final double dash;
  final double gap;
  final double radius;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1
      ..strokeCap = StrokeCap.round
      ..color = color;
    final rect = Rect.fromLTWH(.5, .5, size.width - 1, size.height - 1);
    final path = Path()
      ..addRRect(RRect.fromRectAndRadius(rect, Radius.circular(radius)));
    for (final metric in path.computeMetrics()) {
      double distance = 0;
      while (distance < metric.length) {
        canvas.drawPath(metric.extractPath(distance, distance + dash), paint);
        distance += dash + gap;
      }
    }
  }

  @override
  bool shouldRepaint(covariant DashedRoundedRectPainter old) =>
      old.color != color ||
      old.dash != dash ||
      old.gap != gap ||
      old.radius != radius;
}
