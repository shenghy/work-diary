#include "win32_window.h"

#include <commctrl.h>
#include <dwmapi.h>
#include <flutter_windows.h>

#include "resource.h"
#include "window_state.h"

#pragma comment(lib, "comctl32.lib")

namespace {

/// Window attribute that enables dark mode window decorations.
///
/// Redefined in case the developer's machine has a Windows SDK older than
/// version 10.0.22000.0.
/// See: https://docs.microsoft.com/windows/win32/api/dwmapi/ne-dwmapi-dwmwindowattribute
#ifndef DWMWA_USE_IMMERSIVE_DARK_MODE
#define DWMWA_USE_IMMERSIVE_DARK_MODE 20
#endif

// Window attribute that enables rounded window corners (Windows 11 22000+).
// Same story as above: define it locally for older SDKs.
#ifndef DWMWA_WINDOW_CORNER_PREFERENCE
#define DWMWA_WINDOW_CORNER_PREFERENCE 33
#endif

// Value of DWM_WINDOW_CORNER_PREFERENCE that asks DWM to round the corners
// (DWMWCP_ROUND). Kept as a plain int so we do not depend on the SDK enum.
constexpr int kDwmCornerRound = 2;

// Corner radius of the window frame, in logical pixels (DIP). Scaled by the
// window DPI at runtime, so 200% displays get twice the physical radius.
constexpr int kWindowCornerRadiusDip = 8;

// 自绘标题栏的高度（逻辑像素）。必须和 Flutter 侧 lib/widgets/title_bar.dart
// 里的 kTitleBarHeight 一致，否则原生拖动区会和页面上的按钮错位。
constexpr int kTitleBarHeightDip = 40;

// 标题栏右侧窗口按钮区（置顶 / 最小化 / 关闭）的总宽度，同上需与 Dart 侧一致。
constexpr int kWindowButtonsWidthDip = 120;

// 无边框窗口四边 / 四角的缩放热区宽度（逻辑像素）。
constexpr int kResizeBorderDip = 6;

// 窗口几何写盘的防抖定时器：拖动 / 缩放过程中 WM_MOVE/WM_SIZE 触发很频繁，
// 停止 800ms 后再落盘，避免每次移动都写一次 INI。
constexpr UINT_PTR kWindowStateTimerId = 0x57445331;  // 'WDS1'

// True on Windows 11 (NT 10.0 build 22000) and newer.//
// GetVersionEx lies under the app manifest and reports Windows 8 even on
// Windows 11, so ask ntdll directly. Result is computed once and cached.
bool IsWindows11OrGreater() {
  using RtlGetVersionFn = LONG(WINAPI*)(OSVERSIONINFOW*);
  static const bool is_windows11 = []() {
    HMODULE ntdll = ::GetModuleHandleW(L"ntdll.dll");
    if (ntdll == nullptr) {
      return false;
    }
    auto rtl_get_version = reinterpret_cast<RtlGetVersionFn>(
        ::GetProcAddress(ntdll, "RtlGetVersion"));
    if (rtl_get_version == nullptr) {
      return false;
    }
    OSVERSIONINFOW info{};
    info.dwOSVersionInfoSize = sizeof(OSVERSIONINFOW);
    if (rtl_get_version(&info) != 0) {
      return false;
    }
    return info.dwMajorVersion >= 10 && info.dwBuildNumber >= 22000;
  }();
  return is_windows11;
}

constexpr const wchar_t kWindowClassName[] = L"FLUTTER_RUNNER_WIN32_WINDOW";

// The number of Win32Window objects that currently exist.
static int g_active_window_count = 0;

using EnableNonClientDpiScaling = BOOL __stdcall(HWND hwnd);

// Scale helper to convert logical scaler values to physical using passed in
// scale factor
int Scale(int source, double scale_factor) {
  return static_cast<int>(source * scale_factor);
}

// Dynamically loads |GetDpiForWindow| from User32.dll (Windows 10 1607+).
// Falls back to the system DPI when the API is unavailable.
UINT GetWindowDpi(HWND hwnd) {
  using GetDpiForWindowFn = UINT __stdcall(HWND);
  HMODULE user32_module = LoadLibraryA("User32.dll");
  if (user32_module != nullptr) {
    auto get_dpi_for_window = reinterpret_cast<GetDpiForWindowFn*>(
        GetProcAddress(user32_module, "GetDpiForWindow"));
    if (get_dpi_for_window != nullptr) {
      UINT dpi = get_dpi_for_window(hwnd);
      FreeLibrary(user32_module);
      return dpi;
    }
    FreeLibrary(user32_module);
  }
  HDC screen_dc = GetDC(nullptr);
  UINT dpi = static_cast<UINT>(GetDeviceCaps(screen_dc, LOGPIXELSX));
  ReleaseDC(nullptr, screen_dc);
  return dpi;
}

// Dynamically loads the |EnableNonClientDpiScaling| from the User32 module.
// This API is only needed for PerMonitor V1 awareness mode.
void EnableFullDpiSupportIfAvailable(HWND hwnd) {
  HMODULE user32_module = LoadLibraryA("User32.dll");
  if (!user32_module) {
    return;
  }
  auto enable_non_client_dpi_scaling =
      reinterpret_cast<EnableNonClientDpiScaling*>(
          GetProcAddress(user32_module, "EnableNonClientDpiScaling"));
  if (enable_non_client_dpi_scaling != nullptr) {
    enable_non_client_dpi_scaling(hwnd);
  }
  FreeLibrary(user32_module);
}

// Flutter 的 view 是一个铺满整个客户区的子窗口，鼠标永远落在它上面。
// 而系统只把 WM_NCHITTEST 发给「鼠标正下方的那个窗口」，也就是这个子窗口，
// 父窗口的标题栏 / 缩放热区命中测试根本轮不到执行 —— 表现就是标题栏拖不动、
// 四边也缩放不了。
//
// 这里给子窗口挂一个子类过程：落在标题栏或四边时返回 HTTRANSPARENT，
// 让系统把命中测试继续问父窗口；父窗口返回 HTCAPTION / HTLEFT 之后，
// 拖动和缩放就回到系统原生逻辑（含 Aero Snap、缩放动画）。
constexpr UINT_PTR kChildHitTestSubclassId = 1;

LRESULT CALLBACK ChildHitTestSubclass(HWND child,
                                      UINT message,
                                      WPARAM wparam,
                                      LPARAM lparam,
                                      UINT_PTR subclass_id,
                                      DWORD_PTR ref_data) {
  if (message == WM_NCHITTEST) {
    HWND parent = ::GetParent(child);
    if (parent != nullptr &&
        ::SendMessage(parent, WM_NCHITTEST, wparam, lparam) != HTCLIENT) {
      return HTTRANSPARENT;
    }
    return HTCLIENT;
  }
  return ::DefSubclassProc(child, message, wparam, lparam);
}

}  // namespace

