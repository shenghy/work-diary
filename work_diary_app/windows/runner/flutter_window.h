#ifndef RUNNER_FLUTTER_WINDOW_H_
#define RUNNER_FLUTTER_WINDOW_H_

#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>

#include <memory>

#include "win32_window.h"

// A window that does nothing but host a Flutter view.
class FlutterWindow : public Win32Window {
 public:
  // Creates a new FlutterWindow hosting a Flutter view running |project|.
  explicit FlutterWindow(const flutter::DartProject& project);
  virtual ~FlutterWindow();

  // 静默启动：第一帧完成后不自动显示窗口（开机自启时用），
  // 之后由托盘菜单 / 再次双击图标唤出。
  void SetStartHidden(bool start_hidden);

  // 上次退出时窗口是最大化：第一次真正显示时恢复最大化。
  void SetStartMaximized(bool start_maximized);

 protected:
  // Win32Window:
  bool OnCreate() override;
  void OnDestroy() override;
  LRESULT MessageHandler(HWND window, UINT const message, WPARAM const wparam,
                         LPARAM const lparam) noexcept override;

 private:
  // 把主窗口从“隐藏到托盘 / 最小化”恢复到前台。
  void ShowMainWindow();

  // The project to run.
  flutter::DartProject project_;

  // The Flutter instance hosted by this window.
  std::unique_ptr<flutter::FlutterViewController> flutter_controller_;

  // 启动后是否保持隐藏（--hidden）。
  bool start_hidden_ = false;

  // 上次退出时最大化，等待窗口第一次显示后再应用（隐藏启动时显示时才应用）。
  bool start_maximized_ = false;
  bool pending_maximize_ = false;
};

#endif  // RUNNER_FLUTTER_WINDOW_H_
