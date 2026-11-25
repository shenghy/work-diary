import 'package:hive/hive.dart';

/// 项目里用到的全部 Hive box 名称。
///
/// 新增 box 时记得加到这里：退出软件、升级进程替换之前的 flush 依赖这份清单，
/// 漏掉的 box 在硬退出（`exit(0)`）时可能丢掉最后几次写入。
const List<String> kHiveBoxNames = <String>[
  'tasks', // 任务
  'repeat_rules', // 循环任务规则
  'repeat_skips', // 循环任务「已删除的期 / 已停止的族」账本
  'memos', // 备忘
  'attachments', // 任务/备忘附件的本地元数据（原件在同目录的 attachments/ 下）
  'attachment_deletions', // 待上报的附件删除墓碑
  'settings', // 设置 / 窗口位置 / 热键偏好
  'auth', // 登录态
  'sync_deletions', // 待同步的删除记录
];

/// flush 所有已打开的 box。
///
/// 注意：`Hive` 的静态类型是 `HiveInterface`，它没有 `boxes` getter
/// （只有实现类 `HiveImpl` 有），所以这里只能按已知名称清单遍历。
Future<void> flushOpenHiveBoxes() async {
  for (final name in kHiveBoxNames) {
    if (!Hive.isBoxOpen(name)) continue;
    try {
      await Hive.box(name).flush();
    } catch (_) {
      // 单个 box flush 失败不能影响退出/升级流程
    }
  }
}