// Manages the Win32Window's window class registration.
class WindowClassRegistrar {
 public:
  ~WindowClassRegistrar() = default;

  // Returns the singleton registrar instance.
  static WindowClassRegistrar* GetInstance() {
    if (!instance_) {
      instance_ = new WindowClassRegistrar();
    }
    return instance_;
  }

  // Returns the name of the window class, registering the class if it hasn't
  // previously been registered.
  const wchar_t* GetWindowClass();

  // Unregisters the window class. Should only be called if there are no
  // instances of the window.
  void UnregisterWindowClass();

 private:
  WindowClassRegistrar() = default;

  static WindowClassRegistrar* instance_;

  bool class_registered_ = false;
};

WindowClassRegistrar* WindowClassRegistrar::instance_ = nullptr;

const wchar_t* WindowClassRegistrar::GetWindowClass() {
  if (!class_registered_) {
    WNDCLASS window_class{};
    window_class.hCursor = LoadCursor(nullptr, IDC_ARROW);
    window_class.lpszClassName = kWindowClassName;
    window_class.style = CS_HREDRAW | CS_VREDRAW;
    window_class.cbClsExtra = 0;
    window_class.cbWndExtra = 0;
    window_class.hInstance = GetModuleHandle(nullptr);
    window_class.hIcon =
        LoadIcon(window_class.hInstance, MAKEINTRESOURCE(IDI_APP_ICON));
    window_class.hbrBackground = 0;
    window_class.lpszMenuName = nullptr;
    window_class.lpfnWndProc = Win32Window::WndProc;
    RegisterClass(&window_class);
    class_registered_ = true;
  }
  return kWindowClassName;
}

void WindowClassRegistrar::UnregisterWindowClass() {
  UnregisterClass(kWindowClassName, nullptr);
  class_registered_ = false;
}

Win32Window::Win32Window() {
  ++g_active_window_count;
}

Win32Window::~Win32Window() {
  --g_active_window_count;
  Destroy();
}

