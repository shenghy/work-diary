import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import 'package:work_diary_app/widgets/pending_attachment_picker.dart';

/// 新建/编辑弹窗里的待挂附件区：只负责"挑了哪些文件、还能挑几个"。
void main() {
  late Directory tempDir;
  late String filePath;

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('wd_pending_picker_');
    filePath = p.join(tempDir.path, '需求说明.docx');
    File(filePath).writeAsBytesSync(List<int>.filled(2048, 7));
  });

  tearDown(() {
    tempDir.deleteSync(recursive: true);
  });

  Widget wrap({
    required List<String> paths,
    required int remaining,
    VoidCallback? onPick,
    void Function(String)? onRemove,
  }) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      home: Scaffold(
        body: SizedBox(
          width: 360,
          child: PendingAttachmentPicker(
            paths: paths,
            remaining: remaining,
            onPick: onPick ?? () {},
            onRemove: onRemove ?? (_) {},
          ),
        ),
      ),
    );
  }

  testWidgets('列出已挑的文件与大小，点 × 把它退回未选', (tester) async {
    final removed = <String>[];
    await tester.pumpWidget(wrap(
      paths: [filePath],
      remaining: 4,
      onRemove: removed.add,
    ));

    expect(find.text('需求说明.docx'), findsOneWidget);
    expect(find.textContaining('2.0'), findsOneWidget, reason: '应显示文件大小');
    expect(find.textContaining('最多还能挂 4 个'), findsOneWidget);

    await tester.tap(find.byIcon(Icons.close));
    await tester.pump();
    expect(removed, [filePath]);
  });

  testWidgets('名额用完时不再给"添加文件"按钮', (tester) async {
    await tester.pumpWidget(wrap(paths: [filePath], remaining: 0));
    expect(find.textContaining('最多还能挂'), findsNothing);
  });

  testWidgets('文件已经不在磁盘上也不崩，大小显示为未知', (tester) async {
    final gone = p.join(tempDir.path, '已被移走.pdf');
    await tester.pumpWidget(wrap(paths: [gone], remaining: 3));
    expect(find.text('已被移走.pdf'), findsOneWidget);
    expect(find.text('未知大小'), findsOneWidget);
  });
}
