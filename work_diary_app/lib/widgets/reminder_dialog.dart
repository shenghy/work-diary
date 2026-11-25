import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../models/task.dart';
import '../theme/glass_palette.dart';

/// 显示在屏幕右下角的任务提醒对话框
class ReminderDialog extends StatelessWidget {
  final List<Task> tasks;
  final String type; // 'start' 或 'due'

  const ReminderDialog({
    super.key,
    required this.tasks,
    required this.type,
  });

  /// 显示提醒对话框（右下角），并播放系统音效
  static Future<void> show(BuildContext context, List<Task> tasks, String type) async {
    // 播放系统提示音
    SystemSound.play(SystemSoundType.alert);

    await showGeneralDialog(
      context: context,
      barrierDismissible: true,
      barrierLabel: 'dismiss',
      barrierColor: Colors.transparent,
      transitionDuration: const Duration(milliseconds: 250),
      transitionBuilder: (context, animation, secondaryAnimation, child) {
        return SlideTransition(
          position: Tween<Offset>(
            begin: const Offset(0, 0.3),
            end: Offset.zero,
          ).animate(CurvedAnimation(parent: animation, curve: Curves.easeOut)),
          child: FadeTransition(opacity: animation, child: child),
        );
      },
      pageBuilder: (context, animation, secondaryAnimation) {
        return Align(
          alignment: Alignment.bottomRight,
          child: Padding(
            padding: const EdgeInsets.only(bottom: 24, right: 24),
            child: ReminderDialog(tasks: tasks, type: type),
          ),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final g = GlassPalette.of(context);
    final isStart = type == 'start';
    final title = isStart ? '任务开始提醒' : '任务完成提醒';
    final subtitle = isStart
        ? '以下 ${tasks.length} 个任务即将在 10 分钟内开始'
        : '以下 ${tasks.length} 个任务即将在 20 分钟内到达完成时间';
    final accent = isStart ? g.accent : g.warning;

    return Material(
      elevation: 12,
      borderRadius: BorderRadius.circular(12),
      child: Container(
        width: 360,
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(12),
          color: g.surface,
          border: Border.all(color: accent, width: 1.5),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  isStart ? Icons.alarm : Icons.warning_amber_rounded,
                  color: accent,
                  size: 22,
                ),
                const SizedBox(width: 8),
                Text(
                  title,
                  style: TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.bold,
                    color: g.ink,
                  ),
                ),
                const Spacer(),
                IconButton(
                  icon: Icon(Icons.close, size: 18, color: g.inkTertiary),
                  onPressed: () => Navigator.of(context).pop(),
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              subtitle,
              style: TextStyle(fontSize: 12, color: g.inkTertiary),
            ),
            const SizedBox(height: 12),
            // 同时到点的任务可能很多：限制高度并滚动，否则会超出窗口
            ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 320),
              child: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: tasks
                      .map((task) => Padding(
                            padding: const EdgeInsets.only(bottom: 8),
                            child: Row(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Container(
                                  width: 6,
                                  height: 6,
                                  margin: const EdgeInsets.only(top: 7, right: 8),
                                  decoration: BoxDecoration(
                                    color: accent,
                                    shape: BoxShape.circle,
                                  ),
                                ),
                                Expanded(
                                  child: Text(
                                    task.title,
                                    style: TextStyle(
                                        fontSize: 13, color: g.inkSecondary),
                                    maxLines: 2,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                ),
                              ],
                            ),
                          ))
                      .toList(),
                ),
              ),
            ),
            const SizedBox(height: 8),
            SizedBox(
              width: double.infinity,
              child: ElevatedButton(
                onPressed: () => Navigator.of(context).pop(),
                style: ElevatedButton.styleFrom(
                  backgroundColor: accent,
                  foregroundColor: Colors.white,
                  padding: const EdgeInsets.symmetric(vertical: 10),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                ),
                child: const Text('知道了', style: TextStyle(fontSize: 13)),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
