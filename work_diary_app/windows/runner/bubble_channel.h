#ifndef RUNNER_BUBBLE_CHANNEL_H_
#define RUNNER_BUBBLE_CHANNEL_H_

#include <windows.h>

#include <string>

#include <flutter/flutter_view_controller.h>

/// 桌面悬浮气泡平台通道（com.workdiary/bubble）。
///
/// 负责两件事：
/// 1. 把 Dart 侧的“何时显示 / 显示什么数字 / 隐藏”转成原生窗口操作
///    （窗口本身与消息处理全部在 BubbleWindow 内完成）；
/// 2. 把气泡右键菜单选中的动作回传给 Dart（onAction）。
class BubbleChannel {
 public:
  /// main_window：主窗口句柄，点击气泡时用来恢复。
  static void RegisterWithRegistrar(flutter::FlutterViewController* controller,
                                    HWND main_window);

  /// 气泡右键菜单选中某项后调用，转发给 Dart 侧的 BubbleService。
  /// action 取值：quick_memo / quick_task / show_window / hide_bubble / quit。
  static void NotifyAction(const std::string& action);
};

#endif  // RUNNER_BUBBLE_CHANNEL_H_
