#include "screenshot_window.h"

#include <windows.h>
#include <windowsx.h>
#include <gdiplus.h>
#include <objidl.h>
#include <vector>
#include <string>
#include <algorithm>
#include <cstdint>

// ---------- 静态成员初始化 ----------
ULONG_PTR ScreenshotWindow::s_gdiplus_token_ = 0;
bool ScreenshotWindow::s_gdiplus_inited_ = false;

// ---------- base64 编码 ----------
static std::string base64_encode(const unsigned char* data, size_t len) {
  static const char table[] =
      "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
  std::string result;
  result.reserve(((len + 2) / 3) * 4);
  for (size_t i = 0; i < len; i += 3) {
    uint32_t n = static_cast<uint32_t>(data[i]) << 16;
    if (i + 1 < len) n |= static_cast<uint32_t>(data[i + 1]) << 8;
    if (i + 2 < len) n |= static_cast<uint32_t>(data[i + 2]);
    result.push_back(table[(n >> 18) & 0x3F]);
    result.push_back(table[(n >> 12) & 0x3F]);
    result.push_back(i + 1 < len ? table[(n >> 6) & 0x3F] : '=');
    result.push_back(i + 2 < len ? table[n & 0x3F] : '=');
  }
  return result;
}

// ---------- 获取 PNG 编码器 CLSID ----------
static int GetEncoderClsid(const WCHAR* format, CLSID* pClsid) {
  UINT num = 0;
  UINT size = 0;
  Gdiplus::GetImageEncodersSize(&num, &size);
  if (size == 0) return -1;
  auto* info = (Gdiplus::ImageCodecInfo*)malloc(size);
  Gdiplus::GetImageEncoders(num, size, info);
  for (UINT j = 0; j < num; j++) {
    if (wcscmp(info[j].MimeType, format) == 0) {
      *pClsid = info[j].Clsid;
      free(info);
      return (int)j;
    }
  }
  free(info);
  return -1;
}

// 窗口类名
static const wchar_t kWindowClassName[] = L"WorkDiaryScreenshotWindow";

ScreenshotWindow::ScreenshotWindow(const std::vector<uint8_t>& screenshot_png,
                                   ResultCallback callback)
    : screenshot_png_(screenshot_png), callback_(std::move(callback)) {
  // 初始化 GDI+（只初始化一次）
  if (!s_gdiplus_inited_) {
    Gdiplus::GdiplusStartupInput input;
    Gdiplus::GdiplusStartup(&s_gdiplus_token_, &input, nullptr);
    s_gdiplus_inited_ = true;
  }

  // 从 PNG 数据创建 GDI+ Bitmap
  if (!screenshot_png_.empty()) {
    HGLOBAL hGlobal = GlobalAlloc(GMEM_MOVEABLE, screenshot_png_.size());
    if (hGlobal) {
      void* p = GlobalLock(hGlobal);
      memcpy(p, screenshot_png_.data(), screenshot_png_.size());
      GlobalUnlock(hGlobal);
      IStream* pStream = nullptr;
      if (CreateStreamOnHGlobal(hGlobal, TRUE, &pStream) == S_OK) {
        bitmap_.reset(Gdiplus::Bitmap::FromStream(pStream));
        pStream->Release();
      }
      // 注意：CreateStreamOnHGlobal with TRUE 会在 Release 时自动释放 hGlobal
    }
  }

  if (bitmap_) {
    width_ = bitmap_->GetWidth();
    height_ = bitmap_->GetHeight();
  }
}

