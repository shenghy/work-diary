#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>
#include <windows.h>

#include <string>
#include <vector>

#include "flutter_window.h"
#include "single_instance.h"
#include "utils.h"
#include "window_state.h"

#pragma execution_character_set("utf-8")

namespace {

/// 命令行参数里是否包含指定开关（如 --upgrade / --hidden）。
bool HasArgument(const std::vector<std::string>& arguments,
                 const std::string& flag) {
  for (const std::string& argument : arguments) {
    if (argument == flag) {
      return true;
    }
  }
  return false;
}

/// 单实例守卫。
///
/// 第一个实例返回 true；如果已经有实例在运行，就广播“唤出主窗口”的消息，
/// 然后返回 false 让本进程直接退出。
///
/// 互斥体句柄故意不关闭：跟随进程生命周期，进程退出时由系统自动释放。
/// 这样不会出现“上一个实例刚退出、锁却被提前放掉”的竞态。
bool AcquireSingleInstance() {
  static HANDLE mutex_handle = nullptr;
  if (mutex_handle != nullptr) {
    return true;
  }

  mutex_handle = ::CreateMutexW(nullptr, FALSE, kWorkDiaryMutexName);
  if (mutex_handle == nullptr) {
    // 创建失败（权限不足等）：不拦用户，按普通启动继续。
    return true;
  }
  if (::GetLastError() != ERROR_ALREADY_EXISTS) {
    return true;
  }

  // 已有实例：先授权对方抢前台（Windows 默认只允许前台进程激活别的窗口），
  // 再广播消息让它把主窗口亮出来。对方可能还在初始化窗口，因此重试若干次；
  // 一旦有窗口响应就不再空等（旧实现固定睡满 10 × 200ms = 2 秒）。
  ::AllowSetForegroundWindow(ASFW_ANY);
  for (int attempt = 0; attempt < 3; ++attempt) {
    ::PostMessageW(HWND_BROADCAST, WorkDiaryShowWindowMessage(), 0, 0);
    ::Sleep(200);
  }
  return false;
}

}  // namespace

