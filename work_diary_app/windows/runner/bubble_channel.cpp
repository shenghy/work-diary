#include "bubble_channel.h"

#include <flutter/method_channel.h>
#include <flutter/standard_method_codec.h>
#include <windows.h>

#include <cstdint>
#include <memory>
#include <string>
#include <utility>
#include <variant>

#include "bubble_window.h"

namespace {

/// 进程内唯一的气泡窗口实例。
BubbleWindow* GetBubbleWindow() {
  static BubbleWindow window;
  return &window;
}

/// 从方法调用参数里安全取 "count" 整数（缺省 0）。
/// Dart 端 int 在标准编解码里可能落成 int32 或 int64，两种都要认。
long long GetCountArgument(const flutter::EncodableValue* arguments) {
  if (arguments == nullptr) {
    return 0;
  }
  const auto* argument_map = std::get_if<flutter::EncodableMap>(arguments);
  if (argument_map == nullptr) {
    return 0;
  }
  const auto iterator = argument_map->find(flutter::EncodableValue("count"));
  if (iterator == argument_map->end()) {
    return 0;
  }
  if (const auto* value32 = std::get_if<int32_t>(&iterator->second)) {
    return static_cast<long long>(*value32);
  }
  if (const auto* value64 = std::get_if<int64_t>(&iterator->second)) {
    return static_cast<long long>(*value64);
  }
  return 0;
}

}  // namespace

namespace {

/// 当前通道对象。气泡右键菜单的动作需要从窗口过程里回传 Dart，
/// 所以不能像原来那样藏在 RegisterWithRegistrar 的函数内静态变量里。
std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> g_channel;

}  // namespace

void BubbleChannel::RegisterWithRegistrar(
    flutter::FlutterViewController* controller, HWND main_window) {
  GetBubbleWindow()->SetMainWindow(main_window);

  g_channel =
      std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
          controller->engine()->messenger(), "com.workdiary/bubble",
          &flutter::StandardMethodCodec::GetInstance());

  // 气泡右键菜单选中后，把动作转发给 Dart（与托盘菜单同样的三项）
  GetBubbleWindow()->SetActionHandler(
      [](const std::string& action) { BubbleChannel::NotifyAction(action); });

  g_channel->SetMethodCallHandler(
      [](const flutter::MethodCall<flutter::EncodableValue>& call,
         std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>>
             result) {
        BubbleWindow* window = GetBubbleWindow();

        if (call.method_name() == "show") {
          const bool visible = window->Show(GetCountArgument(call.arguments()));
          result->Success(flutter::EncodableValue(visible));
        } else if (call.method_name() == "hide") {
          window->Hide();
          result->Success(flutter::EncodableValue(true));
        } else if (call.method_name() == "updateCount") {
          window->UpdateCount(GetCountArgument(call.arguments()));
          result->Success(flutter::EncodableValue(true));
        } else if (call.method_name() == "isVisible") {
          result->Success(flutter::EncodableValue(window->IsVisible()));
        } else if (call.method_name() == "isMainWindowForeground") {
          result->Success(
              flutter::EncodableValue(window->IsMainWindowForeground()));
        } else {
          result->NotImplemented();
        }
      });
}

void BubbleChannel::NotifyAction(const std::string& action) {
  if (g_channel == nullptr) {
    return;
  }
  flutter::EncodableMap arguments;
  arguments[flutter::EncodableValue("action")] =
      flutter::EncodableValue(action);
  g_channel->InvokeMethod(
      "onAction",
      std::make_unique<flutter::EncodableValue>(std::move(arguments)));
}