ScreenshotWindow::~ScreenshotWindow() {
  // 释放双缓冲 GDI 对象
  if (back_dc_) {
    SelectObject(back_dc_, back_old_bmp_);
    DeleteObject(back_bmp_);
    DeleteDC(back_dc_);
    back_dc_ = nullptr;
  }
  // 释放预渲染截图 GDI 对象
  if (screenshot_dc_) {
    SelectObject(screenshot_dc_, screenshot_old_bmp_);
    DeleteObject(screenshot_bmp_);
    DeleteDC(screenshot_dc_);
    screenshot_dc_ = nullptr;
  }

  if (hwnd_) {
    SetWindowLongPtr(hwnd_, GWLP_USERDATA, 0);
    HWND h = hwnd_;
    hwnd_ = nullptr;
    DestroyWindow(h);
  }
}

bool ScreenshotWindow::Show() {
  // 先注销旧窗口类（如果存在），确保新样式（CS_DBLCLKS）生效
  HINSTANCE hInst = GetModuleHandle(nullptr);
  UnregisterClass(kWindowClassName, hInst);

  // 注册窗口类
  WNDCLASSEX wc = {0};
  wc.cbSize = sizeof(WNDCLASSEX);
  wc.style = CS_DBLCLKS;  // 接收双击消息（WM_LBUTTONDBLCLK）
  wc.lpfnWndProc = ScreenshotWindow::WndProc;
  wc.hInstance = hInst;
  wc.lpszClassName = kWindowClassName;
  wc.hCursor = LoadCursor(nullptr, IDC_CROSS);
  wc.hbrBackground = (HBRUSH)GetStockObject(BLACK_BRUSH);
  RegisterClassEx(&wc);

  // 虚拟屏幕大小（覆盖所有显示器）
  int screen_left = GetSystemMetrics(SM_XVIRTUALSCREEN);
  int screen_top = GetSystemMetrics(SM_YVIRTUALSCREEN);
  int screen_w = GetSystemMetrics(SM_CXVIRTUALSCREEN);
  int screen_h = GetSystemMetrics(SM_CYVIRTUALSCREEN);

  // 创建全屏置顶无边框窗口
  hwnd_ = CreateWindowEx(
      WS_EX_TOPMOST | WS_EX_TOOLWINDOW,
      kWindowClassName,
      L"截图",
      WS_POPUP | WS_VISIBLE,
      screen_left, screen_top, screen_w, screen_h,
      nullptr, nullptr, GetModuleHandle(nullptr), this);

  if (!hwnd_) return false;

  // 预渲染底层截图到内存 DC（只做一次，拖动时用 BitBlt，极快）
  if (bitmap_ && width_ > 0 && height_ > 0) {
    HDC screen_dc = GetDC(hwnd_);

    // 截图 DC
    screenshot_dc_ = CreateCompatibleDC(screen_dc);
    screenshot_bmp_ = CreateCompatibleBitmap(screen_dc, width_, height_);
    screenshot_old_bmp_ = (HBITMAP)SelectObject(screenshot_dc_, screenshot_bmp_);
    {
      Gdiplus::Graphics g(screenshot_dc_);
      g.SetInterpolationMode(Gdiplus::InterpolationModeNearestNeighbor);
      g.SetPixelOffsetMode(Gdiplus::PixelOffsetModeHalf);
      g.DrawImage(bitmap_.get(), 0, 0, width_, height_);
    }

    // 持久化双缓冲 DC
    back_dc_ = CreateCompatibleDC(screen_dc);
    back_bmp_ = CreateCompatibleBitmap(screen_dc, width_, height_);
    back_old_bmp_ = (HBITMAP)SelectObject(back_dc_, back_bmp_);

    ReleaseDC(hwnd_, screen_dc);
  }

  ShowWindow(hwnd_, SW_SHOW);
  UpdateWindow(hwnd_);
  SetForegroundWindow(hwnd_);
  SetFocus(hwnd_);
  return true;
}

