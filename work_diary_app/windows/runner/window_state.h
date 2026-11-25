#ifndef RUNNER_WINDOW_STATE_H_
#define RUNNER_WINDOW_STATE_H_

#include <windows.h>

namespace window_state {

// 主窗口上次的几何（逻辑像素 / DIP）。x、y 允许为负（窗口停在主屏左侧的副屏）。
struct State {
  int x = 0;
  int y = 0;
  int width = 0;
  int height = 0;
  double dpi = 96.0;
  bool maximized = false;
  bool valid = false;
};

struct Bounds {
  int x;
  int y;
  int width;
  int height;
};

// 读取上次保存的几何；文件不存在或内容不可用时 valid=false。
State Load();

// 校验并换算成可直接传给 Win32Window::Create 的 DIP 几何。
// 尺寸夹在最小窗口与目标显示器工作区之间；标题栏不可达或显示器已断开时
// 回落到传入的默认几何。
Bounds Resolve(const State& state, const Bounds& fallback);

// 保存当前窗口几何。最小化状态下保留原记录不覆盖。
void Save(HWND hwnd);

}  // namespace window_state

#endif  // RUNNER_WINDOW_STATE_H_
