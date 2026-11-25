import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:hive/hive.dart';
import 'package:uuid/uuid.dart';

import '../database/hive_bootstrap.dart';

/// 本机设备身份：附件"按需中转"要知道"我是哪台机器"。
///
/// `SyncClientId` 每次启动都是新随机值，只能用来排除自己的推送；附件的归属、
/// "此文件在其它主机"的提示、以及"谁请求了这份文件"必须用一个跨启动稳定不变的
/// id，否则每次重开软件都会被当成一台新设备，中转请求永远对不上。
class DeviceIdentity {
  DeviceIdentity._();

  static const String _boxName = 'settings';
  static const String _keyId = 'device_id';
  static const String _keyName = 'device_display_name';

  static String _id = '';
  static String _name = '';

  /// 稳定设备 id（首次运行生成，之后一直复用）
  static String get id {
    if (_id.isNotEmpty) return _id;
    return 'unknown-device';
  }

  /// 展示用名称：默认取系统主机名，用户可在"设置"里改名
  static String get name {
    if (_name.isNotEmpty) return _name;
    try {
      return Platform.localHostname;
    } catch (_) {
      return '本机';
    }
  }

  static Future<Box<dynamic>> _box() async {
    await HiveBootstrap.ensureInitialized();
    if (Hive.isBoxOpen(_boxName)) return Hive.box(_boxName);
    return Hive.openBox(_boxName);
  }

  static Future<void> init() async {
    try {
      final box = await _box();
      final storedId = box.get(_keyId);
      if (storedId is String && storedId.isNotEmpty) {
        _id = storedId;
      } else {
        // 长度受服务端限制（VARCHAR(64)），UUID v4 是 36 位，安全
        _id = const Uuid().v4();
        await box.put(_keyId, _id);
      }
      final storedName = box.get(_keyName);
      if (storedName is String && storedName.isNotEmpty) _name = storedName;
    } catch (_) {
      // 读不到也不能阻塞启动：用一个本次会话内稳定的随机 id 顶上
      _id = const Uuid().v4();
    }
  }

  /// 用户自定义的设备名（空串=用主机名）
  static Future<void> setDisplayName(String value) async {
    final trimmed = value.trim();
    _name = trimmed;
    try {
      final box = await _box();
      if (trimmed.isEmpty) {
        await box.delete(_keyName);
      } else {
        await box.put(_keyName, trimmed);
      }
    } catch (_) {
      // 名字只是展示用，存不下不影响功能
    }
  }

  @visibleForTesting
  static void resetForTest() {
    _id = '';
    _name = '';
  }
}
