#include "flutter_window.h"

#include <optional>

#include "bubble_channel.h"
#include "flutter/generated_plugin_registrant.h"
#include "hotkey_channel.h"
#include "screenshot_channel.h"
#include "single_instance.h"
#include "window_state.h"

FlutterWindow::FlutterWindow(const flutter::DartProject& project)
    : project_(project) {}

FlutterWindow::~FlutterWindow() {}

void FlutterWindow::SetStartHidden(bool start_hidden) {
  start_hidden_ = start_hidden;
}

void FlutterWindow::SetStartMaximized(bool start_maximized) {
  start_maximized_ = start_maximized;
}

bool FlutterWindow::OnCreate() {
  if (!Win32Window::OnCreate()) {
    return false;
  }

  pending_maximize_ = start_maximized_;

  RECT frame = GetClientArea();

  // The size here must match the window dimensions to avoid unnecessary surface
  // creation / destruction in the startup path.
  flutter_controller_ = std::make_unique<flutter::FlutterViewController>(
      frame.right - frame.left, frame.bottom - frame.top, project_);
  // Ensure that basic setup of the controller was successful.
  if (!flutter_controller_->engine() || !flutter_controller_->view()) {
    return false;
  }
  RegisterPlugins(flutter_controller_->engine());
  ScreenshotChannel::RegisterWithRegistrar(flutter_controller_.get());
  BubbleChannel::RegisterWithRegistrar(flutter_controller_.get(), GetHandle());
  HotkeyChannel::RegisterWithRegistrar(flutter_controller_.get(), GetHandle());
  SetChildContent(flutter_controller_->view()->GetNativeWindow());

  // 静默启动时不要在第一帧后自动 Show，否则开机自启会弹窗抢焦点。
  if (!start_hidden_) {
    // 按值捕获 this：窗口在第一帧前被销毁时避免悬垂指针
    auto* self = this;
    flutter_controller_->engine()->SetNextFrameCallback([self]() {
      self->Show();
    });
  }

  // Flutter can complete the first frame before the "show window" callback is
  // registered. The following call ensures a frame is pending to ensure the
  // window is shown. It is a no-op if the first frame hasn't completed yet.
  flutter_controller_->ForceRedraw();

  return true;
}

void FlutterWindow::OnDestroy() {
  // 先注销全局热键，避免窗口销毁后仍占着组合键。
  HotkeyChannel::UnregisterAll();

  if (flutter_controller_) {
    flutter_controller_ = nullptr;
  }

  Win32Window::OnDestroy();
}

void FlutterWindow::ShowMainWindow() {
  HWND hwnd = GetHandle();
  if (hwnd == nullptr) {
    return;
  }
  // 最小化 -> SW_RESTORE；隐藏到托盘 -> SW_SHOW（SW_RESTORE 不会显示隐藏窗口）。
  if (::IsIconic(hwnd) != 0) {
    ::ShowWindow(hwnd, SW_RESTORE);
  } else {
    ::ShowWindow(hwnd, SW_SHOW);
  }
  ::SetForegroundWindow(hwnd);
}

LRESULT
FlutterWindow::MessageHandler(HWND hwnd, UINT const message,
                              WPARAM const wparam,
                              LPARAM const lparam) noexcept {
  // 已有实例再次启动时，会广播这条消息把主窗口叫到前台。
  // 消息 ID 由 RegisterWindowMessageW 生成，其他进程不会误响应。
  if (message == WorkDiaryShowWindowMessage()) {
    ShowMainWindow();
    return 0;
  }

  // 关闭 / 关机前落一次盘：window_manager 拦截 WM_CLOSE（关闭到托盘）后
  // 不会再走到基类，必须在交给插件之前保存。
  if (message == WM_CLOSE || (message == WM_ENDSESSION && wparam != FALSE)) {
    window_state::Save(hwnd);
  }

  // 上次退出时是最大化：窗口第一次真正显示（含 --hidden 后从托盘唤出）
  // 时再最大化，避免启动阶段对不可见窗口做多余的状态切换。
  if (message == WM_SHOWWINDOW && wparam == TRUE && pending_maximize_) {
    pending_maximize_ = false;
    ::ShowWindowAsync(hwnd, SW_MAXIMIZE);
  }

  // 全局热键：先于 Flutter 处理，命中本模块注册的 ID 后转成 Dart 回调。
  if (message == WM_HOTKEY) {
    if (HotkeyChannel::HandleHotKey(wparam)) {
      return 0;
    }
  }

  // Give Flutter, including plugins, an opportunity to handle window messages.
  if (flutter_controller_) {
    std::optional<LRESULT> result =
        flutter_controller_->HandleTopLevelWindowProc(hwnd, message, wparam,
                                                      lparam);
    if (result) {
      // window_manager 插件总是拦截 WM_GETMINMAXINFO，这里在其处理后
      // 再叠加本窗口配置的最小尺寸（取较大值），确保最小尺寸始终生效。
      if (message == WM_GETMINMAXINFO) {
        ApplyMinimumTrackSize(lparam);
      }
      return *result;
    }
  }

  switch (message) {
    case WM_FONTCHANGE:
      // 控制器可能已在 OnDestroy 里释放，这里必须判空
      if (flutter_controller_ && flutter_controller_->engine()) {
        flutter_controller_->engine()->ReloadSystemFonts();
      }
      break;
  }

  return Win32Window::MessageHandler(hwnd, message, wparam, lparam);
}
