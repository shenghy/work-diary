#ifndef RUNNER_SCREENSHOT_CHANNEL_H_
#define RUNNER_SCREENSHOT_CHANNEL_H_

#include <flutter/flutter_view_controller.h>

// 屏幕截图平台通道：Win32 BitBlt 截取全屏，返回 base64 PNG
class ScreenshotChannel {
 public:
  static void RegisterWithRegistrar(flutter::FlutterViewController* controller);
};

#endif  // RUNNER_SCREENSHOT_CHANNEL_H_
