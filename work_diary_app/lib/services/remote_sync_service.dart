import 'dart:convert';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:http/http.dart' as http;
import '../models/task.dart';
import '../models/memo.dart';
import '../models/repeat_rule.dart';
import 'sync_websocket.dart';
import 'api_config.dart';
import 'app_logger.dart';
import 'auth_service.dart';

/// 云端服务（走 FastAPI 后端）
///
/// 注册 / 登录 / 找回密码 / 任务同步全部通过 HTTP API 完成，
/// 客户端不再直连 MySQL，只保存一个 API 地址（见 api_config.dart）。
class RemoteSyncService {
  /// 本地待同步删除记录（Hive 持久化）
  /// key = 本地任务 id，value = {local_id, remote_id, deleted_at}
  /// 登录后删除任务时写入，下次同步通知云端软删除，成功后清除
  static const String _deletionBoxName = 'sync_deletions';

  /// 通用请求：自动附带登录 token，并把后端错误信息解析成异常
  static Future<dynamic> _request(
    String method,
    String path, {
    Map<String, dynamic>? body,
  }) async {
    final uri = Uri.parse('${ApiConfig.baseUrl}$path');
    final headers = <String, String>{
      'Content-Type': 'application/json',
      'X-Client-Id': SyncClientId.instance,
      if (AuthService.token != null)
        'Authorization': 'Bearer ${AuthService.token}',
    };
    http.Response resp;
    try {
      switch (method) {
        case 'GET':
          resp = await http
              .get(uri, headers: headers)
              .timeout(const Duration(seconds: 15));
          break;
        case 'POST':
          resp = await http
              .post(uri, headers: headers, body: jsonEncode(body ?? {}))
              .timeout(const Duration(seconds: 15));
          break;
        case 'PATCH':
          resp = await http
              .patch(uri, headers: headers, body: jsonEncode(body ?? {}))
              .timeout(const Duration(seconds: 15));
          break;
        case 'DELETE':
          resp = await http
              .delete(uri, headers: headers)
              .timeout(const Duration(seconds: 15));
          break;
        default:
          throw Exception('不支持的请求方式');
      }
    } catch (_) {
      throw Exception('网络错误，请检查网络或服务器地址');
    }

    dynamic data;
    try {
      // 必须按 UTF-8 解码字节：http 包在响应头没有 charset 时会回退 latin1，
      // 而 FastAPI 的 JSONResponse 只发 application/json，中文会变成乱码。
      data = resp.bodyBytes.isEmpty
          ? <String, dynamic>{}
          : jsonDecode(utf8.decode(resp.bodyBytes, allowMalformed: true));
    } catch (_) {
      data = <String, dynamic>{};
    }
    if (resp.statusCode >= 200 && resp.statusCode < 300) {
      return data is Map<String, dynamic> ? data : <String, dynamic>{};
    }
    // 登录态失效：清除本地登录信息，下次操作会引导重新登录。
    // 排除认证接口本身（登录密码错误也是 401），否则在登录页输错密码
    // 会把本地已保存的登录态一起清掉。
    if (resp.statusCode == 401 &&
        AuthService.token != null &&
        !path.startsWith('/api/auth/')) {
      await AuthService.logout();
    }
    String msg = '请求失败(${resp.statusCode})';
    if (data is Map && data['detail'] != null) {
      msg = data['detail'].toString();
    }
    throw Exception(msg);
  }

  // ================= 认证 =================

  /// 登录，成功返回 (userId, token)
  static Future<(int, String)> login(String email, String password) async {
    final data = await _request('POST', '/api/auth/login', body: {
      'email': email,
      'password': password,
    });
    return (data['user']['id'] as int, data['token'] as String);
  }

  /// 邮箱注册（服务端校验验证码），成功返回 (userId, token)
  static Future<(int, String)> registerByEmail(
    String email,
    String code,
    String password,
  ) async {
    final data = await _request('POST', '/api/auth/register', body: {
      'email': email,
      'code': code,
      'password': password,
    });
    return (data['user']['id'] as int, data['token'] as String);
  }

