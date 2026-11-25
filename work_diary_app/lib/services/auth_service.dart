import 'package:hive_flutter/hive_flutter.dart';

/// 全局登录状态管理（Hive 持久化，重启后保持登录）
class AuthService {
  static const String _boxName = 'auth';
  static int? userId;
  static String? email;
  static String? token; // 后端 JWT，访问云端接口时使用

  /// 应用启动时调用，从本地恢复登录状态
  static Future<void> init() async {
    final box = await Hive.openBox(_boxName);
    userId = box.get('userId');
    email = box.get('email');
    token = box.get('token');
  }

  /// 已登录 = 有用户 id 且 token 非空。
  ///
  /// 只看 userId 是不够的：从旧版本升级上来时可能只有 userId 没有 token，
  /// 那样界面显示"已登录"，但每个请求都会 401，随后被登出，用户莫名其妙。
  static bool get isLoggedIn => userId != null && (token?.isNotEmpty ?? false);

  /// 登录成功，保存到本地
  static Future<void> login(int id, String e, {String? token}) async {
    userId = id;
    email = e;
    AuthService.token = token;
    final box = await Hive.openBox(_boxName);
    await box.put('userId', id);
    await box.put('email', e);
    if (token != null) await box.put('token', token);
  }

  /// 退出登录，清除本地状态
  static Future<void> logout() async {
    userId = null;
    email = null;
    token = null;
    final box = await Hive.openBox(_boxName);
    await box.clear();
  }
}