LRESULT CALLBACK ScreenshotWindow::WndProc(HWND hwnd, UINT msg, WPARAM wparam, LPARAM lparam) {
  ScreenshotWindow* self = nullptr;
  if (msg == WM_CREATE) {
    CREATESTRUCT* cs = reinterpret_cast<CREATESTRUCT*>(lparam);
    self = reinterpret_cast<ScreenshotWindow*>(cs->lpCreateParams);
    SetWindowLongPtr(hwnd, GWLP_USERDATA, reinterpret_cast<LONG_PTR>(self));
    self->hwnd_ = hwnd;
  } else {
    self = reinterpret_cast<ScreenshotWindow*>(GetWindowLongPtr(hwnd, GWLP_USERDATA));
  }

  if (!self) return DefWindowProc(hwnd, msg, wparam, lparam);

  switch (msg) {
    case WM_PAINT: {
      PAINTSTRUCT ps;
      HDC hdc = BeginPaint(hwnd, &ps);
      self->OnPaint(hdc);
      EndPaint(hwnd, &ps);
      return 0;
    }
    case WM_LBUTTONDOWN:
      self->OnLButtonDown(GET_X_LPARAM(lparam), GET_Y_LPARAM(lparam));
      return 0;
    case WM_MOUSEMOVE:
      self->OnMouseMove(GET_X_LPARAM(lparam), GET_Y_LPARAM(lparam));
      return 0;
    case WM_LBUTTONUP:
      self->OnLButtonUp(GET_X_LPARAM(lparam), GET_Y_LPARAM(lparam));
      return 0;
    case WM_LBUTTONDBLCLK:
      self->OnLButtonDblClk(GET_X_LPARAM(lparam), GET_Y_LPARAM(lparam));
      return 0;
    case WM_RBUTTONUP:
      self->OnRButtonUp(GET_X_LPARAM(lparam), GET_Y_LPARAM(lparam));
      return 0;
    case WM_KEYDOWN:
      self->OnKeyDown((int)wparam);
      return 0;
    case WM_DESTROY:
      return 0;
    default:
      return DefWindowProc(hwnd, msg, wparam, lparam);
  }
}