  /// 检查邮箱是否已注册
  static Future<bool> isEmailRegistered(String email) async {
    final data = await _request(
      'GET',
      '/api/auth/email-status?email=${Uri.encodeQueryComponent(email)}',
    );
    return data['registered'] == true;
  }

  /// 找回密码（服务端校验验证码）
  static Future<void> resetPassword(
    String email,
    String code,
    String newPassword,
  ) async {
    await _request('POST', '/api/auth/reset-password', body: {
      'email': email,
      'code': code,
      'password': newPassword,
    });
  }

  /// 记录一条本地删除：下次同步时通知云端把该任务软删除
  static Future<void> recordLocalDeletion(int localId, int? remoteId) async {
    final box = await Hive.openBox(_deletionBoxName);
    await box.put('$localId', {
      'local_id': localId,
      'remote_id': remoteId,
      'deleted_at': DateTime.now().toIso8601String(),
    });
  }

  // ================= 任务同步 =================

  /// 逐条合并同步（最后写入胜出 LWW），返回云端全部未删除任务 + 已删除的循环实例
  /// + 全部循环规则。
  ///
  /// [repeatRules] 为本机全部循环规则（数量很小，每轮全量上报即可，服务端按
  /// updated_at 做 LWW 合并）。这样换设备后规则不丢、停止循环也能同步到其它设备。
  static Future<TaskSyncResult> syncTasks(
    int userId,
    List<Task> localTasks, {
    Map<String, RepeatRule> repeatRules = const <String, RepeatRule>{},
  }) async {
    // 待同步的本地删除
    final deletions = <Map<String, dynamic>>[];
    final box = await Hive.openBox(_deletionBoxName);
    for (final key in box.keys.toList()) {
      // 备忘删除记录（memo_ 前缀）由 syncMemos 单独上报，这里只收集任务删除
      if (key.toString().startsWith('memo_')) continue;
      final entry = Map<String, dynamic>.from(box.get(key) as Map);
      // remote_id 未知（新建后未完成同步即删除）的记录暂不上报：服务端
      // DeletionItem.remote_id 必填，传 null 会让整次同步 422，而失败又不会
      // 清理这条记录 —— 结果是任务同步永久失效。收尾时从云端返回里补
      // remote_id，下一轮再上报（与 syncMemos 的处理保持一致）。
      if (entry['remote_id'] is! int) continue;
      deletions.add({
        'local_id': entry['local_id'],
        'remote_id': entry['remote_id'],
        'deleted_at': _utcIso(
          DateTime.tryParse(entry['deleted_at'].toString()) ?? DateTime.now(),
        ),
      });
    }

    final data = await _request('POST', '/api/tasks/sync', body: {
      'tasks': localTasks.map(_taskToApi).toList(),
      'deletions': deletions,
      // 循环规则：服务端按 group_id 做 LWW 合并后全量回传
      // （repeatType<=0 的规则没有意义，不上报，避免服务端校验失败拖垮整次同步）
      'repeat_groups': repeatRules.values
          .where((r) => r.repeatType > 0 && r.repeatGroupId.isNotEmpty)
          .map(_ruleToApi)
          .toList(),
    });

    // 逐条解析：单条脏数据不能让整次同步失败（否则用户看到的是"同步失败"，
    // 而本地数据一条都不会更新）。
    final remoteTasks = <Task>[];
    for (final e in (data['tasks'] as List)) {
      try {
        remoteTasks.add(_taskFromApi(Map<String, dynamic>.from(e as Map)));
      } catch (err) {
        AppLogger.instance.error('解析云端任务失败，已跳过该条', err);
      }
    }

    // 云端下发的「已被删除的循环实例」：别的设备删掉的某一期，
    // 本机要写进跳过账本，否则补生成引擎会把它再补回来。
    final skips = <String, Set<String>>{};
    final rawSkips = data['skips'];
    if (rawSkips is List) {
      for (final e in rawSkips) {
        try {
          final m = Map<String, dynamic>.from(e as Map);
          final gid = (m['repeat_group_id'] ?? '').toString();
          final date = (m['instance_date'] ?? '').toString();
          if (gid.isEmpty || date.isEmpty) continue;
          skips.putIfAbsent(gid, () => <String>{}).add(date);
        } catch (err) {
          AppLogger.instance.error('解析云端跳过记录失败，已跳过该条', err);
        }
      }
    }

    // 云端下发的循环规则（含"已停止"状态）：其它设备建的循环、以及停止操作
    // 都靠这一段同步过来。
    final rules = <String, RepeatRule>{};
    final rawRules = data['repeat_groups'];
    if (rawRules is List) {
      for (final e in rawRules) {
        try {
          final rule = _ruleFromApi(Map<String, dynamic>.from(e as Map));
          if (rule.repeatGroupId.isEmpty || rule.repeatType <= 0) continue;
          rules[rule.repeatGroupId] = rule;
        } catch (err) {
          AppLogger.instance.error('解析云端循环规则失败，已跳过该条', err);
        }
      }
    }

    // 待同步删除记录收尾：
    // - remote_id 已有 -> 本轮已上报云端，云端处理后不会返回该任务，直接清除记录
    // - remote_id 为空（添加后未完成同步即删除）-> 尝试从云端返回的任务解析出
    //   remote_id 并保留记录，下轮同步再上报删除；云端没有该任务 -> 清除
    final pendingIds = <int>{};
    for (final key in box.keys.toList()) {
      if (key.toString().startsWith('memo_')) continue; // 备忘记录交给 syncMemos
      final entry = Map<String, dynamic>.from(box.get(key) as Map);
      final lid = entry['local_id'];
      final rid = entry['remote_id'];
      if (lid is int) pendingIds.add(lid);
      if (rid is int) {
        await box.delete(key);
      } else {
        Task? matched;
        for (final t in remoteTasks) {
          if (t.id == lid) {
            matched = t;
            break;
          }
        }
        if (matched != null) {
          entry['remote_id'] = matched.remoteId;
          await box.put(key, entry);
        } else {
          await box.delete(key);
        }
      }
    }
    // 云端仍返回但本地已删除的任务 -> 剔除，避免"删除后复活"
    return TaskSyncResult(
      tasks: remoteTasks.where((t) => !pendingIds.contains(t.id)).toList(),
      skips: skips,
      rules: rules,
    );
  }

