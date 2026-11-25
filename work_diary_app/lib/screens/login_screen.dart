import 'dart:async';
import 'dart:math';
import 'package:flutter/material.dart';
import 'package:hive/hive.dart';
import 'package:flutter/services.dart';
import '../services/remote_sync_service.dart';
import '../services/auth_service.dart';
import '../services/email_service.dart';
import '../theme/glass_palette.dart';

/// 登录/注册/找回密码页面
class LoginScreen extends StatefulWidget {
  final VoidCallback onLoginSuccess;
  const LoginScreen({super.key, required this.onLoginSuccess});

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen>
    with TickerProviderStateMixin {
  final _emailCtrl = TextEditingController();
  final _passwordCtrl = TextEditingController();
  final _confirmCtrl = TextEditingController();
  final _codeCtrl = TextEditingController();

  bool _isRegister = false; // false=登录, true=注册或找回
  bool _isRecover = false; // true=找回密码模式
  bool _loading = false;
  bool _sending = false;
  bool _checkingEmail = false;
  bool _emailRegistered = false; // 邮箱失焦时检测到已注册
  int _countdown = 0;
  Timer? _timer;
  String? _error;

  final FocusNode _emailFocusNode = FocusNode();

  // ===== 滑块验证状态 =====
  bool _showSlider = false;
  double _sliderValue = 0.0;
  double _targetValue = 0.5;
  static const double _targetRange = 0.07;
  String _sliderHint = '拖动滑块到蓝色区域';
  bool _sliderVerified = false;
  AnimationController? _bounceAnim;

  @override
  void initState() {
    super.initState();
    _emailFocusNode.addListener(_onEmailFocusChange);
    _loadSavedCredentials();
  }

  /// 加载上次保存的登录账号（仅邮箱自动填入；密码不再明文保存），
  /// 并清理历史版本遗留的明文密码（安全）
  Future<void> _loadSavedCredentials() async {
    try {
      final box = await Hive.openBox('settings');
      final email = box.get('saved_email');
      if (box.get('saved_password') != null) {
        await box.delete('saved_password');
      }
      // 页面可能已关闭：控制器在 dispose 里释放，之后不能再写
      if (!mounted) return;
      if (email != null) _emailCtrl.text = email;
    } catch (_) {}
  }

  @override
  void dispose() {
    _timer?.cancel();
    _bounceAnim?.dispose();
    _emailFocusNode.removeListener(_onEmailFocusChange);
    _emailFocusNode.dispose();
    // 4 个输入控制器之前都没有释放，每次登录/登出都会泄漏一份
    _emailCtrl.dispose();
    _passwordCtrl.dispose();
    _confirmCtrl.dispose();
    _codeCtrl.dispose();
    super.dispose();
  }

  /// 邮箱输入框失去焦点时检查是否已注册
  void _onEmailFocusChange() {
    if (!_emailFocusNode.hasFocus && _isRegister && !_isRecover) {
      _checkEmailRegistered();
    }
  }

  /// 检查邮箱是否已注册（失焦时调用）
  Future<void> _checkEmailRegistered() async {
    final email = _emailCtrl.text.trim();
    if (!_isValidEmail(email)) {
      setState(() => _emailRegistered = false);
      return;
    }
    try {
      final registered = await RemoteSyncService.isEmailRegistered(email);
      if (mounted) setState(() => _emailRegistered = registered);
    } catch (_) {
      // 网络错误时不显示找回入口
    }
  }

  bool _isValidEmail(String email) {
    return RegExp(r'^[\w-\.]+@([\w-]+\.)+[\w-]{2,}$').hasMatch(email);
  }

  String get _title {
    if (!_isRegister) return '登录';
    return _isRecover ? '找回密码' : '注册账号';
  }

  String get _submitText {
    if (!_isRegister) return '登录';
    return _isRecover ? '重置密码' : '注册';
  }

  /// 点击获取验证码：先检查邮箱是否注册，再显示滑块
  Future<void> _onGetCode() async {
    final email = _emailCtrl.text.trim();
    if (!_isValidEmail(email)) {
      setState(() => _error = '请输入正确的邮箱地址');
      return;
    }
    setState(() {
      _checkingEmail = true;
      _error = null;
    });
    try {
      final registered = await RemoteSyncService.isEmailRegistered(email);
      if (registered && !_isRecover) {
        // 邮箱已注册，切换到找回密码模式
        setState(() {
          _isRecover = true;
          _error = '该邮箱已注册，可重置密码';
        });
      } else if (!registered && _isRecover) {
        // 邮箱未注册，切回注册模式
        setState(() {
          _isRecover = false;
          _error = null;
        });
      }
      // 显示滑块验证
      setState(() {
        _showSlider = true;
        _sliderValue = 0.0;
        _sliderVerified = false;
        _sliderHint = '拖动滑块到蓝色区域';
        _targetValue = 0.2 + Random().nextDouble() * 0.6;
      });
    } catch (e) {
      setState(() => _error = '网络错误，请重试');
    } finally {
      if (mounted) setState(() => _checkingEmail = false);
    }
  }

  /// 真正发送验证码
  Future<void> _doSendCode() async {
    final email = _emailCtrl.text.trim();
    setState(() => _sending = true);
    try {
      await EmailService.sendCode(email);
      _countdown = 60;
      _timer = Timer.periodic(const Duration(seconds: 1), (timer) {
        setState(() {
          _countdown--;
          if (_countdown <= 0) timer.cancel();
        });
      });
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('验证码已发送，请查收邮件')),
        );
      }
    } catch (e) {
      setState(() => _error = e.toString().replaceAll('Exception: ', ''));
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  /// 滑块拖动结束
  void _onDragEnd(DragEndDetails details) {
    if (_sliderVerified) return;
    final diff = (_sliderValue - _targetValue).abs();
    if (diff <= _targetRange) {
      setState(() {
        _sliderVerified = true;
        _sliderHint = '验证通过，正在发送...';
      });
      _doSendCode();
      Future.delayed(const Duration(seconds: 2), () {
        if (mounted) setState(() => _showSlider = false);
      });
    } else {
      _bounceAnim?.dispose();
      _bounceAnim = AnimationController(
        vsync: this,
        duration: const Duration(milliseconds: 300),
      );
      final start = _sliderValue;
      _bounceAnim!.addListener(() {
        setState(() => _sliderValue = start * (1 - _bounceAnim!.value));
      });
      _bounceAnim!.forward();
      setState(() => _sliderHint = '位置不对，重试');
    }
  }

  /// 滑块验证条
  Widget _buildSlider() {
    final g = GlassPalette.of(context);
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 8),
      decoration: BoxDecoration(
        color: g.fieldBg,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            _sliderHint,
            style: TextStyle(
              fontSize: 11,
              color: _sliderVerified ? g.success : g.inkTertiary,
            ),
          ),
          const SizedBox(height: 8),
          SizedBox(
            height: 28,
            child: LayoutBuilder(
              builder: (context, constraints) {
                final trackWidth = constraints.maxWidth;
                const handleSize = 24.0;
                final maxDrag = trackWidth - handleSize;
                final handleLeft = _sliderValue * maxDrag;
                final targetCenter = _targetValue * maxDrag + handleSize / 2;
                final targetWidth = _targetRange * 2 * maxDrag;
                final targetLeft = targetCenter - targetWidth / 2;

                return Stack(
                  children: [
                    Positioned(
                      left: 0,
                      right: 0,
                      top: 12,
                      child: Container(
                        height: 4,
                        decoration: BoxDecoration(
                          color: g.divider,
                          borderRadius: BorderRadius.circular(2),
                        ),
                      ),
                    ),
                    Positioned(
                      left: targetLeft,
                      top: 12,
                      width: targetWidth,
                      child: Container(
                        height: 4,
                        decoration: BoxDecoration(
                          color: _sliderVerified ? g.success : g.accent,
                          borderRadius: BorderRadius.circular(2),
                        ),
                      ),
                    ),
                    Positioned(
                      left: handleLeft,
                      top: 2,
                      child: GestureDetector(
                        onHorizontalDragUpdate: (details) {
                          if (_sliderVerified) return;
                          final newVal =
                              (_sliderValue + details.delta.dx / maxDrag)
                                  .clamp(0.0, 1.0);
                          setState(() => _sliderValue = newVal);
                        },
                        onHorizontalDragEnd: _onDragEnd,
                        child: Container(
                          width: handleSize,
                          height: 24,
                          decoration: BoxDecoration(
                            color: g.surface,
                            shape: BoxShape.circle,
                            border: Border.all(
                                color: _sliderVerified
                                    ? g.success
                                    : g.fieldBorder,
                                width: 1.5),
                            boxShadow: [
                              BoxShadow(
                                color: g.shadowSoft,
                                blurRadius: 4,
                                spreadRadius: 1,
                              ),
                            ],
                          ),
                          child: Icon(
                            _sliderVerified
                                ? Icons.check
                                : Icons.chevron_right,
                            size: 16,
                            color: _sliderVerified ? g.success : g.inkTertiary,
                          ),
                        ),
                      ),
                    ),
                  ],
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  /// 登录
  Future<void> _login() async {
    final email = _emailCtrl.text.trim();
    final password = _passwordCtrl.text;
    if (!_isValidEmail(email)) {
      setState(() => _error = '请输入正确的邮箱地址');
      return;
    }
    if (password.isEmpty) {
      setState(() => _error = '请输入密码');
      return;
    }
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final (userId, token) = await RemoteSyncService.login(email, password);
      await AuthService.login(userId, email, token: token);
      // 仅记住邮箱方便下次输入；密码不落盘（登录态由 AuthService 的 token 维持）
      try {
        final box = await Hive.openBox('settings');
        await box.put('saved_email', email);
      } catch (_) {}
      if (mounted) {
        widget.onLoginSuccess();
        Navigator.pop(context);
      }
    } catch (e) {
      setState(() => _error = e.toString().replaceAll('Exception: ', ''));
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  /// 注册
  Future<void> _register() async {
    final email = _emailCtrl.text.trim();
    final code = _codeCtrl.text.trim();
    final password = _passwordCtrl.text;
    final confirm = _confirmCtrl.text;

    if (!_isValidEmail(email)) {
      setState(() => _error = '请输入正确的邮箱地址');
      return;
    }
    if (code.isEmpty) {
      setState(() => _error = '请输入邮箱验证码');
      return;
    }
    if (password.length < 6) {
      setState(() => _error = '密码至少6位');
      return;
    }
    if (password != confirm) {
      setState(() => _error = '两次密码不一致');
      return;
    }

    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      // 服务端校验验证码后完成注册，验证码错误会抛异常
      final (userId, token) =
          await RemoteSyncService.registerByEmail(email, code, password);
      await AuthService.login(userId, email, token: token);
      // 仅记住邮箱方便下次输入；密码不落盘（登录态由 AuthService 的 token 维持）
      try {
        final box = await Hive.openBox('settings');
        await box.put('saved_email', email);
      } catch (_) {}
      if (mounted) {
        widget.onLoginSuccess();
        Navigator.pop(context);
      }
    } catch (e) {
      setState(() => _error = e.toString().replaceAll('Exception: ', ''));
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  /// 找回密码（重置密码）
  Future<void> _recover() async {
    final email = _emailCtrl.text.trim();
    final code = _codeCtrl.text.trim();
    final password = _passwordCtrl.text;
    final confirm = _confirmCtrl.text;

    if (!_isValidEmail(email)) {
      setState(() => _error = '请输入正确的邮箱地址');
      return;
    }
    if (code.isEmpty) {
      setState(() => _error = '请输入邮箱验证码');
      return;
    }
    if (password.length < 6) {
      setState(() => _error = '新密码至少6位');
      return;
    }
    if (password != confirm) {
      setState(() => _error = '两次密码不一致');
      return;
    }

    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      // 服务端校验验证码后重置密码，验证码错误会抛异常
      await RemoteSyncService.resetPassword(email, code, password);
      // 重置成功后自动登录
      final (userId, token) = await RemoteSyncService.login(email, password);
      await AuthService.login(userId, email, token: token);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('密码重置成功，已自动登录')),
        );
        widget.onLoginSuccess();
        Navigator.pop(context);
      }
    } catch (e) {
      setState(() => _error = e.toString().replaceAll('Exception: ', ''));
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  /// 显示用户协议/隐私政策弹窗
  void _showAgreement(String type) {
    final g = GlassPalette.of(context);
    final isUser = type == 'user';
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: g.surface,
        title: Text(isUser ? '用户协议' : '隐私政策',
            style: TextStyle(fontSize: 15, color: g.ink)),
        content: SizedBox(
          width: 500,
          height: 400,
          child: SingleChildScrollView(
            child: Text(
              isUser ? _userAgreementText : _privacyPolicyText,
              style: TextStyle(fontSize: 12, height: 1.8, color: g.ink),
            ),
          ),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context),
              style: TextButton.styleFrom(foregroundColor: g.accent),
              child: const Text('关闭')),
        ],
      ),
    );
  }

  static const String _userAgreementText = '''欢迎使用极简工作日记！

1. 服务说明
本软件是一款个人任务管理工具，提供本地任务记录、云端同步、AI 总结、任务提醒等功能。

2. 账号与使用
- 您需要注册账号才能使用云端同步和 AI 功能
- 您应对自己的账号信息和任务内容负责
- 不得利用本软件从事违法违规活动

3. 功能限制
- AI 功能（截图识别、日报总结、周报总结）有每日使用次数限制
- 免费用户：截图识别 10 次/天，AI 日报 3 次/天，AI 周报 3 次/天

4. 免责声明
- 本软件按"现状"提供，不保证完全无故障
- 因网络故障、服务器维护等原因导致数据同步失败，开发者不承担数据丢失责任
- 重要数据请自行备份

5. 协议变更
开发者保留修改本协议的权利，修改后将在软件内提示。
''';

  static const String _privacyPolicyText = '''我们非常重视您的隐私。

1. 我们收集的信息
- 账号信息：邮箱地址（用于登录）
- 任务数据：您创建的任务标题、内容、时间等（存储在服务器）
- 使用日志：AI 功能调用次数、错误日志（用于服务改进）

2. 信息如何使用
- 任务数据：用于云端同步，让您在多设备间同步任务
- AI 功能：将您的任务内容发送给 AI 服务生成总结，生成后即删除
- 错误日志：仅用于排查问题，不会用于其他用途

3. 信息存储
- 任务数据存储在您自己的服务器上
- 我们不会将您的任务数据分享给任何第三方
- 我们不会将您的任务数据用于广告或其他商业用途

4. 您的权利
- 您可以随时删除自己的任务数据
- 您可以联系作者删除账号和所有数据

5. 联系我们
如有隐私相关问题，请联系作者微信：php100
''';

  @override
  Widget build(BuildContext context) {
    final g = GlassPalette.of(context);
    final showCodeFields = _isRegister; // 注册和找回都需要验证码
    return Scaffold(
      appBar: AppBar(
        title: Text(_title),
        backgroundColor: g.accent,
        foregroundColor: Colors.white,
      ),
      body: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const SizedBox(height: 16),
            Icon(
              !_isRegister
                  ? Icons.email_outlined
                  : (_isRecover ? Icons.lock_reset : Icons.person_add),
              size: 52,
              color: g.accent,
            ),
            const SizedBox(height: 12),
            Text(
              !_isRegister
                  ? '欢迎回来'
                  : (_isRecover ? '重置密码' : '创建账号'),
              textAlign: TextAlign.center,
              style: TextStyle(
                  fontSize: 18, fontWeight: FontWeight.w600, color: g.ink),
            ),
            const SizedBox(height: 24),
            // 登录模式：展示登录好处（字少在上，字多在下）
            if (!_isRegister) ...[
              _BenefitRow(icon: Icons.crop_free, text: 'AI 截图建任务'),
              const SizedBox(height: 8),
              _BenefitRow(icon: Icons.article_outlined, text: 'AI 自动总结日报周报'),
              const SizedBox(height: 8),
              _BenefitRow(icon: Icons.cloud_sync_outlined, text: '云端存储，多端同步'),
              const SizedBox(height: 24),
            ],
            TextField(
              controller: _emailCtrl,
              focusNode: _emailFocusNode,
              keyboardType: TextInputType.emailAddress,
              decoration: InputDecoration(
                labelText: '邮箱地址',
                prefixIcon: const Icon(Icons.email_outlined),
                border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(10)),
              ),
            ),
            if (_isRegister && !_isRecover && _emailRegistered) ...[
              const SizedBox(height: 6),
              Text(
                '该邮箱已被注册，可点击下方「找回密码」',
                style: TextStyle(color: g.danger, fontSize: 12),
              ),
            ],
            const SizedBox(height: 16),
            // 注册/找回模式：滑块 + 验证码
            if (showCodeFields) ...[
              if (_showSlider) _buildSlider(),
              Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _codeCtrl,
                      keyboardType: TextInputType.number,
                      inputFormatters: [
                        FilteringTextInputFormatter.digitsOnly,
                        LengthLimitingTextInputFormatter(6),
                      ],
                      decoration: InputDecoration(
                        labelText: '邮箱验证码',
                        prefixIcon: const Icon(Icons.lock_outline),
                        border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(10)),
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  SizedBox(
                    height: 48,
                    child: OutlinedButton(
                      onPressed: (_sending ||
                              _countdown > 0 ||
                              _checkingEmail)
                          ? null
                          : _onGetCode,
                      style: OutlinedButton.styleFrom(
                        foregroundColor: g.accent,
                        side: BorderSide(color: g.accent),
                        shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(10)),
                      ),
                      child: _checkingEmail
                          ? const SizedBox(
                              width: 16,
                              height: 16,
                              child: CircularProgressIndicator(
                                  strokeWidth: 2))
                          : (_sending
                              ? const SizedBox(
                                  width: 16,
                                  height: 16,
                                  child: CircularProgressIndicator(
                                      strokeWidth: 2))
                              : Text(
                                  _countdown > 0
                                      ? '${_countdown}s'
                                      : '获取验证码',
                                  style: const TextStyle(fontSize: 13),
                                )),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 16),
            ],
            TextField(
              controller: _passwordCtrl,
              obscureText: true,
              decoration: InputDecoration(
                labelText: _isRegister
                    ? (_isRecover ? '新密码（至少6位）' : '设置密码（至少6位）')
                    : '密码',
                prefixIcon: const Icon(Icons.lock_outline),
                border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(10)),
              ),
            ),
            if (_isRegister) ...[
              const SizedBox(height: 16),
              TextField(
                controller: _confirmCtrl,
                obscureText: true,
                decoration: InputDecoration(
                  labelText: _isRecover ? '确认新密码' : '确认密码',
                  prefixIcon: const Icon(Icons.lock_outline),
                  border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(10)),
                ),
              ),
            ],
            if (_error != null) ...[
              const SizedBox(height: 12),
              Text(_error!, style: TextStyle(color: g.danger, fontSize: 12)),
            ],
            const SizedBox(height: 24),
            ElevatedButton(
              onPressed: _loading
                  ? null
                  : (!_isRegister
                      ? _login
                      : (_isRecover ? _recover : _register)),
              style: ElevatedButton.styleFrom(
                backgroundColor: g.accent,
                foregroundColor: Colors.white,
                padding: const EdgeInsets.symmetric(vertical: 14),
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(10)),
              ),
              child: _loading
                  ? const SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(
                          strokeWidth: 2, color: Colors.white))
                  : Text(_submitText),
            ),
            const SizedBox(height: 12),
            // 协议提示
            Center(
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text('登录即代表同意',
                      style: TextStyle(fontSize: 12, color: g.inkTertiary)),
                  GestureDetector(
                    onTap: () => _showAgreement('user'),
                    child: Text('《用户协议》',
                        style: TextStyle(fontSize: 12, color: g.accent)),
                  ),
                  Text('与', style: TextStyle(fontSize: 12, color: g.inkTertiary)),
                  GestureDetector(
                    onTap: () => _showAgreement('privacy'),
                    child: Text('《隐私政策》',
                        style: TextStyle(fontSize: 12, color: g.accent)),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 12),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                TextButton(
                  onPressed: () {
                    setState(() {
                      _isRegister = !_isRegister;
                      _isRecover = false;
                      _emailRegistered = false;
                      _error = null;
                      _showSlider = false;
                    });
                  },
                  child: Text(
                    _isRegister ? '已有账号？去登录' : '没有账号？注册一个',
                    style: TextStyle(color: g.accent),
                  ),
                ),
                // 登录模式始终显示找回密码；注册模式下邮箱已注册时显示找回密码
                if (!_isRegister || (_isRegister && !_isRecover && _emailRegistered)) ...[
                  const SizedBox(width: 24),
                  TextButton(
                    onPressed: () {
                      setState(() {
                        _isRegister = true;
                        _isRecover = true;
                        _emailRegistered = false;
                        _error = null;
                        _showSlider = false;
                      });
                    },
                    child: Text(
                      '找回密码',
                      style: TextStyle(color: g.accent),
                    ),
                  ),
                ],
              ],
            ),
          ],
        ),
      ),
    );
  }
}


class _BenefitRow extends StatelessWidget {
  final IconData icon;
  final String text;
  const _BenefitRow({required this.icon, required this.text});

  @override
  Widget build(BuildContext context) {
    final g = GlassPalette.of(context);
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Icon(icon, size: 16, color: g.accent),
        const SizedBox(width: 8),
        Text(text, style: TextStyle(fontSize: 13, color: g.inkSecondary)),
      ],
    );
  }
}
