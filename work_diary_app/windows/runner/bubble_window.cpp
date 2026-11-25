#include "bubble_window.h"

#include <windows.h>
#include <gdiplus.h>

#include <cmath>
#include <cstring>
#include <string>
#include <utility>

#include "resource.h"

#pragma comment(lib, "gdiplus.lib")

namespace {

// 气泡窗口类名（进程内唯一）
constexpr wchar_t kWindowClassName[] = L"WorkDiaryBubbleWindow";

// 距离工作区右下角的边距
constexpr int kMargin = 24;

// 右键菜单项 ID（菜单是每次临时创建的，ID 只要在本菜单内唯一即可）
constexpr UINT kMenuQuickMemo = 1;
constexpr UINT kMenuQuickTask = 2;
constexpr UINT kMenuShowWindow = 3;
constexpr UINT kMenuHideBubble = 4;
constexpr UINT kMenuQuit = 5;

// 菜单文案用 \u 转义而不是直接写中文：源文件的编码在不同机器上可能被
// 当成 GBK 解释，转义可以保证在任何编码下都编译出正确的宽字符。
constexpr wchar_t kTextQuickMemo[] = L"\u8BB0\u4E00\u7B14";              // 记一笔
constexpr wchar_t kTextQuickTask[] = L"\u8BB0\u4EFB\u52A1";              // 记任务
constexpr wchar_t kTextShowWindow[] = L"\u6253\u5F00\u4E3B\u7A97\u53E3";  // 打开主窗口
constexpr wchar_t kTextHideBubble[] = L"\u5173\u95ED\u6C14\u6CE1\u7403";  // 关闭气泡球
constexpr wchar_t kTextQuit[] = L"\u9000\u51FA\u8F6F\u4EF6";              // 退出软件

// ---- GDI+ 生命周期（进程内只启动一次）----
Gdiplus::GdiplusStartupInput g_gdiplus_input;
ULONG_PTR g_gdiplus_token = 0;
bool g_gdiplus_ready = false;

void EnsureGdiplus() {
  if (g_gdiplus_ready) {
    return;
  }
  if (Gdiplus::GdiplusStartup(&g_gdiplus_token, &g_gdiplus_input, nullptr) ==
      Gdiplus::Ok) {
    g_gdiplus_ready = true;
  }
}

void AddRoundRect(Gdiplus::GraphicsPath* path, const Gdiplus::RectF& rect,
                  Gdiplus::REAL radius) {
  const Gdiplus::REAL d = radius * 2.0f;
  path->AddArc(rect.X, rect.Y, d, d, 180.0f, 90.0f);
  path->AddArc(rect.GetRight() - d, rect.Y, d, d, 270.0f, 90.0f);
  path->AddArc(rect.GetRight() - d, rect.GetBottom() - d, d, d, 0.0f, 90.0f);
  path->AddArc(rect.X, rect.GetBottom() - d, d, d, 90.0f, 90.0f);
  path->CloseFigure();
}

/// 绕设计画布中心缩放：出现动画与呼吸共用同一个变换。
Gdiplus::Matrix MakeScaleAboutCenter(double scale) {
  const Gdiplus::REAL center =
      static_cast<Gdiplus::REAL>(BubbleWindow::kWindow) / 2.0f;
  const Gdiplus::REAL factor = static_cast<Gdiplus::REAL>(scale);
  const Gdiplus::REAL offset = center * (1.0f - factor);
  return Gdiplus::Matrix(factor, 0.0f, 0.0f, factor, offset, offset);
}

/// 系统是否允许窗口动画（设置 → 辅助功能 → 视觉效果 → 动画效果）。
/// 关闭时保持静态气泡，尊重“减少动效”的用户偏好。
bool SystemAnimationsEnabled() {
  BOOL animations_enabled = TRUE;
  if (::SystemParametersInfoW(SPI_GETCLIENTAREAANIMATION, 0,
                              &animations_enabled, 0) == 0) {
    return true;  // 查询失败按“开启动画”处理
  }
  return animations_enabled != FALSE;
}

}  // namespace

bool BubbleWindow::s_class_registered_ = false;

BubbleWindow::~BubbleWindow() {
  if (icon_ != nullptr) {
    DestroyIcon(icon_);
    icon_ = nullptr;
  }
  // 进程退出时不主动 DestroyWindow：窗口会随进程结束由系统回收，
  // 避免在静态析构阶段操作已失效的消息循环。
}

void BubbleWindow::SetMainWindow(HWND main_window) {
  main_window_ = main_window;
}

void BubbleWindow::SetActionHandler(ActionHandler handler) {
  action_handler_ = std::move(handler);
}