  // ================= 备忘同步 =================

  /// 逐条合并同步（最后写入胜出 LWW），返回云端全部未删除备忘
  static Future<List<Memo>> syncMemos(int userId, List<Memo> localMemos) async {
    // 待同步的本地删除（复用同一删除记录 box，key 前加 memo_ 前缀避免与任务冲突）
    final deletions = <Map<String, dynamic>>[];
    final box = await Hive.openBox(_deletionBoxName);
    for (final key in box.keys.toList()) {
      final k = key.toString();
      if (!k.startsWith('memo_')) continue;
      final entry = Map<String, dynamic>.from(box.get(key) as Map);
      // remote_id 未知（添加后未完成同步即删除）的记录暂不上报
      //（服务端 remote_id 必填校验会 422），收尾时从云端返回的备忘解析出
      // remote_id，下轮同步再上报删除
      if (entry['remote_id'] is! int) continue;
      deletions.add({
        'local_id': entry['local_id'],
        'remote_id': entry['remote_id'],
        'deleted_at': _utcIso(
          DateTime.tryParse(entry['deleted_at'].toString()) ?? DateTime.now(),
        ),
      });
    }

    final data = await _request('POST', '/api/memos/sync', body: {
      'memos': localMemos.map(_memoToApi).toList(),
      'deletions': deletions,
    });

    // 云端返回的未删除备忘（逐条解析，单条异常不拖垮整次同步）
    final remoteMemos = <Memo>[];
    for (final e in (data['memos'] as List)) {
      try {
        remoteMemos.add(_memoFromApi(Map<String, dynamic>.from(e as Map)));
      } catch (err) {
        AppLogger.instance.error('解析云端备忘失败，已跳过该条', err);
      }
    }
    // 云端已软删除的备忘 remote_id
    final deletedIds = (data['deleted_ids'] as List?)?.cast<int>() ?? const <int>[];

    // 合并：以本地为基础，远端较新者胜出；本地独有条目保留（下次同步重新上传），防止云端数据不全覆盖本地
    // 注意：不能用 -1 之类的占位 key —— 云端 id 为 null 的备忘（其它设备/小程序写入）
    // 会全部塌缩到同一个 key 互相覆盖，随后 replaceAll 把其余几条从本地清掉。
    final merged = <int, Memo>{};
    final withoutLocalId = <Memo>[];
    for (final m in localMemos) {
      if (m.id != null) merged[m.id!] = m;
    }
    for (final m in remoteMemos) {
      final key2 = m.id;
      if (key2 == null) {
        withoutLocalId.add(m);
        continue;
      }
      final existing = merged[key2];
      // 远端时间不早于本地即采用远端副本：首次同步时服务端回写的是同一时间戳，
      // 若仅在"远端更晚"时才采用，本地 memo 的 remoteId 永远填不上，
      // 删除时因 remoteId 为空记不了 tombstone，备忘会在下次同步"复活"
      if (existing == null || !existing.updatedAt.isAfter(m.updatedAt)) {
        merged[key2] = m;
      }
    }
    // 云端已删除的条目 -> 本地同步删除
    for (final rid in deletedIds) {
      merged.removeWhere((_, m) => m.remoteId == rid);
    }

    // 待同步删除记录收尾：
    // - 云端已确认（deleted_ids 命中）-> 清除记录
    // - remote_id 为空 -> 尝试从云端返回的备忘解析出 remote_id，保留记录下轮再删；
    //   云端没有该备忘（从未上传成功）-> 清除
    // - 云端仍返回但本地已删除的备忘 -> 从合并结果剔除，避免"删除后复活"
    final pendingIds = <int>{};
    for (final key in box.keys.toList()) {
      if (!key.toString().startsWith('memo_')) continue;
      final entry = Map<String, dynamic>.from(box.get(key) as Map);
      final lid = entry['local_id'];
      final rid = entry['remote_id'];
      if (lid is int) pendingIds.add(lid);
      if (rid is int && deletedIds.contains(rid)) {
        await box.delete(key);
      } else if (rid is! int) {
        Memo? matched;
        for (final rm in remoteMemos) {
          if (rm.id == lid) {
            matched = rm;
            break;
          }
        }
        if (matched != null) {
          entry['remote_id'] = matched.remoteId;
          await box.put(key, entry);
        } else {
          await box.delete(key);
        }
      }
    }
    merged.removeWhere((_, m) => pendingIds.contains(m.id));

    // 云端没有本地 id 的备忘原样带回：由 replaceAll 分配新的本地 id。
    // 已在本机删除（pendingIds 含其 remoteId）或云端已删的排除掉。
    final extra = withoutLocalId
        .where((m) => !deletedIds.contains(m.remoteId))
        .toList();

    final result = <Memo>[...merged.values, ...extra]
      ..sort((a, b) => b.createdAt.compareTo(a.createdAt));
    return result;
  }

