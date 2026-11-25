#include "hotkey_channel.h"

#include <flutter/encodable_value.h>
#include <flutter/method_channel.h>
#include <flutter/standard_method_codec.h>

#include <memory>
#include <set>
#include <utility>

namespace {

// 当前注册在 main_window 上的热键 ID。
// ID 由 Dart 侧用 (modifiers << 8 | vk) 算出来，同一个组合键永远对应同一个 ID。
std::set<int> g_registered_ids;

// 热键注册与 WM_HOTKEY 接收都依赖主窗口。
HWND g_main_window = nullptr;

// 通道对象必须活到进程结束（消息回调里还要用它）。
std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> g_channel;

// 探测可用性时使用的临时 ID，避开 Dart 侧使用的 (modifiers << 8 | vk)。
constexpr int kProbeHotkeyId = 0x7F01;

int GetIntArgument(const flutter::EncodableMap& arguments,
                   const char* key,
                   int fallback) {
  const auto iterator = arguments.find(flutter::EncodableValue(key));
  if (iterator == arguments.end()) {
    return fallback;
  }
  if (const auto* value32 = std::get_if<int32_t>(&iterator->second)) {
    return *value32;
  }
  if (const auto* value64 = std::get_if<int64_t>(&iterator->second)) {
    return static_cast<int>(*value64);
  }
  return fallback;
}

flutter::EncodableValue MakeRegisterResult(bool ok, int error_code) {
  flutter::EncodableMap map;
  map[flutter::EncodableValue("ok")] = flutter::EncodableValue(ok);
  map[flutter::EncodableValue("error")] =
      flutter::EncodableValue(static_cast<int32_t>(error_code));
  return flutter::EncodableValue(std::move(map));
}

/// 注册热键。同 ID 重复注册时先注销，保证“换键 = 覆盖”而不是叠加。
bool RegisterHotkey(int id, int vk, int modifiers, int* error_code) {
  if (error_code != nullptr) {
    *error_code = 0;
  }
  if (g_main_window == nullptr || id <= 0 || vk <= 0) {
    if (error_code != nullptr) {
      *error_code = ERROR_INVALID_PARAMETER;
    }
    return false;
  }

  ::UnregisterHotKey(g_main_window, id);
  // MOD_NOREPEAT：按住组合键不重复触发（否则长按会连续弹出多次截图）。
  // 探测时不带这个标志，保证“是否被别的软件占用”的判断与其他程序一致。
  if (::RegisterHotKey(g_main_window, id,
                       static_cast<UINT>(modifiers) | MOD_NOREPEAT,
                       static_cast<UINT>(vk)) == 0) {
    if (error_code != nullptr) {
      *error_code = static_cast<int>(::GetLastError());
    }
    g_registered_ids.erase(id);
    return false;
  }

  g_registered_ids.insert(id);
  return true;
}

bool UnregisterHotkey(int id) {
  if (g_main_window == nullptr) {
    return false;
  }
  const BOOL ok = ::UnregisterHotKey(g_main_window, id);
  g_registered_ids.erase(id);
  return ok != 0;
}

}  // namespace

void HotkeyChannel::RegisterWithRegistrar(
    flutter::FlutterViewController* controller, HWND main_window) {
  g_main_window = main_window;

  g_channel =
      std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
          controller->engine()->messenger(), "com.workdiary/hotkey",
          &flutter::StandardMethodCodec::GetInstance());

  g_channel->SetMethodCallHandler(
      [](const flutter::MethodCall<flutter::EncodableValue>& call,
         std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>>
             result) {
        const auto* arguments =
            std::get_if<flutter::EncodableMap>(call.arguments());
        if (arguments == nullptr) {
          result->Error("INVALID_ARGS", "缺少参数");
          return;
        }

        if (call.method_name() == "register") {
          const int id = GetIntArgument(*arguments, "id", 0);
          const int vk = GetIntArgument(*arguments, "vk", 0);
          const int modifiers = GetIntArgument(*arguments, "modifiers", 0);
          int error_code = 0;
          const bool ok = RegisterHotkey(id, vk, modifiers, &error_code);
          result->Success(MakeRegisterResult(ok, error_code));
        } else if (call.method_name() == "unregister") {
          const int id = GetIntArgument(*arguments, "id", 0);
          result->Success(flutter::EncodableValue(UnregisterHotkey(id)));
        } else if (call.method_name() == "probe") {
          // 临时注册一次再注销：能注册上就说明这个组合键没被别的软件占用。
          const int vk = GetIntArgument(*arguments, "vk", 0);
          const int modifiers = GetIntArgument(*arguments, "modifiers", 0);
          bool available = false;
          if (g_main_window != nullptr && vk > 0) {
            ::UnregisterHotKey(g_main_window, kProbeHotkeyId);
            available =
                ::RegisterHotKey(g_main_window, kProbeHotkeyId,
                                 static_cast<UINT>(modifiers),
                                 static_cast<UINT>(vk)) != 0;
            if (available) {
              ::UnregisterHotKey(g_main_window, kProbeHotkeyId);
            }
          }
          result->Success(flutter::EncodableValue(available));
        } else {
          result->NotImplemented();
        }
      });
}

bool HotkeyChannel::HandleHotKey(WPARAM wparam) {
  const int id = static_cast<int>(wparam);
  if (g_registered_ids.find(id) == g_registered_ids.end()) {
    return false;
  }
  if (g_channel != nullptr) {
    g_channel->InvokeMethod(
        "onHotkey",
        std::make_unique<flutter::EncodableValue>(static_cast<int32_t>(id)));
  }
  return true;
}

void HotkeyChannel::UnregisterAll() {
  // 窗口可能已经被销毁（句柄失效），再注销会被忽略，这里先确认一次。
  if (g_main_window != nullptr && ::IsWindow(g_main_window) != 0) {
    for (const int id : g_registered_ids) {
      ::UnregisterHotKey(g_main_window, id);
    }
  }
  g_registered_ids.clear();
}
