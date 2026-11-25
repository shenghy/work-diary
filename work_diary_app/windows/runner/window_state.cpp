#include "window_state.h"

#include <algorithm>
#include <cmath>
#include <cstdlib>
#include <cwchar>
#include <string>

namespace window_state {
namespace {

constexpr wchar_t kSection[] = L"window";
constexpr int kMinWidth = 420;
constexpr int kMinHeight = 480;
constexpr int kMaxWidth = 20000;
constexpr int kMaxHeight = 20000;
constexpr double kMinDpi = 72.0;
constexpr double kMaxDpi = 480.0;

using GetDpiForWindowFn = UINT(WINAPI*)(HWND);

UINT WindowDpi(HWND hwnd) {
  static GetDpiForWindowFn get_dpi_for_window = []() -> GetDpiForWindowFn {
    HMODULE user32 = ::LoadLibraryA("User32.dll");
    if (user32 == nullptr) {
      return nullptr;
    }
    auto fn = reinterpret_cast<GetDpiForWindowFn>(
        ::GetProcAddress(user32, "GetDpiForWindow"));
    ::FreeLibrary(user32);
    return fn;
  }();
  if (get_dpi_for_window != nullptr) {
    UINT dpi = get_dpi_for_window(hwnd);
    if (dpi >= 48) {
      return dpi;
    }
  }
  return ::GetDpiForSystem();
}

std::wstring StatePath() {
  wchar_t app_data[MAX_PATH] = {};
  DWORD length =
      ::GetEnvironmentVariableW(L"APPDATA", app_data, MAX_PATH);
  if (length == 0 || length >= MAX_PATH) {
    return std::wstring();
  }
  std::wstring dir = app_data;
  dir += L"\\jspang.com\\极简工作日记";
  ::CreateDirectoryW((app_data + std::wstring(L"\\jspang.com")).c_str(),
                     nullptr);
  ::CreateDirectoryW(dir.c_str(), nullptr);
  return dir + L"\\window_state.ini";
}

bool ReadInt(const std::wstring& path,
             const wchar_t* key,
             int* value) {
  wchar_t buffer[32] = {};
  ::GetPrivateProfileStringW(kSection, key, L"", buffer, 32, path.c_str());
  if (buffer[0] == L'\0') {
    return false;
  }
  wchar_t* end = nullptr;
  long parsed = std::wcstol(buffer, &end, 10);
  if (end == buffer || *end != L'\0') {
    return false;
  }
  *value = static_cast<int>(parsed);
  return true;
}

int Clamp(int value, int low, int high) {
  return std::max(low, std::min(value, high));
}

LONG ToPhysical(int dip, double scale) {
  return static_cast<LONG>(std::lround(dip * scale));
}

}  // namespace

State Load() {
  State state;
  const std::wstring path = StatePath();
  if (path.empty() ||
      ::GetFileAttributesW(path.c_str()) == INVALID_FILE_ATTRIBUTES) {
    return state;
  }

  int x = 0;
  int y = 0;
  int width = 0;
  int height = 0;
  int dpi = 96;
  int maximized = 0;
  if (!ReadInt(path, L"x", &x) || !ReadInt(path, L"y", &y) ||
      !ReadInt(path, L"width", &width) ||
      !ReadInt(path, L"height", &height) || !ReadInt(path, L"dpi", &dpi) ||
      width < kMinWidth || height < kMinHeight || width > kMaxWidth ||
      height > kMaxHeight || dpi < kMinDpi || dpi > kMaxDpi) {
    return state;
  }
  maximized = ::GetPrivateProfileIntW(kSection, L"maximized", 0,
                                      path.c_str());

  state.x = x;
  state.y = y;
  state.width = width;
  state.height = height;
  state.dpi = static_cast<double>(dpi);
  state.maximized = maximized != 0;
  state.valid = true;
  return state;
}

Bounds Resolve(const State& state, const Bounds& fallback) {
  if (!state.valid) {
    return fallback;
  }

  const double scale = state.dpi / 96.0;
  const RECT saved_rect{
      ToPhysical(state.x, scale), ToPhysical(state.y, scale),
      ToPhysical(state.x + state.width, scale),
      ToPhysical(state.y + state.height, scale)};
  HMONITOR monitor = ::MonitorFromRect(&saved_rect, MONITOR_DEFAULTTONEAREST);
  MONITORINFO monitor_info{};
  monitor_info.cbSize = sizeof(monitor_info);
  if (monitor == nullptr || !::GetMonitorInfo(monitor, &monitor_info)) {
    return fallback;
  }
  const RECT work = monitor_info.rcWork;
  const int work_width = work.right - work.left;
  const int work_height = work.bottom - work.top;
  if (work_width <= 0 || work_height <= 0) {
    return fallback;
  }

  // 分辨率变小/显示器更换后，窗口尺寸不能超过工作区。
  const int physical_width =
      std::min<int>(saved_rect.right - saved_rect.left, work_width);
  const int physical_height =
      std::min<int>(saved_rect.bottom - saved_rect.top, work_height);

  Bounds bounds;
  bounds.width = Clamp(static_cast<int>(std::lround(physical_width / scale)),
                       kMinWidth, kMaxWidth);
  bounds.height = Clamp(static_cast<int>(std::lround(physical_height / scale)),
                        kMinHeight, kMaxHeight);

  // 标题栏（顶部一条）必须露在工作区里，否则用户拖不动也关不掉。
  const LONG title_band =
      std::min<LONG>(physical_height, ToPhysical(40, scale));
  const LONG overlap_width =
      std::min<LONG>(saved_rect.right, work.right) -
      std::max<LONG>(saved_rect.left, work.left);
  const LONG overlap_band =
      std::min<LONG>(saved_rect.top + title_band, work.bottom) -
      std::max<LONG>(saved_rect.top, work.top);
  if (overlap_width < ToPhysical(120, scale) ||
      overlap_band < ToPhysical(20, scale)) {
    return fallback;
  }

  bounds.x = state.x;
  bounds.y = state.y;
  return bounds;
}

void Save(HWND hwnd) {
  // 隐藏到托盘 / --hidden 静默启动期间窗口不可见：此时 GetWindowPlacement
  // 的 showCmd 是 SW_HIDE，会把上次的"最大化"状态冲成普通窗口，跳过。
  if (hwnd == nullptr || ::IsWindowVisible(hwnd) == FALSE ||
      ::IsIconic(hwnd) != 0) {
    return;
  }
  WINDOWPLACEMENT placement{};
  placement.length = sizeof(placement);
  if (!::GetWindowPlacement(hwnd, &placement)) {
    return;
  }
  const RECT rect = placement.rcNormalPosition;
  const int width = rect.right - rect.left;
  const int height = rect.bottom - rect.top;
  if (width < kMinWidth || height < kMinHeight) {
    return;
  }

  const double scale = WindowDpi(hwnd) / 96.0;
  const int dip_width = static_cast<int>(std::lround(width / scale));
  const int dip_height = static_cast<int>(std::lround(height / scale));
  const int dip_x = static_cast<int>(std::lround(rect.left / scale));
  const int dip_y = static_cast<int>(std::lround(rect.top / scale));
  const int dpi = static_cast<int>(std::lround(scale * 96.0));
  const bool maximized = placement.showCmd == SW_SHOWMAXIMIZED;

  const std::wstring path = StatePath();
  if (path.empty()) {
    return;
  }
  auto write_int = [&path](const wchar_t* key, long value) {
    const std::wstring text = std::to_wstring(value);
    ::WritePrivateProfileStringW(kSection, key, text.c_str(), path.c_str());
  };
  write_int(L"x", dip_x);
  write_int(L"y", dip_y);
  write_int(L"width", dip_width);
  write_int(L"height", dip_height);
  write_int(L"dpi", dpi);
  write_int(L"maximized", maximized ? 1 : 0);
}

}  // namespace window_state
