#ifndef RUNNER_BUBBLE_WINDOW_H_
#define RUNNER_BUBBLE_WINDOW_H_

#include <windows.h>

#include <functional>
#include <string>

/// 桌面悬浮气泡窗口（纯原生实现，不依赖 Flutter，也不涉及任何 Dart 回调）。
///
/// 主窗口最小化、或连续若干分钟不在前台时，在屏幕右下角显示一个可拖拽的
/// 光泽玻璃球：径向渐变底盘 + 顶部高光 + 底部反光，中央是圆形裁切的应用
/// 图标，右上角红色角标显示未完成任务数（数字完整显示，不截断）。
/// 点击气泡 → 恢复并显示主窗口，气泡自动隐藏。
///
/// 渲染方式：WS_EX_LAYERED + UpdateLayeredWindow，GDI+ 画到 32 位带 alpha
/// 的位图上，因此圆边抗锯齿、渐变、柔光阴影和图标高质量缩放都是原生支持。
/// 窗口比气泡大一圈（留阴影和角标外溢的空间），超出气泡的透明区域通过
/// WM_NCHITTEST 返回 HTTRANSPARENT 穿透掉。
///
/// 尺寸单位：kBubble / kPad 是“设计单位”，实际像素 = 设计单位 × scale_。
/// scale_ 由当前显示器 DPI 换算（见 UpdateScale），保证 4K / 150% 缩放下
/// 气泡的物理大小和视觉比例与 100% 缩放一致。
class BubbleWindow {
 public:
  static constexpr int kBubble = 88;                  // 气泡可视直径（设计单位）
  static constexpr int kPad = 14;                     // 四周留给阴影/角标的余量（设计单位）
  static constexpr int kWindow = kBubble + kPad * 2;  // 设计画布边长
  static constexpr double kBaseScale = 0.5;           // 96 DPI 下的缩放（保持原有视觉尺寸）
  static constexpr float kIconRatio = 0.64f;          // 图标占气泡直径的比例

  BubbleWindow() = default;
  ~BubbleWindow();

  BubbleWindow(const BubbleWindow&) = delete;
  BubbleWindow& operator=(const BubbleWindow&) = delete;

  /// 绑定“点击气泡后要恢复”的主窗口句柄（platform 线程调用一次即可）。
  void SetMainWindow(HWND main_window);

  /// 右键菜单被选中时的回调（由 bubble_channel 注入，转发给 Dart）。
  /// 参数为动作标识：quick_memo / quick_task / show_window / hide_bubble / quit。
  using ActionHandler = std::function<void(const std::string&)>;
  void SetActionHandler(ActionHandler handler);

  /// 显示气泡并设置角标数字；已显示时只更新数字。
  bool Show(long long count);

  /// 隐藏并销毁气泡窗口（幂等）。
  void Hide();

  /// 仅在可见时更新角标数字。
  void UpdateCount(long long count);

  /// 气泡当前是否可见。
  bool IsVisible() const;

  /// 主窗口当前是否为前台窗口（用于“连续 N 分钟不在前台”检测）。
  bool IsMainWindowForeground() const;

 private:
  static LRESULT CALLBACK WndProc(HWND hwnd, UINT message, WPARAM wparam,
                                  LPARAM lparam);

  bool EnsureClassRegistered();
  LRESULT HandleMessage(HWND hwnd, UINT message, WPARAM wparam, LPARAM lparam);
  void Render();
  bool HitTest(POINT client_point) const;
  void RestoreMainWindow();
  void EnsureIcon();

  /// 右键菜单：前三项与托盘菜单一致（记一笔 / 记任务 / 打开主窗口），
  /// 另外多出「关闭气泡球」和「退出软件」
  void ShowContextMenu(HWND hwnd);

  /// 按当前显示器 DPI 重新计算实际像素尺寸。
  /// [dpi_hint] 非 0 时优先使用（WM_DPICHANGED 会带上新的 DPI）。
  void UpdateScale(UINT dpi_hint = 0);

  // ===== 呼吸 / 出现动画 =====

  /// 启动（或切换间隔）动画计时器。
  void EnsureAnimationTimer(UINT interval_ms);

  /// 用墙钟时间推进出现进度与呼吸相位。
  void UpdateAnimationState();

  /// 拖拽时暂停动画，冻结在当前帧。
  void PauseAnimation();

  /// 拖拽结束后从冻结的那一帧继续，相位不跳变。
  void ResumeAnimation();

  static constexpr UINT_PTR kAnimationTimerId = 1;
  static constexpr UINT kAppearFrameMs = 16;  // 出现动画 60fps（只有 250ms）
  static constexpr UINT kBreathFrameMs = 41;  // 呼吸 24fps，足够平滑且省电
  static constexpr double kAppearDurationSec = 0.25;
  static constexpr double kAppearMinScale = 0.92;
  static constexpr double kBreathPeriodSec = 4.2;   // 一次完整呼吸
  static constexpr double kBreathAmplitude = 0.06;  // 球体（含图标）直径 ±6%

  ULONGLONG animation_started_at_ = 0;
  ULONGLONG paused_at_ = 0;
  bool animating_ = false;
  UINT timer_interval_ms_ = 0;
  double appear_ = 1.0;  // 0..1，出现进度（1 = 已完全出现）
  double breath_ = 0.0;  // 0..1，呼吸相位（0.5 处最大）

  HWND hwnd_ = nullptr;
  HWND main_window_ = nullptr;
  HICON icon_ = nullptr;
  long long count_ = 0;

  /// 右键菜单动作回调（为空时菜单项不生效，但菜单仍能弹出）
  ActionHandler action_handler_;

  // 设计单位 -> 实际像素
  double scale_ = kBaseScale;
  int window_pixels_ = 0;
  int bubble_pixels_ = 0;
  int pad_pixels_ = 0;

  // 角标命中区域（客户端坐标，渲染时更新）
  RECT badge_rect_ = {0, 0, 0, 0};

  // 拖拽状态（不使用系统的 HTCAPTION 模态拖拽循环，避免丢鼠标抬起消息）
  bool dragging_ = false;
  POINT drag_origin_cursor_ = {0, 0};
  POINT drag_origin_window_ = {0, 0};

  static bool s_class_registered_;
};

#endif  // RUNNER_BUBBLE_WINDOW_H_