bool Win32Window::Create(const std::wstring& title,
                         const Point& origin,
                         const Size& size) {
  Destroy();

  const wchar_t* window_class =
      WindowClassRegistrar::GetInstance()->GetWindowClass();

  const POINT target_point = {static_cast<LONG>(origin.x),
                              static_cast<LONG>(origin.y)};
  HMONITOR monitor = MonitorFromPoint(target_point, MONITOR_DEFAULTTONEAREST);
  UINT dpi = FlutterDesktopGetDpiForMonitor(monitor);
  double scale_factor = dpi / 96.0;

  // 自绘标题栏：保留 WS_OVERLAPPEDWINDOW 的样式位（DWM 的投影、最小化动画、
  // Aero Snap 都依赖它），再在 WM_NCCALCSIZE 里把客户区扩到整个窗口，
  // 系统标题栏和边框就不会被画出来。比直接去掉 WS_CAPTION 更稳：
  // 纯 WS_POPUP 窗口在 Win10 上会丢掉 DWM 投影。
  HWND window = CreateWindow(
      window_class, title.c_str(), WS_OVERLAPPEDWINDOW,
      Scale(origin.x, scale_factor), Scale(origin.y, scale_factor),
      Scale(size.width, scale_factor), Scale(size.height, scale_factor),
      nullptr, nullptr, GetModuleHandle(nullptr), this);

  if (!window) {
    return false;
  }

  UpdateTheme(window);
  ApplyCornerStyle(window);

  return OnCreate();
}

bool Win32Window::Show() {
  return ShowWindow(window_handle_, SW_SHOWNORMAL);
}

// static
LRESULT CALLBACK Win32Window::WndProc(HWND const window,
                                      UINT const message,
                                      WPARAM const wparam,
                                      LPARAM const lparam) noexcept {
  if (message == WM_NCCREATE) {
    auto window_struct = reinterpret_cast<CREATESTRUCT*>(lparam);
    SetWindowLongPtr(window, GWLP_USERDATA,
                     reinterpret_cast<LONG_PTR>(window_struct->lpCreateParams));

    auto that = static_cast<Win32Window*>(window_struct->lpCreateParams);
    EnableFullDpiSupportIfAvailable(window);
    that->window_handle_ = window;
  } else if (Win32Window* that = GetThisFromHandle(window)) {
    return that->MessageHandler(window, message, wparam, lparam);
  }

  return DefWindowProc(window, message, wparam, lparam);
}