  /// 记录一条本地备忘删除：下次同步时通知云端软删除
  static Future<void> recordMemoDeletion(int localId, int? remoteId) async {
    final box = await Hive.openBox(_deletionBoxName);
    await box.put('memo_$localId', {
      'local_id': localId,
      'remote_id': remoteId,
      'deleted_at': DateTime.now().toIso8601String(),
    });
  }

  // ================= 备忘序列化 =================

  /// 备忘 -> API 请求体
  static Map<String, dynamic> _memoToApi(Memo m) => {
        'id': m.id,
        'remote_id': m.remoteId,
        'content': m.content,
        'created_at': _utcIso(m.createdAt),
        'updated_at': _utcIso(m.updatedAt),
      };

  /// API 返回（UTC 字符串）-> 本地 Memo（时间转本地时区）
  static Memo _memoFromApi(Map<String, dynamic> m) {
    DateTime parse(String s) => DateTime.parse(s).toLocal();
    return Memo(
      id: m['id'] as int?,
      remoteId: m['remote_id'] as int,
      content: m['content'] as String,
      createdAt: parse(m['created_at'] as String),
      updatedAt: parse(m['updated_at'] as String),
    );
  }

  /// 测试连接是否可用
  static Future<bool> testConnection() async {
    try {
      await _request('GET', '/api/health');
      return true;
    } catch (_) {
      return false;
    }
  }

