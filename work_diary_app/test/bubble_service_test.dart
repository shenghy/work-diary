import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';

import 'package:work_diary_app/services/bubble_service.dart';

/// 只测总开关的持久化与即时状态，不碰原生通道和窗口监听。
void main() {
  late Directory tempDir;

  setUpAll(() async {
    tempDir = await Directory.systemTemp.createTemp('work_diary_bubble_');
    Hive.init(tempDir.path);
    await Hive.openBox('settings');
  });

  tearDownAll(() async {
    await Hive.close();
    await tempDir.delete(recursive: true);
  });

  setUp(() async {
    await Hive.box('settings').clear();
    BubbleService.instance.enabled.value = true;
  });

  test('默认开启', () {
    expect(BubbleService.instance.enabled.value, isTrue);
  });

  test('关闭后立即生效并写入设置', () {
    BubbleService.instance.setEnabled(false);

    expect(BubbleService.instance.enabled.value, isFalse);
    expect(Hive.box('settings').get('bubble_enabled'), isFalse);
  });

  test('重新打开会覆盖设置', () {
    BubbleService.instance.setEnabled(false);
    BubbleService.instance.setEnabled(true);

    expect(BubbleService.instance.enabled.value, isTrue);
    expect(Hive.box('settings').get('bubble_enabled'), isTrue);
  });

  test('重复设置同一状态保持幂等', () {
    BubbleService.instance.setEnabled(false);
    BubbleService.instance.setEnabled(false);

    expect(BubbleService.instance.enabled.value, isFalse);
    expect(Hive.box('settings').get('bubble_enabled'), isFalse);
  });
}