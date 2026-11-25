import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:work_diary_app/models/task.dart';
import 'package:work_diary_app/widgets/summary_dialog.dart';

void main() {
  group('filterTasksFor 日期与范围过滤', () {
    final tasks = [
      Task(
        id: 1,
        title: '工作A',
        status: TaskStatus.completed,
        taskType: 1,
        createdAt: DateTime(2026, 9, 7, 9),
      ),
      Task(
        id: 2,
        title: '工作B',
        status: TaskStatus.executing,
        taskType: 1,
        createdAt: DateTime(2026, 9, 8, 10),
      ),
      Task(
        id: 3,
        title: '个人C',
        status: TaskStatus.planned,
        taskType: 0,
        createdAt: DateTime(2026, 9, 9, 8),
      ),
      Task(
        id: 4,
        title: '工作D(10日)',
        status: TaskStatus.completed,
        taskType: 1,
        createdAt: DateTime(2026, 9, 10, 20),
      ),
    ];

    test('周范围 9/7-9/9 全部 → 应含前 3 条', () {
      final r = SummaryDialog.filterTasksFor(
        tasks,
        start: DateTime(2026, 9, 7),
        end: DateTime(2026, 9, 9),
        scope: 'all',
      );
      expect(r.map((t) => t.id), [1, 2, 3]);
    });

    test('同范围仅工作 → 只含工作任务', () {
      final r = SummaryDialog.filterTasksFor(
        tasks,
        start: DateTime(2026, 9, 7),
        end: DateTime(2026, 9, 9),
        scope: 'work',
      );
      expect(r.map((t) => t.id), [1, 2]);
    });

    test('同范围仅个人 → 只含个人任务', () {
      final r = SummaryDialog.filterTasksFor(
        tasks,
        start: DateTime(2026, 9, 7),
        end: DateTime(2026, 9, 9),
        scope: 'personal',
      );
      expect(r.map((t) => t.id), [3]);
    });

    test('单日 9/10 → 只含当日创建的任务', () {
      final r = SummaryDialog.filterTasksFor(
        tasks,
        start: DateTime(2026, 9, 10),
        end: DateTime(2026, 9, 10),
        scope: 'all',
      );
      expect(r.map((t) => t.id), [4]);
    });

    test('范围不含任何任务 → 空列表', () {
      final r = SummaryDialog.filterTasksFor(
        tasks,
        start: DateTime(2026, 9, 1),
        end: DateTime(2026, 9, 2),
        scope: 'all',
      );
      expect(r, isEmpty);
    });
  });

  group('buildDocxFromMarkdown Word 生成', () {
    test('生成合法 docx 且包含标题与正文', () {
      const md = '# 当日工作日志\n'
          '## 一、总体概述\n'
          '今日工作顺利。\n'
          '### 【已完成】\n'
          '- 完成窗口修改（紧急/工作任务）\n'
          '1. 步骤一\n'
          '2. 步骤二\n';
      final bytes = SummaryDialog.buildDocxFromMarkdown(md);
      expect(bytes.length, greaterThan(1000));

      // docx 本质是 zip，解压检查关键部件
      final dir = Directory.systemTemp.createTempSync('wd_docx_test');
      try {
        final zipPath = '${dir.path}/test.docx';
        File(zipPath).writeAsBytesSync(bytes);
        final proc = Process.runSync('tar', ['-tf', zipPath]);
        expect(proc.exitCode, 0);
        final listing = proc.stdout as String;
        expect(listing, contains('[Content_Types].xml'));
        expect(listing, contains('word/document.xml'));

        // 解压并检查 document.xml 里的内容
        final extractDir = '${dir.path}/x';
        Directory(extractDir).createSync();
        Process.runSync('tar', ['-xf', zipPath, '-C', extractDir]);
        final xml = File('$extractDir/word/document.xml').readAsStringSync();
        expect(xml, contains('当日工作日志'));
        expect(xml, contains('一、总体概述'));
        expect(xml, contains('完成窗口修改'));
        expect(xml, contains('步骤一'));
      } finally {
        dir.deleteSync(recursive: true);
      }
    });

    test('空文本也能生成合法 docx', () {
      final bytes = SummaryDialog.buildDocxFromMarkdown('');
      expect(bytes.length, greaterThan(500));
    });
  });
}