LRESULT
Win32Window::MessageHandler(HWND hwnd,
                            UINT const message,
                            WPARAM const wparam,
                            LPARAM const lparam) noexcept {
  // 窗口几何记忆：移动 / 缩放后防抖保存，拖动结束、关机、销毁时立即保存。
  // 这样升级重启（Dart 直接 exit(0)）和进程被强杀也不会丢位置。
  switch (message) {
    case WM_MOVE:
    case WM_SIZE:
      if (::IsIconic(hwnd) == 0) {
        ::SetTimer(hwnd, kWindowStateTimerId, 800, nullptr);
      }
      break;
    case WM_EXITSIZEMOVE:
      ::KillTimer(hwnd, kWindowStateTimerId);
      window_state::Save(hwnd);
      break;
    case WM_ENDSESSION:
      if (wparam != FALSE) {
        ::KillTimer(hwnd, kWindowStateTimerId);
        window_state::Save(hwnd);
      }
      break;
    case WM_TIMER:
      if (wparam == kWindowStateTimerId) {
        ::KillTimer(hwnd, kWindowStateTimerId);
        window_state::Save(hwnd);
        return 0;
      }
      break;
  }

  switch (message) {
    case WM_DESTROY:
      ::KillTimer(hwnd, kWindowStateTimerId);
      window_state::Save(hwnd);
      window_handle_ = nullptr;
      Destroy();
      if (quit_on_close_) {
        PostQuitMessage(0);
      }
      return 0;

    case WM_NCCALCSIZE:
      // 客户区 = 窗口区域：抹掉系统标题栏和边框，标题栏由 Flutter 自己画。
      if (wparam == TRUE) {
        auto* params = reinterpret_cast<NCCALCSIZE_PARAMS*>(lparam);
        if (::IsZoomed(hwnd)) {
          // 最大化时窗口比工作区大出边框厚度，用工作区兜底，免得盖住任务栏。
          MONITORINFO monitor_info{};
          monitor_info.cbSize = sizeof(monitor_info);
          if (::GetMonitorInfo(
                  ::MonitorFromWindow(hwnd, MONITOR_DEFAULTTONEAREST),
                  &monitor_info)) {
            params->rgrc[0] = monitor_info.rcWork;
          }
        }
        return 0;
      }
      break;

    case WM_NCHITTEST: {
      // 屏幕坐标（可能为负，必须按 short 取）。
      const int screen_x = static_cast<short>(LOWORD(lparam));
      const int screen_y = static_cast<short>(HIWORD(lparam));
      POINT point{screen_x, screen_y};
      ::ScreenToClient(hwnd, &point);

      RECT client{};
      ::GetClientRect(hwnd, &client);

      const double scale = GetWindowDpi(hwnd) / 96.0;
      const int border = Scale(kResizeBorderDip, scale);
      const int title_bar = Scale(kTitleBarHeightDip, scale);
      const int buttons = Scale(kWindowButtonsWidthDip, scale);

      // 四边 / 四角缩放热区。最大化后窗口贴边，不需要再缩放。
      if (!::IsZoomed(hwnd)) {
        const bool at_left = point.x < border;
        const bool at_right = point.x >= client.right - border;
        const bool at_top = point.y < border;
        const bool at_bottom = point.y >= client.bottom - border;
        if (at_top && at_left) return HTTOPLEFT;
        if (at_top && at_right) return HTTOPRIGHT;
        if (at_bottom && at_left) return HTBOTTOMLEFT;
        if (at_bottom && at_right) return HTBOTTOMRIGHT;
        if (at_left) return HTLEFT;
        if (at_right) return HTRIGHT;
        if (at_top) return HTTOP;
        if (at_bottom) return HTBOTTOM;
      }

      // 标题栏：右侧留给窗口按钮，其余整条都能拖动窗口。
      if (point.y >= 0 && point.y < title_bar &&
          point.x < client.right - buttons) {
        return HTCAPTION;
      }
      return HTCLIENT;
    }

    case WM_NCLBUTTONDBLCLK:
      // 双击标题栏不最大化：530x750 的面板窗，误触代价太大。
      return 0;

    case WM_DPICHANGED: {
      auto newRectSize = reinterpret_cast<RECT*>(lparam);
      LONG newWidth = newRectSize->right - newRectSize->left;
      LONG newHeight = newRectSize->bottom - newRectSize->top;

      SetWindowPos(hwnd, nullptr, newRectSize->left, newRectSize->top, newWidth,
                   newHeight, SWP_NOZORDER | SWP_NOACTIVATE);
      // 圆角半径按 DPI 换算，换到别的显示器后必须重算一次。
      ApplyCornerStyle(hwnd);

      return 0;
    }
    case WM_GETMINMAXINFO:
      ApplyMinimumTrackSize(lparam);
      return 0;
    case WM_SIZE: {
      RECT rect = GetClientArea();
      if (child_content_ != nullptr) {
        // Size and position the child window.
        MoveWindow(child_content_, rect.left, rect.top, rect.right - rect.left,
                   rect.bottom - rect.top, TRUE);
      }
      // 区域裁剪是按窗口尺寸算的，尺寸变了要重画圆角。
      ApplyCornerStyle(hwnd);
      return 0;
    }

    case WM_ACTIVATE:
      if (child_content_ != nullptr) {
        SetFocus(child_content_);
      }
      return 0;

    case WM_DWMCOLORIZATIONCOLORCHANGED:
      UpdateTheme(hwnd);
      return 0;
  }

  return DefWindowProc(window_handle_, message, wparam, lparam);
}

void Win32Window::Destroy() {
  OnDestroy();

  if (window_handle_) {
    DestroyWindow(window_handle_);
    window_handle_ = nullptr;
  }
  if (g_active_window_count == 0) {
    WindowClassRegistrar::GetInstance()->UnregisterWindowClass();
  }
}

Win32Window* Win32Window::GetThisFromHandle(HWND const window) noexcept {
  return reinterpret_cast<Win32Window*>(
      GetWindowLongPtr(window, GWLP_USERDATA));
}

void Win32Window::SetChildContent(HWND content) {
  child_content_ = content;
  SetParent(content, window_handle_);

  // 让子窗口把标题栏 / 四边的命中测试透传给父窗口，拖动和缩放才有效。
  ::SetWindowSubclass(content, ChildHitTestSubclass, kChildHitTestSubclassId, 0);

  RECT frame = GetClientArea();

  MoveWindow(content, frame.left, frame.top, frame.right - frame.left,
             frame.bottom - frame.top, true);

  SetFocus(child_content_);
}

RECT Win32Window::GetClientArea() {
  RECT frame;
  GetClientRect(window_handle_, &frame);
  return frame;
}

HWND Win32Window::GetHandle() {
  return window_handle_;
}

