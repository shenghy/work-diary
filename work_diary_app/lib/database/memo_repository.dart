import '../models/memo.dart';

/// 备忘数据仓库抽象接口
abstract class MemoRepository {
  Future<int> insertMemo(Memo memo);
  Future<List<Memo>> getMemos();
  Future<int> updateMemo(Memo memo);
  Future<int> deleteMemo(int id);
  /// 用云端结果覆盖本地。
  ///
  /// [keepAfter]：本次同步开始的时间。云端结果里没有、但本地在该时间之后
  /// 又被修改过的备忘会被保留（还没上传成功，删掉就是丢数据）。
  Future<void> replaceAll(List<Memo> memos, {DateTime? keepAfter});
}
