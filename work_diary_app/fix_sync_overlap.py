p = r'E:\Code\WorkDiary\work_diary_app\lib\screens\home_screen.dart'
with open(p, 'r', encoding='utf-8') as f:
    t = f.read()

# 1. 加字段
old = "  Timer? _syncDebounce; // 防抖：合并短时间内的连续操作"
new = """  Timer? _syncDebounce; // 防抖：合并短时间内的连续操作
  DateTime _ignoreWsSyncUntil = DateTime.now(); // 本地刚修改后的忽略窗口，忽略自己触发的 WS 推送"""
assert old in t
t = t.replace(old, new)

# 2. _syncAfterChange 里设置忽略窗口
old2 = """  void _syncAfterChange() {
    if (!AuthService.isLoggedIn) return; // 未登录不做任何同步
    _syncDebounce?.cancel();"""
new2 = """  void _syncAfterChange() {
    if (!AuthService.isLoggedIn) return; // 未登录不做任何同步
    // 本地刚修改，3秒内忽略 WebSocket 推送的同步（避免覆盖刚创建的任务）
    _ignoreWsSyncUntil = DateTime.now().add(const Duration(seconds: 3));
    _syncDebounce?.cancel();"""
assert old2 in t
t = t.replace(old2, new2)

# 3. WebSocket 回调里检查忽略窗口
old3 = """      SyncWebSocket.instance.onDataChanged = () {
        _performSync(showToast: false);
      };"""
new3 = """      SyncWebSocket.instance.onDataChanged = () {
        // 本地刚修改后的忽略窗口内，跳过同步（这是自己刚触发的）
        if (DateTime.now().isBefore(_ignoreWsSyncUntil)) return;
        _performSync(showToast: false);
      };"""
# 这个回调出现了两次（initState 和 _syncToCloud），都要改
count = t.count(old3)
t = t.replace(old3, new3)
print(f'replaced {count} callbacks')

with open(p, 'w', encoding='utf-8') as f:
    f.write(t)
print('done')
