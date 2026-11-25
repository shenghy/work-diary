import 'task_repository.dart';
// 条件导入：桌面/移动用 SQLite，Web 用内存
import 'task_repository_io.dart'
    if (dart.library.html) 'task_repository_web.dart';

/// 根据当前平台创建对应的数据仓库实现
TaskRepository createTaskRepository() => TaskRepositoryImpl();