  // ================= 序列化 =================

  /// 本地时间 -> UTC ISO 字符串（与服务端一致）
  static String _utcIso(DateTime dt) => dt.toUtc().toIso8601String();

  /// 只取日期部分（服务端 instance_date 是字符串 YYYY-MM-DD）
  static String _isoDate(DateTime dt) =>
      '${dt.year.toString().padLeft(4, '0')}-'
      '${dt.month.toString().padLeft(2, '0')}-'
      '${dt.day.toString().padLeft(2, '0')}';

  /// "1,3,5" / [1,3,5] -> List<int>；其余情况返回 null
  static List<int>? _parseWeekDays(Object? raw) {
    if (raw is List) {
      final list = raw
          .map((e) => e is int ? e : int.tryParse(e.toString()))
          .whereType<int>()
          .toList();
      return list.isEmpty ? null : list;
    }
    if (raw is String && raw.isNotEmpty) {
      final list =
          raw.split(',').map((e) => int.tryParse(e.trim())).whereType<int>().toList();
      return list.isEmpty ? null : list;
    }
    return null;
  }

  /// 任务 -> API 请求体
  static Map<String, dynamic> _taskToApi(Task t) => {
        'id': t.id,
        'remote_id': t.remoteId,
        'title': t.title,
        'status': t.status.index,
        'urgency': t.urgency.index,
        'created_at': _utcIso(t.createdAt),
        'started_at': t.startedAt != null ? _utcIso(t.startedAt!) : null,
        'completed_at':
            t.completedAt != null ? _utcIso(t.completedAt!) : null,
        'plan_start_at':
            t.planStartAt != null ? _utcIso(t.planStartAt!) : null,
        'due_at': t.dueAt != null ? _utcIso(t.dueAt!) : null,
        'sort_order': t.sortOrder,
        'task_type': t.taskType,
        // 循环任务字段必须一起上报：服务端 TaskIn 对缺失字段用默认值 0 覆盖，
        // 漏发等于每次同步都把云端的循环规则清空一次。
        'repeat_type': t.repeatType,
        'repeat_week_days': t.repeatWeekDays?.join(','),
        'repeat_month_day': t.repeatMonthDay,
        'repeat_group_id': t.repeatGroupId,
        'instance_date':
            t.instanceDate == null ? null : _isoDate(t.instanceDate!),
        'updated_at': _utcIso(t.updatedAt),
      };

