import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

import '../theme/glass_palette.dart';
import '../utils/attachment_types.dart';

/// 新建/编辑弹窗里的"待挂附件"区。
///
/// 这里只攒路径，不复制文件：任务/备忘还没落库就没有本地 id，
/// 附件必须挂在具体记录上。点"创建/保存"后才真正收进本机。
class PendingAttachmentPicker extends StatelessWidget {
  const PendingAttachmentPicker({
    required this.paths,
    required this.remaining,
    required this.onPick,
    required this.onRemove,
    super.key,
  });

  final List<String> paths;
  final int remaining;
  final VoidCallback onPick;
  final void Function(String path) onRemove;

  @override
  Widget build(BuildContext context) {
    final g = GlassPalette.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SizedBox(height: 16),
        Text(
          '附件',
          style: TextStyle(fontSize: 13, color: g.inkTertiary),
        ),
        const SizedBox(height: 8),
        for (final path in paths)
          Container(
            margin: const EdgeInsets.only(bottom: 4),
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
            decoration: BoxDecoration(
              color: g.fieldBg,
              border: Border.all(color: g.fieldBorder),
              borderRadius: BorderRadius.circular(6),
            ),
            child: Row(
              children: [
                Icon(Icons.attach_file, size: 13, color: g.inkSecondary),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    p.basename(path),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 12, color: g.ink),
                  ),
                ),
                const SizedBox(width: 6),
                Text(
                  _sizeLabel(path),
                  style: TextStyle(fontSize: 11, color: g.inkTertiary),
                ),
                InkWell(
                  onTap: () => onRemove(path),
                  child: Padding(
                    padding: const EdgeInsets.only(left: 6),
                    child: Icon(Icons.close, size: 13, color: g.inkTertiary),
                  ),
                ),
              ],
            ),
          ),
        if (remaining > 0)
          Align(
            alignment: Alignment.centerLeft,
            child: OutlinedButton.icon(
              onPressed: onPick,
              icon: const Icon(Icons.add, size: 15),
              label: Text('添加文件（最多还能挂 $remaining 个）',
                  style: const TextStyle(fontSize: 12)),
              style: OutlinedButton.styleFrom(
                foregroundColor: g.accentSoft,
                side: BorderSide(color: g.fieldBorder),
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
              ),
            ),
          ),
      ],
    );
  }

  String _sizeLabel(String path) {
    try {
      return formatAttachmentSize(File(path).lengthSync());
    } catch (_) {
      // 文件可能已经被移走：这里只负责显示，真正收文件时还有第二次校验
      return '未知大小';
    }
  }
}