void ScreenshotWindow::OnPaint(HDC hdc) {
  if (!back_dc_ || !screenshot_dc_) return;

  // 1. 把预渲染的底层截图 BitBlt 到双缓冲（GDI，极快，比 GDI+ DrawImage 快 10 倍以上）
  BitBlt(back_dc_, 0, 0, width_, height_, screenshot_dc_, 0, 0, SRCCOPY);

  // 2. 用 GDI+ 在双缓冲上绘制遮罩、边框、文字、按钮（只绘制小元素，不绘制大图）
  {
    Gdiplus::Graphics graphics(back_dc_);
    graphics.SetPixelOffsetMode(Gdiplus::PixelOffsetModeHalf);

    // 半透明遮罩（选中区域外变暗）
    Gdiplus::SolidBrush dim_brush(Gdiplus::Color(140, 0, 0, 0));
    if (has_selection_ && selection_.right > selection_.left &&
        selection_.bottom > selection_.top) {
      int sel_w = selection_.right - selection_.left;
      int sel_h = selection_.bottom - selection_.top;
      // 上
      graphics.FillRectangle(&dim_brush, 0, 0, width_, selection_.top);
      // 下
      graphics.FillRectangle(&dim_brush, 0, selection_.bottom, width_, height_ - selection_.bottom);
      // 左
      graphics.FillRectangle(&dim_brush, 0, selection_.top, selection_.left, sel_h);
      // 右
      graphics.FillRectangle(&dim_brush, selection_.right, selection_.top,
                             width_ - selection_.right, sel_h);

      // 选中区域边框（蓝色）
      Gdiplus::Pen border_pen(Gdiplus::Color(255, 59, 130, 246), 2);
      graphics.DrawRectangle(&border_pen, selection_.left, selection_.top, sel_w, sel_h);

      // 尺寸提示（选中区域上方）
      std::wstring size_text = std::to_wstring(sel_w) + L" x " + std::to_wstring(sel_h);
      Gdiplus::FontFamily font_family(L"Microsoft YaHei");
      Gdiplus::Font font(&font_family, 12, Gdiplus::FontStyleRegular, Gdiplus::UnitPixel);
      Gdiplus::SolidBrush text_bg(Gdiplus::Color(200, 59, 130, 246));
      Gdiplus::SolidBrush text_brush(Gdiplus::Color(255, 255, 255, 255));
      Gdiplus::PointF text_pos((Gdiplus::REAL)selection_.left,
                                (Gdiplus::REAL)(selection_.top > 24 ? selection_.top - 22 : selection_.bottom + 4));
      Gdiplus::RectF text_bounds;
      graphics.MeasureString(size_text.c_str(), -1, &font, Gdiplus::PointF(0, 0), &text_bounds);
      graphics.FillRectangle(&text_bg, text_pos.X, text_pos.Y,
                             text_bounds.Width + 12.0f, 20.0f);
      Gdiplus::PointF text_draw(text_pos.X + 6, text_pos.Y + 2);
      graphics.DrawString(size_text.c_str(), -1, &font, text_draw, &text_brush);
    } else {
      // 无选中区域：全屏遮罩
      graphics.FillRectangle(&dim_brush, 0, 0, width_, height_);
    }

    // 顶部提示文字
    {
      Gdiplus::FontFamily font_family(L"Microsoft YaHei");
      Gdiplus::Font font(&font_family, 14, Gdiplus::FontStyleRegular, Gdiplus::UnitPixel);
      Gdiplus::SolidBrush hint_brush(Gdiplus::Color(220, 255, 255, 255));
      std::wstring hint = L"拖拽鼠标选择区域 · 双击确认 · ESC/右键取消";
      Gdiplus::PointF hint_pos(20, 16);
      graphics.DrawString(hint.c_str(), -1, &font, hint_pos, &hint_brush);
    }

    // 底部按钮（有选中区域时显示）
    if (has_selection_ && selection_.right > selection_.left &&
        selection_.bottom > selection_.top) {
      UpdateButtons();
      Gdiplus::FontFamily font_family(L"Microsoft YaHei");
      Gdiplus::Font btn_font(&font_family, 13, Gdiplus::FontStyleRegular, Gdiplus::UnitPixel);

      // 取消按钮
      {
        Gdiplus::Color bg = hover_cancel_
            ? Gdiplus::Color(255, 100, 100, 100)
            : Gdiplus::Color(200, 70, 70, 70);
        Gdiplus::SolidBrush btn_bg(bg);
        graphics.FillRectangle(&btn_bg, btn_cancel_.left, btn_cancel_.top,
                               btn_cancel_.right - btn_cancel_.left,
                               btn_cancel_.bottom - btn_cancel_.top);
        Gdiplus::SolidBrush btn_text(Gdiplus::Color(255, 255, 255, 255));
        Gdiplus::PointF text_pos((Gdiplus::REAL)(btn_cancel_.left + 24),
                                  (Gdiplus::REAL)(btn_cancel_.top + 5));
        graphics.DrawString(L"取消", -1, &btn_font, text_pos, &btn_text);
      }

      // 确认按钮
      {
        Gdiplus::Color bg = hover_confirm_
            ? Gdiplus::Color(255, 80, 150, 255)
            : Gdiplus::Color(255, 59, 130, 246);
        Gdiplus::SolidBrush btn_bg(bg);
        graphics.FillRectangle(&btn_bg, btn_confirm_.left, btn_confirm_.top,
                               btn_confirm_.right - btn_confirm_.left,
                               btn_confirm_.bottom - btn_confirm_.top);
        Gdiplus::SolidBrush btn_text(Gdiplus::Color(255, 255, 255, 255));
        Gdiplus::PointF text_pos((Gdiplus::REAL)(btn_confirm_.left + 24),
                                  (Gdiplus::REAL)(btn_confirm_.top + 5));
        graphics.DrawString(L"确认", -1, &btn_font, text_pos, &btn_text);
      }
    }
  }

  // 3. 把双缓冲 BitBlt 到窗口（GDI，极快）
  BitBlt(hdc, 0, 0, width_, height_, back_dc_, 0, 0, SRCCOPY);
}