void BubbleWindow::UpdateScale(UINT dpi_hint) {
  // 按主窗口所在显示器的 DPI 换算：100% -> 0.5（保持原有视觉尺寸），
  // 150% -> 0.75，200% -> 1.0，保证高 DPI 下气泡不会缩成一个小点。
  UINT dpi = dpi_hint;
  if (dpi == 0 && main_window_ != nullptr && ::IsWindow(main_window_) != 0) {
    dpi = ::GetDpiForWindow(main_window_);
  }
  if (dpi == 0) {
    dpi = ::GetDpiForSystem();
  }
  if (dpi == 0) {
    dpi = 96;
  }
  scale_ = kBaseScale * (static_cast<double>(dpi) / 96.0);
  window_pixels_ = static_cast<int>(std::lround(kWindow * scale_));
  bubble_pixels_ = static_cast<int>(std::lround(kBubble * scale_));
  pad_pixels_ = static_cast<int>(std::lround(kPad * scale_));

  // 兜底：极端 DPI 下窗口至少要有几个像素，避免创建失败。
  if (window_pixels_ < 16) {
    window_pixels_ = 16;
  }
  if (bubble_pixels_ < 8) {
    bubble_pixels_ = 8;
  }
  if (pad_pixels_ < 0) {
    pad_pixels_ = 0;
  }
}

void BubbleWindow::EnsureAnimationTimer(UINT interval_ms) {
  if (hwnd_ == nullptr) {
    return;
  }
  if (animating_ && timer_interval_ms_ == interval_ms) {
    return;
  }
  ::KillTimer(hwnd_, kAnimationTimerId);
  if (::SetTimer(hwnd_, kAnimationTimerId, interval_ms, nullptr) == 0) {
    // 计时器创建失败（极少见）：退回静态显示，不能让气泡停在半透明状态。
    animating_ = false;
    timer_interval_ms_ = 0;
    appear_ = 1.0;
    return;
  }
  animating_ = true;
  timer_interval_ms_ = interval_ms;
}

void BubbleWindow::UpdateAnimationState() {
  if (hwnd_ == nullptr) {
    return;
  }
  // 相位用墙钟计算而不是累加帧数：消息循环偶发卡顿、掉帧都不会让节奏变形。
  const double elapsed_seconds =
      static_cast<double>(::GetTickCount64() - animation_started_at_) / 1000.0;
  appear_ = elapsed_seconds >= kAppearDurationSec
                ? 1.0
                : elapsed_seconds / kAppearDurationSec;
  const double angle =
      2.0 * 3.14159265358979323846 * elapsed_seconds / kBreathPeriodSec;
  breath_ = 0.5 - 0.5 * std::cos(angle);
}

void BubbleWindow::PauseAnimation() {
  if (hwnd_ == nullptr || !animating_) {
    return;
  }
  ::KillTimer(hwnd_, kAnimationTimerId);
  animating_ = false;
  timer_interval_ms_ = 0;
  paused_at_ = ::GetTickCount64();
}

void BubbleWindow::ResumeAnimation() {
  if (hwnd_ == nullptr || animating_) {
    return;
  }
  if (!SystemAnimationsEnabled()) {
    return;
  }
  const ULONGLONG now = ::GetTickCount64();
  // 暂停时长不计入相位：恢复后从冻结的那一帧继续，不会跳变。
  if (paused_at_ != 0 && now > paused_at_) {
    animation_started_at_ += now - paused_at_;
  }
  paused_at_ = 0;
  EnsureAnimationTimer(appear_ < 1.0 ? kAppearFrameMs : kBreathFrameMs);
}

bool BubbleWindow::EnsureClassRegistered() {
  if (s_class_registered_) {
    return true;
  }
  EnsureGdiplus();

  HINSTANCE instance = GetModuleHandleW(nullptr);
  // 与 ScreenshotWindow 一致：先注销，确保样式改动在重复注册时也能生效
  UnregisterClassW(kWindowClassName, instance);

  WNDCLASSEXW window_class{};
  window_class.cbSize = static_cast<UINT>(sizeof(WNDCLASSEXW));
  window_class.style = 0;
  window_class.lpfnWndProc = BubbleWindow::WndProc;
  window_class.hInstance = instance;
  window_class.hCursor = LoadCursorW(nullptr, IDC_HAND);
  window_class.hbrBackground = nullptr;  // 全部自绘
  window_class.lpszClassName = kWindowClassName;

  if (RegisterClassExW(&window_class) == 0) {
    return false;
  }
  s_class_registered_ = true;
  return true;
}

bool BubbleWindow::Show(long long count) {
  count_ = count < 0 ? 0 : count;
  UpdateScale();

  if (hwnd_ != nullptr) {
    Render();
    ShowWindow(hwnd_, SW_SHOWNOACTIVATE);
    return true;
  }

  if (!EnsureClassRegistered()) {
    return false;
  }

  // 位置：主窗口所在显示器的工作区右下角
  HWND reference = main_window_ != nullptr ? main_window_ : GetForegroundWindow();
  HMONITOR monitor = MonitorFromWindow(reference, MONITOR_DEFAULTTONEAREST);
  RECT work_area{};
  MONITORINFO monitor_info{};
  monitor_info.cbSize = static_cast<DWORD>(sizeof(MONITORINFO));
  if (monitor != nullptr && GetMonitorInfoW(monitor, &monitor_info) != 0) {
    work_area = monitor_info.rcWork;
  } else {
    SystemParametersInfoW(SPI_GETWORKAREA, 0, &work_area, 0);
  }

  // 位置：贴右侧、竖直居中。窗口比气泡大一圈，所以坐标要减掉四周边距，
  // 视觉上的气泡才落在期望的位置。
  const int work_height = work_area.bottom - work_area.top;
  const int margin_pixels = static_cast<int>(std::lround(kMargin * scale_));
  const int x = work_area.right - bubble_pixels_ - margin_pixels - pad_pixels_;
  const int y = work_area.top + (work_height - bubble_pixels_) / 2 - pad_pixels_;

  hwnd_ = CreateWindowExW(
      WS_EX_TOPMOST | WS_EX_TOOLWINDOW | WS_EX_NOACTIVATE | WS_EX_LAYERED,
      kWindowClassName, L"", WS_POPUP, x, y, window_pixels_, window_pixels_,
      nullptr, nullptr, GetModuleHandleW(nullptr), this);
  if (hwnd_ == nullptr) {
    return false;
  }

  // 出现动画：250ms 内从 92% 淡入到 100%，随后进入呼吸循环。
  // 系统关闭动画时直接渲染静态帧，不启动计时器。
  animating_ = false;
  timer_interval_ms_ = 0;
  paused_at_ = 0;
  animation_started_at_ = ::GetTickCount64();
  breath_ = 0.0;
  appear_ = SystemAnimationsEnabled() ? 0.0 : 1.0;
  Render();
  ShowWindow(hwnd_, SW_SHOWNOACTIVATE);
  if (appear_ < 1.0) {
    EnsureAnimationTimer(kAppearFrameMs);
    if (!animating_) {
      // 计时器没建起来（SetTimer 失败）：立即补一帧完整显示的画面。
      Render();
    }
  }
  return true;
}

