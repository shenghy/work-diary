import 'dart:io';
import 'package:hive/hive.dart';

void main() async {
  Hive.init('C:/Users/Administrator/Documents');
  final memos = await Hive.openBox('memos_copy_check');
  print('=== memos box 条数: ${memos.length} ===');
  memos.toMap().forEach((k, v) {
    print('key=$k -> $v');
  });
  final dels = await Hive.openBox('sync_deletions_copy_check');
  print('=== sync_deletions box 条数: ${dels.length} ===');
  dels.toMap().forEach((k, v) {
    print('key=$k -> $v');
  });
  exit(0);
}
