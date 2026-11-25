import 'package:flutter_test/flutter_test.dart';
import 'package:work_diary_app/utils/subtask_parser.dart';

void main() {
  group('parseSubTasks', () {
    test('标准 [ ] 格式', () {
      final r = parseSubTasks('主标题\n[ ] 任务一\n[ ] 任务二');
      expect(r.mainTitle, '主标题');
      expect(r.items.length, 2);
      expect(r.items[0].done, false);
      expect(r.items[0].prefix, isNull);
      expect(r.items[0].text, '任务一');
    });

    test('[x] 已勾选格式', () {
      final r = parseSubTasks('[x] 已完成');
      expect(r.items.length, 1);
      expect(r.items[0].done, true);
      expect(r.items[0].text, '已完成');
    });

    test('数字编号 1. 保留编号', () {
      final r = parseSubTasks('1. 首页设计\n2. 后端接口');
      expect(r.items.length, 2);
      expect(r.items[0].prefix, '1.');
      expect(r.items[0].text, '首页设计');
      expect(r.items[0].done, false);
      expect(r.items[1].prefix, '2.');
      expect(r.items[1].text, '后端接口');
    });

    test('连字符 - 渲染为无编号子任务', () {
      final r = parseSubTasks('- 体检\n- 准备学费');
      expect(r.items.length, 2);
      expect(r.items[0].prefix, isNull);
      expect(r.items[0].text, '体检');
      expect(r.items[0].done, false);
      expect(r.items[1].text, '准备学费');
    });

    test('[ ] 1. 已转义格式保留编号', () {
      final r = parseSubTasks('[ ] 1. 首页设计\n[x] 2. 后端接口');
      expect(r.items.length, 2);
      expect(r.items[0].prefix, '1.');
      expect(r.items[0].text, '首页设计');
      expect(r.items[0].done, false);
      expect(r.items[1].prefix, '2.');
      expect(r.items[1].done, true);
    });

    test('混合格式', () {
      final r = parseSubTasks('主标题\n[ ] a\n- b\n1. c');
      expect(r.mainTitle, '主标题');
      expect(r.items.length, 3);
      expect(r.items[0].prefix, isNull);
      expect(r.items[1].prefix, isNull);
      expect(r.items[2].prefix, '1.');
    });

    test('无子任务', () {
      final r = parseSubTasks('普通任务');
      expect(r.items.length, 0);
      expect(r.mainTitle, '普通任务');
    });
  });

  group('setSubTaskDone', () {
    test('数字编号勾选保留编号', () {
      expect(setSubTaskDone('1. 首页设计', 0, true), '[x] 1. 首页设计');
    });

    test('数字编号取消勾选保留编号', () {
      expect(setSubTaskDone('[x] 1. 首页设计', 0, false), '[ ] 1. 首页设计');
    });

    test('连字符勾选前缀消失', () {
      expect(setSubTaskDone('- 体检', 0, true), '[x] 体检');
    });

    test('标准勾选', () {
      expect(setSubTaskDone('[ ] 任务一', 0, true), '[x] 任务一');
      expect(setSubTaskDone('[x] 任务一', 0, false), '[ ] 任务一');
    });

    test('多行只改目标行，其他原样', () {
      final r = setSubTaskDone('主标题\n[ ] a\n1. b', 1, true);
      expect(r, '主标题\n[ ] a\n[x] 1. b');
    });
  });

  group('autoConvertNumberedToCheckbox', () {
    test('数字保留编号', () {
      expect(autoConvertNumberedToCheckbox('1. 首页设计'), '[ ] 1. 首页设计');
    });

    test('连字符替换', () {
      expect(autoConvertNumberedToCheckbox('- 体检'), '[ ] 体检');
    });

    test('多行混合', () {
      expect(
        autoConvertNumberedToCheckbox('1. a\n- b\n2. c'),
        '[ ] 1. a\n[ ] b\n[ ] 2. c',
      );
    });

    test('普通文本不受影响', () {
      expect(autoConvertNumberedToCheckbox('今天开会讨论 1. 方案'), '今天开会讨论 1. 方案');
    });
  });
}
