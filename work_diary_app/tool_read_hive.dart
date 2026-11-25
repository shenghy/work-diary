import 'package:hive/hive.dart';

void main() async {
  Hive.init('C:/Users/Administrator/Documents');
  final box = await Hive.openBox('settings');
  final beforeX = box.get('window_x');
  final beforeW = box.get('window_w');
  await box.delete('window_x');
  await box.delete('window_y');
  await box.delete('window_w');
  await box.delete('window_h');
  print('已清除窗口尺寸记录 (之前: x=$beforeX, w=$beforeW)');
  await box.close();
}
