import '../models/repeat_rule.dart';
import '../models/task.dart';

/// 任务数据仓库抽象接口
/// 桌面/移动端用 Hive 实现，Web 端用内存实现
abstract class TaskRepository {
  Future<int> insertTask(Task task);
  Future<List<Task>> getTasks({TaskStatus? status});
  Future<int> updateTask(Task task);
  Future<int> deleteTask(int id);
  /// 用云端结果覆盖本地。
  ///
  /// [keepAfter]：本次同步开始的时间。云端结果里没有、但本地在该时间之后
  /// 又被修改过的任务会被保留（它们还没上传成功，删掉就是丢数据）。
  Future<void> replaceAll(List<Task> tasks, {DateTime? keepAfter});

  // ===== 循环任务规则库（与实例分离持久化）=====
  /// 全部循环规则：键 = repeatGroupId
  Future<Map<String, RepeatRule>> getRepeatRules();
  /// 写入 / 更新一条循环规则
  Future<void> putRepeatRule(RepeatRule rule);
  /// 物理删除一条循环规则（仅用于数据清理）。
  ///
  /// 用户侧的"停止循环"请用 [stopRepeatGroup]：它保留规则并打 stopped 标记，
  /// 这样能同步到其它设备、也能在「循环任务」里恢复。
  Future<void> deleteRepeatRule(String repeatGroupId);

  /// 标记"本期已被用户删除"，引擎生成时跳过该日期，避免删掉的实例立刻被补回来。
  ///
  /// 独立于规则库存储：删除某一期的设备上可能根本没有规则，
  /// 所以跳过记录必须自己存一份，不能只存在规则里。
  Future<void> skipRepeatInstance(Task task);

  /// 全部跳过记录：键 = repeatGroupId，值 = 日期集合（YYYY-MM-DD）
  Future<Map<String, Set<String>>> getRepeatSkips();

  /// 标记"该族已停止循环"：规则打上 stopped 标记（随同步下发到其它设备），
  /// 并在本地跳过账本写入哨兵 [RepeatRule.stoppedMarker]（规则丢失时兜底）。
  ///
  /// 只删规则是不够的：引擎在规则缺失时会回退到"用现存实例当模板"，
  /// 同族还有任何一条实例就会继续补生成。
  Future<void> stopRepeatGroup(String groupId);

  /// 恢复循环：清掉 stopped 标记与本地哨兵，今后照常生成新一期。
  Future<void> resumeRepeatGroup(String groupId);

  /// 合并云端下发的循环规则（按 `updatedAt` 走 LWW，本地更晚的保留等下一轮上传）
  Future<void> mergeRepeatRules(Map<String, RepeatRule> rules);

  /// 合并云端下发的跳过记录（取并集，不会覆盖本地已有的）
  Future<void> mergeRepeatSkips(Map<String, Set<String>> skips);
}
