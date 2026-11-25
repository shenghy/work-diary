#ifndef RUNNER_HOTKEY_CHANNEL_H_
#define RUNNER_HOTKEY_CHANNEL_H_

#include <windows.h>

#include <flutter/flutter_view_controller.h>

/// 全局热键平台通道（com.workdiary/hotkey）。
///
/// 为什么不用 hotkey_manager 的 Windows 实现：
/// 1. 它把 Dart 传来的 physicalKey.keyCode（USB HID 码，A = 0x00070004）直接
///    当成虚拟键码传给 RegisterHotKey（VK_A 应该是 0x41），热键实际不会触发；
/// 2. 它丢弃 RegisterHotKey 的返回值，永远返回成功，调用方无法知道
///    “已被其他软件占用”，也就无法提示用户换键。
///
/// 这里直接封装 RegisterHotKey：注册结果与 GetLastError（1409 =
/// ERROR_HOTKEY_ALREADY_REGISTERED）如实返回；WM_HOTKEY 转成 Dart 回调。
/// 非 Windows 平台仍然走 hotkey_manager，不受影响。
class HotkeyChannel {
 public:
  /// main_window：主窗口句柄，热键注册在它上面，WM_HOTKEY 也由它接收。
  static void RegisterWithRegistrar(flutter::FlutterViewController* controller,
                                    HWND main_window);

  /// 处理 WM_HOTKEY；返回 true 表示是本模块注册的热键，已转交 Dart。
  static bool HandleHotKey(WPARAM wparam);

  /// 注销全部热键（窗口销毁时调用，避免残留到进程退出）。
  static void UnregisterAll();
};

#endif  // RUNNER_HOTKEY_CHANNEL_H_
