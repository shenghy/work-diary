#pragma once

#include <windows.h>
#include <gdiplus.h>
#include <functional>
#include <memory>
#include <string>
#include <vector>
#include <cstdint>

#pragma comment(lib, "gdiplus.lib")

/// 纯原生截图窗口：用 GDI+ 绘制区域选择界面，不依赖 Flutter
/// 启动极快，几乎无黑屏
class ScreenshotWindow {
 public:
  /// 结果回调：cropped_base64 为空字符串表示用户取消
  using ResultCallback = std::function<void(const std::string& cropped_base64)>;

  ScreenshotWindow(const std::vector<uint8_t>& screenshot_png,
                   ResultCallback callback);
  ~ScreenshotWindow();

  /// 创建并显示全屏截图窗口
  bool Show();

 private:
  static LRESULT CALLBACK WndProc(HWND hwnd, UINT msg, WPARAM wparam, LPARAM lparam);
  void OnPaint(HDC hdc);
  void OnLButtonDown(int x, int y);
  void OnMouseMove(int x, int y);
  void OnLButtonUp(int x, int y);
  void OnLButtonDblClk(int x, int y);
  void OnRButtonUp(int x, int y);
  void OnKeyDown(int key);
  void Confirm();
  void Cancel();
  std::string CropAndEncode();
  void UpdateButtons();
  bool PointInRect(int x, int y, const RECT& r);

  HWND hwnd_ = nullptr;
  ResultCallback callback_;
  std::vector<uint8_t> screenshot_png_;
  std::unique_ptr<Gdiplus::Bitmap> bitmap_;
  int width_ = 0;
  int height_ = 0;

  // 预渲染：底层截图 DC（只渲染一次，拖动时用 BitBlt，极快）
  HDC screenshot_dc_ = nullptr;
  HBITMAP screenshot_bmp_ = nullptr;
  HBITMAP screenshot_old_bmp_ = nullptr;

  // 持久化双缓冲（不每次创建销毁）
  HDC back_dc_ = nullptr;
  HBITMAP back_bmp_ = nullptr;
  HBITMAP back_old_bmp_ = nullptr;

  // 选中区域（客户区坐标）
  bool dragging_ = false;
  POINT drag_start_ = {0, 0};
  RECT selection_ = {0, 0, 0, 0};
  bool has_selection_ = false;

  // 上一次的有效选择（双击时第一次点击会重置选择，用这个恢复）
  RECT last_valid_selection_ = {0, 0, 0, 0};
  bool has_last_valid_selection_ = false;

  // 底部按钮
  RECT btn_cancel_ = {0, 0, 0, 0};
  RECT btn_confirm_ = {0, 0, 0, 0};
  bool hover_cancel_ = false;
  bool hover_confirm_ = false;

  // GDI+ 初始化标志
  static ULONG_PTR s_gdiplus_token_;
  static bool s_gdiplus_inited_;
};
