#ifndef RUNNER_SINGLE_INSTANCE_H_
#define RUNNER_SINGLE_INSTANCE_H_

#include <windows.h>

// 单实例相关的共享定义。
//
// 旧实现用固定端口 49152 判断“是否已有实例在运行”，而 49152 是 Windows
// 动态端口段（49152-65535）的起点，可能被系统分配给普通网络连接，导致
// bind 失败、新进程把自己误判成“第二实例”后静默退出。
// 这里改用命名互斥体做判断，用系统级注册的窗口消息唤出已有窗口。

// 单实例互斥体名称。
// Local\ 前缀表示仅当前登录会话可见，多用户同时登录时互不影响。
inline constexpr wchar_t kWorkDiaryMutexName[] =
    L"Local\\WorkDiary.SingleInstance.5C9E4B72";

// “把主窗口恢复到前台”的窗口消息 ID。
// 用 RegisterWindowMessageW 生成系统唯一 ID，第二个实例通过 HWND_BROADCAST
// 广播，已运行的实例在 FlutterWindow 里收到后处理。
inline UINT WorkDiaryShowWindowMessage() {
  static const UINT message_id =
      ::RegisterWindowMessageW(L"WorkDiary.ShowMainWindow.5C9E4B72");
  return message_id;
}

#endif  // RUNNER_SINGLE_INSTANCE_H_