int APIENTRY wWinMain(_In_ HINSTANCE instance, _In_opt_ HINSTANCE prev,
                      _In_ wchar_t *command_line, _In_ int show_command) {
  // ===== 系统兼容性检测 =====
  // 老系统（Windows XP / 精简版系统）的 WS2_32.dll 缺少 GetHostNameW，
  // Flutter 引擎启动时会报"无法定位程序输入点"并直接崩溃。
  // 这里在引擎启动前提前检测，不满足则弹出友好中文提示后退出。
  HMODULE ws2 = ::LoadLibraryW(L"WS2_32.dll");
  bool has_hostname = false;
  if (ws2 != nullptr) {
    has_hostname = ::GetProcAddress(ws2, "GetHostNameW") != nullptr;
    ::FreeLibrary(ws2);
  }
  if (!has_hostname) {
    ::MessageBoxW(
        nullptr,
        L"您的系统版本过低，极简工作日记需要 Windows 10（64 位）及以上系统。\n"
        L"请升级系统后重新打开本软件。",
        L"极简工作日记", MB_OK | MB_ICONWARNING);
    return 0;
  }

  std::vector<std::string> command_line_arguments = GetCommandLineArguments();

  // 升级启动由独立脚本控制进程替换：此时旧进程可能还没退干净，
  // 不能因为互斥体已存在就把新版本直接退掉。
  const bool upgrade_mode = HasArgument(command_line_arguments, "--upgrade");
  if (!upgrade_mode && !AcquireSingleInstance()) {
    return 0;
  }

  // 静默启动（开机自启）：窗口创建后保持隐藏，只在托盘里待命。
  const bool start_hidden = HasArgument(command_line_arguments, "--hidden");

  // 在创建任何窗口 / 调用任何 UI 之前，显式声明 PerMonitorV2 DPI 感知，
  // 与 runner.exe.manifest 双保险。华为 3K 屏等高 DPI 屏下避免窗口尺寸错误。
  // 失败则退化为 PerMonitor (V1)；再失败保持 manifest 默认。
  if (!::SetProcessDpiAwarenessContext(DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2)) {
    ::SetProcessDpiAwarenessContext(DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE);
  }

  // Attach to console when present (e.g., 'flutter run') or create a
  // new console when running with a debugger.
  if (!::AttachConsole(ATTACH_PARENT_PROCESS) && ::IsDebuggerPresent()) {
    CreateAndAttachConsole();
  }

  // Initialize COM, so that it is available for use in the library and/or
  // plugins.
  ::CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);

  flutter::DartProject project(L"data");

  project.set_dart_entrypoint_arguments(std::move(command_line_arguments));

  FlutterWindow window(project);
  window.SetStartHidden(start_hidden);

  // 逻辑窗口尺寸（DIP）。win32_window.cpp 的 Create() 会按当前显示器 DPI
  // 自动乘上 scale_factor 换算成物理像素，这里不要再乘。
  const Win32Window::Size default_size(530, 750);

  // 取主屏 DPI，用于把物理像素的系统信息（工作区、边距）换算回逻辑 DIP。
  UINT system_dpi = ::GetDpiForSystem();
  double scale = system_dpi / 96.0;
  if (scale < 1.0) {
    scale = 1.0;  // 兜底：异常 DPI 时按 100% 处理
  }

  // SPI_GETWORKAREA 在 PerMonitorV2 进程中返回【主屏】工作区的物理像素坐标。
  // 多屏扩展时它始终指向主屏，保证默认位置只出现在主屏上，不会漂到副屏。
  RECT work_area;
  ::SystemParametersInfo(SPI_GETWORKAREA, 0, &work_area, 0);

  // 物理像素 -> 逻辑 DIP，再和逻辑窗口尺寸相减，保证单位一致。
  double work_right_logical = work_area.right / scale;
  double work_top_logical = work_area.top / scale;

  // 边距统一用逻辑像素（DIP）：Create() 会按显示器 scale_factor 换算成物理
  // 像素。旧实现乘过一次 scale，150% 缩放下变成 15/75 DIP，和注释对不上。
  const int right_margin = 10;
  const int top_offset = 50;

  // 默认停靠主屏右侧、距顶部 50 逻辑像素。
  const window_state::Bounds fallback{
      static_cast<int>(work_right_logical) - static_cast<int>(default_size.width) -
          right_margin,
      static_cast<int>(work_top_logical) + top_offset,
      static_cast<int>(default_size.width),
      static_cast<int>(default_size.height)};

  // 上次退出时的窗口几何。首帧就按记忆的尺寸 / 位置创建，避免先出现在默认
  // 位置再跳过去；文件缺失、显示器断开、分辨率变小时回落到默认停靠位置。
  const window_state::State saved_state = window_state::Load();
  const window_state::Bounds bounds =
      window_state::Resolve(saved_state, fallback);
  window.SetStartMaximized(saved_state.valid && saved_state.maximized);

  Win32Window::Point origin(bounds.x, bounds.y);
  Win32Window::Size size(bounds.width, bounds.height);
  if (!window.Create(L"极简工作日记", origin, size)) {
    return EXIT_FAILURE;
  }
  // 最小尺寸单独设置：默认打开 530x750，但允许用户缩小到刚好能用的尺寸
  // （小屏笔记本 / 150% 缩放下 750 逻辑高度可能超出工作区）。
  window.SetMinimumSize(Win32Window::Size(420, 480));
  window.SetQuitOnClose(true);

  ::MSG msg;
  while (::GetMessage(&msg, nullptr, 0, 0)) {
    ::TranslateMessage(&msg);
    ::DispatchMessage(&msg);
  }

  ::CoUninitialize();
  return EXIT_SUCCESS;
}