void BubbleWindow::Hide() {
  if (hwnd_ == nullptr) {
    return;
  }
  HWND hwnd = hwnd_;
  hwnd_ = nullptr;  // 先摘句柄，避免销毁过程中的重入
  dragging_ = false;
  ::KillTimer(hwnd, kAnimationTimerId);
  animating_ = false;
  timer_interval_ms_ = 0;
  appear_ = 1.0;
  DestroyWindow(hwnd);
}

void BubbleWindow::UpdateCount(long long count) {
  const long long next = count < 0 ? 0 : count;
  if (next == count_) {
    return;
  }
  count_ = next;
  if (hwnd_ != nullptr) {
    Render();
  }
}

bool BubbleWindow::IsVisible() const {
  return hwnd_ != nullptr && IsWindowVisible(hwnd_) != 0;
}

bool BubbleWindow::IsMainWindowForeground() const {
  if (main_window_ == nullptr || IsWindow(main_window_) == 0) {
    return false;
  }
  return GetForegroundWindow() == main_window_;
}

LRESULT CALLBACK BubbleWindow::WndProc(HWND hwnd, UINT message, WPARAM wparam,
                                       LPARAM lparam) {
  if (message == WM_NCCREATE) {
    const auto* create_struct = reinterpret_cast<const CREATESTRUCTW*>(lparam);
    auto* self = static_cast<BubbleWindow*>(create_struct->lpCreateParams);
    SetWindowLongPtr(hwnd, GWLP_USERDATA, reinterpret_cast<LONG_PTR>(self));
    if (self != nullptr) {
      return self->HandleMessage(hwnd, message, wparam, lparam);
    }
    return DefWindowProcW(hwnd, message, wparam, lparam);
  }

  auto* self =
      reinterpret_cast<BubbleWindow*>(GetWindowLongPtr(hwnd, GWLP_USERDATA));
  if (self == nullptr) {
    return DefWindowProcW(hwnd, message, wparam, lparam);
  }
  return self->HandleMessage(hwnd, message, wparam, lparam);
}

