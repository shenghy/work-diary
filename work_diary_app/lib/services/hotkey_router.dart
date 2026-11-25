/// 全局热键回调路由。
///
/// 原生通道 `com.workdiary/hotkey` 在每个 BinaryMessenger 上只能有一个
/// 方法调用处理器，但原生侧其实可以同时注册多个热键 —— 按下时会把热键 id
/// （`(modifiers << 8) | vk`）一起回传。
///
/// 所以这里按 id 把回调分发到对应的功能：
/// - 截图热键：由 HotkeyService 自己处理（它知道自己当前注册的是哪个 id）；
/// - 其它热键（如快速录入）：注册到本路由。
class HotkeyRouter {
  HotkeyRouter._();

  static final Map<int, void Function()> _handlers = <int, void Function()>{};

  /// 注册某个热键 id 的回调（同一 id 重复注册会覆盖）
  static void register(int hotkeyId, void Function() handler) {
    _handlers[hotkeyId] = handler;
  }

  /// 注销某个热键 id 的回调
  static void unregister(int hotkeyId) {
    _handlers.remove(hotkeyId);
  }

  /// 原生回传热键 id 时调用；返回是否有功能处理了这个 id
  static bool dispatch(int hotkeyId) {
    final handler = _handlers[hotkeyId];
    if (handler == null) return false;
    handler();
    return true;
  }

  /// 清空所有注册（主要给测试用）
  static void clear() => _handlers.clear();
}
