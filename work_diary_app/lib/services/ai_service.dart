import 'dart:convert';
import 'dart:typed_data';
import 'package:http/http.dart' as http;
import 'api_config.dart';
import 'auth_service.dart';

/// AI 识别出的任务
class RecognizedTask {
  final String title;
  final String urgency;       // 一般 / 重要 / 紧急
  final String? planStartAt;  // YYYY-MM-DD
  final String? dueAt;        // YYYY-MM-DD

  RecognizedTask({
    required this.title,
    this.urgency = '一般',
    this.planStartAt,
    this.dueAt,
  });

  factory RecognizedTask.fromJson(Map<String, dynamic> json) {
    return RecognizedTask(
      title: json['title']?.toString() ?? '',
      urgency: json['urgency']?.toString() ?? '一般',
      planStartAt: json['plan_start_at']?.toString(),
      dueAt: json['due_at']?.toString(),
    );
  }
}

/// 总结素材中的单个任务（与服务端 SummarizeTask 对应）
class SummarizeTaskItem {
  final String title;
  final int status; // 0计划中 1执行中 2已完成
  final int urgency; // 0一般 1紧急 2重要
  final int taskType; // 0个人 1工作
  final String? createdAt;
  final String? startedAt;
  final String? completedAt;

  SummarizeTaskItem({
    required this.title,
    required this.status,
    required this.urgency,
    required this.taskType,
    this.createdAt,
    this.startedAt,
    this.completedAt,
  });

  Map<String, dynamic> toJson() => {
        'title': title,
        'status': status,
        'urgency': urgency,
        'task_type': taskType,
        'created_at': createdAt,
        'started_at': startedAt,
        'completed_at': completedAt,
      };
}

/// AI 额度详情：单个功能今日/本月使用情况
class UsageItem {
  final int todayUsed;
  final int todayLimit;
  final int monthUsed;

  UsageItem({
    required this.todayUsed,
    required this.todayLimit,
    required this.monthUsed,
  });

  factory UsageItem.fromJson(Map<String, dynamic> json) => UsageItem(
        todayUsed: json['today_used'] ?? 0,
        todayLimit: json['today_limit'] ?? 0,
        monthUsed: json['month_used'] ?? 0,
      );

  double get progress =>
      todayLimit > 0 ? (todayUsed / todayLimit).clamp(0.0, 1.0) : 0.0;
}

/// AI 额度详情（今日/本月）
class AiUsage {
  final String date;
  final UsageItem ocr; // 截图任务
  final UsageItem daily; // AI日报总结
  final UsageItem weekly; // AI周报总结

  AiUsage({
    required this.date,
    required this.ocr,
    required this.daily,
    required this.weekly,
  });

  factory AiUsage.fromJson(Map<String, dynamic> json) {
    final items = json['items'] as Map<String, dynamic>? ?? {};
    Map<String, dynamic> item(String k) =>
        Map<String, dynamic>.from(items[k] as Map? ?? {});
    return AiUsage(
      date: json['date']?.toString() ?? '',
      ocr: UsageItem.fromJson(item('ocr')),
      daily: UsageItem.fromJson(item('daily')),
      weekly: UsageItem.fromJson(item('weekly')),
    );
  }
}

/// AI 截图识别服务：调用服务端 /api/ai/recognize-tasks
class AiService {
  /// AI 工作日志总结：把所选范围的任务交给服务端生成结构化 Markdown 日志
  /// [range]: day / week；[scope]: all / work / personal
  /// [tasks]: 已按日期与范围过滤好的任务素材
  static Future<String> summarizeTasks({
    required String range,
    required String scope,
    required String startDate, // YYYY-MM-DD
    required String endDate, // YYYY-MM-DD
    required List<SummarizeTaskItem> tasks,
  }) async {
    final uri = Uri.parse('${ApiConfig.baseUrl}/api/ai/summarize');
    final headers = <String, String>{
      'Content-Type': 'application/json',
      if (AuthService.token != null)
        'Authorization': 'Bearer ${AuthService.token}',
    };
    final body = jsonEncode({
      'range': range,
      'scope': scope,
      'start_date': startDate,
      'end_date': endDate,
      'tasks': tasks.map((t) => t.toJson()).toList(),
    });

    final resp = await http
        .post(uri, headers: headers, body: body)
        .timeout(const Duration(seconds: 90));

    if (resp.statusCode == 503) {
      throw Exception('AI 总结服务未配置：请联系管理员在服务端设置 DASHSCOPE_API_KEY');
    }
    if (resp.statusCode >= 400) {
      String msg = '总结失败(${resp.statusCode})';
      try {
        final data = jsonDecode(resp.body);
        if (data['detail'] != null) msg = data['detail'].toString();
      } catch (_) {}
      throw Exception(msg);
    }

    final data = jsonDecode(resp.body);
    final summary = data['summary']?.toString() ?? '';
    if (summary.isEmpty) {
      throw Exception('AI 返回内容为空，请重试');
    }
    return summary;
  }

  /// 发送截图到服务端，AI 识别工作任务
  static Future<List<RecognizedTask>> recognizeTasks(Uint8List imageBytes) async {
    final uri = Uri.parse('${ApiConfig.baseUrl}/api/ai/recognize-tasks');
    final headers = <String, String>{
      'Content-Type': 'application/json',
      if (AuthService.token != null)
        'Authorization': 'Bearer ${AuthService.token}',
    };
    final body = jsonEncode({
      'image': base64Encode(imageBytes),
    });

    final resp = await http
        .post(uri, headers: headers, body: body)
        .timeout(const Duration(seconds: 30));

    if (resp.statusCode == 503) {
      throw Exception('AI 识别服务未配置：请在服务端 .env 中设置 DASHSCOPE_API_KEY');
    }
    if (resp.statusCode >= 400) {
      String msg = '识别失败(${resp.statusCode})';
      try {
        final data = jsonDecode(resp.body);
        if (data['detail'] != null) msg = data['detail'].toString();
      } catch (_) {}
      throw Exception(msg);
    }

    final data = jsonDecode(resp.body);
    final tasks = (data['tasks'] as List? ?? [])
        .map((e) => RecognizedTask.fromJson(Map<String, dynamic>.from(e as Map)))
        .where((t) => t.title.isNotEmpty)
        .toList();
    return tasks;
  }

  /// 获取 AI 额度详情（需登录）：截图任务 / AI日报总结 / AI周报总结 的今日与本月使用情况
  static Future<AiUsage> fetchUsage() async {
    final uri = Uri.parse('${ApiConfig.baseUrl}/api/ai/usage');
    final headers = <String, String>{
      if (AuthService.token != null)
        'Authorization': 'Bearer ${AuthService.token}',
    };
    final resp = await http
        .get(uri, headers: headers)
        .timeout(const Duration(seconds: 10));

    if (resp.statusCode == 401 || resp.statusCode == 403) {
      throw Exception('登录已过期，请重新登录');
    }
    if (resp.statusCode >= 400) {
      String msg = '获取额度失败(${resp.statusCode})';
      try {
        final data = jsonDecode(resp.body);
        if (data['detail'] != null) msg = data['detail'].toString();
      } catch (_) {}
      throw Exception(msg);
    }

    final data = jsonDecode(resp.body) as Map<String, dynamic>;
    return AiUsage.fromJson(data);
  }
}
