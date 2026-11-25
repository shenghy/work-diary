import 'dart:convert';
import 'package:http/http.dart' as http;
import 'api_config.dart';

/// 邮箱验证码服务（通过后端 /api/auth/send-code 发送，SMTP 在服务器上）
class EmailService {
  /// 发送邮箱验证码（后端有 60 秒冷却限制）
  static Future<void> sendCode(String email) async {
    final response = await http.post(
      Uri.parse('${ApiConfig.baseUrl}/api/auth/send-code'),
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({'email': email}),
    ).timeout(const Duration(seconds: 15));

    if (response.statusCode != 200) {
      String msg = '发送失败';
      try {
        final data = jsonDecode(response.body);
        if (data is Map && data['detail'] != null) {
          msg = data['detail'].toString();
        }
      } catch (_) {}
      throw Exception(msg);
    }
  }
}
