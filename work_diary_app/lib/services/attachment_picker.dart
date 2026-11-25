import 'dart:io';

import 'package:file_selector/file_selector.dart';

import '../utils/attachment_types.dart';

/// 打开系统文件框挑附件。
///
/// 类型过滤直接交给系统对话框（只显示白名单后缀），比让用户选了再报错省事；
/// 体积和"还能挂几个"仍要在这里补一遍，因为一次能选多个，逐个校验才知道超没超。
Future<({List<String> paths, List<String> messages})> pickAttachmentFiles({
  required int remaining,
}) async {
  if (remaining <= 0) {
    return (paths: const <String>[], messages: ['每个任务/备忘最多挂 $kAttachmentMaxPerParent 个附件']);
  }
  final allowed = <String>{...kImageExts, ...kDocExts}.toList()..sort();
  final picked = await openFiles(
    acceptedTypeGroups: [
      XTypeGroup(label: '文档与图片', extensions: allowed),
    ],
  );
  final paths = <String>[];
  final messages = <String>[];
  for (final file in picked) {
    if (paths.length >= remaining) {
      messages.add('最多还能挂 $remaining 个，后面的文件没添加');
      break;
    }
    final name = file.name.isNotEmpty ? file.name : file.path;
    try {
      final size = await File(file.path).length();
      final check = checkAttachmentFile(name, sizeBytes: size);
      if (!check.allowed) {
        messages.add(check.reason);
        continue;
      }
    } catch (_) {
      messages.add('$name 读不到，可能已被移动');
      continue;
    }
    paths.add(file.path);
  }
  return (paths: paths, messages: messages);
}