LRESULT BubbleWindow::HandleMessage(HWND hwnd, UINT message, WPARAM wparam,
                                    LPARAM lparam) {
  switch (message) {
    case WM_ERASEBKGND:
      return 1;

    case WM_PAINT: {
      // 内容由 UpdateLayeredWindow 提供，这里只负责把更新区域清掉，
      // 否则 WM_PAINT 会无限重复。
      PAINTSTRUCT paint_struct{};
      HDC hdc = BeginPaint(hwnd, &paint_struct);
      if (hdc != nullptr) {
        EndPaint(hwnd, &paint_struct);
      }
      return 0;
    }

    case WM_TIMER: {
      if (wparam == kAnimationTimerId) {
        UpdateAnimationState();
        Render();
        // 出现动画结束后降到呼吸帧率，省一点 CPU。
        if (appear_ >= 1.0 && timer_interval_ms_ != kBreathFrameMs) {
          EnsureAnimationTimer(kBreathFrameMs);
        }
        return 0;
      }
      break;
    }

    case WM_NCHITTEST: {
      // 窗口比气泡大一圈，气泡之外的透明区域要让点击穿透过去
      POINT cursor{};
      GetCursorPos(&cursor);
      ScreenToClient(hwnd, &cursor);
      if (HitTest(cursor)) {
        return HTCLIENT;
      }
      return HTTRANSPARENT;
    }

    case WM_DPICHANGED: {
      // 拖到不同 DPI 的显示器上：按新 DPI 重算尺寸并重绘，避免气泡变小/变糊。
      UpdateScale(static_cast<UINT>(LOWORD(wparam)));
      const RECT* target = reinterpret_cast<const RECT*>(lparam);
      if (target != nullptr) {
        SetWindowPos(hwnd, HWND_TOPMOST, target->left, target->top,
                     window_pixels_, window_pixels_,
                     SWP_NOACTIVATE | SWP_NOOWNERZORDER);
      }
      Render();
      return 0;
    }

    case WM_RBUTTONUP: {
      // 右键：弹出菜单
      //（记一笔 / 记任务 / 打开主窗口 / 关闭气泡球 / 退出软件）
      ShowContextMenu(hwnd);
      return 0;
    }

    case WM_LBUTTONDOWN: {
      // 拖拽时暂停呼吸：球正在跟着鼠标走，再缩放会显得晃。
      PauseAnimation();
      SetCapture(hwnd);
      dragging_ = false;
      GetCursorPos(&drag_origin_cursor_);
      RECT window_rect{};
      if (GetWindowRect(hwnd, &window_rect) != 0) {
        drag_origin_window_.x = window_rect.left;
        drag_origin_window_.y = window_rect.top;
      }
      return 0;
    }

    case WM_MOUSEMOVE: {
      if (GetCapture() == hwnd) {
        POINT cursor{};
        GetCursorPos(&cursor);
        const int delta_x = cursor.x - drag_origin_cursor_.x;
        const int delta_y = cursor.y - drag_origin_cursor_.y;
        if (!dragging_ &&
            (delta_x > 4 || delta_x < -4 || delta_y > 4 || delta_y < -4)) {
          dragging_ = true;
        }
        if (dragging_) {
          SetWindowPos(hwnd, HWND_TOPMOST, drag_origin_window_.x + delta_x,
                       drag_origin_window_.y + delta_y, 0, 0,
                       SWP_NOSIZE | SWP_NOACTIVATE);
        }
      }
      return 0;
    }

    case WM_LBUTTONUP: {
      // 必须在 ReleaseCapture 之前取状态：ReleaseCapture 会同步派发
      // WM_CAPTURECHANGED，那里会把 dragging_ 清零，之后再判断就永远是“点击”。
      const bool was_dragging = dragging_;
      dragging_ = false;
      if (GetCapture() == hwnd) {
        ReleaseCapture();
      }
      if (!was_dragging) {
        // 纯点击：恢复主窗口并隐藏气泡
        RestoreMainWindow();
        Hide();
      } else {
        // 拖拽结束：从冻结的那一帧继续呼吸
        ResumeAnimation();
      }
      return 0;
    }

    case WM_CAPTURECHANGED:
      // 捕获被抢走（Alt+Tab 等）时也要恢复动画，否则会一直停在冻结帧。
      dragging_ = false;
      ResumeAnimation();
      return 0;

    case WM_NCDESTROY:
      hwnd_ = nullptr;
      dragging_ = false;
      // 计时器随窗口销毁，这里同步清掉“正在动画”的标记，
      // 否则下次 Show 会以为计时器还在而跳过 SetTimer。
      animating_ = false;
      timer_interval_ms_ = 0;
      break;

    default:
      break;
  }
  return DefWindowProcW(hwnd, message, wparam, lparam);
}

bool BubbleWindow::HitTest(POINT client_point) const {
  // 客户端坐标是实际像素，先换算回设计单位再判几何
  const double design_x = static_cast<double>(client_point.x) / scale_;
  const double design_y = static_cast<double>(client_point.y) / scale_;
  const double center = static_cast<double>(kPad) + kBubble / 2.0;
  const double radius = kBubble / 2.0;
  const double dx = design_x - center;
  const double dy = design_y - center;
  if (dx * dx + dy * dy <= radius * radius) {
    return true;
  }
  // 角标外溢到圆外的部分也要能点
  const POINT design_point{static_cast<LONG>(design_x),
                           static_cast<LONG>(design_y)};
  return PtInRect(&badge_rect_, design_point) != 0;
}

void BubbleWindow::ShowContextMenu(HWND hwnd) {
  HMENU menu = ::CreatePopupMenu();
  if (menu == nullptr) {
    return;
  }
  ::AppendMenuW(menu, MF_STRING, kMenuQuickMemo, kTextQuickMemo);
  ::AppendMenuW(menu, MF_STRING, kMenuQuickTask, kTextQuickTask);
  ::AppendMenuW(menu, MF_STRING, kMenuShowWindow, kTextShowWindow);
  ::AppendMenuW(menu, MF_SEPARATOR, 0, nullptr);
  ::AppendMenuW(menu, MF_STRING, kMenuHideBubble, kTextHideBubble);
  ::AppendMenuW(menu, MF_STRING, kMenuQuit, kTextQuit);

  POINT cursor{};
  ::GetCursorPos(&cursor);

  // TrackPopupMenu 前必须把窗口设为前台，否则点击菜单外面不会收起菜单
  //（WS_EX_NOACTIVATE 的窗口在用户刚点过它时允许这样取前台）。
  ::SetForegroundWindow(hwnd);
  const UINT command = ::TrackPopupMenu(
      menu, TPM_RIGHTBUTTON | TPM_RETURNCMD | TPM_NONOTIFY, cursor.x,
      cursor.y, 0, hwnd, nullptr);
  ::DestroyMenu(menu);
  // 官方建议：菜单结束后补一条空消息，避免菜单残留
  ::PostMessageW(hwnd, WM_NULL, 0, 0);

  if (command == 0 || !action_handler_) {
    return;
  }
  switch (command) {
    case kMenuQuickMemo:
      action_handler_("quick_memo");
      break;
    case kMenuQuickTask:
      action_handler_("quick_task");
      break;
    case kMenuShowWindow:
      action_handler_("show_window");
      break;
    case kMenuHideBubble:
      action_handler_("hide_bubble");
      break;
    case kMenuQuit:
      action_handler_("quit");
      break;
    default:
      break;
  }
  // 这几项执行后都要把气泡收起来：
  // - 前三项会把主窗口带回前台，气泡留着会挡在窗口上面；
  // - 「关闭气泡球」本身就是关闭动作。
  // （退出软件不需要：进程马上结束，`Hide()` 里的 DestroyWindow 反而多余。）
  if (command == kMenuQuickMemo || command == kMenuQuickTask ||
      command == kMenuShowWindow || command == kMenuHideBubble) {
    Hide();
  }
}