  /// API 返回（UTC 字符串）-> 本地 Task（时间转本地时区，与旧行为一致）
  static Task _taskFromApi(Map<String, dynamic> m) {
    DateTime parse(String s) => DateTime.parse(s).toLocal();
    return Task(
      id: m['id'] as int?,
      remoteId: m['remote_id'] as int,
      title: m['title'] as String,
      status: TaskStatus.values[m['status'] as int],
      urgency: Urgency.values[m['urgency'] as int],
      createdAt: parse(m['created_at'] as String),
      startedAt: m['started_at'] != null
          ? parse(m['started_at'] as String)
          : null,
      completedAt: m['completed_at'] != null
          ? parse(m['completed_at'] as String)
          : null,
      planStartAt: m['plan_start_at'] != null
          ? parse(m['plan_start_at'] as String)
          : null,
      dueAt: m['due_at'] != null ? parse(m['due_at'] as String) : null,
      sortOrder: (m['sort_order'] as int?) ?? 0,
      taskType: (m['task_type'] as int?) ?? 1,
      repeatType: (m['repeat_type'] as int?) ?? 0,
      repeatWeekDays: _parseWeekDays(m['repeat_week_days']),
      repeatMonthDay: m['repeat_month_day'] as int?,
      repeatGroupId: m['repeat_group_id'] as String?,
      instanceDate: m['instance_date'] is String
          ? DateTime.tryParse(m['instance_date'] as String)
          : null,
      updatedAt: parse(m['updated_at'] as String),
    );
  }

  // ================= 循环规则序列化 =================

  /// 循环规则 -> API 请求体。
  ///
  /// 只上报规则本身，不上报 `skip_dates`：跳过记录走 `repeat_skips` 通道，
  /// 两边口径统一，避免规则时间戳因为"删了一期"而被无意义地刷新。
  static Map<String, dynamic> _ruleToApi(RepeatRule r) => {
        'group_id': r.repeatGroupId,
        'title': r.title,
        'urgency': r.urgency.index,
        'task_type': r.taskType,
        'repeat_type': r.repeatType,
        'repeat_week_days': r.repeatWeekDays?.join(','),
        'repeat_month_day': r.repeatMonthDay,
        'plan_start_at':
            r.planStartAt == null ? null : _utcIso(r.planStartAt!),
        'due_at': r.dueAt == null ? null : _utcIso(r.dueAt!),
        'stopped': r.stopped,
        'deleted': r.deleted,
        'updated_at': _utcIso(r.updatedAt),
      };

  /// API 返回（UTC 字符串）-> 本地 RepeatRule
  static RepeatRule _ruleFromApi(Map<String, dynamic> m) {
    DateTime? parse(Object? raw) =>
        raw is String ? DateTime.parse(raw).toLocal() : null;
    final rawType = m['repeat_type'];
    final rawUrgency = m['urgency'];
    final rawTaskType = m['task_type'];
    final rawMonthDay = m['repeat_month_day'];
    final rawStopped = m['stopped'];
    final rawDeleted = m['deleted'];
    return RepeatRule(
      repeatGroupId: (m['group_id'] ?? '').toString(),
      title: (m['title'] ?? '').toString(),
      urgency: rawUrgency is int && rawUrgency >= 0 && rawUrgency < Urgency.values.length
          ? Urgency.values[rawUrgency]
          : Urgency.normal,
      taskType: rawTaskType is int ? rawTaskType : 1,
      repeatType: rawType is int ? rawType : 0,
      repeatWeekDays: _parseWeekDays(m['repeat_week_days']),
      repeatMonthDay: rawMonthDay is int ? rawMonthDay : null,
      planStartAt: parse(m['plan_start_at']),
      dueAt: parse(m['due_at']),
      stopped: rawStopped == true || rawStopped == 1,
      deleted: rawDeleted == true || rawDeleted == 1,
      updatedAt: parse(m['updated_at']) ?? DateTime.fromMillisecondsSinceEpoch(0),
    );
  }
}

/// 任务同步结果。
class TaskSyncResult {
  const TaskSyncResult({
    required this.tasks,
    required this.skips,
    this.rules = const <String, RepeatRule>{},
  });

  /// 云端全部未删除任务
  final List<Task> tasks;

  /// 云端下发的「已删除循环实例」：键 = repeatGroupId，值 = YYYY-MM-DD 集合
  final Map<String, Set<String>> skips;

  /// 云端全部循环规则（键 = repeatGroupId，含 stopped 状态）
  final Map<String, RepeatRule> rules;
}