void ScreenshotWindow::UpdateButtons() {
  int btn_w = 80;
  int btn_h = 30;
  int gap = 12;
  int bottom_margin = 20;

  // 按钮显示在选中区域右下角
  int limit_right = width_ - 10;
  int btn_right = (selection_.right < limit_right) ? selection_.right : limit_right;
  int limit_bottom = height_ - 10;
  int btn_bottom_val = selection_.bottom + btn_h + bottom_margin;
  int btn_bottom = (btn_bottom_val < limit_bottom) ? btn_bottom_val : limit_bottom;

  btn_confirm_.left = btn_right - btn_w;
  btn_confirm_.top = btn_bottom - btn_h;
  btn_confirm_.right = btn_right;
  btn_confirm_.bottom = btn_bottom;

  btn_cancel_.left = btn_confirm_.left - btn_w - gap;
  btn_cancel_.top = btn_bottom - btn_h;
  btn_cancel_.right = btn_confirm_.left - gap;
  btn_cancel_.bottom = btn_bottom;
}

bool ScreenshotWindow::PointInRect(int x, int y, const RECT& r) {
  return x >= r.left && x <= r.right && y >= r.top && y <= r.bottom;
}

void ScreenshotWindow::OnLButtonDown(int x, int y) {
  // 如果点击了按钮，不开始拖拽
  if (has_selection_) {
    if (PointInRect(x, y, btn_cancel_)) {
      Cancel();
      return;
    }
    if (PointInRect(x, y, btn_confirm_)) {
      Confirm();
      return;
    }
  }

  // 重置前保存上一次的有效选择（双击时第一次点击会重置，第二次点击用这个恢复）
  if (has_selection_ && selection_.right > selection_.left &&
      selection_.bottom > selection_.top) {
    last_valid_selection_ = selection_;
    has_last_valid_selection_ = true;
  }

  dragging_ = true;
  drag_start_.x = x;
  drag_start_.y = y;
  selection_.left = x;
  selection_.top = y;
  selection_.right = x;
  selection_.bottom = y;
  has_selection_ = false;
  InvalidateRect(hwnd_, nullptr, FALSE);
}

void ScreenshotWindow::OnMouseMove(int x, int y) {
  // 更新按钮 hover 状态
  bool need_redraw = false;
  if (has_selection_) {
    bool new_hover_cancel = PointInRect(x, y, btn_cancel_);
    bool new_hover_confirm = PointInRect(x, y, btn_confirm_);
    if (new_hover_cancel != hover_cancel_ || new_hover_confirm != hover_confirm_) {
      hover_cancel_ = new_hover_cancel;
      hover_confirm_ = new_hover_confirm;
      need_redraw = true;
      // 更新鼠标样式
      if (hover_cancel_ || hover_confirm_) {
        SetCursor(LoadCursor(nullptr, IDC_HAND));
      } else {
        SetCursor(LoadCursor(nullptr, IDC_CROSS));
      }
    }
  }

  if (dragging_) {
    selection_.right = x;
    selection_.bottom = y;
    // 规范化（支持从右下往左上拖拽）
    if (selection_.left > selection_.right) {
      int tmp = selection_.left;
      selection_.left = selection_.right;
      selection_.right = tmp;
    }
    if (selection_.top > selection_.bottom) {
      int tmp = selection_.top;
      selection_.top = selection_.bottom;
      selection_.bottom = tmp;
    }
    // 限制在窗口范围内
    if (selection_.left < 0) selection_.left = 0;
    if (selection_.top < 0) selection_.top = 0;
    if (selection_.right > width_) selection_.right = width_;
    if (selection_.bottom > height_) selection_.bottom = height_;

    has_selection_ = (selection_.right > selection_.left &&
                      selection_.bottom > selection_.top);
    need_redraw = true;
  }

  if (need_redraw) {
    InvalidateRect(hwnd_, nullptr, FALSE);
  }
}

