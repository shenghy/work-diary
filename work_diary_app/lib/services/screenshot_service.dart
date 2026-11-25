import 'dart:convert';
import 'package:flutter/services.dart';

/// 虚拟屏幕信息（所有显示器的并集）
class VirtualScreen {
  final int left;
  final int top;
  final int width;
  final int height;

  VirtualScreen({
    required this.left,
    required this.top,
    required this.width,
    required this.height,
  });

  factory VirtualScreen.fromMap(Map<dynamic, dynamic> map) {
    return VirtualScreen(
      left: map['left'] as int,
      top: map['top'] as int,
      width: map['width'] as int,
      height: map['height'] as int,
    );
  }
}

/// 屏幕截图服务（Win32 平台通道）
///
/// 不预先截图，而是先获取虚拟屏幕信息，用户框选区域后再按坐标截取。
/// 这样多显示器下不会压缩画质。
class ScreenshotService {
  static const MethodChannel _channel =
      MethodChannel('com.workdiary/screenshot');

  /// 获取虚拟屏幕（所有显示器并集）的坐标和尺寸
  static Future<VirtualScreen> getVirtualScreen() async {
    try {
      final result = await _channel.invokeMethod('getVirtualScreen');
      return VirtualScreen.fromMap(result as Map);
    } on PlatformException catch (e) {
      throw Exception('获取屏幕信息失败: ${e.message}');
    }
  }

  /// 按虚拟屏幕坐标截取指定区域，返回 base64 编码的 PNG
  static Future<String?> captureRegion({
    required int x,
    required int y,
    required int width,
    required int height,
  }) async {
    try {
      final result = await _channel.invokeMethod<String>(
        'captureRegion',
        {
          'x': x,
          'y': y,
          'width': width,
          'height': height,
        },
      );
      return result;
    } on PlatformException catch (e) {
      throw Exception('截图失败: ${e.message}');
    }
  }

  /// 截取全屏（兼容旧方法，不推荐在多显示器下使用）
  static Future<String?> captureFullScreen() async {
    try {
      return await _channel.invokeMethod<String>('captureFullScreen');
    } on PlatformException catch (e) {
      throw Exception('截图失败: ${e.message}');
    }
  }

  /// 开启截图：创建独立的全屏窗口进行区域选择
  /// 返回裁剪后的图片 base64，空字符串表示用户取消
  static Future<String?> startScreenshot() async {
    try {
      return await _channel.invokeMethod<String>('startScreenshot');
    } on PlatformException catch (e) {
      throw Exception('截图失败: ${e.message}');
    }
  }
}