void BubbleWindow::RestoreMainWindow() {
  if (main_window_ == nullptr || IsWindow(main_window_) == 0) {
    return;
  }
  // 最小化 → SW_RESTORE；被隐藏到托盘 → SW_SHOW（SW_RESTORE 不会显示隐藏窗口）
  if (IsIconic(main_window_) != 0) {
    ShowWindow(main_window_, SW_RESTORE);
  } else {
    ShowWindow(main_window_, SW_SHOW);
  }
  SetForegroundWindow(main_window_);
}

void BubbleWindow::EnsureIcon() {
  if (icon_ != nullptr) {
    return;
  }
  // 按 256 加载，绘制时再用 GDI+ 高质量缩到 56px，避免最近邻放大的糊边
  HINSTANCE instance = GetModuleHandleW(nullptr);
  icon_ = static_cast<HICON>(LoadImageW(instance, MAKEINTRESOURCEW(IDI_APP_ICON),
                                        IMAGE_ICON, 256, 256, LR_DEFAULTCOLOR));
}

void BubbleWindow::Render() {
  if (hwnd_ == nullptr) {
    return;
  }
  EnsureGdiplus();
  EnsureIcon();

  // 出现动画：三次缓出，0.92 -> 1.0；呼吸：±6% 的正弦缩放。
  // 幅度不能太小：44px 的球上 2.5% 只有 ±1px，肉眼几乎看不出，只剩阴影在动。
  // 球体和图标共用同一个「绕画布中心」的变换，彼此没有相对位移；角标不参与呼吸。
  const double appear_eased = 1.0 - std::pow(1.0 - appear_, 3.0);
  const double appear_scale =
      kAppearMinScale + (1.0 - kAppearMinScale) * appear_eased;
  const double orb_scale = appear_scale * (1.0 + kBreathAmplitude * breath_);

  const int width = window_pixels_;
  const int height = window_pixels_;

  BITMAPINFO bitmap_info{};
  bitmap_info.bmiHeader.biSize = sizeof(BITMAPINFOHEADER);
  bitmap_info.bmiHeader.biWidth = width;
  bitmap_info.bmiHeader.biHeight = -height;  // 自上而下
  bitmap_info.bmiHeader.biPlanes = 1;
  bitmap_info.bmiHeader.biBitCount = 32;
  bitmap_info.bmiHeader.biCompression = BI_RGB;

  void* bits = nullptr;
  HBITMAP dib = CreateDIBSection(nullptr, &bitmap_info, DIB_RGB_COLORS, &bits,
                                 nullptr, 0);
  if (dib == nullptr || bits == nullptr) {
    if (dib != nullptr) {
      DeleteObject(dib);
    }
    return;
  }

  HDC memory_dc = CreateCompatibleDC(nullptr);
  if (memory_dc == nullptr) {
    DeleteObject(dib);
    return;
  }
  HGDIOBJ old_bitmap = SelectObject(memory_dc, dib);
  SecureZeroMemory(bits, static_cast<size_t>(width) * static_cast<size_t>(height) * 4u);

  // 必须画在 Gdiplus::Bitmap 上：直接画进 DIB 的 HDC 不会维护 alpha 通道，
  // UpdateLayeredWindow 拿到的会是全透明，窗口看着就是“什么都不显示”。
  Gdiplus::Bitmap design(kWindow, kWindow, PixelFormat32bppPARGB);
  {
    Gdiplus::Graphics g(&design);
    g.Clear(Gdiplus::Color(0, 0, 0, 0));
    g.SetSmoothingMode(Gdiplus::SmoothingModeAntiAlias);
    g.SetInterpolationMode(Gdiplus::InterpolationModeHighQualityBicubic);
    g.SetPixelOffsetMode(Gdiplus::PixelOffsetModeHalf);
    g.SetCompositingQuality(Gdiplus::CompositingQualityHighQuality);
    g.SetTextRenderingHint(Gdiplus::TextRenderingHintAntiAliasGridFit);

    // 球体（阴影 / 底盘 / 高光 / 图标）跟随出现动画与呼吸缩放。
    Gdiplus::Matrix orb_matrix = MakeScaleAboutCenter(orb_scale);
    g.SetTransform(&orb_matrix);

    const Gdiplus::RectF circle(static_cast<Gdiplus::REAL>(kPad),
                                static_cast<Gdiplus::REAL>(kPad),
                                static_cast<Gdiplus::REAL>(kBubble),
                                static_cast<Gdiplus::REAL>(kBubble));

    // ---- 1. 柔光投影：多层半透明椭圆叠加，越靠外越淡 ----
    // 吸气时阴影略深一点，配合缩放形成“起伏”的错觉。
    // Gdiplus::Color 的通道参数是 BYTE，运行时算出来的值必须显式转换，
    // 否则 /W4 /WX 下会因 C4244（可能丢失数据）直接编译失败。
    const BYTE shadow_alpha = static_cast<BYTE>(
        5 + static_cast<int>(std::lround(2.0 * breath_)));
    for (int i = 12; i >= 1; --i) {
      const Gdiplus::REAL grow = static_cast<Gdiplus::REAL>(i);
      const Gdiplus::SolidBrush shadow(Gdiplus::Color(shadow_alpha, 0, 0, 0));
      g.FillEllipse(&shadow, circle.X - grow, circle.Y - grow + 3.0f,
                    circle.Width + grow * 2.0f, circle.Height + grow * 2.0f);
    }

    // ---- 2. 底盘：径向渐变（左上偏亮）----
    Gdiplus::GraphicsPath circle_path;
    circle_path.AddEllipse(circle);

    Gdiplus::PathGradientBrush base_brush(&circle_path);
    base_brush.SetCenterPoint(
        Gdiplus::PointF(circle.X + circle.Width * 0.34f,
                        circle.Y + circle.Height * 0.26f));
    // 底盘中心随呼吸微微提亮：球体本身“吸气变亮”，而不是只有阴影在动。
    // Gdiplus::Color 的通道是 BYTE，运行时算出的值必须显式转换（/WX 下 C4244 会报错）。
    const int base_light = static_cast<int>(std::lround(14.0 * breath_));
    base_brush.SetCenterColor(
        Gdiplus::Color(255, static_cast<BYTE>(0x74 + base_light),
                       static_cast<BYTE>(0x82 + base_light),
                       static_cast<BYTE>(0x9c + base_light)));
    Gdiplus::Color base_surround[] = {Gdiplus::Color(255, 0x16, 0x1c, 0x27)};
    INT surround_count = 1;
    base_brush.SetSurroundColors(base_surround, &surround_count);
    g.FillPath(&base_brush, &circle_path);

    // ---- 3. 顶部高光 ----
    {
      Gdiplus::RectF highlight(circle.X + circle.Width * 0.06f,
                               circle.Y - circle.Height * 0.06f,
                               circle.Width * 0.88f,
                               circle.Height * 0.46f);
      Gdiplus::GraphicsPath highlight_path;
      highlight_path.AddEllipse(highlight);
      Gdiplus::PathGradientBrush highlight_brush(&highlight_path);
      highlight_brush.SetCenterPoint(
          Gdiplus::PointF(highlight.X + highlight.Width / 2.0f,
                          highlight.Y + highlight.Height * 0.18f));
      const BYTE highlight_alpha = static_cast<BYTE>(
          215 + static_cast<int>(std::lround(17.0 * breath_)));
      highlight_brush.SetCenterColor(
          Gdiplus::Color(highlight_alpha, 255, 255, 255));
      Gdiplus::Color highlight_surround[] = {Gdiplus::Color(0, 255, 255, 255)};
      INT highlight_count = 1;
      highlight_brush.SetSurroundColors(highlight_surround, &highlight_count);

      g.SetClip(&circle_path);
      g.FillPath(&highlight_brush, &highlight_path);

      // 顶部细边缘光，强化玻璃球的轮廓；吸气时更亮一点
      const BYTE rim_alpha = static_cast<BYTE>(
          105 + static_cast<int>(std::lround(40.0 * breath_)));
      Gdiplus::Pen rim(Gdiplus::Color(rim_alpha, 255, 255, 255), 1.6f);
      g.DrawArc(&rim, circle.X + 0.8f, circle.Y + 0.8f, circle.Width - 1.6f,
                circle.Height - 1.6f, 205.0f, 130.0f);
      g.ResetClip();
    }

    // ---- 4. 底部反光 ----
    {
      Gdiplus::RectF reflect(circle.X + circle.Width * 0.22f,
                             circle.Y + circle.Height * 0.82f,
                             circle.Width * 0.56f,
                             circle.Height * 0.13f);
      Gdiplus::GraphicsPath reflect_path;
      reflect_path.AddEllipse(reflect);
      Gdiplus::PathGradientBrush reflect_brush(&reflect_path);
      reflect_brush.SetCenterPoint(
          Gdiplus::PointF(reflect.X + reflect.Width / 2.0f,
                          reflect.Y + reflect.Height / 2.0f));
      reflect_brush.SetCenterColor(Gdiplus::Color(45, 130, 175, 255));
      Gdiplus::Color reflect_surround[] = {Gdiplus::Color(0, 120, 170, 255)};
      INT reflect_count = 1;
      reflect_brush.SetSurroundColors(reflect_surround, &reflect_count);

      g.SetClip(&circle_path);
      g.FillPath(&reflect_brush, &reflect_path);
      g.ResetClip();
    }

    // ---- 5. 外轮廓细高光 ----
    {
      const BYTE ring_alpha = static_cast<BYTE>(
          34 + static_cast<int>(std::lround(20.0 * breath_)));
      Gdiplus::Pen ring(Gdiplus::Color(ring_alpha, 255, 255, 255), 1.0f);
      g.DrawEllipse(&ring, circle.X + 0.5f, circle.Y + 0.5f,
                    circle.Width - 1.0f, circle.Height - 1.0f);
    }

    // ---- 6. 中央图标（圆形裁切 + 高质量缩放）----
    // 图标不再单独缩放：它和球体共用同一个「绕画布中心」的变换。
    // 之前给图标额外加过一点相对缩放，但猫的轮廓左右不对称（左肩更重），
    // 相对放大时视觉重心会横向漂移，看起来像图标在左右挪动。
    if (icon_ != nullptr) {
      Gdiplus::Bitmap* icon_bitmap = Gdiplus::Bitmap::FromHICON(icon_);
      if (icon_bitmap != nullptr) {
        const Gdiplus::REAL icon_size =
            static_cast<Gdiplus::REAL>(kBubble) * kIconRatio;
        const Gdiplus::REAL icon_left =
            circle.X + (static_cast<Gdiplus::REAL>(kBubble) - icon_size) / 2.0f;
        const Gdiplus::REAL icon_top =
            circle.Y + (static_cast<Gdiplus::REAL>(kBubble) - icon_size) / 2.0f;
        const Gdiplus::RectF icon_rect(icon_left, icon_top, icon_size, icon_size);

        // 放大一小圈再裁圆：裁掉图标自带的那层白边，猫头在气泡里更饱满
        const Gdiplus::REAL zoom = 1.12f;
        const Gdiplus::REAL zoomed_size = icon_size * zoom;
        const Gdiplus::RectF icon_draw_rect(
            icon_left - (zoomed_size - icon_size) / 2.0f,
            icon_top - (zoomed_size - icon_size) / 2.0f, zoomed_size, zoomed_size);

        Gdiplus::GraphicsPath icon_clip;
        icon_clip.AddEllipse(icon_rect);
        g.SetClip(&icon_clip);
        g.DrawImage(icon_bitmap, icon_draw_rect);
        g.ResetClip();

        delete icon_bitmap;
      }
    }

    // ---- 7. 角标：数字完整显示，宽度自适应 ----
    // 角标不参与呼吸（文字反复缩放会发虚），只跟随出现动画。
    // 先复位变换，保证下面的 MeasureString 在未缩放的坐标系里量字宽。
    g.ResetTransform();
    badge_rect_ = RECT{0, 0, 0, 0};
    if (count_ > 0) {
      const std::wstring text = std::to_wstring(count_);

      Gdiplus::FontFamily segoe(L"Segoe UI");
      const Gdiplus::FontFamily* family =
          (segoe.GetLastStatus() == Gdiplus::Ok)
              ? &segoe
              : Gdiplus::FontFamily::GenericSansSerif();

      // 从大到小试字号，保证数字能完整放进角标里。
      // 注意：设计画布 116 最终会被缩到 window_pixels_（100% 缩放下 58），
      // 所以这里的字号约为最终物理像素的 2 倍：22 设计像素 ≈ 100% 下 11px。
      // 旧值 15（≈7.5px）在小球上几乎看不清，这里整体放大。
      static const Gdiplus::REAL kFontSizes[] = {22.0f, 20.0f, 18.0f, 16.0f, 14.0f};
      Gdiplus::REAL chosen_size = kFontSizes[0];
      Gdiplus::REAL text_width = 0.0f;
      const Gdiplus::REAL kMaxTextWidth = 52.0f;

      for (const Gdiplus::REAL size : kFontSizes) {
        Gdiplus::Font probe(family, size, Gdiplus::FontStyleBold,
                            Gdiplus::UnitPixel);
        Gdiplus::RectF bounds;
        g.MeasureString(text.c_str(), static_cast<INT>(text.size()), &probe,
                        Gdiplus::PointF(0.0f, 0.0f), &bounds);
        chosen_size = size;
        text_width = bounds.Width;
        if (bounds.Width <= kMaxTextWidth) {
          break;
        }
      }

      const Gdiplus::REAL badge_height = 34.0f;
      Gdiplus::REAL badge_width = text_width + 16.0f;
      if (badge_width < 30.0f) {
        badge_width = 30.0f;
      }
      if (badge_width > static_cast<Gdiplus::REAL>(kWindow) - 4.0f) {
        badge_width = static_cast<Gdiplus::REAL>(kWindow) - 4.0f;
      }

      // 右上角锚定，允许向圆外溢出 6px；整体上移一点，减少对图标上沿的遮挡。
      Gdiplus::REAL badge_x =
          static_cast<Gdiplus::REAL>(kPad + kBubble) + 6.0f - badge_width;
      Gdiplus::REAL badge_y = static_cast<Gdiplus::REAL>(kPad) - 6.0f;
      if (badge_x < 2.0f) {
        badge_x = 2.0f;
      }
      if (badge_y < 2.0f) {
        badge_y = 2.0f;
      }

      const Gdiplus::RectF badge_rect(badge_x, badge_y, badge_width, badge_height);
      badge_rect_ = RECT{static_cast<LONG>(std::floor(badge_rect.X)),
                         static_cast<LONG>(std::floor(badge_rect.Y)),
                         static_cast<LONG>(std::ceil(badge_rect.GetRight())),
                         static_cast<LONG>(std::ceil(badge_rect.GetBottom()))};

      // 角标只在出现动画期间跟着整体缩放。
      Gdiplus::Matrix badge_matrix = MakeScaleAboutCenter(appear_scale);
      g.SetTransform(&badge_matrix);

      // 先在角标周围“挖空” 4px，形成与气泡之间的透明间隙
      {
        const Gdiplus::RectF knockout(badge_rect.X - 4.0f, badge_rect.Y - 4.0f,
                                      badge_rect.Width + 8.0f,
                                      badge_rect.Height + 8.0f);
        Gdiplus::GraphicsPath knockout_path;
        AddRoundRect(&knockout_path, knockout,
                     (knockout.Height) / 2.0f);
        g.SetCompositingMode(Gdiplus::CompositingModeSourceCopy);
        Gdiplus::SolidBrush clear(Gdiplus::Color(0, 0, 0, 0));
        g.FillPath(&clear, &knockout_path);
        g.SetCompositingMode(Gdiplus::CompositingModeSourceOver);
      }

      // 角标底色：竖向红色渐变
      {
        Gdiplus::GraphicsPath badge_path;
        AddRoundRect(&badge_path, badge_rect, badge_height / 2.0f);
        Gdiplus::LinearGradientBrush badge_brush(
            badge_rect, Gdiplus::Color(255, 0xff, 0x62, 0x59),
            Gdiplus::Color(255, 0xe8, 0x28, 0x1d),
            Gdiplus::LinearGradientModeVertical);
        g.FillPath(&badge_brush, &badge_path);
      }

      // 数字
      {
        Gdiplus::Font font(family, chosen_size, Gdiplus::FontStyleBold,
                           Gdiplus::UnitPixel);
        Gdiplus::StringFormat format;
        format.SetAlignment(Gdiplus::StringAlignmentCenter);
        format.SetLineAlignment(Gdiplus::StringAlignmentCenter);
        format.SetFormatFlags(Gdiplus::StringFormatFlagsNoWrap |
                              Gdiplus::StringFormatFlagsNoClip);
        Gdiplus::SolidBrush text_brush(Gdiplus::Color(255, 255, 255, 255));
        Gdiplus::RectF text_rect = badge_rect;
        text_rect.Y += 2.0f;  // GDI+ 文字基线略偏上，按字号微调一格
        g.DrawString(text.c_str(), static_cast<INT>(text.size()), &font,
                     text_rect, &format, &text_brush);
      }
    }
  }

  // 按设计尺寸画完后降采样到实际像素：等比缩小，线条和文字都比直接按
  // 小尺寸绘制更干净。
  Gdiplus::Bitmap surface(width, height, PixelFormat32bppPARGB);
  {
    Gdiplus::Graphics gp(&surface);
    gp.SetInterpolationMode(Gdiplus::InterpolationModeHighQualityBicubic);
    gp.SetPixelOffsetMode(Gdiplus::PixelOffsetModeHalf);
    gp.SetCompositingQuality(Gdiplus::CompositingQualityHighQuality);
    gp.Clear(Gdiplus::Color(0, 0, 0, 0));
    gp.DrawImage(&design, Gdiplus::Rect(0, 0, width, height));
  }

  // 把 GDI+ 表面（已经是预乘 alpha）逐行拷进 DIB，供 UpdateLayeredWindow 使用
  {
    const Gdiplus::Rect lock_rect(0, 0, width, height);
    Gdiplus::BitmapData bitmap_data{};
    if (surface.LockBits(&lock_rect, Gdiplus::ImageLockModeRead,
                         PixelFormat32bppPARGB, &bitmap_data) == Gdiplus::Ok) {
      const size_t row_bytes = static_cast<size_t>(width) * 4u;
      auto* destination = static_cast<BYTE*>(bits);
      for (int row = 0; row < height; ++row) {
        const auto* source =
            static_cast<const BYTE*>(bitmap_data.Scan0) +
            static_cast<size_t>(row) * static_cast<size_t>(bitmap_data.Stride);
        std::memcpy(destination + static_cast<size_t>(row) * row_bytes, source,
                    row_bytes);
      }
      surface.UnlockBits(&bitmap_data);
    }
  }

  POINT source_point{0, 0};
  POINT destination_point{0, 0};
  SIZE window_size{window_pixels_, window_pixels_};
  RECT window_rect{};
  if (GetWindowRect(hwnd_, &window_rect) != 0) {
    destination_point.x = window_rect.left;
    destination_point.y = window_rect.top;
  }
  BLENDFUNCTION blend{};
  blend.BlendOp = AC_SRC_OVER;
  blend.BlendFlags = 0;
  // 出现动画用整窗常量 alpha 做淡入，位图本身不用重算。
  blend.SourceConstantAlpha =
      static_cast<BYTE>(std::lround(255.0 * appear_eased));
  blend.AlphaFormat = AC_SRC_ALPHA;
  UpdateLayeredWindow(hwnd_, nullptr, &destination_point, &window_size,
                      memory_dc, &source_point, 0, &blend, ULW_ALPHA);

  SelectObject(memory_dc, old_bitmap);
  DeleteDC(memory_dc);
  DeleteObject(dib);
}