void ScreenshotWindow::OnLButtonUp(int x, int y) {
  if (dragging_) {
    dragging_ = false;
    if (has_selection_) {
      InvalidateRect(hwnd_, nullptr, FALSE);
    }
  }
}

void ScreenshotWindow::OnLButtonDblClk(int x, int y) {
  // 双击确认（需要有选中区域）
  // 注意：Win32 双击时第一次点击会触发 WM_LBUTTONDOWN 重置选择，
  // 所以这里需要检查当前选择和上一次保存的有效选择
  bool valid = has_selection_ && selection_.right > selection_.left &&
               selection_.bottom > selection_.top;
  if (!valid && has_last_valid_selection_) {
    // 用上次保存的有效选择恢复
    selection_ = last_valid_selection_;
    has_selection_ = true;
    valid = true;
  }
  if (valid) {
    Confirm();
  }
}

void ScreenshotWindow::OnRButtonUp(int x, int y) {
  // 右键取消
  Cancel();
}

void ScreenshotWindow::OnKeyDown(int key) {
  if (key == VK_ESCAPE) {
    Cancel();
  }
}

void ScreenshotWindow::Confirm() {
  if (!has_selection_ || !bitmap_) {
    Cancel();
    return;
  }
  std::string cropped_base64 = CropAndEncode();
  // 通知主窗口（通过回调）
  if (callback_) {
    auto cb = std::move(callback_);
    cb(cropped_base64);
  }
  // 关闭窗口
  if (hwnd_) {
    SetWindowLongPtr(hwnd_, GWLP_USERDATA, 0);
    HWND h = hwnd_;
    hwnd_ = nullptr;
    DestroyWindow(h);
  }
}

void ScreenshotWindow::Cancel() {
  if (callback_) {
    auto cb = std::move(callback_);
    cb("");  // 空字符串表示取消
  }
  if (hwnd_) {
    SetWindowLongPtr(hwnd_, GWLP_USERDATA, 0);
    HWND h = hwnd_;
    hwnd_ = nullptr;
    DestroyWindow(h);
  }
}

std::string ScreenshotWindow::CropAndEncode() {
  if (!bitmap_ || !has_selection_) return "";

  int x = selection_.left;
  int y = selection_.top;
  int w = selection_.right - selection_.left;
  int h = selection_.bottom - selection_.top;

  if (w <= 0 || h <= 0) return "";

  // 裁剪
  std::unique_ptr<Gdiplus::Bitmap> cropped(
      bitmap_->Clone(x, y, w, h, PixelFormat32bppARGB));
  if (!cropped) return "";

  // 获取 PNG 编码器
  CLSID png_clsid;
  if (GetEncoderClsid(L"image/png", &png_clsid) < 0) return "";

  // 保存到内存流
  IStream* stream = nullptr;
  if (CreateStreamOnHGlobal(nullptr, TRUE, &stream) != S_OK) return "";

  if (cropped->Save(stream, &png_clsid, nullptr) != Gdiplus::Ok) {
    stream->Release();
    return "";
  }

  // 从流中读取数据
  STATSTG stat;
  stream->Stat(&stat, STATFLAG_NONAME);
  ULONG size = (ULONG)stat.cbSize.QuadPart;
  if (size == 0) {
    stream->Release();
    return "";
  }

  std::vector<uint8_t> buffer(size);
  LARGE_INTEGER pos = {0};
  stream->Seek(pos, STREAM_SEEK_SET, nullptr);
  ULONG read = 0;
  stream->Read(buffer.data(), size, &read);
  stream->Release();

  // base64 编码
  return base64_encode(buffer.data(), read);
}