void Win32Window::SetQuitOnClose(bool quit_on_close) {
  quit_on_close_ = quit_on_close;
}

void Win32Window::SetMinimumSize(const Size& size) {
  minimum_size_ = size;
}

void Win32Window::ApplyMinimumTrackSize(LPARAM lparam) {
  auto minmax_info = reinterpret_cast<MINMAXINFO*>(lparam);
  if (minimum_size_.width == 0 || minimum_size_.height == 0) {
    return;
  }
  // 优先用窗口句柄算 DPI；窗口重建过程中 window_handle_ 可能为空，
  // 此时退回系统 DPI（GetWindowDpi(nullptr) 会返回 0）。
  HWND hwnd = window_handle_;
  UINT dpi = hwnd != nullptr ? GetWindowDpi(hwnd) : 0;
  if (dpi == 0) {
    dpi = ::GetDpiForSystem();
  }
  if (dpi == 0) {
    dpi = 96;
  }
  double scale_factor = dpi / 96.0;
  LONG min_x = Scale(static_cast<int>(minimum_size_.width), scale_factor);
  LONG min_y = Scale(static_cast<int>(minimum_size_.height), scale_factor);
  if (minmax_info->ptMinTrackSize.x < min_x) {
    minmax_info->ptMinTrackSize.x = min_x;
  }
  if (minmax_info->ptMinTrackSize.y < min_y) {
    minmax_info->ptMinTrackSize.y = min_y;
  }
}

void Win32Window::ApplyCornerStyle(HWND window) {
  if (window == nullptr || in_corner_style_) {
    return;
  }
  in_corner_style_ = true;

  // Windows 11：DWM 原生圆角，自带抗锯齿和与圆角贴合的阴影，不用自己裁。
  if (IsWindows11OrGreater()) {
    int corner = kDwmCornerRound;
    DwmSetWindowAttribute(window, DWMWA_WINDOW_CORNER_PREFERENCE, &corner,
                          sizeof(corner));
    in_corner_style_ = false;
    return;
  }

  // Windows 10 及更早没有圆角窗口能力，只能用窗口区域裁剪。
  // 注意：区域会裁窗口，但 DWM 画的标准边框（标题栏 + 1px 外框）不跟着裁，
  // 所以在"带系统标题栏"的窗口上看不出圆角效果；等窗口改成自绘标题栏
  // （无 WS_CAPTION）之后，这段裁剪才会真正可见。
  // 最大化 / 最小化时窗口以矩形铺满，裁角只会切掉内容，这里清掉区域。
  if (::IsZoomed(window) || ::IsIconic(window)) {
    ::SetWindowRgn(window, nullptr, TRUE);
    in_corner_style_ = false;
    return;
  }

  RECT rect{};
  if (!::GetWindowRect(window, &rect)) {
    in_corner_style_ = false;
    return;
  }
  const int width = rect.right - rect.left;
  const int height = rect.bottom - rect.top;
  if (width <= 0 || height <= 0) {
    in_corner_style_ = false;
    return;
  }

  int radius =
      static_cast<int>(kWindowCornerRadiusDip * (GetWindowDpi(window) / 96.0));
  // 窗口缩得很小时别把角裁成异形。
  const int max_radius = (width < height ? width : height) / 4;
  if (radius > max_radius) {
    radius = max_radius;
  }
  if (radius <= 0) {
    in_corner_style_ = false;
    return;
  }

  // 区域坐标是窗口坐标（含标题栏和边框），+1 让右下角的像素不被裁掉。
  HRGN region = ::CreateRoundRectRgn(0, 0, width + 1, height + 1, radius * 2,
                                     radius * 2);
  if (region != nullptr) {
    // 成功后区域所有权归系统，这里不能再 DeleteObject。
    ::SetWindowRgn(window, region, TRUE);
  }

  in_corner_style_ = false;
}

bool Win32Window::OnCreate() {
  // No-op; provided for subclasses.
  return true;
}

void Win32Window::OnDestroy() {
  // No-op; provided for subclasses.
}

void Win32Window::UpdateTheme(HWND const window) {
  // 应用目前只有浅色主题：标题栏统一用浅色，避免系统开启深色模式后出现
  // “深色标题栏 + 纯白内容”的割裂观感。等应用支持深色主题后再跟随系统。
  BOOL enable_dark_mode = FALSE;
  DwmSetWindowAttribute(window, DWMWA_USE_IMMERSIVE_DARK_MODE,
                        &enable_dark_mode, sizeof(enable_dark_mode));
}
