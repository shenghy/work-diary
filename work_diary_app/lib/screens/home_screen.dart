import 'dart:async';
import 'dart:io';
import 'dart:convert';
import 'package:flutter_markdown/flutter_markdown.dart';
import 'dart:math';
import 'dart:typed_data';
import 'dart:ffi' as ffi;

import 'package:flutter/material.dart';
// PointerDeviceKind / PointerScrollEvent（标签栏拖拽与滚轮用）
import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:flutter/rendering.dart';
import 'package:file_selector/file_selector.dart';
import 'package:desktop_drop/desktop_drop.dart';
import 'package:hive/hive.dart';

import 'package:window_manager/window_manager.dart';
import '../models/task.dart';
import '../models/attachment.dart';
import '../models/memo.dart';
import '../models/repeat_rule.dart';
import '../models/stats.dart';
import '../theme/glass_palette.dart';
import '../database/task_repository.dart';
import '../database/repository_provider.dart';
import '../database/memo_repository.dart';
import '../database/memo_repository_io.dart';
import '../utils/subtask_parser.dart';
import '../utils/attachment_types.dart';
import '../utils/repeat_task_engine.dart';
import '../utils/repeat_family.dart';
import '../utils/stats_calculator.dart';
import '../widgets/memo_card.dart';
import '../widgets/attachment_strip.dart';
import '../widgets/glass_surface.dart';
import '../widgets/pending_attachment_picker.dart';
import '../widgets/memo_code_block.dart';
import '../widgets/task_card.dart';
import '../widgets/theme_mode_switch.dart';
import '../widgets/hotkey_conflict_dialog.dart';
import '../widgets/about_dialog.dart';
import '../widgets/repeat_manager_dialog.dart';
import '../widgets/region_selector.dart';
import '../widgets/recognize_result_dialog.dart';
import '../widgets/summary_dialog.dart';
import '../services/auth_service.dart';
import '../services/ambient_motion.dart';
import '../services/remote_sync_service.dart';
import '../services/app_lifecycle.dart';
import '../services/attachment_picker.dart';
import '../services/attachment_store.dart';
import '../services/attachment_sync_service.dart';
import '../services/sync_websocket.dart';
import '../services/screenshot_service.dart';
import '../services/auto_start_service.dart';
import '../services/upgrade_service.dart';
import '../widgets/upgrade_banner.dart';
import '../widgets/quota_detail_dialog.dart';
import '../services/task_reminder_service.dart';
import '../widgets/reminder_dialog.dart';
import '../widgets/datetime_picker_sheet.dart';
import '../services/ai_service.dart';
import '../services/app_logger.dart';
import '../services/hotkey_service.dart';
import '../services/quick_capture_hotkey.dart';
import '../services/bubble_service.dart';
import 'login_screen.dart';
import 'stats_screen.dart';

// Win32 光标：拖拽时强制设置系统光标（Flutter MouseRegion 在 pointer 捕获时不更新）
final _user32 = ffi.DynamicLibrary.open('user32.dll');
typedef _LoadCursorW = ffi.IntPtr Function(ffi.IntPtr, ffi.IntPtr);
typedef _LoadCursorWDart = int Function(int, int);
typedef _SetCursorFn = ffi.IntPtr Function(ffi.IntPtr);
typedef _SetCursorDart = int Function(int);
final _loadCursor = _user32.lookupFunction<_LoadCursorW, _LoadCursorWDart>(
  'LoadCursorW',
);
final _setCursor = _user32.lookupFunction<_SetCursorFn, _SetCursorDart>(
  'SetCursor',
);

void _setWin32Cursor(int resourceId) {
  final hCursor = _loadCursor(0, resourceId);
  if (hCursor != 0) _setCursor(hCursor);
}

/// 截图流程日志：同时输出到控制台和文件，崩溃后可查看最后执行到哪一步。
/// 文件按大小滚动（超过 512KB 重写），避免长期使用后无限增长。
void _screenshotLog(String msg) {
  final line = '[截图] $msg';
  debugPrint(line);
  AppLogger.instance.log(line);
  if (!Platform.isWindows) return;
  try {
    final dir = Platform.environment['LOCALAPPDATA'];
    if (dir == null || dir.isEmpty) return;
    final logFile = File('$dir\\work_diary_screenshot.log');
    if (logFile.existsSync() && logFile.lengthSync() > 512 * 1024) {
      logFile.deleteSync();
    }
    logFile.writeAsStringSync(
      '${DateTime.now().toIso8601String()} $line\n',
      mode: FileMode.append,
    );
  } catch (_) {}
}

/// 顶部标签栏的滚动行为。
///
/// 桌面端 ScrollView 的默认 dragDevices 不含鼠标，导致横向标签栏只能靠
/// 触控板滑动、鼠标按住拖不动。这里显式放开鼠标/触控板拖拽，并关掉
/// 横向滚动条（60px 高的标签栏里滚动条会挤掉 chips 的位置）。
class _TabScrollBehavior extends MaterialScrollBehavior {
  @override
  Set<PointerDeviceKind> get dragDevices => const {
        PointerDeviceKind.mouse,
        PointerDeviceKind.touch,
        PointerDeviceKind.stylus,
        PointerDeviceKind.trackpad,
      };

  @override
  Widget buildScrollbar(
    BuildContext context,
    Widget child,
    ScrollableDetails details,
  ) {
    return child;
  }
}

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen>
    with SingleTickerProviderStateMixin, WidgetsBindingObserver {
  final TaskRepository _repo = createTaskRepository();
  final MemoRepository _memoRepo = MemoRepositoryImpl();
  List<Task> _tasks = [];
  List<Memo> _memos = []; // 备忘列表
  bool _showMemoView = false; // 是否显示备忘视图（备忘 Tab）
  bool _showStatsView = false; // 是否显示「我的数据」看板（整页替换列表）
  int _statsRefreshTick = 0; // 看板重算信号：F5 / 任务变更后 +1
  StatsRange _statsRange = StatsRange.last7; // 看板时间范围：会话内记住上次选择
  final TextEditingController _memoSearchCtrl = TextEditingController();
  TaskStatus? _filter = TaskStatus.planned; // 默认显示计划中
  Map<TaskStatus, int> _counts = {}; // 各状态任务数量
  bool _syncing = false; // 同步中状态
  final GlobalKey _menuKey = GlobalKey(); // 菜单按钮定位
  final GlobalKey _settingsMenuKey = GlobalKey(); // 设置齿轮按钮定位
  final ScrollController _tabScrollCtrl = ScrollController(); // 顶部标签栏横向滚动
  bool _isMenuOpen = false; // 三条杠/齿轮菜单是否展开（窗口失焦时自动收起）

  /// 快速录入对话框（记一笔 = 备忘 / 记任务 = 新建任务）的路由名。
  /// 托盘/气泡菜单再次触发时用它定位并关掉已经打开的那个，避免叠两个。
  static const String _quickDialogRouteName = 'quick_add_dialog';

  /// 当前打开的快速录入对话框类型：'memo' / 'task'，null 表示没有。
  String? _quickDialogKind;

  // ===== 自动同步（登录后变更即同步）=====
  Timer? _syncDebounce; // 防抖：合并短时间内的连续操作
  DateTime _ignoreWsSyncUntil = DateTime.now(); // 本地刚修改后的忽略窗口，忽略自己触发的 WS 推送
  bool _pendingSync = false; // 同步期间又有新变更，结束后补一次
  Timer? _repeatSyncTimer; // 循环任务补生成后的延时上传
  // 跨天补生成：软件常驻（托盘）时零点过后自动补出新一期
  Timer? _dayRolloverTimer;
  DateTime? _lastMaterializeDay; // 上次补生成所在的日历日（00:00）
  // 本次会话已经补生成过的「族 ID|日期」：同一期只生成一次，
  // 从根上堵死"生成 → 同步覆盖 → 再生成"的死循环。
  final Set<String> _materializedKeys = <String>{};
  // ===== 非侵入轻提示（提示同步结果，不挡操作）=====
  String? _syncToastMsg;
  bool _syncToastError = false;
  bool _syncToastVisible = false;
  bool _showUpgradeBanner = false; // 是否显示底部升级提示条
  bool _upgradeDownloading = false; // 是否正在下载升级包
  bool _applyingUpgrade = false;
  // ===== 任务卡片入场动画（打开软件首次显示时逐张上浮淡入）=====
  late final AnimationController _entranceCtrl;
  bool _entrancePlayed = false; // 是否已播放过入场动画（只播首次）
  bool _animateNextList = false; // 切换任务 tab 后，下次加载列表时重放入场动画
  bool _animateNextMemo = false; // 切换备忘 tab 后，加载完成时重放入场动画
  int _loadSeq = 0; // 加载序号：只允许最后一次加载触发动画（防连续切换竞态）
  // ===== 已完成/全部 tab：分页 + 搜索 + 筛选 =====
  List<Task> _allTasks = []; // 全量任务缓存（已完成/全部的搜索与筛选基于它）
  final TextEditingController _taskSearchCtrl = TextEditingController();
  Urgency? _filterUrgency; // 紧急度筛选，null=全部
  int? _filterType; // 类型筛选，null=全部，0=个人，1=工作
  int _visibleCount = 10; // 分页当前显示条数
  static const int _pageSize = 10; // 每页条数
  late final Future<void> _initialTaskLoad;
  double _upgradeProgress = 0; // 下载进度 0~1
  Timer? _toastTimer;

  // 标签定位 Key，用于飞行动画的目标位置
  final GlobalKey _plannedChipKey = GlobalKey();
  final GlobalKey _executingChipKey = GlobalKey();
  final GlobalKey _completedChipKey = GlobalKey();

  // 托盘事件监听（记一笔）
  StreamSubscription<String>? _traySub;

  // ===== 附件 =====
  /// 本地父记录 id → 该记录当前挂着的附件（含"原件在别的机器"的那些）
  Map<int, List<AttachmentView>> _taskAttachments = {};
  Map<int, List<AttachmentView>> _memoAttachments = {};

  /// 正被拖到其上的卡片（文件从资源管理器拖进来时高亮，指明落点）
  int? _dropTaskId;
  int? _dropMemoId;

  // ===== 拖拽排序 =====
  int? _draggingIndex; // 当前拖拽的任务索引
  Offset? _dragStartPos; // 拖拽开始时的鼠标位置（全局）
  Offset? _dragCurrentPos; // 当前鼠标位置（全局）
  bool _isDragging = false; // 是否已经触发拖拽（移动了5px后）
  int? _insertIndex; // 当前插入位置
  OverlayEntry? _dragOverlay; // 浮动预览
  final List<GlobalKey> _cardKeys = []; // 每个卡片的 Key，用于计算插入位置
  static const double _dragThreshold = 5.0; // 触发拖拽的移动阈值

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _entranceCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1000),
    );
    _initialTaskLoad = _loadTasks();
    _startDayRolloverTimer();
    _loadMemos(); // 加载本地备忘
    // 启动时如果已登录，自动同步一次
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (AuthService.isLoggedIn) {
        _syncToCloud();
      }
    });
    // 附件中转：服务器把"其它主机要这份文件"推给本机，谁有原件谁应答上传。
    // 挂在 WebSocket 上就要一直有效，登录可能在会话中途才发生，所以放在
    // 连接判断之外。
    SyncWebSocket.instance.onAttachmentEvent =
        AttachmentSyncService.instance.handlePush;
    // 附件下载完成 / 被对端删除 / 转孤儿之后，卡片上的附件条要跟着刷新
    AttachmentSyncService.instance.onAttachmentsChanged = _loadAttachments;
    // 连接 WebSocket：收到其他设备的数据变更通知后自动同步
    if (AuthService.isLoggedIn) {
      SyncWebSocket.instance.onDataChanged = () {
        // 本地刚修改后的忽略窗口内，跳过同步（这是自己刚触发的）
        if (DateTime.now().isBefore(_ignoreWsSyncUntil)) return;
        // 延迟2秒再同步，让本地修改先写入，避免竞态覆盖新任务
        Future.delayed(const Duration(seconds: 2), () {
          if (mounted) _performSync(showToast: false);
        });
      };
      SyncWebSocket.instance.connect();
    }
    // 监听托盘「记一笔」事件
    _traySub = AppLifecycle.instance.onAction.listen(_onTrayAction);
    // 初始化任务提醒服务
    TaskReminderService.instance.init(
      // 必须用全量列表：_tasks 是按当前 tab 过滤后的结果，切到"已完成"
      // 或"备忘"后提醒会静默失效。
      taskProvider: () => _allTasks,
      onRemind: (tasks, type) => _showReminder(tasks, type),
    );
    // 桌面悬浮气泡：挂接未完成任务数（Windows）
    if (Platform.isWindows) {
      BubbleService.instance.attachCountProvider(
        () => _allTasks.where((t) => t.status != TaskStatus.completed).length,
      );
    }
    // 绑定全局截图热键触发：无论窗口是否聚焦都能响应
    HotkeyService.instance.onTrigger = _startScreenshotRecognition;
    // 全局快速录入热键（Ctrl+Alt+N）：随时唤起迷你录入框
    QuickCaptureHotkey.instance.onTrigger = _onQuickCaptureHotkey;
    // 热键在 main() 里已经尝试注册过（可能已自动降级），首帧后按需提示
    WidgetsBinding.instance.addPostFrameCallback((_) {
      unawaited(_maybePromptHotkeyConflict());
    });
    // 初始化升级服务并后台检查更新（静默下载，完成后提示）
    _initUpgradeFlow();
  }

  /// 启动时热键被占用：提示一次，并让用户就地换一个可用组合键。
  ///
  /// 自动降级已经保证“能用”，这里只是告知 + 给一次改键机会；
  /// 用户点“暂不设置”后，同一个热键不再重复弹窗（设置菜单里仍显示“临时”）。
  Future<void> _maybePromptHotkeyConflict() async {
    if (!mounted || !Platform.isWindows) return;
    final service = HotkeyService.instance;
    if (service.status == HotkeyStatus.registered ||
        service.status == HotkeyStatus.unsupported) {
      return;
    }
    if (await service.isConflictAcknowledged()) return;
    // 静默启动（--hidden）或已隐藏到托盘时不弹：用户看不到弹窗，
    // 弹了还会挡住后续操作。设置菜单里仍然能看到“临时/未生效”。
    try {
      if (!await windowManager.isVisible()) return;
    } catch (_) {}
    // 稍等一下再弹：避开启动瞬间的“检查更新”弹窗，避免叠两个模态框。
    await Future<void>.delayed(const Duration(milliseconds: 1200));
    if (!mounted) return;
    final choice = await HotkeyConflictDialog.show(context);
    if (choice == HotkeyConflictChoice.later) {
      await service.acknowledgeConflict();
    }
    if (mounted) setState(() {});
  }

  // ==================== 跨天补生成 ====================

  /// 每分钟检查一次"是不是跨天了"。
  ///
  /// 补生成原来只在 `_loadTasks()` 里跑，而 `_loadTasks()` 只由用户操作触发。
  /// 桌面端是托盘常驻应用，开着放一夜后第二天不会出现新的日任务，必须点一下
  /// 界面才"长"出来。这个定时器只做一次日历日比较，不读盘，开销可忽略。
  void _startDayRolloverTimer() {
    _dayRolloverTimer?.cancel();
    _dayRolloverTimer = Timer.periodic(const Duration(minutes: 1), (_) {
      _checkDayRollover();
    });
  }

  /// 日期变了就重新加载（加载过程中会补生成新一期）
  void _checkDayRollover() {
    if (!mounted) return;
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final last = _lastMaterializeDay;
    if (last != null && !today.isAfter(last)) return;
    AppLogger.instance.log('跨天检查：补生成新一期（$today）');
    _lastMaterializeDay = today; // 先占位，避免定时器和生命周期回调重复触发
    unawaited(_loadTasks());
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // 手机从后台切回、桌面端唤醒后立刻检查一次，不必等下一次轮询
    if (state == AppLifecycleState.resumed) _checkDayRollover();
  }

  /// 升级流程初始化：
  /// 1. 本地数据与首帧就绪后确认升级（备份由升级脚本清理）
  /// 2. 恢复已下载的待升级状态（重启不丢）
  /// 3. 无待升级状态则后台检查新版本
  Future<void> _initUpgradeFlow() async {
    try {
      await _initialTaskLoad;
      await WidgetsBinding.instance.endOfFrame;
      if (!mounted) return;
      await UpgradeService.instance.init();
    } catch (e, st) {
      AppLogger.instance.error('升级服务初始化失败', e, st);
    }
    if (!mounted) return;
    // 以下每一步单独 try：任何一步抛异常（例如升级标记文件损坏）都不能让
    // 后面的"检查更新"被跳过，否则本次会话再也不会提示新版本。
    try {
      await UpgradeService.instance.confirmUpgradeSuccess();
    } catch (e, st) {
      AppLogger.instance.error('确认升级结果失败', e, st);
    }
    try {
      final failure = await UpgradeService.instance.takeUpgradeFailure();
      if (failure != null && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(failure),
            duration: const Duration(seconds: 8),
          ),
        );
      }
    } catch (e, st) {
      AppLogger.instance.error('读取升级失败原因失败', e, st);
    }
    try {
      final restored = await UpgradeService.instance.restorePending();
      if (restored) {
        if (mounted) _showUpgradeDialog();
        return;
      }
    } catch (e, st) {
      AppLogger.instance.error('恢复待升级状态失败', e, st);
    }
    await _backgroundCheckUpgrade();
  }

  /// 阻止准备升级期间继续编辑，准备失败时保留应用及升级入口。
  Future<void> _applyUpgrade() async {
    if (_applyingUpgrade) return;
    _applyingUpgrade = true;
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => const PopScope(
        canPop: false,
        child: AlertDialog(
          content: Row(
            children: [
              SizedBox(
                width: 22,
                height: 22,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
              SizedBox(width: 16),
              Expanded(child: Text('正在准备升级，请稍候…')),
            ],
          ),
        ),
      ),
    );
    try {
      await UpgradeService.instance.performUpgrade();
    } catch (e) {
      if (!mounted) return;
      Navigator.of(context, rootNavigator: true).pop();
      setState(() => _showUpgradeBanner = true);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(e.toString().replaceFirst('Bad state: ', '')),
          duration: const Duration(seconds: 8),
        ),
      );
      if (UpgradeService.instance.isForceUpdate) _showUpgradeDialog();
    } finally {
      _applyingUpgrade = false;
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    if (AttachmentSyncService.instance.onAttachmentsChanged ==
        _loadAttachments) {
      AttachmentSyncService.instance.onAttachmentsChanged = null;
    }
    _syncDebounce?.cancel();
    _toastTimer?.cancel();
    _repeatSyncTimer?.cancel();
    _dayRolloverTimer?.cancel();
    _memoSearchCtrl.dispose();
    _taskSearchCtrl.dispose();
    _tabScrollCtrl.dispose();
    _traySub?.cancel();
    _entranceCtrl.dispose();
    _hideDragOverlay();
    super.dispose();
  }

  /// 托盘菜单 / 气泡右键菜单事件
  void _onTrayAction(String action) {
    if (action == TrayActions.quickMemo) {
      // 记一笔 = 备忘
      unawaited(_openQuickDialog('memo'));
    } else if (action == TrayActions.quickTask) {
      // 记任务 = 新建任务
      unawaited(_openQuickDialog('task'));
    } else if (action == TrayActions.windowBlur) {
      // 窗口失焦（用户点了 app 外区域）：收起展开的菜单
      if (_isMenuOpen && mounted) {
        _isMenuOpen = false;
        Navigator.of(context, rootNavigator: true).pop();
      }
    }
  }

  /// 显示任务提醒对话框（右下角）。
  ///
  /// 窗口最小化或隐藏到托盘时，先走 restore + show + focus 把窗口带到前台，
  /// 只调 show() 的话最小化窗口仍然是不可见的，用户收不到提醒。
  Future<void> _showReminder(List<Task> tasks, String type) async {
    if (!mounted) return;
    try {
      await AppLifecycle.instance.showWindow();
    } catch (_) {}
    if (!mounted) return;
    await ReminderDialog.show(context, tasks, type);
  }

  /// 后台检查更新：有新版本则立即显示底部下载提示条（带进度），
  /// 不打扰用户使用；下载完成后提示条切换为「立即升级」。
  Future<void> _backgroundCheckUpgrade() async {
    try {
      final hasUpdate = await UpgradeService.instance.checkUpdate();
      if (!hasUpdate) return;
      if (!mounted) return;
      // 立即显示下载中提示条
      setState(() {
        _showUpgradeBanner = true;
        _upgradeDownloading = true;
        _upgradeProgress = 0;
      });
      final zip = await UpgradeService.instance.downloadUpdate(
        onProgress: (p) {
          if (mounted) setState(() => _upgradeProgress = p);
        },
      );
      if (!mounted) return;
      if (zip == null) {
        final reason = UpgradeService.instance.lastDownloadError;
        setState(() {
          _showUpgradeBanner = false;
          _upgradeDownloading = false;
        });
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(reason == null ? '升级包下载失败，请重试' : '升级包校验失败：$reason'),
            ),
          );
        }
        return;
      }
      // 下载完成：切换为升级提示
      setState(() {
        _upgradeDownloading = false;
        _upgradeProgress = 1;
      });
      if (UpgradeService.instance.isForceUpdate) _showUpgradeDialog();
    } catch (_) {
      // 升级检查/下载失败静默处理，不打扰用户
    }
  }

  /// 弹出升级提示
  void _showUpgradeDialog() {
    final latest = UpgradeService.instance.latest;
    if (latest == null || !mounted) return;
    // 强制升级：弹不可关闭的模态框，必须升级后才能使用
    if (latest.forceUpdate) {
      showDialog(
        context: context,
        barrierDismissible: false,
        builder: (ctx) => PopScope(
          canPop: false,
          child: AlertDialog(
            title: const Text('发现新版本，必须升级', style: TextStyle(fontSize: 16)),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'v${latest.version}',
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: GlassPalette.of(context).accent,
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  latest.releaseNotes.isEmpty
                      ? '当前版本需要升级后才能继续使用。'
                      : latest.releaseNotes,
                  style: const TextStyle(fontSize: 13, height: 1.5),
                ),
              ],
            ),
            actions: [
              TextButton(
                onPressed: () {
                  Navigator.of(ctx).pop();
                  _applyUpgrade();
                },
                style: TextButton.styleFrom(
                  backgroundColor: GlassPalette.of(context).accent,
                  foregroundColor: Colors.white,
                ),
                child: const Text('立即升级'),
              ),
            ],
          ),
        ),
      );
      return;
    }
    // 非强制升级：显示底部升级提示条（非模态，不打断用户操作）
    setState(() => _showUpgradeBanner = true);
  }

  /// 手动检查更新（菜单入口）
  Future<void> _checkUpdateManually() async {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('正在检查更新...'),
        duration: Duration(seconds: 2),
      ),
    );
    final hasUpdate = await UpgradeService.instance.checkUpdate();
    if (!mounted) return;
    if (!hasUpdate) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('当前已是最新版本 v${UpgradeService.instance.currentVersion}'),
        ),
      );
      return;
    }
    // 有新版本：显示底部下载提示条（带进度）
    if (!mounted) return;
    setState(() {
      _showUpgradeBanner = true;
      _upgradeDownloading = true;
      _upgradeProgress = 0;
    });
    final zip = await UpgradeService.instance.downloadUpdate(
      onProgress: (p) {
        if (mounted) setState(() => _upgradeProgress = p);
      },
    );
    if (!mounted) return;
    if (zip == null) {
      setState(() {
        _showUpgradeBanner = false;
        _upgradeDownloading = false;
      });
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            UpgradeService.instance.lastDownloadError ?? '下载失败，请检查网络后重试',
          ),
        ),
      );
      return;
    }
    // 下载完成：切换为升级提示
    setState(() {
      _upgradeDownloading = false;
      _upgradeProgress = 1;
    });
    if (UpgradeService.instance.isForceUpdate) _showUpgradeDialog();
  }

  /// 首次启动自动创建引导任务
  Future<void> _maybeCreateWelcomeTask() async {
    try {
      final box = Hive.box('settings');
      if (box.get('has_created_welcome', defaultValue: false) == true) return;

      final all = await _repo.getTasks();
      if (all.isNotEmpty) {
        // 已有任务（老用户或手动创建过），只写标记不创建
        await box.put('has_created_welcome', true);
        return;
      }

      // 空任务列表，创建引导任务（全部内容放标题里，因为 Task 只有 title 字段）
      const welcomeTitle = '''👋 欢迎使用极简工作日记！30 秒上手（删掉即可）

【如何创建任务】
点击右下角 + 按钮，输入任务内容，选择紧急度，保存。

【截图识别任务】
按 Ctrl+Alt+A 截图，AI 自动识别任务内容，一键创建。

【AI 总结】
登录账号后，左下角菜单可用：
· AI 日报总结：自动生成今日工作日报
· AI 周报总结：自动生成本周工作总结
不登录只能本地记录，不能用 AI 功能。

【任务提醒】
给任务设置计划开始时间，到点自动弹窗提醒。

【云端同步】
登录后任务自动同步到云端，多设备不丢失。

【更多帮助】
齿轮 → 关于我们 → 加作者微信：php100''';

      await _repo.insertTask(
        Task(
          title: welcomeTitle,
          status: TaskStatus.planned,
          urgency: Urgency.important,
          taskType: 0,
          sortOrder: 0,
          createdAt: DateTime.now(),
        ),
      );
      await box.put('has_created_welcome', true);
      AppLogger.instance.log('已创建首次引导任务');
    } catch (e) {
      AppLogger.instance.error('创建引导任务失败', e);
    }
  }

  /// 循环任务（日/周/月）自动补生成最近一期实例；幂等，无新增时不动作。
  ///
  /// [loaded] 为调用方刚读出来的全量任务（避免为了补生成再把整表读一遍）。
  /// 返回本次真正插入的期数。
  Future<int> _materializeRepeatTasks(List<Task> loaded) async {
    final now = DateTime.now();
    _lastMaterializeDay = DateTime(now.year, now.month, now.day);
    try {
      final rules = await _repo.getRepeatRules();
      final skips = await _repo.getRepeatSkips();
      // 历史脏数据：周任务的星期越界会让该族永远不生成，这里留一条日志便于排查
      for (final entry in rules.entries) {
        final days = entry.value.repeatWeekDays;
        if (entry.value.repeatType == 2 &&
            days != null &&
            days.any((d) => d < 1 || d > 7)) {
          AppLogger.instance.log('循环规则星期越界，已按周一兜底：${entry.key} $days');
        }
      }
      final missing = RepeatTaskEngine.generateMissing(
        loaded,
        rules,
        now,
        skips: skips,
      );
      if (missing.isEmpty) return 0;

      var inserted = 0;
      for (final t in missing) {
        // 同一个「族 + 日期」本次会话只生成一次。
        // 之前这里没有任何保护：生成的实例如果在同步中被云端结果覆盖掉，
        // 下一轮 _loadTasks 又会补一条，配合「生成即同步」形成 1 秒级的死循环。
        final key = '${t.repeatGroupId}|${t.instanceDate}';
        if (!_materializedKeys.add(key)) continue;
        await _repo.insertTask(t);
        inserted++;
      }
      if (inserted == 0) {
        AppLogger.instance.log('循环任务补生成被拦截：本会话已生成过同期实例');
        return 0;
      }
      AppLogger.instance.log('循环任务自动生成 $inserted 期');
      // 不在这里立刻同步：立即同步会和「云端结果覆盖本地」形成秒级循环，
      // 改成延时上传，失败也不会打转。
      _scheduleRepeatSync();
      return inserted;
    } catch (e) {
      AppLogger.instance.error('循环任务自动生成失败', e);
      return 0;
    }
  }

  /// 补生成后的延时同步：10 秒后一次性上传，不弹提示、不参与防抖。
  void _scheduleRepeatSync() {
    if (!AuthService.isLoggedIn) return;
    _repeatSyncTimer?.cancel();
    _repeatSyncTimer = Timer(const Duration(seconds: 10), () {
      if (!mounted) return;
      _performSync(showToast: false);
    });
  }

  /// 循环任务族ID：时间戳 + 随机数
  String _genRepeatGroupId() {
    final now = DateTime.now();
    final rand = Random();
    final buf = StringBuffer();
    buf.write(now.microsecondsSinceEpoch.toRadixString(16));
    for (var i = 0; i < 8; i++) {
      buf.write(rand.nextInt(16).toRadixString(16));
    }
    return buf.toString();
  }

  /// 把时间 t 的时分秒套用到 date 上
  DateTime? _timeOnDate(DateTime? t, DateTime date) {
    if (t == null) return null;
    return DateTime(date.year, date.month, date.day, t.hour, t.minute, t.second);
  }

  Future<void> _loadTasks() async {
    final seq = ++_loadSeq; // 本次加载序号，用于丢弃过期的并发加载
    // 首次启动：自动创建引导任务（如果从未创建过）
    await _maybeCreateWelcomeTask();
    // 循环任务自动补生成（日/周/月任务）：复用同一份读盘结果，避免整表读两遍
    var all = await _repo.getTasks();
    final inserted = await _materializeRepeatTasks(all);
    if (seq != _loadSeq) return; // 已被更新的加载取代，丢弃本次结果
    if (inserted > 0) all = await _repo.getTasks();

    _counts = {
      TaskStatus.planned: all
          .where((t) => t.status == TaskStatus.planned)
          .length,
      TaskStatus.executing: all
          .where((t) => t.status == TaskStatus.executing)
          .length,
      TaskStatus.completed: all
          .where((t) => t.status == TaskStatus.completed)
          .length,
    };
    final tasks = _filter == null
        ? all
        : all.where((t) => t.status == _filter).toList();
    if (seq != _loadSeq) return; // 已被更新的加载取代，丢弃本次结果
    if (mounted) {
      setState(() {
        _allTasks = all; // 缓存全量，供已完成/全部的搜索与筛选
        _tasks = tasks;
      });
    }
    unawaited(_loadAttachments()); // 卡片上的附件条跟着列表一起刷新
    // 任务数据变化后刷新桌面气泡的未完成任务数
    if (Platform.isWindows) BubbleService.instance.refreshCount();
    // 播放任务卡片入场动画：打开软件首次加载，或切换任务 tab 后
    final shouldPlay = _animateNextList || (!_entrancePlayed && tasks.isNotEmpty);
    _animateNextList = false;
    if (shouldPlay && tasks.isNotEmpty) {
      _entrancePlayed = true;
      AppLogger.instance.log('任务列表入场动画：tab切换/首次 ${tasks.length}条');
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _entranceCtrl.forward(from: 0);
      });
    }
  }

  /// 附件条数据：一次读全部附件元数据，顺带把"原件在哪、还能不能读"判好。
  ///
  /// 判定要 stat 文件，所以不能放进卡片每次 build 里做；这里跟着任务/备忘列表
  /// 一起刷新，卡片只负责画。引用模式的原件说改就改，顺带在这里对账：
  /// 内容变了就重算哈希并立刻上报，对端才会发现副本过期。
  Future<void> _loadAttachments() async {
    final store = AttachmentStore.instance;
    var refreshed = false;
    Future<Map<int, List<AttachmentView>>> views(
      String parentKind,
      Map<int, List<Attachment>> grouped,
    ) async {
      final out = <int, List<AttachmentView>>{};
      for (final entry in grouped.entries) {
        final list = <AttachmentView>[];
        for (final raw in entry.value) {
          var attachment = raw;
          if (raw.isLinked && await store.refreshLink(raw)) {
            attachment = await store.repository.byUid(raw.uid) ?? raw;
            refreshed = true;
          }
          final local = await store.hasLocalCopy(attachment);
          list.add(AttachmentView(
            attachment: attachment,
            local: local,
            source: await store.locate(attachment),
            // 缩略图只在本机确有原件时给路径，避免拿清洗后的 uid 去读别人的目录
            localPath: local ? await store.pathOf(attachment) : null,
          ));
        }
        out[entry.key] = list;
      }
      return out;
    }

    final taskGrouped =
        await store.repository.groupedByParent(Attachment.kindTask);
    final memoGrouped =
        await store.repository.groupedByParent(Attachment.kindMemo);
    final taskViews = await views(Attachment.kindTask, taskGrouped);
    final memoViews = await views(Attachment.kindMemo, memoGrouped);
    if (!mounted) return;
    setState(() {
      _taskAttachments = taskViews;
      _memoAttachments = memoViews;
    });
    if (refreshed) _syncAfterChange();
  }

  /// 把一批文件挂到指定任务/备忘上。
  ///
  /// 默认按开关走"引用原件"：只记路径不复制，用户改原件、复制路径、在资源
  /// 管理器里显示都直接作用在他自己的文件上；开关关掉才复制进附件库。
  /// 每个文件单独报失败原因（类型不符 / 超体积 / 已经挂过 / 数量到顶）。
  Future<void> _attachPaths(
    String parentKind,
    int parentLocalId,
    List<String> paths, {
    Set<String> screenshots = const {},
  }) async {
    if (paths.isEmpty) return;
    final store = AttachmentStore.instance;
    final messages = <String>[];
    var imported = 0;
    for (final path in paths) {
      final outcome = await store.importFile(
        path,
        parentKind: parentKind,
        parentLocalId: parentLocalId,
        isScreenshot: screenshots.contains(path),
        link: AttachmentStore.linkByDefault,
      );
      if (outcome.ok) {
        imported++;
      } else {
        messages.add(outcome.error!);
      }
    }
    await _loadAttachments();
    if (imported > 0) _syncAfterChange(); // 元数据要上报，别等下一次手动同步
    if (messages.isNotEmpty) {
      _showSyncToast(messages.take(2).join('；'), error: true, durationMs: 4200);
    }
  }

  /// 截图建任务：把图先落到临时文件，再走和拖拽同一条收编路径（复制进附件库）。
  Future<String?> _writeScreenshotTemp(Uint8List bytes) async {
    final now = DateTime.now();
    String two(int v) => v.toString().padLeft(2, '0');
    final name = '截图 ${now.year}-${two(now.month)}-${two(now.day)} '
        '${two(now.hour)}-${two(now.minute)}-${two(now.second)}.png';
    try {
      final file = File(
        '${Directory.systemTemp.path}${Platform.pathSeparator}$name',
      );
      await file.writeAsBytes(bytes, flush: true);
      return file.path;
    } catch (e, st) {
      AppLogger.instance.error('截图临时文件写入失败', e, st);
      return null;
    }
  }

  /// 新建/编辑弹窗里的「添加文件」：只攒本机路径，保存拿到本地 id 后才收进附件库。
  /// `existing` 是这条记录身上已经挂着的附件数，用来算还能加几个。
  Future<void> _pickPending(
    List<String> pending,
    StateSetter reload, {
    int existing = 0,
  }) async {
    final result = await pickAttachmentFiles(
      remaining: kAttachmentMaxPerParent - existing - pending.length,
    );
    if (result.paths.isNotEmpty) reload(() => pending.addAll(result.paths));
    if (result.messages.isNotEmpty && mounted) {
      _showSyncToast(result.messages.take(2).join('；'), error: true, durationMs: 4200);
    }
  }

  Future<void> _openAttachment(Attachment attachment) async {
    final error = await AttachmentStore.instance.open(attachment);
    if (error != null && mounted) {
      _showSyncToast(error, error: true, durationMs: 4200);
    }
  }

  Future<void> _pullAttachment(Attachment attachment) async {
    if (!AuthService.isLoggedIn) {
      _showSyncToast('登录后才能从其它主机取文件', error: true, durationMs: 4200);
      return;
    }
    // 进度与失败原因都显示在卡片那颗胶囊上，这里只要发起就行
    unawaited(AttachmentSyncService.instance.pull(attachment));
  }

  /// 右键菜单第二项：在资源管理器里选中这个原件
  Future<void> _revealAttachment(AttachmentView item) async {
    final error = await AttachmentStore.instance
        .revealInFolder(item.attachment, path: item.localPath);
    if (error != null && mounted) {
      _showSyncToast(error, error: true, durationMs: 4200);
    }
  }

  /// 右键菜单第三项：路径进剪贴板，粘到别处就能直接用
  void _copyAttachmentPath(AttachmentView item) {
    final path = item.localPath;
    if (path == null || path.isEmpty) return;
    Clipboard.setData(ClipboardData(text: path));
    _showSyncToast('路径已复制', error: false);
  }

  /// 右键菜单：原件失联时"重新定位原件"，附件库副本时"改为引用本机文件"。
  /// 两件事其实是同一个动作——把这条记录指向用户新挑的那个文件，
  /// 记录不换、附件数不占，类型和体积照样过一遍。
  Future<void> _relocateAttachment(AttachmentView item) async {
    final picked = await pickAttachmentFiles(remaining: 1);
    if (picked.paths.isEmpty) return;
    final outcome = await AttachmentStore.instance
        .relocate(item.attachment, picked.paths.first);
    if (!outcome.ok) {
      if (mounted) {
        _showSyncToast(outcome.error!, error: true, durationMs: 4200);
      }
      return;
    }
    await _loadAttachments();
    _syncAfterChange(); // 文件名/哈希变了，云端要跟上
  }

  /// 右键菜单：把引用的原件收进附件库，之后原件怎么挪、改名都不影响这条附件。
  Future<void> _pinCopyAttachment(AttachmentView item) async {
    final outcome = await AttachmentStore.instance.pinCopy(item.attachment);
    if (!outcome.ok) {
      if (mounted) {
        _showSyncToast(outcome.error!, error: true, durationMs: 4200);
      }
      return;
    }
    await _loadAttachments();
    if (mounted) _showSyncToast('已收进本机附件库', error: false);
  }

  Future<void> _confirmDeleteAttachment(Attachment attachment) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (dialogCtx) => AlertDialog(
        title: const Text('删除附件', style: TextStyle(fontSize: 16)),
        content: Text(
          '要从本机删掉「${attachment.fileName}」吗？\n'
          '其它主机上的原件不受影响，稍后同步会一并撤下记录。',
          style: const TextStyle(fontSize: 13),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogCtx, false),
            child: const Text('取消'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
                backgroundColor: GlassPalette.of(dialogCtx).urgencyImportant),
            onPressed: () => Navigator.pop(dialogCtx, true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    await AttachmentSyncService.instance.deleteAttachment(attachment);
    await _loadAttachments();
    _syncAfterChange();
  }

  /// 卡片接住从资源管理器拖进来的文件：拖上去描一圈高亮，松手就挂附件。
  ///
  /// 边框常驻（不激活时透明），否则高亮出现的那一帧卡片会被撑宽 2px 抖一下。
  Widget _withFileDrop({
    required bool active,
    required VoidCallback onEnter,
    required VoidCallback onExit,
    required void Function(List<String> paths) onDone,
    required Widget child,
  }) {
    return DropTarget(
      onDragEntered: (_) => onEnter(),
      onDragExited: (_) => onExit(),
      onDragDone: (detail) {
        onExit();
        onDone(detail.files.map((item) => item.path).toList());
      },
      child: DecoratedBox(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(GlassStyle.radius),
          border: Border.all(
            color: active ? GlassPalette.of(context).accent : Colors.transparent,
            width: 2,
          ),
        ),
        child: child,
      ),
    );
  }

  /// 计算指定状态组的下一个 sortOrder（放在组最前面 = 当前最小值 - 1）
  Future<int> _nextSortOrder(TaskStatus status) async {
    final all = await _repo.getTasks();
    final group = all.where((t) => t.status == status).toList();
    if (group.isEmpty) return 0;
    final minOrder = group
        .map((t) => t.sortOrder)
        .reduce((a, b) => a < b ? a : b);
    return minOrder - 1;
  }

  // ==================== 拖拽排序 ====================

  /// 指针按下：记录拖拽开始状态
  void _onPointerDown(int index, PointerDownEvent event) {
    if (_isDragging) return;

    // 拖拽手柄：只有在左侧 10px 颜色条区域按下才触发拖拽
    // TaskCard 结构：margin horizontal 12px，颜色条在卡片左侧 10px
    // 所以颜色条的局部 x 范围是 [12, 22]
    final cardBox =
        _cardKeys[index]?.currentContext?.findRenderObject() as RenderBox?;
    if (cardBox != null) {
      final localPos = cardBox.globalToLocal(event.position);
      if (localPos.dx < 12 || localPos.dx > 22) {
        return; // 不在拖拽手柄区域，不触发拖拽（允许正常选择文字）
      }
    }

    _draggingIndex = index;
    _dragStartPos = event.position;
    _dragCurrentPos = event.position;
    _isDragging = false;
    _insertIndex = null;
  }

  /// 指针移动：超过阈值则触发拖拽，更新插入位置
  void _onPointerMove(PointerMoveEvent event) {
    if (_draggingIndex == null) return;
    _dragCurrentPos = event.position;

    if (!_isDragging) {
      final dist = (_dragCurrentPos! - _dragStartPos!).distance;
      if (dist < _dragThreshold) return;
      // 超过阈值，触发拖拽
      _isDragging = true;
      _insertIndex = _draggingIndex;
      _showDragOverlay();
      // 强制设置系统光标为移动手型（Flutter MouseRegion 在 pointer 捕获时不更新）
      _setWin32Cursor(32646); // IDC_SIZEALL
    }

    // 更新插入位置
    _updateInsertIndex(event.position);
    // 更新浮动预览位置
    _dragOverlay?.markNeedsBuild();
  }

  /// 指针释放：执行重排
  void _onPointerUp(PointerUpEvent event) {
    if (_draggingIndex == null) return;
    final fromIndex = _draggingIndex!;
    final toIndex = _insertIndex ?? fromIndex;
    final wasDragging = _isDragging;

    _hideDragOverlay();
    _draggingIndex = null;
    _dragStartPos = null;
    _dragCurrentPos = null;
    _isDragging = false;
    _insertIndex = null;
    _setWin32Cursor(32512); // IDC_ARROW
    if (wasDragging && fromIndex != toIndex) {
      _reorderTasks(fromIndex, toIndex);
    }
    if (mounted) setState(() {});
  }

  /// 根据鼠标全局位置计算插入位置
  void _updateInsertIndex(Offset globalPos) {
    if (_draggingIndex == null) return;
    int newInsert = _tasks.length;
    for (int i = 0; i < _cardKeys.length; i++) {
      final ctx = _cardKeys[i].currentContext;
      if (ctx == null) continue;
      final box = ctx.findRenderObject() as RenderBox?;
      if (box == null) continue;
      final topLeft = box.localToGlobal(Offset.zero);
      final center = topLeft + Offset(0, box.size.height / 2);
      if (globalPos.dy < center.dy) {
        newInsert = i;
        break;
      }
    }
    if (newInsert != _insertIndex) {
      setState(() => _insertIndex = newInsert);
    }
  }

  /// 显示浮动预览（跟随鼠标）
  void _showDragOverlay() {
    if (_draggingIndex == null || _dragOverlay != null) return;
    final task = _tasks[_draggingIndex!];
    final overlay = Overlay.of(context);
    _dragOverlay = OverlayEntry(
      builder: (ctx) => Positioned(
        left: _dragCurrentPos!.dx - 20,
        top: _dragCurrentPos!.dy - 30,
        width: 360,
        child: Material(
          elevation: 12,
          shadowColor: Colors.black38,
          borderRadius: BorderRadius.circular(10),
          child: Opacity(
            opacity: 0.92,
            child: TaskCard(
              task: task,
              onStatusToggle: (_) {},
              onDelete: () {},
              onDoubleTap: () {},
              onEdit: () {},
              isDragging: true,
            ),
          ),
        ),
      ),
    );
    overlay.insert(_dragOverlay!);
  }

  /// 隐藏浮动预览
  void _hideDragOverlay() {
    _dragOverlay?.remove();
    _dragOverlay = null;
  }

  /// 执行重排：更新受影响任务的 sortOrder，保存并同步
  Future<void> _reorderTasks(int fromIndex, int toIndex) async {
    if (fromIndex == toIndex) return;
    final tasks = List<Task>.from(_tasks);
    final task = tasks.removeAt(fromIndex);
    final adjustedToIndex = toIndex > fromIndex ? toIndex - 1 : toIndex;
    tasks.insert(adjustedToIndex, task);

    // 重新分配 sortOrder：按当前顺序，从 0 开始递增（步长 100，留余量）
    final now = DateTime.now();
    for (int i = 0; i < tasks.length; i++) {
      final newOrder = i * 100;
      if (tasks[i].sortOrder != newOrder) {
        tasks[i] = tasks[i].copyWith(sortOrder: newOrder, updatedAt: now);
        await _repo.updateTask(tasks[i]);
      }
    }

    if (mounted) {
      setState(() => _tasks = tasks);
      _syncAfterChange();
    }
  }

  /// 状态切换飞行动画：卡片变小球飞入目标标签
  ///
  /// [to] 为空时按默认流转取下一个状态；「回到计划中」这类非顺序流转
  /// 需要显式指定目标，小球才会飞向正确的标签。
  void _animateStatusChange(Task task, BuildContext cardContext,
      {TaskStatus? to}) {
    final target = to ?? _nextStatus(task.status);
    final targetKey = switch (target) {
      TaskStatus.planned => _plannedChipKey,
      TaskStatus.executing => _executingChipKey,
      TaskStatus.completed => _completedChipKey,
    };

    final cardBox = cardContext.findRenderObject() as RenderBox?;
    final targetBox =
        targetKey.currentContext?.findRenderObject() as RenderBox?;

    // 拿不到位置时直接切换
    if (cardBox == null || targetBox == null) {
      _toggleStatus(task, to: to);
      return;
    }

    final cardPos = cardBox.localToGlobal(Offset.zero);
    final targetPos = targetBox.localToGlobal(Offset.zero);
    final cardSize = cardBox.size;
    final targetSize = targetBox.size;

    final startX = cardPos.dx + cardSize.width / 2;
    final startY = cardPos.dy + cardSize.height / 2;
    final endX = targetPos.dx + targetSize.width / 2;
    final endY = targetPos.dy + targetSize.height / 2;
    final color = TaskCard.urgencyColors(GlassPalette.of(context))[task.urgency]!;

    late OverlayEntry overlayEntry;
    overlayEntry = OverlayEntry(
      builder: (context) => _FlyingBall(
        startX: startX,
        startY: startY,
        endX: endX,
        endY: endY,
        color: color,
        onComplete: () {
          overlayEntry.remove();
        },
      ),
    );
    Overlay.of(context).insert(overlayEntry);

    // 立即刷新列表，小球动画通过 Overlay 独立播放不受影响
    _toggleStatus(task, to: to);
  }

  TaskStatus _nextStatus(TaskStatus status) => switch (status) {
        TaskStatus.planned => TaskStatus.executing,
        TaskStatus.executing => TaskStatus.completed,
        TaskStatus.completed => TaskStatus.executing,
      };

  /// 状态流转：计划中→执行中→已完成，已完成可重开；
  /// [to] 可显式指定目标（例如执行中退回计划中）。
  Future<void> _toggleStatus(Task task, {TaskStatus? to}) async {
    final now = DateTime.now();
    final target = to ?? _nextStatus(task.status);
    final updated = switch (target) {
      TaskStatus.planned => task.copyWith(
          status: TaskStatus.planned,
          clearStartedAt: true,
          clearCompletedAt: true,
          updatedAt: now,
        ),
      TaskStatus.executing => task.copyWith(
          status: TaskStatus.executing,
          startedAt: now,
          clearCompletedAt: true,
          updatedAt: now,
        ),
      TaskStatus.completed => task.copyWith(
          status: TaskStatus.completed,
          completedAt: now,
          updatedAt: now,
        ),
    };
    await _repo.updateTask(updated);
    _loadTasks();
    _syncAfterChange();
  }

  /// 子任务勾选回调：更新任务标题并保存（不改数据库结构）
  Future<void> _onSubTaskChanged(Task updated) async {
    // 必须刷新 updatedAt，否则云端按时间戳合并时会用旧数据覆盖本地勾选状态
    await _repo.updateTask(updated.copyWith(updatedAt: DateTime.now()));
    _loadTasks();
    _syncAfterChange();
  }

  /// 删除任务。stopRepeat=true 时同时停止该族的循环（彻底取消，今后不再生成）
  Future<void> _deleteTask(Task task, {bool stopRepeat = false}) async {
    if (task.repeatGroupId != null) {
      if (stopRepeat) {
        // 停止循环 = 规则标记 stopped（会同步到其它设备）+ 本地哨兵兜底。
        // 只删规则是不够的：引擎在规则缺失时会回退到"用现存实例当模板"，
        // 同族只要还有一条实例，紧接着的 _loadTasks 就会把这一期补回来。
        // 同族其它期次保持原样（历史仍是循环任务），只是不再产生新一期。
        await _repo.stopRepeatGroup(task.repeatGroupId!);
        AppLogger.instance.log('已停止循环任务族：${task.repeatGroupId}');
      } else if (task.instanceDate != null) {
        // 仅删除本期：写进跳过账本（独立于规则，规则不存在也生效），
        // 否则紧接着的 _loadTasks 会调用补生成引擎，把刚删掉的这一期补回来。
        await _repo.skipRepeatInstance(task);
      }
    }
    await _repo.deleteTask(task.id!);
    // 附件：卡片没了就转孤儿，原件按用户规则留着（截图任务的图直接删）
    await AttachmentSyncService.instance
        .onParentDeleted(Attachment.kindTask, task.id!);
    // 无条件记录删除：remoteId 可能为空（添加后未完成同步即删除），
    // 由 syncTasks 从云端响应解析 remote_id 后下轮软删除，避免"删除后复活"
    await RemoteSyncService.recordLocalDeletion(task.id!, task.remoteId);
    _loadTasks();
    _syncAfterChange();
  }

  // ===== 计划时间选择：明天 / 后天 / 选日期时间 / 清除 =====
  String _fmtTime(DateTime dt) {
    final t = dt.isUtc ? dt.toLocal() : dt;
    return '${t.month}/${t.day} '
        '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';
  }

  Widget _buildTimeRow(
    BuildContext dialogCtx,
    StateSetter setDialogState,
    String label,
    DateTime? value,
    void Function(DateTime?) onChanged, {
    DateTime? minTime,
    DateTime? maxTime,
  }) {
    return InkWell(
      onTap: () => _pickTime(
        dialogCtx,
        value,
        onChanged,
        minTime: minTime,
        maxTime: maxTime,
      ),
      borderRadius: BorderRadius.circular(8),
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        decoration: BoxDecoration(
          color: GlassPalette.of(context).fieldBg,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: GlassPalette.of(context).fieldBorder),
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(
              label,
              style: TextStyle(fontSize: 13, color: GlassPalette.of(context).inkTertiary),
            ),
            Text(
              value == null ? '未设置' : _fmtTime(value),
              style: TextStyle(
                fontSize: 13,
                color: value == null ? GlassPalette.of(context).inkTertiary : GlassPalette.of(context).ink,
                fontWeight: value == null ? FontWeight.w400 : FontWeight.w500,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _pickTime(
    BuildContext dialogCtx,
    DateTime? current,
    void Function(DateTime?) onChanged, {
    DateTime? minTime,
    DateTime? maxTime,
  }) async {
    final result = await DateTimePickerSheet.show(
      dialogCtx,
      initialDateTime: current,
      minDateTime: minTime,
      maxDateTime: maxTime,
      title: '选择日期和时间',
    );
    if (result == null) return; // 用户取消
    if (result.isCleared) {
      onChanged(null);
    } else {
      final v = result.value;
      if (v == null) return; // 清空/无效值
      // 时间先后校验：计划开始 < 预计完成（弹窗提示，点确定才消失）
      if (maxTime != null && v.isAfter(maxTime)) {
        if (context.mounted) {
          await showDialog(
            context: context,
            builder: (ctx) => AlertDialog(
              title: const Text('时间冲突'),
              content: const Text('计划开始时间不能晚于预计完成时间，请重新选择。'),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(ctx),
                  child: const Text('确定'),
                ),
              ],
            ),
          );
        }
        return;
      }
      if (minTime != null && v.isBefore(minTime)) {
        if (context.mounted) {
          await showDialog(
            context: context,
            builder: (ctx) => AlertDialog(
              title: const Text('时间冲突'),
              content: const Text('预计完成时间不能早于计划开始时间，请重新选择。'),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(ctx),
                  child: const Text('确定'),
                ),
              ],
            ),
          );
        }
        return;
      }
      onChanged(v);
    }
  }

  /// 快捷选择：保留已有时分，未设置过默认 09:00
  DateTime _dayAt(DateTime day, DateTime? current) {
    final h = current?.hour ?? 9;
    final m = current?.minute ?? 0;
    return DateTime(day.year, day.month, day.day, h, m);
  }

  // ================= 备忘功能 =================

  /// 加载本地备忘（按创建时间倒序）
  Future<void> _loadMemos() async {
    final memos = await _memoRepo.getMemos();
    if (mounted) setState(() => _memos = memos);
    unawaited(_loadAttachments());
    // 切换备忘 tab 后播放入场动画（只播一次；搜索/增删改不重播）
    final playMemo = _animateNextMemo;
    _animateNextMemo = false;
    if (playMemo && memos.isNotEmpty) {
      _entrancePlayed = true;
      AppLogger.instance.log('备忘列表入场动画：tab切换 ${memos.length}条');
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _entranceCtrl.forward(from: 0);
      });
    }
  }

  /// 打开快速录入对话框（'memo' = 记一笔 / 'task' = 记任务 / 'capture' = 热键快速录入）。
  ///
  /// 托盘、气泡菜单和全局热键可以在已有对话框的情况下再次触发，这里保证同一
  /// 时间只有一个快速录入对话框：
  /// - 已经打开的是同一种 → 保留现场（不清掉用户已输入的内容）；
  /// - 已经打开的是另一种 → 先关掉旧的，再开新的。
  Future<void> _openQuickDialog(String kind) async {
    if (_quickDialogKind == kind) return;
    _closeQuickDialog();
    if (!mounted) return;
    _quickDialogKind = kind;
    try {
      if (kind == 'memo') {
        await _showMemoEditor();
      } else if (kind == 'capture') {
        await _showQuickCaptureDialog();
      } else {
        await _showAddDialog();
      }
    } finally {
      // 只清理自己这一轮的状态（切换时旧的 finally 会晚于新的一轮执行）
      if (_quickDialogKind == kind) _quickDialogKind = null;
    }
  }

  /// 全局热键 Ctrl+Alt+N 的入口。
  ///
  /// 如果主窗口当时在托盘里或已最小化，先临时叫出来显示对话框，录入结束后
  /// 再放回原状态，尽量不打断用户手头的操作（气泡也一并恢复）。
  Future<void> _onQuickCaptureHotkey() async {
    if (!mounted) return;
    var wasVisible = true;
    var wasMinimized = false;
    var bubbleWasShown = false;
    try {
      wasVisible = await windowManager.isVisible();
      wasMinimized = wasVisible && await windowManager.isMinimized();
      bubbleWasShown = BubbleService.instance.isShown;
      if (!wasVisible || wasMinimized) {
        await AppLifecycle.instance.showWindow();
      }
    } catch (e, st) {
      AppLogger.instance.error('快速录入：唤起窗口失败', e, st);
    }
    if (!mounted) return;
    try {
      await _openQuickDialog('capture');
    } finally {
      // 恢复原来的窗口状态
      try {
        if (!wasVisible) {
          await windowManager.hide();
          // hide() 不会触发窗口事件，气泡要手动放回去
          if (bubbleWasShown) BubbleService.instance.onHidden();
        } else if (wasMinimized) {
          // minimize() 会触发 onWindowMinimize，气泡由 BubbleService 自己恢复
          await windowManager.minimize();
        }
      } catch (e, st) {
        AppLogger.instance.error('快速录入：恢复窗口状态失败', e, st);
      }
    }
  }

  /// 迷你录入框：两行文字 + 紧急度，回车保存、Esc 取消。
  Future<void> _showQuickCaptureDialog() async {
    final result = await showDialog<(String, Urgency)>(
      context: context,
      routeSettings: const RouteSettings(name: _quickDialogRouteName),
      builder: (_) => const _QuickCaptureDialog(),
    );
    if (result == null || !mounted) return;
    final (title, urgency) = result;
    if (title.isEmpty) return;
    await _saveQuickCapture(title, urgency);
  }

  /// 快速录入保存：默认「计划中 / 工作任务」，排序放最前面。
  Future<void> _saveQuickCapture(String title, Urgency urgency) async {
    try {
      final sortOrder = await _nextSortOrder(TaskStatus.planned);
      await _repo.insertTask(
        Task(
          title: title,
          urgency: urgency,
          taskType: 1,
          createdAt: DateTime.now(),
          sortOrder: sortOrder,
        ),
      );
      _loadTasks();
      _syncAfterChange();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('已记下：$title'),
            duration: const Duration(seconds: 2),
          ),
        );
      }
    } catch (e, st) {
      AppLogger.instance.error('快速录入保存失败', e, st);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('保存失败：$e')),
        );
      }
    }
  }

  /// 关掉已打开的快速录入对话框。
  ///
  /// 按路由名匹配，不碰其它对话框（关于我们、AI 总结等）；没有打开时是空操作。
  void _closeQuickDialog() {
    if (!mounted) return;
    Navigator.of(context, rootNavigator: true).popUntil(
      (route) => route.settings.name != _quickDialogRouteName,
    );
  }

  /// 右下角加号：先让用户选择「任务 / 备忘」（方案A：清单式）
  Future<void> _showAddChoice() async {
    final choice = await showDialog<String>(
      context: context,
      builder: (context) => const _AddChoiceDialog(),
    );
    if (!mounted) return;
    // 走同一个入口，保证从「+」按钮打开的对话框也被记录，
    // 之后从托盘/气泡切换时能被正确关掉
    if (choice == 'task') {
      await _openQuickDialog('task');
    } else if (choice == 'memo') {
      await _openQuickDialog('memo');
    }
  }

  /// 导出全部备忘为 Markdown 文件
  Future<void> _exportMemos() async {
    if (_memos.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('暂无备忘可导出')),
      );
      return;
    }
    final now = DateTime.now();
    String two(int v) => v.toString().padLeft(2, '0');
    final fileName =
        '备忘导出_${now.year}${two(now.month)}${two(now.day)}_${two(now.hour)}${two(now.minute)}.md';
    const typeGroup = XTypeGroup(label: 'Markdown', extensions: ['md']);
    final file = await getSaveLocation(
      suggestedName: fileName,
      acceptedTypeGroups: const [typeGroup],
    );
    if (file == null) return; // 用户取消
    try {
      await File(file.path).writeAsString(_memosToMarkdown(now));
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('已导出：${file.path}')),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('导出失败：$e')),
      );
    }
  }

  /// 生成 Markdown 导出内容
  String _memosToMarkdown(DateTime now) {
    final buf = StringBuffer();
    String two(int v) => v.toString().padLeft(2, '0');
    buf.writeln('# 极简工作日记 · 备忘导出');
    buf.writeln('');
    buf.writeln('导出时间：${now.year}-${two(now.month)}-${two(now.day)} '
        '${two(now.hour)}:${two(now.minute)}');
    buf.writeln('共 ${_memos.length} 条');
    for (final m in _memos) {
      buf.writeln('');
      buf.writeln('---');
      buf.writeln('');
      buf.writeln('## ${_formatMemoTime(m.createdAt)}');
      buf.writeln('');
      buf.writeln(m.content);
    }
    buf.writeln('');
    return buf.toString();
  }

  /// 插入一条 Markdown 示例备忘（首次体验引导）
  Future<void> _addDemoMemo() async {
    const demo =
        '# 我的第一条备忘\n\n- **加粗** 重点内容\n- 普通列表项\n- `代码片段`\n\n> 引用：用 Markdown 写备忘，查看时自动排版';
    await _memoRepo.insertMemo(Memo(content: demo, createdAt: DateTime.now()));
    await _loadMemos();
    _syncAfterChange();
  }

  /// 备忘视图：搜索框 + 备忘卡片列表

  /// 是否处于分页模式（已完成 / 全部 tab）
  bool get _isPagedTab =>
      !_showMemoView && (_filter == TaskStatus.completed || _filter == null);

  /// 打开「我的数据」看板：整页替换列表，返回时回到进来时的那个 tab。
  void _openStatsView() {
    if (_showStatsView) return;
    setState(() => _showStatsView = true);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _showStatsView) _entranceCtrl.forward(from: 0);
    });
  }

  void _closeStatsView() {
    if (!_showStatsView) return;
    setState(() => _showStatsView = false);
  }

  /// 「全部」tab 头部的看板入口（图标 + 数据），尺寸与筛选胶囊对齐。
  Widget _statsEntryButton() {
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTap: _openStatsView,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
          decoration: BoxDecoration(
            color: GlassPalette.of(context).statsPrimary.withValues(alpha: 0.14),
            borderRadius: BorderRadius.circular(14),
            border: Border.all(
              color: GlassPalette.of(context).statsPrimary.withValues(alpha: 0.35),
            ),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.insights_outlined,
                  size: 14, color: GlassPalette.of(context).statsPrimary),
              SizedBox(width: 4),
              Text('数据',
                  style: TextStyle(
                      fontSize: 12, color: GlassPalette.of(context).statsPrimary)),
            ],
          ),
        ),
      ),
    );
  }

  /// 看板数据源：直接读本地全量任务，不依赖当前 tab 的缓存，
  /// 这样「已完成数」和「已完成」tab 角标必然同源（需求验收 1）。
  Future<StatsSnapshot> _loadStatsSnapshot(StatsRange range) async {
    final tasks = await _repo.getTasks();
    final skips = await _repo.getRepeatSkips();
    return StatsCalculator.compute(
      tasks: tasks,
      skips: skips,
      range: range,
    );
  }

  /// 已完成/全部：全量缓存 → 状态 → 搜索 → 紧急度 → 类型 过滤
  List<Task> _filteredTasks() {
    List<Task> list = _filter == null
        ? List.of(_allTasks)
        : _allTasks.where((t) => t.status == _filter).toList();
    final kw = _taskSearchCtrl.text.trim().toLowerCase();
    if (kw.isNotEmpty) {
      list = list
          .where((t) => t.title.toLowerCase().contains(kw))
          .toList();
    }
    if (_filterUrgency != null) {
      list = list.where((t) => t.urgency == _filterUrgency).toList();
    }
    if (_filterType != null) {
      list = list.where((t) => t.taskType == _filterType).toList();
    }
    return list;
  }

  /// 已完成/全部 tab 视图：搜索框 + 筛选条 + 分页列表
  Widget _buildPagedTaskView() {
    final filtered = _filteredTasks();
    final visible = filtered.take(_visibleCount).toList();
    final hasMore = filtered.length > _visibleCount;
    return Column(
      children: [
        // 搜索框（方案A：主题蓝边框 + 浅蓝底 + 阴影，更醒目）
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
          child: Container(
            decoration: BoxDecoration(
              color: GlassPalette.of(context).fieldBg,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: GlassPalette.of(context).fieldBorder, width: 1),
              boxShadow: [
                BoxShadow(
                  color: GlassPalette.of(context).shadow.withAlpha(0x33),
                  blurRadius: 10,
                  offset: Offset(0, 3),
                ),
              ],
            ),
            child: SizedBox(
              height: 38,
              child: TextField(
                controller: _taskSearchCtrl,
                textAlignVertical: TextAlignVertical.center,
                onChanged: (_) => setState(() {}),
                style: TextStyle(fontSize: 13, color: GlassPalette.of(context).ink),
                cursorColor: GlassPalette.of(context).accentSoft,
                decoration: InputDecoration(
                  hintText: '搜索任务标题 / 子任务内容…',
                  hintStyle: TextStyle(
                      fontSize: 13, color: GlassPalette.of(context).inkFaint),
                  isDense: true,
                  prefixIcon: Icon(Icons.search,
                      size: 18, color: GlassPalette.of(context).accentSoft),
                  suffixIcon: _taskSearchCtrl.text.isEmpty
                      ? null
                      : IconButton(
                          icon: Icon(Icons.clear,
                              size: 16, color: GlassPalette.of(context).accentSoft),
                          padding: EdgeInsets.zero,
                          constraints: const BoxConstraints(
                              minWidth: 28, minHeight: 28),
                          onPressed: () {
                            _taskSearchCtrl.clear();
                            setState(() {});
                          },
                        ),
                  border: InputBorder.none,
                  contentPadding: EdgeInsets.zero,
                ),
              ),
            ),
          ),
        ),
        // 筛选条
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 6, 12, 0),
          child: SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              children: [
                _filterChip('紧急度', null, _filterUrgency, '全部',
                    () => setState(() => _filterUrgency = null)),
                _filterChip('紧急度', Urgency.normal, _filterUrgency, '一般',
                    () => setState(() => _filterUrgency = Urgency.normal)),
                _filterChip('紧急度', Urgency.important, _filterUrgency, '重要',
                    () => setState(() => _filterUrgency = Urgency.important)),
                _filterChip('紧急度', Urgency.urgent, _filterUrgency, '紧急',
                    () => setState(() => _filterUrgency = Urgency.urgent)),
                const SizedBox(width: 6),
                Text('|',
                    style: TextStyle(fontSize: 12, color: GlassPalette.of(context).decoInk.withAlpha(0x33))),
                const SizedBox(width: 6),
                _filterChip('类型', null, _filterType, '全部',
                    () => setState(() => _filterType = null)),
                _filterChip('类型', 1, _filterType, '工作',
                    () => setState(() => _filterType = 1)),
                _filterChip('类型', 0, _filterType, '个人',
                    () => setState(() => _filterType = 0)),
              ],
            ),
          ),
        ),
        // 「全部」tab 头部的小号看板入口：和设置菜单里的「我的数据」进同一页
        if (_filter == null)
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 6, 12, 0),
            child: Align(
              alignment: Alignment.centerRight,
              child: _statsEntryButton(),
            ),
          ),
        Expanded(
          child: filtered.isEmpty
              ? Center(
                  child: Text(
                    _allTasks.isEmpty
                        ? '还没有任务，点击右下角 + 创建'
                        : '没有找到匹配的任务',
                    style: TextStyle(
                        color: GlassPalette.of(context).inkTertiary, fontSize: 14),
                  ),
                )
              : ListView.builder(
                  padding: const EdgeInsets.only(top: 8, bottom: 108),
                  itemCount: visible.length + (hasMore ? 1 : 0),
                  itemBuilder: (context, i) {
                    if (i == visible.length) {
                      return _buildLoadMoreButton(
                          filtered.length - visible.length);
                    }
                    return _buildTaskItem(i, visible[i], visible.length);
                  },
                ),
        ),
      ],
    );
  }

  /// 加载更多按钮
  Widget _buildLoadMoreButton(int remaining) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 10),
        child: OutlinedButton(
          onPressed: () =>
              setState(() => _visibleCount += _pageSize),
          style: OutlinedButton.styleFrom(
            visualDensity: VisualDensity.compact,
            side: BorderSide(color: GlassPalette.of(context).accentSoft),
          ),
          child: Text(
            '还有 $remaining 条，点击加载更多',
            style: TextStyle(
                fontSize: 12, color: GlassPalette.of(context).accentSoft),
          ),
        ),
      ),
    );
  }

  /// 筛选胶囊
  Widget _filterChip(String group, dynamic value, dynamic current, String label,
      VoidCallback onTap) {
    final selected = value == current;
    return Padding(
      padding: const EdgeInsets.only(right: 6),
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        child: GestureDetector(
          onTap: onTap,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 150),
            height: 26,
            padding: const EdgeInsets.symmetric(horizontal: 10),
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: selected
                  ? GlassPalette.of(context).accent
                  : GlassPalette.of(context).decoInk.withAlpha(14),
              borderRadius: BorderRadius.circular(13),
              border: Border.all(
                color: selected ? Colors.transparent : GlassPalette.of(context).chipBorder,
              ),
            ),
            child: Text(
              label,
              style: TextStyle(
                fontSize: 11.5,
                color: selected ? Colors.white : GlassPalette.of(context).inkSecondary,
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// 任务卡片条目（供普通列表与分页列表共用）
  Widget _buildTaskItem(int i, Task task, int total) {
    // 确保 cardKeys 长度匹配
    while (_cardKeys.length < total) {
      _cardKeys.add(GlobalKey());
    }
    while (_cardKeys.length > total) {
      _cardKeys.removeLast();
    }

    final isDragging = _draggingIndex == i && _isDragging;
    final showInsertGap =
        _insertIndex == i && _isDragging && _draggingIndex != i;

    return _EntranceItem(
      controller: _entranceCtrl,
      index: i,
      total: total,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (showInsertGap)
            Container(
              margin: const EdgeInsets.symmetric(horizontal: 12),
              height: 3,
              decoration: BoxDecoration(
                color: GlassPalette.of(context).accent,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
          Listener(
            key: _cardKeys[i],
            onPointerDown: (e) => _onPointerDown(i, e),
            onPointerMove: _onPointerMove,
            onPointerUp: _onPointerUp,
            child: Opacity(
              opacity: isDragging ? 0.3 : 1.0,
              child: _withFileDrop(
                active: _dropTaskId == task.id,
                onEnter: () => setState(() => _dropTaskId = task.id),
                onExit: () {
                  if (_dropTaskId == task.id) setState(() => _dropTaskId = null);
                },
                onDone: (paths) {
                  final id = task.id;
                  if (id != null) {
                    unawaited(_attachPaths(Attachment.kindTask, id, paths));
                  }
                },
                child: TaskCard(
                  task: task,
                  isDragging: _isDragging,
                  onStatusToggle: (ctx) => _animateStatusChange(task, ctx),
                  onBackToPlanned: (ctx) => _animateStatusChange(
                    task,
                    ctx,
                    to: TaskStatus.planned,
                  ),
                  onDelete: () => _deleteTask(task),
                  onStopRepeat: () => _deleteTask(task, stopRepeat: true),
                  onDoubleTap: () => _showEditDialog(task),
                  onEdit: () => _showEditDialog(task),
                  onSubTaskChanged: (updated) => _onSubTaskChanged(updated),
                  attachments: AttachmentStrip(
                    items: _taskAttachments[task.id] ?? const <AttachmentView>[],
                    onOpen: _openAttachment,
                    onPull: _pullAttachment,
                    onDelete: _confirmDeleteAttachment,
                    onReveal: _revealAttachment,
                    onCopyPath: _copyAttachmentPath,
                    onRelocate: _relocateAttachment,
                    onPinCopy: _pinCopyAttachment,
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildMemoView() {
    final keyword = _memoSearchCtrl.text.trim();
    final memos = keyword.isEmpty
        ? _memos
        : _memos.where((m) => m.content.contains(keyword)).toList();
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 10, 12, 4),
          child: Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _memoSearchCtrl,
                  onChanged: (_) => setState(() {}),
                  style: TextStyle(fontSize: 13, color: GlassPalette.of(context).ink),
                  cursorColor: GlassPalette.of(context).accentSoft,
                  decoration: InputDecoration(
                    hintText: '搜索备忘内容…',
                    hintStyle: TextStyle(
                        fontSize: 13, color: GlassPalette.of(context).inkFaint),
                    isDense: true,
                    prefixIcon: Icon(Icons.search,
                        size: 18, color: GlassPalette.of(context).inkTertiary),
                    suffixIcon: _memoSearchCtrl.text.isEmpty
                        ? null
                        : IconButton(
                            icon: Icon(Icons.clear,
                                size: 16, color: GlassPalette.of(context).inkSecondary),
                            onPressed: () {
                              _memoSearchCtrl.clear();
                              setState(() {});
                            },
                          ),
                    filled: true,
                    fillColor: GlassPalette.of(context).fieldBg,
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(10),
                      borderSide:
                          BorderSide(color: GlassPalette.of(context).fieldBorder),
                    ),
                    enabledBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(10),
                      borderSide:
                          BorderSide(color: GlassPalette.of(context).fieldBorder),
                    ),
                    contentPadding: const EdgeInsets.symmetric(vertical: 8),
                  ),
                ),
              ),
              const SizedBox(width: 2),
              IconButton(
                tooltip: '导出全部备忘',
                icon: Icon(Icons.file_download_outlined,
                    size: 18, color: GlassPalette.of(context).accentSoft),
                onPressed: _exportMemos,
              ),
            ],
          ),
        ),
        Expanded(
          child: memos.isEmpty
              ? Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.note_alt_outlined,
                          size: 40, color: GlassPalette.of(context).decoInk.withAlpha(0x33)),
                      const SizedBox(height: 10),
                      Text(
                        '还没有备忘，点击右下角 + 选择「新建备忘」',
                        style: TextStyle(
                            color: GlassPalette.of(context).inkTertiary, fontSize: 14),
                      ),
                      const SizedBox(height: 10),
                      TextButton.icon(
                        onPressed: _addDemoMemo,
                        icon: const Icon(Icons.auto_awesome, size: 16),
                        label: const Text('试试 Markdown 示例'),
                        style: TextButton.styleFrom(
                          foregroundColor: GlassPalette.of(context).accentSoft,
                          visualDensity: VisualDensity.compact,
                        ),
                      ),
                    ],
                  ),
                )
              : ListView(
                  padding: const EdgeInsets.only(top: 6, bottom: 106),
                  // 备忘数量少，全量渲染；每条带独立 key 防止复用错乱
                  children: [
                    for (var i = 0; i < memos.length; i++)
                      _EntranceItem(
                        controller: _entranceCtrl,
                        index: i,
                        total: memos.length,
                        child: _buildMemoCard(memos[i], i),
                      ),
                  ],
                ),
        ),
      ],
    );
  }

  /// 备忘卡片：隔行换色 + 左侧主题色竖条 + 悬停上浮 + 搜索关键词高亮 + 可选中复制
  Widget _buildMemoCard(Memo memo, int index) {
    return _withFileDrop(
      active: _dropMemoId == memo.id,
      onEnter: () => setState(() => _dropMemoId = memo.id),
      onExit: () {
        if (_dropMemoId == memo.id) setState(() => _dropMemoId = null);
      },
      onDone: (paths) {
        final id = memo.id;
        if (id != null) {
          unawaited(_attachPaths(Attachment.kindMemo, id, paths));
        }
      },
      child: MemoCard(
        key: ValueKey(memo.id ?? index),
        memo: memo,
        index: index,
        onEdit: () => _showMemoEditor(memo: memo),
        onDelete: () => _confirmDeleteMemo(memo),
        keyword: _memoSearchCtrl.text.trim(),
        timeText: _formatMemoTime(memo.createdAt),
        attachments: AttachmentStrip(
          items: _memoAttachments[memo.id] ?? const <AttachmentView>[],
          padding: const EdgeInsets.only(bottom: 4),
          onOpen: _openAttachment,
          onPull: _pullAttachment,
          onDelete: _confirmDeleteAttachment,
          onReveal: _revealAttachment,
          onCopyPath: _copyAttachmentPath,
          onRelocate: _relocateAttachment,
          onPinCopy: _pinCopyAttachment,
        ),
      ),
    );
  }

  /// 时间显示：今天显示 HH:mm，其他显示 MM-dd HH:mm
  String _formatMemoTime(DateTime dt) {
    final now = DateTime.now();
    final sameDay = dt.year == now.year && dt.month == now.month && dt.day == now.day;
    String two(int v) => v.toString().padLeft(2, '0');
    final hm = '${two(dt.hour)}:${two(dt.minute)}';
    if (sameDay) return hm;
    return '${two(dt.month)}-${two(dt.day)} $hm';
  }

  /// 新建/编辑备忘弹窗（支持 Markdown：编辑/预览切换）
  Future<void> _showMemoEditor({Memo? memo}) async {
    final ctrl = TextEditingController(text: memo?.content ?? '');
    final pendingFiles = <String>[]; // 待挂附件：保存拿到本地 id 后才收进本机
    final attachedCount =
        memo == null ? 0 : (_memoAttachments[memo.id] ?? const <AttachmentView>[]).length;
    var tab = 0; // 0=编辑 1=预览
    final saved = await showDialog<bool>(
      context: context,
      // 路由名用于「记任务 / 记一笔」切换时定位并关闭本对话框
      routeSettings: const RouteSettings(name: _quickDialogRouteName),
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: Text(memo == null ? '新建备忘' : '编辑备忘', style: const TextStyle(fontSize: 16)),
          content: SizedBox(
            width: 430,
            height: 420,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SegmentedButton<int>(
                  segments: const [
                    ButtonSegment(
                      value: 0,
                      label: Text('编辑', style: TextStyle(fontSize: 13)),
                      icon: Icon(Icons.edit_outlined, size: 15),
                    ),
                    ButtonSegment(
                      value: 1,
                      label: Text('预览', style: TextStyle(fontSize: 13)),
                      icon: Icon(Icons.visibility_outlined, size: 15),
                    ),
                  ],
                  selected: {tab},
                  onSelectionChanged: (s) => setDialogState(() => tab = s.first),
                  showSelectedIcon: false,
                  style: ButtonStyle(
                    visualDensity: VisualDensity.compact,
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  '支持 Markdown：# 标题、**加粗**、- 列表、`代码`、[链接](url)',
                  style: TextStyle(fontSize: 11, color: GlassPalette.of(context).menuTextFaint),
                ),
                const SizedBox(height: 8),
                Expanded(
                  child: tab == 0
                      ? _ImeSafeTextField(
                          controller: ctrl,
                          hintText: '输入备忘内容…',
                          autofocus: true,
                          // 备忘不转换子任务语法（避免与 Markdown 有序列表 1. 冲突）
                          enableAutoConvert: false,
                          maxLength: 3000,
                          counterText: '',
                          maxLines: 12,
                        )
                      : Container(
                          width: double.infinity,
                          decoration: BoxDecoration(
                            color: GlassPalette.of(context).fieldBg,
                            borderRadius: BorderRadius.circular(8),
                            border: Border.all(color: GlassPalette.of(context).fieldBorder),
                          ),
                          padding: const EdgeInsets.all(10),
                          child: SelectionArea(
                            child: SingleChildScrollView(
                              child: ctrl.text.trim().isEmpty
                                  ? Text(
                                      '输入内容后，点击「预览」查看渲染效果',
                                      style: TextStyle(color: GlassPalette.of(context).inkTertiary, fontSize: 13),
                                    )
                                  : _memoMarkdown(context, ctrl.text),
                            ),
                          ),
                        ),
                ),
                const SizedBox(height: 4),
                ValueListenableBuilder<TextEditingValue>(
                  valueListenable: ctrl,
                  builder: (context, v, _) => Text(
                    '${v.text.characters.length}/3000',
                    textAlign: TextAlign.right,
                    style: TextStyle(fontSize: 11, color: GlassPalette.of(context).menuTextFaint),
                  ),
                ),
                ConstrainedBox(
                  constraints: const BoxConstraints(maxHeight: 120),
                  child: SingleChildScrollView(
                    child: PendingAttachmentPicker(
                      paths: pendingFiles,
                      remaining: kAttachmentMaxPerParent - attachedCount - pendingFiles.length,
                      onPick: () => _pickPending(pendingFiles, setDialogState, existing: attachedCount),
                      onRemove: (path) => setDialogState(() => pendingFiles.remove(path)),
                    ),
                  ),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(context).pop(true),
              child: const Text('保存'),
            ),
          ],
        ),
      ),
    );
    if (saved != true || !mounted) {
      // 取消、或者被「记任务」切换时程序化关闭：同样要释放控制器
      ctrl.dispose();
      return;
    }
    final content = ctrl.text.trim();
    ctrl.dispose();
    if (content.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('备忘内容不能为空')),
      );
      return;
    }
    final now = DateTime.now();
    final int savedId;
    if (memo == null) {
      savedId = await _memoRepo.insertMemo(Memo(content: content, createdAt: now));
    } else {
      await _memoRepo.updateMemo(memo.copyWith(content: content, updatedAt: now));
      savedId = memo.id!;
    }
    await _loadMemos();
    _syncAfterChange(); // 登录后自动同步到云端
    await _attachPaths(Attachment.kindMemo, savedId, pendingFiles);
  }

  /// 删除备忘：二次确认，登录时记录删除待同步
  Future<void> _confirmDeleteMemo(Memo memo) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('删除备忘', style: TextStyle(fontSize: 16)),
        content: const Text('确定要删除这条备忘吗？', style: TextStyle(fontSize: 13)),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: GlassPalette.of(context).urgencyImportant),
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    await _memoRepo.deleteMemo(memo.id!);
    await AttachmentSyncService.instance
        .onParentDeleted(Attachment.kindMemo, memo.id!);
    // 无条件记录删除（不依赖登录状态）：remoteId 可能为空（添加后未完成同步即删除），
    // 由 syncMemos 从云端响应解析 remote_id 后下轮软删除，避免"删除后复活"
    await RemoteSyncService.recordMemoDeletion(memo.id!, memo.remoteId);
    await _loadMemos();
    _syncAfterChange();
  }
  Future<void> _showAddDialog({
    String? initialTitle,
    Urgency? initialUrgency,
    DateTime? initialPlanStartAt,
    DateTime? initialDueAt,
    String? initialScreenshotPath,
  }) async {
    final titleCtrl = TextEditingController(text: initialTitle ?? '');
    Urgency urgency = initialUrgency ?? Urgency.normal;
    int taskType = 1; // 0个人任务 1工作任务，默认工作任务
    int repeatType = 0; // 0正常 1日任务 2周任务 3月任务
    List<int> repeatWeekDays = [DateTime.monday];
    int repeatMonthDay = 1;
    DateTime? planStartAt = initialPlanStartAt;
    DateTime? dueAt = initialDueAt;
    // 待挂附件：新建任务此时还没有本地 id，先攒路径，创建成功后再收进附件库
    final pendingFiles = <String>[?initialScreenshotPath];

    await showDialog(
      context: context,
      // 路由名用于「记任务 / 记一笔」切换时定位并关闭本对话框
      routeSettings: const RouteSettings(name: _quickDialogRouteName),
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: const Text('新建任务', style: TextStyle(fontSize: 16)),
          content: SizedBox(
            width: 360,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Container(
                    constraints: const BoxConstraints(minHeight: 100),
                    child: _ImeSafeTextField(
                      controller: titleCtrl,
                      hintText: '输入任务内容（每行以 1. 2. - 开头即为子任务）',
                      autofocus: true,
                    ),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    '提示：每行以 1. 2. 或 - 开头即为子任务，勾选表示完成。'
                    '其中 1. 2. 保留编号显示，- 不显示编号。',
                    style: TextStyle(fontSize: 11, color: GlassPalette.of(context).inkTertiary),
                  ),
                  const SizedBox(height: 16),
                  Text(
                    '紧急程度',
                    style: TextStyle(fontSize: 13, color: GlassPalette.of(context).inkTertiary),
                  ),
                  const SizedBox(height: 8),
                  Row(
                    children: Urgency.values.map((u) {
                      final selected = urgency == u;
                      final label = u == Urgency.normal
                          ? '一般'
                          : u == Urgency.urgent
                          ? '紧急'
                          : '重要';
                      return Expanded(
                        child: GestureDetector(
                          onTap: () => setDialogState(() => urgency = u),
                          child: Container(
                            margin: const EdgeInsets.symmetric(horizontal: 3),
                            padding: const EdgeInsets.symmetric(vertical: 8),
                            decoration: BoxDecoration(
                              color: selected
                                  ? TaskCard.urgencyColors(GlassPalette.of(context))[u]!.withValues(
                                      alpha: 0.15,
                                    )
                                  : GlassPalette.of(context).fieldBg,
                              borderRadius: BorderRadius.circular(8),
                              border: Border.all(
                                color: selected
                                    ? TaskCard.urgencyColors(GlassPalette.of(context))[u]!
                                    : GlassPalette.of(context).fieldBorder,
                                width: selected ? 1.5 : 1,
                              ),
                            ),
                            child: Row(
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                Container(
                                  width: 8,
                                  height: 8,
                                  decoration: BoxDecoration(
                                    color: TaskCard.urgencyColors(GlassPalette.of(context))[u],
                                    shape: BoxShape.circle,
                                  ),
                                ),
                                const SizedBox(width: 6),
                                Text(
                                  label,
                                  style: TextStyle(
                                    fontSize: 12,
                                    color: selected
                                        ? GlassPalette.of(context).ink
                                        : GlassPalette.of(context).inkTertiary,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      );
                    }).toList(),
                  ),
                  const SizedBox(height: 16),
                  Text(
                    '任务类型',
                    style: TextStyle(fontSize: 13, color: GlassPalette.of(context).inkTertiary),
                  ),
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      Expanded(
                        child: GestureDetector(
                          onTap: () => setDialogState(() => taskType = 0),
                          child: Container(
                            margin: const EdgeInsets.symmetric(horizontal: 3),
                            padding: const EdgeInsets.symmetric(vertical: 8),
                            decoration: BoxDecoration(
                              color: taskType == 0
                                  ? const Color(
                                      0xFF10B981,
                                    ).withValues(alpha: 0.15)
                                  : GlassPalette.of(context).fieldBg,
                              borderRadius: BorderRadius.circular(8),
                              border: Border.all(
                                color: taskType == 0
                                    ? GlassPalette.of(context).urgencyNormal
                                    : GlassPalette.of(context).fieldBorder,
                                width: taskType == 0 ? 1.5 : 1,
                              ),
                            ),
                            child: Row(
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                Container(
                                  width: 8,
                                  height: 8,
                                  decoration: BoxDecoration(
                                    color: GlassPalette.of(context).urgencyNormal,
                                    shape: BoxShape.circle,
                                  ),
                                ),
                                const SizedBox(width: 6),
                                Text(
                                  '个人任务',
                                  style: TextStyle(
                                    fontSize: 12,
                                    color: taskType == 0
                                        ? GlassPalette.of(context).ink
                                        : GlassPalette.of(context).inkTertiary,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                      Expanded(
                        child: GestureDetector(
                          onTap: () => setDialogState(() => taskType = 1),
                          child: Container(
                            margin: const EdgeInsets.symmetric(horizontal: 3),
                            padding: const EdgeInsets.symmetric(vertical: 8),
                            decoration: BoxDecoration(
                              color: taskType == 1
                                  ? const Color(
                                      0xFF3B82F6,
                                    ).withValues(alpha: 0.15)
                                  : GlassPalette.of(context).fieldBg,
                              borderRadius: BorderRadius.circular(8),
                              border: Border.all(
                                color: taskType == 1
                                    ? GlassPalette.of(context).accent
                                    : GlassPalette.of(context).fieldBorder,
                                width: taskType == 1 ? 1.5 : 1,
                              ),
                            ),
                            child: Row(
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                Container(
                                  width: 8,
                                  height: 8,
                                  decoration: BoxDecoration(
                                    color: GlassPalette.of(context).accent,
                                    shape: BoxShape.circle,
                                  ),
                                ),
                                const SizedBox(width: 6),
                                Text(
                                  '工作任务',
                                  style: TextStyle(
                                    fontSize: 12,
                                    color: taskType == 1
                                        ? GlassPalette.of(context).ink
                                        : GlassPalette.of(context).inkTertiary,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 16),
                  Text(
                    '任务类别',
                    style: TextStyle(fontSize: 13, color: GlassPalette.of(context).inkTertiary),
                  ),
                  const SizedBox(height: 8),
                  Row(
                    children: [0, 1, 2, 3].map((rt) {
                      final selected = repeatType == rt;
                      final label = rt == 0
                          ? '正常'
                          : rt == 1
                          ? '日任务'
                          : rt == 2
                          ? '周任务'
                          : '月任务';
                      final color = GlassPalette.of(context).accent;
                      return Expanded(
                        child: GestureDetector(
                          onTap: () => setDialogState(() {
                            repeatType = rt;
                            if (rt > 0 && planStartAt == null && dueAt == null) {
                              final now = DateTime.now();
                              planStartAt = DateTime(now.year, now.month, now.day, 9, 0);
                              dueAt = rt == 1
                                  ? DateTime(now.year, now.month, now.day, 23, 59)
                                  : DateTime(now.year, now.month, now.day, 18, 0);
                            }
                          }),
                          child: Container(
                            margin: const EdgeInsets.symmetric(horizontal: 3),
                            padding: const EdgeInsets.symmetric(vertical: 8),
                            decoration: BoxDecoration(
                              color: selected
                                  ? color.withValues(alpha: 0.15)
                                  : GlassPalette.of(context).fieldBg,
                              borderRadius: BorderRadius.circular(8),
                              border: Border.all(
                                color: selected ? color : GlassPalette.of(context).fieldBorder,
                                width: selected ? 1.5 : 1,
                              ),
                            ),
                            child: Row(
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                Container(
                                  width: 8,
                                  height: 8,
                                  decoration: BoxDecoration(
                                    color: color,
                                    shape: BoxShape.circle,
                                  ),
                                ),
                                const SizedBox(width: 6),
                                Text(
                                  label,
                                  style: TextStyle(
                                    fontSize: 12,
                                    color: selected ? GlassPalette.of(context).ink : GlassPalette.of(context).inkTertiary,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      );
                    }).toList(),
                  ),
                  if (repeatType == 2) ...[
                    const SizedBox(height: 12),
                    Text(
                      '每周重复（可多选）',
                      style: TextStyle(fontSize: 12, color: GlassPalette.of(context).inkTertiary),
                    ),
                    const SizedBox(height: 6),
                    Wrap(
                      spacing: 6,
                      runSpacing: 6,
                      children: [1, 2, 3, 4, 5, 6, 7].map((wd) {
                        final selected = repeatWeekDays.contains(wd);
                        final wdLabel = ['一', '二', '三', '四', '五', '六', '日'][wd - 1];
                        return GestureDetector(
                          onTap: () => setDialogState(() {
                            if (selected) {
                              repeatWeekDays = List.of(repeatWeekDays)..remove(wd);
                              if (repeatWeekDays.isEmpty) repeatWeekDays = [wd];
                            } else {
                              repeatWeekDays = List.of(repeatWeekDays)..add(wd);
                              repeatWeekDays.sort();
                            }
                          }),
                          child: Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 10,
                              vertical: 5,
                            ),
                            decoration: BoxDecoration(
                              color: selected
                                  ? GlassPalette.of(context).accent.withValues(alpha: 0.15)
                                  : GlassPalette.of(context).fieldBg,
                              borderRadius: BorderRadius.circular(6),
                              border: Border.all(
                                color: selected
                                    ? GlassPalette.of(context).accent
                                    : GlassPalette.of(context).fieldBorder,
                                width: selected ? 1.5 : 1,
                              ),
                            ),
                            child: Text(
                              '周$wdLabel',
                              style: TextStyle(
                                fontSize: 11,
                                color: selected ? GlassPalette.of(context).accent : GlassPalette.of(context).inkTertiary,
                              ),
                            ),
                          ),
                        );
                      }).toList(),
                    ),
                  ],
                  if (repeatType == 3) ...[
                    const SizedBox(height: 12),
                    Row(
                      children: [
                        Text(
                          '每月',
                          style: TextStyle(fontSize: 12, color: GlassPalette.of(context).inkTertiary),
                        ),
                        DropdownButton<int>(
                          value: repeatMonthDay,
                          style: TextStyle(fontSize: 12, color: GlassPalette.of(context).ink),
                          items: [
                            for (var i = 1; i <= 31; i++)
                              DropdownMenuItem(
                                value: i,
                                child: Text('$i 号', style: const TextStyle(fontSize: 12)),
                              ),
                          ],
                          onChanged: (v) =>
                              setDialogState(() => repeatMonthDay = v ?? 1),
                        ),
                      ],
                    ),
                    Padding(
                      padding: EdgeInsets.only(top: 4, left: 2),
                      child: Text(
                        '提示：小月（2/4/6/9/11）没有这一天时，自动取当月最后一天。',
                        style: TextStyle(fontSize: 11, color: GlassPalette.of(context).inkTertiary),
                      ),
                    ),
                  ],
                  if (repeatType == 1) ...[
                    const SizedBox(height: 10),
                    Text(
                      '每天自动生成新的一期，时间可自定义',
                      style: TextStyle(fontSize: 12, color: GlassPalette.of(context).inkTertiary),
                    ),
                  ],
                  const SizedBox(height: 16),
                  _buildTimeRow(
                    context,
                    setDialogState,
                    '计划开始',
                    planStartAt,
                    (v) => setDialogState(() => planStartAt = v),
                    maxTime: dueAt,
                  ),
                  const SizedBox(height: 8),
                  _buildTimeRow(
                    context,
                    setDialogState,
                    '预计完成',
                    dueAt,
                    (v) => setDialogState(() => dueAt = v),
                    minTime: planStartAt,
                  ),
                  PendingAttachmentPicker(
                    paths: pendingFiles,
                    remaining: kAttachmentMaxPerParent - pendingFiles.length,
                    onPick: () => _pickPending(pendingFiles, setDialogState),
                    onRemove: (path) => setDialogState(() => pendingFiles.remove(path)),
                  ),
                ],
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('取消'),
            ),
            ElevatedButton(
              onPressed: () async {
                final title = titleCtrl.text.trim();
                if (title.isEmpty) return;
                final sortOrder = await _nextSortOrder(TaskStatus.planned);
                final now = DateTime.now();
                // 循环任务：生成族ID + 初始实例日期，并把时间重定位到实例日期
                String? groupId;
                DateTime? instanceDate;
                if (repeatType > 0) {
                  groupId = _genRepeatGroupId();
                  instanceDate = RepeatTaskEngine.initialInstanceDate(
                    repeatType: repeatType,
                    weekDays: repeatWeekDays,
                    monthDay: repeatMonthDay,
                    now: now,
                  );
                  planStartAt = _timeOnDate(planStartAt, instanceDate);
                  dueAt = _timeOnDate(dueAt, instanceDate);
                }
                final newTaskId = await _repo.insertTask(
                  Task(
                    title: title,
                    urgency: urgency,
                    taskType: taskType,
                    createdAt: now,
                    planStartAt: planStartAt,
                    dueAt: dueAt,
                    sortOrder: sortOrder,
                    repeatType: repeatType,
                    repeatWeekDays: repeatType == 2 ? List.of(repeatWeekDays) : null,
                    repeatMonthDay: repeatType == 3 ? repeatMonthDay : null,
                    repeatGroupId: groupId,
                    instanceDate: instanceDate,
                  ),
                );
                // 循环任务：写入独立规则（删除实例不影响后续生成）
                if (repeatType > 0 && groupId != null) {
                  await _repo.putRepeatRule(
                    RepeatRule(
                      repeatGroupId: groupId,
                      title: title,
                      urgency: urgency,
                      taskType: taskType,
                      repeatType: repeatType,
                      repeatWeekDays:
                          repeatType == 2 ? List.of(repeatWeekDays) : null,
                      repeatMonthDay: repeatType == 3 ? repeatMonthDay : null,
                      planStartAt: planStartAt,
                      dueAt: dueAt,
                    ),
                  );
                }
                if (context.mounted) Navigator.pop(context);
                _loadTasks();
                _syncAfterChange();
                await _attachPaths(
                  Attachment.kindTask,
                  newTaskId,
                  pendingFiles,
                  screenshots: {?initialScreenshotPath},
                );
              },
              style: ElevatedButton.styleFrom(
                backgroundColor: GlassPalette.of(context).accent,
                foregroundColor: Colors.white,
              ),
              child: const Text('创建'),
            ),
          ],
        ),
      ),
    );
  }

  /// 双击卡片进入编辑：可改内容、状态、紧急程度
  Future<void> _showEditDialog(Task task) async {
    final titleCtrl = TextEditingController(text: task.title);
    Urgency urgency = task.urgency;
    TaskStatus status = task.status;
    int taskType = task.taskType;
    int repeatType = task.repeatType;
    // 空集合（脏数据）会让周任务一个都没选中，退回周一
    List<int> repeatWeekDays = (task.repeatWeekDays?.isNotEmpty ?? false)
        ? List.of(task.repeatWeekDays!)
        : [DateTime.monday];
    int repeatMonthDay = task.repeatMonthDay ?? 1;
    DateTime? planStartAt = task.planStartAt;
    DateTime? dueAt = task.dueAt;
    final pendingFiles = <String>[]; // 本次新挑的文件，保存成功后才收进附件库
    final attachedCount = (_taskAttachments[task.id] ?? const <AttachmentView>[]).length;

    await showDialog(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('编辑任务', style: TextStyle(fontSize: 16)),
              if (repeatType > 0)
                Padding(
                  padding: EdgeInsets.only(top: 4),
                  child: Text(
                    '循环任务的改动会应用到后续期次（历史期次保持原样）',
                    style: TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.normal,
                      color: GlassPalette.of(context).inkTertiary,
                    ),
                  ),
                ),
            ],
          ),
          content: SizedBox(
            width: 360,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Container(
                    constraints: const BoxConstraints(minHeight: 100),
                    child: _ImeSafeTextField(
                      controller: titleCtrl,
                      hintText: '输入任务内容（每行以 1. 2. - 开头即为子任务）',
                    ),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    '提示：每行以 1. 2. 或 - 开头即为子任务，勾选表示完成。'
                    '其中 1. 2. 保留编号显示，- 不显示编号。',
                    style: TextStyle(fontSize: 11, color: GlassPalette.of(context).inkTertiary),
                  ),
                  const SizedBox(height: 16),
                  Text(
                    '当前状态',
                    style: TextStyle(fontSize: 13, color: GlassPalette.of(context).inkTertiary),
                  ),
                  const SizedBox(height: 8),
                  Row(
                    children: TaskStatus.values.map((s) {
                      final selected = status == s;
                      final label = s == TaskStatus.planned
                          ? '计划中'
                          : s == TaskStatus.executing
                          ? '执行中'
                          : '已完成';
                      final color = TaskCard.statusColors(GlassPalette.of(context))[s]!;
                      return Expanded(
                        child: GestureDetector(
                          onTap: () => setDialogState(() => status = s),
                          child: Container(
                            margin: const EdgeInsets.symmetric(horizontal: 3),
                            padding: const EdgeInsets.symmetric(vertical: 8),
                            decoration: BoxDecoration(
                              color: selected
                                  ? color.withValues(alpha: 0.15)
                                  : GlassPalette.of(context).fieldBg,
                              borderRadius: BorderRadius.circular(8),
                              border: Border.all(
                                color: selected ? color : GlassPalette.of(context).fieldBorder,
                                width: selected ? 1.5 : 1,
                              ),
                            ),
                            child: Center(
                              child: Text(
                                label,
                                style: TextStyle(
                                  fontSize: 12,
                                  color: selected ? GlassPalette.of(context).ink : GlassPalette.of(context).inkTertiary,
                                ),
                              ),
                            ),
                          ),
                        ),
                      );
                    }).toList(),
                  ),
                  const SizedBox(height: 16),
                  Text(
                    '紧急程度',
                    style: TextStyle(fontSize: 13, color: GlassPalette.of(context).inkTertiary),
                  ),
                  const SizedBox(height: 8),
                  Row(
                    children: Urgency.values.map((u) {
                      final selected = urgency == u;
                      final label = u == Urgency.normal
                          ? '一般'
                          : u == Urgency.urgent
                          ? '紧急'
                          : '重要';
                      return Expanded(
                        child: GestureDetector(
                          onTap: () => setDialogState(() => urgency = u),
                          child: Container(
                            margin: const EdgeInsets.symmetric(horizontal: 3),
                            padding: const EdgeInsets.symmetric(vertical: 8),
                            decoration: BoxDecoration(
                              color: selected
                                  ? TaskCard.urgencyColors(GlassPalette.of(context))[u]!.withValues(
                                      alpha: 0.15,
                                    )
                                  : GlassPalette.of(context).fieldBg,
                              borderRadius: BorderRadius.circular(8),
                              border: Border.all(
                                color: selected
                                    ? TaskCard.urgencyColors(GlassPalette.of(context))[u]!
                                    : GlassPalette.of(context).fieldBorder,
                                width: selected ? 1.5 : 1,
                              ),
                            ),
                            child: Row(
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                Container(
                                  width: 8,
                                  height: 8,
                                  decoration: BoxDecoration(
                                    color: TaskCard.urgencyColors(GlassPalette.of(context))[u],
                                    shape: BoxShape.circle,
                                  ),
                                ),
                                const SizedBox(width: 6),
                                Text(
                                  label,
                                  style: TextStyle(
                                    fontSize: 12,
                                    color: selected
                                        ? GlassPalette.of(context).ink
                                        : GlassPalette.of(context).inkTertiary,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      );
                    }).toList(),
                  ),
                  const SizedBox(height: 16),
                  Text(
                    '任务类型',
                    style: TextStyle(fontSize: 13, color: GlassPalette.of(context).inkTertiary),
                  ),
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      Expanded(
                        child: GestureDetector(
                          onTap: () => setDialogState(() => taskType = 0),
                          child: Container(
                            margin: const EdgeInsets.symmetric(horizontal: 3),
                            padding: const EdgeInsets.symmetric(vertical: 8),
                            decoration: BoxDecoration(
                              color: taskType == 0
                                  ? const Color(
                                      0xFF10B981,
                                    ).withValues(alpha: 0.15)
                                  : GlassPalette.of(context).fieldBg,
                              borderRadius: BorderRadius.circular(8),
                              border: Border.all(
                                color: taskType == 0
                                    ? GlassPalette.of(context).urgencyNormal
                                    : GlassPalette.of(context).fieldBorder,
                                width: taskType == 0 ? 1.5 : 1,
                              ),
                            ),
                            child: Row(
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                Container(
                                  width: 8,
                                  height: 8,
                                  decoration: BoxDecoration(
                                    color: GlassPalette.of(context).urgencyNormal,
                                    shape: BoxShape.circle,
                                  ),
                                ),
                                const SizedBox(width: 6),
                                Text(
                                  '个人任务',
                                  style: TextStyle(
                                    fontSize: 12,
                                    color: taskType == 0
                                        ? GlassPalette.of(context).ink
                                        : GlassPalette.of(context).inkTertiary,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                      Expanded(
                        child: GestureDetector(
                          onTap: () => setDialogState(() => taskType = 1),
                          child: Container(
                            margin: const EdgeInsets.symmetric(horizontal: 3),
                            padding: const EdgeInsets.symmetric(vertical: 8),
                            decoration: BoxDecoration(
                              color: taskType == 1
                                  ? const Color(
                                      0xFF3B82F6,
                                    ).withValues(alpha: 0.15)
                                  : GlassPalette.of(context).fieldBg,
                              borderRadius: BorderRadius.circular(8),
                              border: Border.all(
                                color: taskType == 1
                                    ? GlassPalette.of(context).accent
                                    : GlassPalette.of(context).fieldBorder,
                                width: taskType == 1 ? 1.5 : 1,
                              ),
                            ),
                            child: Row(
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                Container(
                                  width: 8,
                                  height: 8,
                                  decoration: BoxDecoration(
                                    color: GlassPalette.of(context).accent,
                                    shape: BoxShape.circle,
                                  ),
                                ),
                                const SizedBox(width: 6),
                                Text(
                                  '工作任务',
                                  style: TextStyle(
                                    fontSize: 12,
                                    color: taskType == 1
                                        ? GlassPalette.of(context).ink
                                        : GlassPalette.of(context).inkTertiary,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 16),
                  Text(
                    '任务类别',
                    style: TextStyle(fontSize: 13, color: GlassPalette.of(context).inkTertiary),
                  ),
                  const SizedBox(height: 8),
                  Row(
                    children: [0, 1, 2, 3].map((rt) {
                      final selected = repeatType == rt;
                      final label = rt == 0
                          ? '正常'
                          : rt == 1
                          ? '日任务'
                          : rt == 2
                          ? '周任务'
                          : '月任务';
                      final color = GlassPalette.of(context).accent;
                      return Expanded(
                        child: GestureDetector(
                          onTap: () => setDialogState(() {
                            repeatType = rt;
                            if (rt > 0 && planStartAt == null && dueAt == null) {
                              final now = DateTime.now();
                              planStartAt = DateTime(now.year, now.month, now.day, 9, 0);
                              dueAt = rt == 1
                                  ? DateTime(now.year, now.month, now.day, 23, 59)
                                  : DateTime(now.year, now.month, now.day, 18, 0);
                            }
                          }),
                          child: Container(
                            margin: const EdgeInsets.symmetric(horizontal: 3),
                            padding: const EdgeInsets.symmetric(vertical: 8),
                            decoration: BoxDecoration(
                              color: selected
                                  ? color.withValues(alpha: 0.15)
                                  : GlassPalette.of(context).fieldBg,
                              borderRadius: BorderRadius.circular(8),
                              border: Border.all(
                                color: selected ? color : GlassPalette.of(context).fieldBorder,
                                width: selected ? 1.5 : 1,
                              ),
                            ),
                            child: Row(
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                Container(
                                  width: 8,
                                  height: 8,
                                  decoration: BoxDecoration(
                                    color: color,
                                    shape: BoxShape.circle,
                                  ),
                                ),
                                const SizedBox(width: 6),
                                Text(
                                  label,
                                  style: TextStyle(
                                    fontSize: 12,
                                    color: selected ? GlassPalette.of(context).ink : GlassPalette.of(context).inkTertiary,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      );
                    }).toList(),
                  ),
                  if (repeatType == 2) ...[
                    const SizedBox(height: 12),
                    Text(
                      '每周重复（可多选）',
                      style: TextStyle(fontSize: 12, color: GlassPalette.of(context).inkTertiary),
                    ),
                    const SizedBox(height: 6),
                    Wrap(
                      spacing: 6,
                      runSpacing: 6,
                      children: [1, 2, 3, 4, 5, 6, 7].map((wd) {
                        final selected = repeatWeekDays.contains(wd);
                        final wdLabel = ['一', '二', '三', '四', '五', '六', '日'][wd - 1];
                        return GestureDetector(
                          onTap: () => setDialogState(() {
                            if (selected) {
                              repeatWeekDays = List.of(repeatWeekDays)..remove(wd);
                              if (repeatWeekDays.isEmpty) repeatWeekDays = [wd];
                            } else {
                              repeatWeekDays = List.of(repeatWeekDays)..add(wd);
                              repeatWeekDays.sort();
                            }
                          }),
                          child: Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 10,
                              vertical: 5,
                            ),
                            decoration: BoxDecoration(
                              color: selected
                                  ? GlassPalette.of(context).accent.withValues(alpha: 0.15)
                                  : GlassPalette.of(context).fieldBg,
                              borderRadius: BorderRadius.circular(6),
                              border: Border.all(
                                color: selected
                                    ? GlassPalette.of(context).accent
                                    : GlassPalette.of(context).fieldBorder,
                                width: selected ? 1.5 : 1,
                              ),
                            ),
                            child: Text(
                              '周$wdLabel',
                              style: TextStyle(
                                fontSize: 11,
                                color: selected ? GlassPalette.of(context).accent : GlassPalette.of(context).inkTertiary,
                              ),
                            ),
                          ),
                        );
                      }).toList(),
                    ),
                  ],
                  if (repeatType == 3) ...[
                    const SizedBox(height: 12),
                    Row(
                      children: [
                        Text(
                          '每月',
                          style: TextStyle(fontSize: 12, color: GlassPalette.of(context).inkTertiary),
                        ),
                        DropdownButton<int>(
                          value: repeatMonthDay,
                          style: TextStyle(fontSize: 12, color: GlassPalette.of(context).ink),
                          items: [
                            for (var i = 1; i <= 31; i++)
                              DropdownMenuItem(
                                value: i,
                                child: Text('$i 号', style: const TextStyle(fontSize: 12)),
                              ),
                          ],
                          onChanged: (v) =>
                              setDialogState(() => repeatMonthDay = v ?? 1),
                        ),
                      ],
                    ),
                    Padding(
                      padding: EdgeInsets.only(top: 4, left: 2),
                      child: Text(
                        '提示：小月（2/4/6/9/11）没有这一天时，自动取当月最后一天。',
                        style: TextStyle(fontSize: 11, color: GlassPalette.of(context).inkTertiary),
                      ),
                    ),
                  ],
                  if (repeatType == 1) ...[
                    const SizedBox(height: 10),
                    Text(
                      '每天自动生成新的一期，时间可自定义',
                      style: TextStyle(fontSize: 12, color: GlassPalette.of(context).inkTertiary),
                    ),
                  ],
                  const SizedBox(height: 16),
                  _buildTimeRow(
                    context,
                    setDialogState,
                    '计划开始',
                    planStartAt,
                    (v) => setDialogState(() => planStartAt = v),
                    maxTime: dueAt,
                  ),
                  const SizedBox(height: 8),
                  _buildTimeRow(
                    context,
                    setDialogState,
                    '预计完成',
                    dueAt,
                    (v) => setDialogState(() => dueAt = v),
                    minTime: planStartAt,
                  ),
                  PendingAttachmentPicker(
                    paths: pendingFiles,
                    remaining: kAttachmentMaxPerParent - attachedCount - pendingFiles.length,
                    onPick: () => _pickPending(
                      pendingFiles,
                      setDialogState,
                      existing: attachedCount,
                    ),
                    onRemove: (path) => setDialogState(() => pendingFiles.remove(path)),
                  ),
                ],
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('取消'),
            ),
            ElevatedButton(
              onPressed: () async {
                final title = titleCtrl.text.trim();
                if (title.isEmpty) return;
                final now = DateTime.now();
                var updated = task.copyWith(
                  title: title,
                  urgency: urgency,
                  status: status,
                  taskType: taskType,
                  planStartAt: planStartAt,
                  dueAt: dueAt,
                  clearPlanStartAt: planStartAt == null,
                  clearDueAt: dueAt == null,
                  updatedAt: now,
                );
                // 根据状态变化自动维护时间字段
                if (status == TaskStatus.planned) {
                  updated = updated.copyWith(
                    clearStartedAt: true,
                    clearCompletedAt: true,
                  );
                } else if (status == TaskStatus.executing) {
                  if (task.startedAt == null) {
                    updated = updated.copyWith(startedAt: now);
                  }
                  if (task.status == TaskStatus.completed) {
                    updated = updated.copyWith(clearCompletedAt: true);
                  }
                } else if (status == TaskStatus.completed) {
                  if (task.completedAt == null) {
                    updated = updated.copyWith(completedAt: now);
                  }
                }
                // 循环任务规则：升级为循环任务 / 修改规则 / 降级为正常任务
                // （规则与实例分离存储：删除实例不影响循环，改回"正常"才彻底取消）
                String? ruleGroupId; // 需要写入/更新规则的族
                String? stoppedGroupId; // 需要标记"已停止循环"的族
                if (repeatType > 0) {
                  if (task.repeatGroupId == null) {
                    // 普通任务 → 循环任务：本期作为第一期
                    final inst = RepeatTaskEngine.initialInstanceDate(
                      repeatType: repeatType,
                      weekDays: repeatWeekDays,
                      monthDay: repeatMonthDay,
                      now: now,
                    );
                    updated = updated.copyWith(
                      repeatType: repeatType,
                      repeatGroupId: _genRepeatGroupId(),
                      instanceDate: inst,
                      planStartAt: _timeOnDate(updated.planStartAt, inst),
                      dueAt: _timeOnDate(updated.dueAt, inst),
                    );
                    ruleGroupId = updated.repeatGroupId;
                  } else {
                    // 已有循环任务：仅更新规则与时间，实例日期保持不变
                    updated = updated.copyWith(
                      repeatType: repeatType,
                      repeatWeekDays:
                          repeatType == 2 ? List.of(repeatWeekDays) : null,
                      repeatMonthDay: repeatType == 3 ? repeatMonthDay : null,
                      clearRepeatWeekDays: repeatType != 2,
                      clearRepeatMonthDay: repeatType != 3,
                    );
                    ruleGroupId = task.repeatGroupId;
                  }
                } else {
                  // 改回正常任务：清除循环字段
                  updated = updated.copyWith(
                    repeatType: 0,
                    clearRepeatWeekDays: true,
                    clearRepeatMonthDay: true,
                    clearRepeatGroupId: true,
                    clearInstanceDate: true,
                  );
                  if (task.repeatGroupId != null) {
                    // 改回正常 = 停止循环：规则保留但标记 stopped（可在
                    // 「循环任务」里恢复），同时写本地哨兵，否则同族其它实例
                    // 会被引擎当成兜底模板，继续补生成新一期
                    stoppedGroupId = task.repeatGroupId;
                  }
                }
                // 覆盖写规则前先读旧规则：跳过记录与"已停止"状态必须保留，
                // 否则用户删过的期次会被重新放回来、已停止的族会被悄悄重启。
                final oldRules = await _repo.getRepeatRules();
                await _repo.updateTask(updated);
                // 同步循环规则库
                if (ruleGroupId != null) {
                  final old = oldRules[ruleGroupId];
                  await _repo.putRepeatRule(RepeatRule.fromTask(
                    updated,
                    skippedDates: old?.skippedDates ?? const <String>[],
                    stopped: old?.stopped ?? false,
                  ));
                }
                if (stoppedGroupId != null) {
                  // 规则不删除，只标记 stopped：这样「循环任务」里还能看到它并恢复
                  await _repo.stopRepeatGroup(stoppedGroupId);
                  AppLogger.instance.log('编辑任务设为正常，已停止循环族：$stoppedGroupId');
                }
                // 规则变更后把新配置同步到同族"未完成"的其它实例，
                // 否则卡片徽章会一半"每日"一半"每周"。
                if (ruleGroupId != null && repeatType > 0) {
                  await _syncFamilySchedule(
                    groupId: ruleGroupId,
                    exceptTaskId: task.id,
                    repeatType: repeatType,
                    weekDays: repeatWeekDays,
                    monthDay: repeatMonthDay,
                  );
                }
                if (context.mounted) Navigator.pop(context);
                _loadTasks();
                _syncAfterChange();
                await _attachPaths(Attachment.kindTask, task.id!, pendingFiles);
              },
              style: ElevatedButton.styleFrom(
                backgroundColor: GlassPalette.of(context).accent,
                foregroundColor: Colors.white,
              ),
              child: const Text('保存'),
            ),
          ],
        ),
      ),
    );
  }

  /// 把新的循环配置同步到同族"未完成"的其它实例。
  ///
  /// 只改 schedule 字段（repeatType / 星期 / 每月几号），不动标题、时间、状态；
  /// 已完成的历史期次保持原样——它们本来就是按旧规则发生的，改掉会让历史失真。
  Future<void> _syncFamilySchedule({
    required String groupId,
    required int? exceptTaskId,
    required int repeatType,
    required List<int> weekDays,
    required int monthDay,
  }) async {
    try {
      final all = await _repo.getTasks();
      final now = DateTime.now();
      var changed = 0;
      for (final t in all) {
        if (t.repeatGroupId != groupId) continue;
        if (t.id == exceptTaskId) continue; // 当前这条已在保存流程里更新过
        if (t.status == TaskStatus.completed) continue;
        if (RepeatTaskEngine.sameSchedule(
          t,
          repeatType: repeatType,
          weekDays: repeatType == 2 ? weekDays : null,
          monthDay: repeatType == 3 ? monthDay : null,
        )) {
          continue;
        }
        await _repo.updateTask(RepeatTaskEngine.applySchedule(
          t,
          repeatType: repeatType,
          weekDays: weekDays,
          monthDay: monthDay,
          now: now,
        ));
        changed++;
      }
      if (changed > 0) {
        AppLogger.instance.log('循环规则变更：同族 $changed 条未完成实例已同步配置');
      }
    } catch (e, st) {
      // 同族同步失败不影响本次编辑本身（当前这条已经保存好了）
      AppLogger.instance.error('同步同族循环配置失败', e, st);
    }
  }

  // ==================== 循环任务管理 ====================

  /// 打开「循环任务」管理页：集中查看 / 改规则 / 停止 / 恢复
  Future<void> _showRepeatManager() async {
    if (!mounted) return;
    await RepeatManagerDialog.show(
      context,
      load: _loadRepeatFamilies,
      onEditRule: _editFamilyRule,
      onStop: _stopFamily,
      onResume: _resumeFamily,
      onDelete: _deleteFamily,
    );
  }

  Future<List<RepeatFamilyInfo>> _loadRepeatFamilies() async {
    final tasks = await _repo.getTasks();
    final rules = await _repo.getRepeatRules();
    final skips = await _repo.getRepeatSkips();
    return RepeatFamily.build(
      tasks,
      rules,
      DateTime.now(),
      skips: skips,
    );
  }

  /// 只改规则：标题/时间沿用原规则，实例日期不动，未完成期次同步成新配置
  Future<void> _editFamilyRule(RepeatFamilyInfo info) async {
    final rules = await _repo.getRepeatRules();
    final old = rules[info.groupId];

    // 没有本地规则（换设备 / 老数据）时，用族内最早的一条实例当模板
    Task? template;
    if (old == null) {
      final all = await _repo.getTasks();
      for (final t in all) {
        if (t.repeatGroupId != info.groupId) continue;
        if (template == null || t.createdAt.isBefore(template.createdAt)) {
          template = t;
        }
      }
      if (template == null) return;
    }
    final base = old ?? RepeatRule.fromTask(template!);

    if (!mounted) return;
    final draft = await showRepeatRuleEditor(
      context,
      title: base.title,
      wasStopped: info.stopped,
      initial: RepeatRuleDraft(
        repeatType: info.repeatType,
        weekDays: info.weekDays ?? const <int>[DateTime.monday],
        monthDay: info.monthDay ?? 1,
      ),
    );
    if (draft == null || !mounted) return;

    final now = DateTime.now();
    await _repo.putRepeatRule(base.copyWith(
      repeatType: draft.repeatType,
      repeatWeekDays: draft.repeatType == 2 ? draft.weekDays : null,
      repeatMonthDay: draft.repeatType == 3 ? draft.monthDay : null,
      clearRepeatWeekDays: draft.repeatType != 2,
      clearRepeatMonthDay: draft.repeatType != 3,
      // 改规则视为"要它继续跑"，顺手把停止状态清掉
      stopped: false,
      updatedAt: now,
    ));
    await _repo.resumeRepeatGroup(info.groupId);
    await _syncFamilySchedule(
      groupId: info.groupId,
      exceptTaskId: null,
      repeatType: draft.repeatType,
      weekDays: draft.weekDays,
      monthDay: draft.monthDay,
    );
    AppLogger.instance.log('循环规则已更新：${info.groupId} → ${draft.repeatType}');
    await _loadTasks();
    _syncAfterChange();
  }

  Future<void> _stopFamily(RepeatFamilyInfo info) async {
    await _repo.stopRepeatGroup(info.groupId);
    await _loadTasks();
    _syncAfterChange();
  }

  Future<void> _resumeFamily(RepeatFamilyInfo info) async {
    await _repo.resumeRepeatGroup(info.groupId);
    await _loadTasks();
    _syncAfterChange();
  }

  /// 永久删除一个循环族：规则墓碑 + 全部期次 + 多端同步。
  ///
  /// 不能只删本地规则：下一轮同步会把规则带回来；也不能只删任务：
  /// 引擎会拿现存实例当模板继续补生成。墓碑 + 停止哨兵一起写，才是终态。
  Future<void> _deleteFamily(RepeatFamilyInfo info) async {
    final all = await _repo.getTasks();
    final members = all
        .where((t) => t.repeatGroupId == info.groupId)
        .toList(growable: false);

    // 没有本地规则的老数据，用最早的一条实例造墓碑。
    Task? template;
    for (final t in members) {
      if (template == null || t.createdAt.isBefore(template.createdAt)) {
        template = t;
      }
    }

    for (final t in members) {
      final id = t.id;
      if (id == null) continue;
      await _repo.deleteTask(id);
      // 永久删除整族：每一期的附件都转孤儿（同 _deleteTask 的口径）
      await AttachmentSyncService.instance
          .onParentDeleted(Attachment.kindTask, id);
      // 离线也排队：下次同步通知云端软删除
      await RemoteSyncService.recordLocalDeletion(id, t.remoteId);
    }

    final rules = await _repo.getRepeatRules();
    final existing = rules[info.groupId];
    final base =
        existing ?? (template == null ? null : RepeatRule.fromTask(template));
    if (base != null) {
      await _repo.putRepeatRule(base.copyWith(
        deleted: true,
        stopped: true,
        updatedAt: DateTime.now(),
      ));
    }
    // 本地跳过账本哨兵：即使规则被清理，生成引擎也不会再补这一族。
    await _repo.stopRepeatGroup(info.groupId);

    AppLogger.instance.log(
      '永久删除循环任务：${info.groupId}，实例 ${members.length} 条',
    );
    await _loadTasks();
    _syncAfterChange();
  }


  /// Markdown 渲染样式（与卡片风格统一）
  MarkdownStyleSheet _mdStyle(BuildContext context) {
    final base = MarkdownStyleSheet.fromTheme(Theme.of(context));
    return base.copyWith(
      p: TextStyle(fontSize: 15, height: 1.5, color: GlassPalette.of(context).ink),
      h1: TextStyle(fontSize: 18, height: 1.4, fontWeight: FontWeight.bold, color: GlassPalette.of(context).ink),
      h2: TextStyle(fontSize: 16.5, height: 1.4, fontWeight: FontWeight.bold, color: GlassPalette.of(context).ink),
      h3: TextStyle(fontSize: 15.5, height: 1.4, fontWeight: FontWeight.w600, color: GlassPalette.of(context).ink),
      h4: TextStyle(fontSize: 15.5, height: 1.4, fontWeight: FontWeight.w600, color: GlassPalette.of(context).ink),
      listBullet: TextStyle(fontSize: 15, height: 1.5, color: GlassPalette.of(context).ink),
      listBulletPadding: EdgeInsets.zero,
      listIndent: 20,
      // 和备忘纸卡保持一致：代码比正文小一档、用弱化灰，不抢视线；
      // 底色只由代码块负责，code 自己不再上底色。
      code: TextStyle(
          fontSize: 13,
          height: 1.45,
          color: GlassPalette.of(context).inkTertiary),
      codeblockDecoration: BoxDecoration(color: GlassPalette.of(context).fieldBg, borderRadius: BorderRadius.circular(6)),
      codeblockPadding: const EdgeInsets.all(8),
      blockquote: TextStyle(fontSize: 15, height: 1.5, color: GlassPalette.of(context).inkTertiary),
      blockquoteDecoration: BoxDecoration(
        color: GlassPalette.of(context).fieldBg,
        border: Border(left: BorderSide(color: GlassPalette.of(context).fieldBorder, width: 3)),
      ),
      blockquotePadding: const EdgeInsets.fromLTRB(10, 0, 10, 0),
    );
  }

  /// 备忘 Markdown 渲染：围栏代码块带复制按钮（卡片与预览共用）
  MarkdownBody _memoMarkdown(BuildContext context, String data) {
    final style = _mdStyle(context);
    return MarkdownBody(
      data: data,
      styleSheet: style,
      builders: {'pre': MemoCodeBlockBuilder(style)},
    );
  }

  @override
  Widget build(BuildContext context) {
    return Focus(
      autofocus: true,
      onKeyEvent: (node, event) {
        // 截图热键已迁移为系统级全局热键（HotkeyService），
        // 此处不再处理 Ctrl+Alt+A，避免全局热键与窗口内监听双重触发
        // F5 刷新看板数据：只在打开「我的数据」时接管，其它场景仍是浏览器习惯
        if (_showStatsView &&
            event is KeyDownEvent &&
            event.logicalKey == LogicalKeyboardKey.f5) {
          setState(() => _statsRefreshTick++);
          return KeyEventResult.handled;
        }
        return KeyEventResult.ignored;
      },
      child: MouseRegion(
        cursor: _isDragging
            ? SystemMouseCursors.click
            : SystemMouseCursors.basic,
        child: Scaffold(
          // 底板（浅灰 + 流动色晕）画在最外层，这里整页透明让玻璃卡片能透出底色。
          backgroundColor: Colors.transparent,
          appBar: AppBar(
            toolbarHeight: 0,
            centerTitle: false,
            elevation: 0,
            backgroundColor: Colors.transparent,
            surfaceTintColor: Colors.transparent,
            shadowColor: Colors.transparent,
            foregroundColor: GlassPalette.of(context).ink,
            bottom: PreferredSize(
              // 比原 48 高 12px：横向滚动容器会裁掉溢出内容，需要给
              // ChoiceChip 右上角的未读数角标留出空间（文字放大时也不裁）。
              preferredSize: const Size.fromHeight(60),
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 6,
                ),
                child: Row(
                  children: [
                    // 窄窗口（最小 420 逻辑宽度）下 chips 横向滚动，避免溢出。
                    // 桌面端 ScrollView 默认不响应鼠标拖拽，这里用自定义
                    // ScrollBehavior 放开鼠标/触控板，并支持滚轮左右滚动。
                    Expanded(
                      child: ScrollConfiguration(
                        behavior: _TabScrollBehavior(),
                        child: Listener(
                          onPointerSignal: _onTabBarPointerSignal,
                          child: SingleChildScrollView(
                            controller: _tabScrollCtrl,
                            scrollDirection: Axis.horizontal,
                            padding: const EdgeInsets.only(
                              right: 8,
                              top: 6,
                              bottom: 6,
                            ),
                            child: Row(
                              children: [
                                _chip(
                                  '计划中',
                                  TaskStatus.planned,
                                  Icons.event_note,
                                  _plannedChipKey,
                                  count: _counts[TaskStatus.planned] ?? 0,
                                ),
                                const SizedBox(width: 8),
                                _chip(
                                  '执行中',
                                  TaskStatus.executing,
                                  Icons.play_circle_outline,
                                  _executingChipKey,
                                  count: _counts[TaskStatus.executing] ?? 0,
                                ),
                                const SizedBox(width: 8),
                                // 备忘放在「执行中」和「已完成」之间：它是"记录"类
                                // 入口，和任务状态并列，比挤在最右边更容易点到。
                                _chip('备忘', null, Icons.note_alt_outlined,
                                    GlobalKey(),
                                    isMemoTab: true),
                                const SizedBox(width: 8),
                                _chip(
                                  '已完成',
                                  TaskStatus.completed,
                                  Icons.check_circle_outline,
                                  _completedChipKey,
                                ),
                                const SizedBox(width: 8),
                                _chip(
                                    '全部', null, Icons.grid_view, GlobalKey()),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(width: 4),
                    IconButton(
                      key: _settingsMenuKey,
                      icon: Icon(
                        Icons.settings,
                        size: 20,
                        color: GlassPalette.of(context).inkSecondary,
                      ),
                      onPressed: _showSettingsMenu,
                      tooltip: '设置',
                    ),
                  ],
                ),
              ),
            ),
          ),
          body: Stack(
            children: [
              _showStatsView
                  ? StatsScreen(
                      loadSnapshot: _loadStatsSnapshot,
                      onBack: _closeStatsView,
                      refreshTick: _statsRefreshTick,
                      initialRange: _statsRange,
                      onRangeChanged: (range) => _statsRange = range,
                      animateEntrance: true,
                      entranceController: _entranceCtrl,
                    )
                  : _showMemoView
                  ? _buildMemoView()
                  : _isPagedTab
                  ? _buildPagedTaskView()
                  : _tasks.isEmpty
                  ? Center(
                      child: Text(
                        '还没有任务，点击右下角 + 创建',
                        style: TextStyle(
                            color: GlassPalette.of(context).inkTertiary, fontSize: 14),
                      ),
                    )
                  : ListView.builder(
                      padding: const EdgeInsets.only(top: 8, bottom: 108),
                      itemCount: _tasks.length,
                      itemBuilder: (context, i) =>
                          _buildTaskItem(i, _tasks[i], _tasks.length),
                    ),
              // 左下角菜单按钮
              Positioned(
                left: 20,
                bottom: _showUpgradeBanner ? 80 : 20,
                child: _buildMenuButton(),
              ),
              // 右下角添加按钮
              Positioned(
                right: 20,
                bottom: _showUpgradeBanner ? 80 : 20,
                child: FloatingActionButton(
                  heroTag: 'addBtn',
                  onPressed: _showAddChoice,
                  backgroundColor: GlassPalette.of(context).accent,
                  child: const Icon(Icons.add, color: Colors.white),
                ),
              ),
              // 底部升级提示条（非模态，不打断用户）
              if (_showUpgradeBanner && UpgradeService.instance.latest != null)
                Positioned(
                  left: 0,
                  right: 0,
                  bottom: 0,
                  child: UpgradeBanner(
                    version: UpgradeService.instance.latest!,
                    downloading: _upgradeDownloading,
                    progress: _upgradeProgress,
                    onUpgrade: _applyUpgrade,
                    onDismiss: () {
                      // 下载中关闭 = 取消本次下载提示（后台下载仍继续，重启后可恢复）
                      setState(() {
                        _showUpgradeBanner = false;
                        _upgradeDownloading = false;
                      });
                    },
                  ),
                ),
              // 云端同步轻提示：底部居中、自动消失、不拦截操作
              if (_syncToastMsg != null)
                Positioned(
                  left: 0,
                  right: 0,
                  bottom: 90,
                  child: IgnorePointer(
                    child: Center(
                      child: AnimatedOpacity(
                        opacity: _syncToastVisible ? 1.0 : 0.0,
                        duration: const Duration(milliseconds: 220),
                        curve: Curves.easeOut,
                        child: AnimatedSlide(
                          offset: _syncToastVisible
                              ? Offset.zero
                              : const Offset(0, 0.35),
                          duration: const Duration(milliseconds: 220),
                          curve: Curves.easeOut,
                          child: Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 14,
                              vertical: 8,
                            ),
                            decoration: BoxDecoration(
                              // 提示条是浮在内容上的实色胶囊，不能用 shadow：
                              // 浅色档的 shadow 几乎透明，白字会直接消失在背景里。
                              color: GlassPalette.of(context)
                                  .opaqueControl
                                  .withValues(alpha: 0.94),
                              borderRadius: BorderRadius.circular(20),
                              border: Border.all(
                                  color: GlassPalette.of(context).cardBorder,
                                  width: 1),
                            ),
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Icon(
                                  _syncToastError
                                      ? Icons.cloud_off
                                      : Icons.cloud_done,
                                  size: 15,
                                  color: _syncToastError
                                      ? GlassPalette.of(context).dangerSoft
                                      : GlassPalette.of(context).successSoft,
                                ),
                                const SizedBox(width: 6),
                                Text(
                                  _syncToastMsg ?? '',
                                  style: TextStyle(
                                    fontSize: 12,
                                    color: GlassPalette.of(context).ink,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _chip(
    String label,
    TaskStatus? status,
    IconData icon,
    Key key, {
    int count = 0,
    bool isMemoTab = false,
  }) {
    // 备忘 Tab 激活时 _filter 也被置为 null，任务 Tab 必须排除备忘视图，
    // 否则「全部」会和「备忘」同时显示选中。
    final selected = !_showStatsView &&
        (isMemoTab ? _showMemoView : (!_showMemoView && _filter == status));
    void onTap() {
      if (isMemoTab) {
        setState(() {
          _showStatsView = false;
          _showMemoView = true;
          _filter = null;
        });
        _animateNextList = false;
        _animateNextMemo = true; // 备忘 tab：加载完成后重放入场动画
        _loadMemos();
      } else {
        setState(() {
          _showStatsView = false;
          _showMemoView = false;
          _filter = status;
        });
        // 切换任务 tab：重置搜索词、筛选条件和分页
        _taskSearchCtrl.clear();
        _filterUrgency = null;
        _filterType = null;
        _visibleCount = _pageSize;
        _animateNextList = true; // 切换任务 tab 后重放入场动画
        _loadTasks();
      }
    }

    return Stack(
      clipBehavior: Clip.none,
      children: [
        Semantics(
          button: true,
          selected: selected,
          child: MouseRegion(
            cursor: SystemMouseCursors.click,
            child: GestureDetector(
              key: key,
              onTap: onTap,
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 160),
                curve: Curves.easeOut,
                height: 32,
                padding: const EdgeInsets.symmetric(horizontal: 12),
                decoration: BoxDecoration(
                  color: selected
                      ? GlassPalette.of(context).accent
                      : GlassPalette.of(context).decoInk.withAlpha(16),
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(
                    color: selected
                        ? GlassPalette.of(context).decoInk.withAlpha(56)
                        : GlassPalette.of(context).chipBorder,
                  ),
                  boxShadow: selected
                      ? [
                          BoxShadow(
                            color: GlassPalette.of(context).accent.withAlpha(0x4D),
                            blurRadius: 14,
                            offset: Offset(0, 4),
                          ),
                        ]
                      : null,
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      icon,
                      size: 14,
                      color: selected ? Colors.white : GlassPalette.of(context).inkTertiary,
                    ),
                    const SizedBox(width: 4),
                    Text(
                      label,
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight:
                            selected ? FontWeight.w500 : FontWeight.w400,
                        color: selected
                            ? Colors.white
                            : GlassPalette.of(context).inkSecondary,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
        if (count > 0)
          Positioned(
            right: -6,
            top: -6,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
              decoration: BoxDecoration(
                color: selected ? Colors.white : GlassPalette.of(context).danger,
                borderRadius: BorderRadius.circular(10),
                border: Border.all(
                  color: selected ? GlassPalette.of(context).accent : Colors.white,
                  width: 1.5,
                ),
              ),
              child: Text(
                '$count',
                style: TextStyle(
                  fontSize: 10,
                  fontWeight: FontWeight.bold,
                  color: selected ? GlassPalette.of(context).accent : Colors.white,
                ),
              ),
            ),
          ),
      ],
    );
  }

  /// 左下角三条杠菜单按钮
  Widget _buildMenuButton() {
    return FloatingActionButton(
      key: _menuKey,
      heroTag: 'menuBtn',
      mini: true,
      onPressed: _showMainMenu,
      // 实色，不跟随背景透出：任务卡滚到按钮后面时不能看见卡片文字。
      backgroundColor: GlassPalette.of(context).opaqueControl,
      // 图标颜色必须跟着档走：浅色档的 opaqueControl 是白的，
      // 写死 Colors.white 就变成白底白杠，看不出这是个按钮。
      foregroundColor: GlassPalette.of(context).ink,
      elevation: 4,
      highlightElevation: 6,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: BorderSide(color: GlassPalette.of(context).decoInk.withAlpha(46)),
      ),
      child: const Icon(Icons.menu, size: 22),
    );
  }

  /// 主菜单：云端同步 / 截图 / 日报 / 周报
  void _showMainMenu() {
    // 未登录时直接弹登录界面，不再先弹菜单
    if (!AuthService.isLoggedIn) {
      _syncToCloud();
      return;
    }
    final box = _menuKey.currentContext?.findRenderObject() as RenderBox?;
    if (box == null) return;
    final pos = box.localToGlobal(Offset.zero);
    final size = box.size;

    _isMenuOpen = true;
    showMenu<dynamic>(
      context: context,
      position: RelativeRect.fromLTRB(
        pos.dx + size.width + 3,
        pos.dy,
        pos.dx + size.width + 223,
        pos.dy + 1,
      ),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      items: <PopupMenuEntry<dynamic>>[
        // 1. 云端同步
        PopupMenuItem(
          height: 42,
          onTap: _syncing ? null : _syncToCloud,
          child: Row(
            children: [
              Icon(
                AuthService.isLoggedIn
                    ? Icons.cloud_sync
                    : Icons.cloud_outlined,
                size: 18,
                color: GlassPalette.of(context).accent,
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  AuthService.isLoggedIn ? '云端同步' : '登录(更多功能)',
                  style: TextStyle(fontSize: 13),
                ),
              ),
              if (_syncing)
                SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
            ],
          ),
        ),
        // 2. 截图识别任务
        if (AuthService.isLoggedIn)
          PopupMenuItem(
            height: 42,
            onTap: _startScreenshotRecognition,
            child: Row(
              children: [
                Icon(Icons.crop_free, size: 18, color: GlassPalette.of(context).accent),
                SizedBox(width: 10),
                Text('截图任务', style: TextStyle(fontSize: 13)),
                Spacer(),
                Text(
                  'Ctrl+Alt+A',
                  style: TextStyle(fontSize: 11, color: GlassPalette.of(context).inkTertiary),
                ),
              ],
            ),
          ),
        // 3. AI日报总结
        if (AuthService.isLoggedIn)
          PopupMenuItem(
            height: 42,
            onTap: () => _openSummary('day'),
            child: Row(
              children: [
                Icon(Icons.today, size: 18, color: GlassPalette.of(context).accent),
                SizedBox(width: 10),
                Text('AI日报总结', style: TextStyle(fontSize: 13)),
              ],
            ),
          ),
        // 4. AI周报总结
        if (AuthService.isLoggedIn)
          PopupMenuItem(
            height: 42,
            onTap: () => _openSummary('week'),
            child: Row(
              children: [
                Icon(Icons.date_range, size: 18, color: GlassPalette.of(context).accent),
                SizedBox(width: 10),
                Text('AI周报总结', style: TextStyle(fontSize: 13)),
              ],
            ),
          ),
        // 5. 额度详情（登录后显示）
        if (AuthService.isLoggedIn)
          PopupMenuItem(
            height: 42,
            onTap: _showQuotaDetail,
            child: Row(
              children: [
                Icon(Icons.insights, size: 18, color: GlassPalette.of(context).accent),
                SizedBox(width: 10),
                Text('额度详情', style: TextStyle(fontSize: 13)),
              ],
            ),
          ),
      ],
    ).then((_) => _isMenuOpen = false);
  }

/// 设置菜单：检查更新 / 关于我们 / 开机自启 / 任务提醒 / 退出登录 / 退出软件
  ///
  /// 菜单内容整体放进一个 PopupMenuEntry：点行只执行动作、菜单保持展开，
  /// 只有点菜单外区域、按 Esc 或窗口失焦时才收起。
  void _showSettingsMenu() {
    final box =
        _settingsMenuKey.currentContext?.findRenderObject() as RenderBox?;
    if (box == null) return;
    final pos = box.localToGlobal(Offset.zero);
    final size = box.size;

    _isMenuOpen = true;
    showMenu<dynamic>(
      context: context,
      position: RelativeRect.fromLTRB(
        pos.dx - 200,
        pos.dy + size.height + 5,
        pos.dx + size.width,
        pos.dy + size.height + 6,
      ),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      items: <PopupMenuEntry<dynamic>>[
        _SettingsMenuPanelEntry(
          child: _SettingsMenuPanel(
            hotkeyLabel: _hotkeyMenuLabel,
            onStats: _openStatsView,
            onRepeatManager: _showRepeatManager,
            onCheckUpdate: _checkUpdateManually,
            onAbout: _showAbout,
            onPickHotkey: _showHotkeyPicker,
            onQuickCapture: _onQuickCaptureHotkey,
            onLogout: () async {
              // 退出登录前先把未同步的变更推上云端
              _syncDebounce?.cancel();
              await _performSync(showToast: false);
              await AuthService.logout();
              SyncWebSocket.instance.disconnect();
              if (mounted) setState(() {});
            },
            onQuit: () => AppLifecycle.instance.quit(),
          ),
        ),
      ],
    ).then((_) => _isMenuOpen = false);
  }

  /// 截图热键选择：展示每个预置组合键的实时可用性，选中即生效。
  Future<void> _showHotkeyPicker() async {
    await HotkeyConflictDialog.show(context, pickerMode: true);
    if (mounted) setState(() {});
  }

  /// 设置菜单里显示的热键文案：未生效标红，自动降级时标注“临时”。
  String _hotkeyMenuLabel() {
    final service = HotkeyService.instance;
    final active = service.activeOption;
    if (active == null) return '未生效';
    if (service.status == HotkeyStatus.fallback) {
      return '${active.label}（临时）';
    }
    return active.label;
  }

  /// 鼠标滚轮在标签栏上时改为左右滚动。
  ///
  /// 横向 SingleChildScrollView 对垂直滚轮没有任何反应（它只取 dx），
  /// 这里把 dy 映射到横向偏移。横向滚轮/触控板滑动保持不变，交给
  /// ScrollView 自己处理，避免同一手势被处理两次。
  void _onTabBarPointerSignal(PointerSignalEvent event) {
    if (event is! PointerScrollEvent) return;
    final delta = event.scrollDelta.dy;
    if (delta == 0 || !_tabScrollCtrl.hasClients) return;
    var target = _tabScrollCtrl.position.pixels + delta;
    if (target < 0) target = 0;
    final maxExtent = _tabScrollCtrl.position.maxScrollExtent;
    if (target > maxExtent) target = maxExtent;
    if (target != _tabScrollCtrl.position.pixels) {
      _tabScrollCtrl.jumpTo(target);
    }
  }

  /// 打开 AI 工作日志总结对话框（当日 / 周）
  Future<void> _openSummary(String range) async {
    if (!AuthService.isLoggedIn) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('请先登录云端账号，再使用 AI 总结功能')));
      return;
    }
    final all = await _repo.getTasks();
    if (!mounted) return;
    await showDialog(
      context: context,
      builder: (_) => SummaryDialog(initialRange: range, allTasks: all),
    );
  }

  /// 截图识别任务：截图 → AI识别 → 打开新建任务对话框并自动填充
  Future<void> _startScreenshotRecognition() async {
    try {
      _screenshotLog('开始（独立窗口模式）');

      // 截图前先把主窗口藏起来：否则用户正好在用本应用时，截到的就是
      // 自己的界面（AI 会把界面上的文字当成任务内容）。
      var selfHidden = false;
      var wasVisible = true;
      if (Platform.isWindows) {
        try {
          wasVisible = await windowManager.isVisible() &&
              !await windowManager.isMinimized();
          if (wasVisible) {
            await windowManager.hide();
            selfHidden = true;
            // 给 DWM 一点时间真正把窗口从屏幕上撤下来
            await Future<void>.delayed(const Duration(milliseconds: 180));
          }
        } catch (_) {}
      }

      // 调用原生端开启截图：创建独立的全屏窗口进行区域选择
      String? croppedBase64;
      try {
        croppedBase64 = await ScreenshotService.startScreenshot();
      } finally {
        if (selfHidden) {
          try {
            await windowManager.show();
          } catch (_) {}
        }
      }
      _screenshotLog(
        '截图窗口返回, 空=${croppedBase64 == null || croppedBase64.isEmpty}',
      );

      if (croppedBase64 == null || croppedBase64.isEmpty) {
        return; // 用户取消
      }

      // 截到内容后要显示识别结果：窗口本来在托盘/最小化就先带出来，
      // 否则用户会在一个看不见的窗口里等 AI 返回。
      if (!wasVisible) {
        try {
          await AppLifecycle.instance.showWindow();
        } catch (_) {}
      }
      if (!mounted) return;

      final cropped = base64Decode(croppedBase64);

      // 2. 显示 AI 识别中加载框
      showDialog(
        context: context,
        barrierDismissible: false,
        builder: (_) => const AlertDialog(
          content: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              SizedBox(
                width: 24,
                height: 24,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
              SizedBox(width: 16),
              Text('AI 正在识别截图内容...', style: TextStyle(fontSize: 14)),
            ],
          ),
        ),
      );

      // 3. 调用 AI 识别接口
      List<RecognizedTask> recognized;
      try {
        recognized = await AiService.recognizeTasks(cropped);
      } catch (e) {
        if (mounted) Navigator.pop(context); // 关闭加载框
        _screenshotLog('AI识别失败: $e');
        if (!mounted) return;

        final errMsg = e.toString();
        // 限流错误弹出对话框提醒
        if (errMsg.contains('每分钟') ||
            errMsg.contains('今天') ||
            errMsg.contains('429')) {
          showDialog(
            context: context,
            builder: (_) => AlertDialog(
              title: const Text('使用提醒', style: TextStyle(fontSize: 16)),
              content: Text(errMsg, style: const TextStyle(fontSize: 14)),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(context),
                  child: const Text('知道了'),
                ),
              ],
            ),
          );
        } else {
          ScaffoldMessenger.of(
            context,
          ).showSnackBar(SnackBar(content: Text('AI 识别失败: $e')));
        }
        return;
      }

      if (mounted) Navigator.pop(context); // 关闭加载框

      if (recognized.isEmpty) {
        if (mounted) {
          ScaffoldMessenger.of(
            context,
          ).showSnackBar(const SnackBar(content: Text('未识别到任务内容')));
        }
        return;
      }

      if (!mounted) return;

      // 截图原件先落一个临时文件：识别出来的任务把它作为截图附件收进本机
      final screenshotPath = await _writeScreenshotTemp(cropped);
      if (!mounted) return;

      // 4. 分流：1 条直接进新建对话框；多条打开识别结果列表，勾选后批量创建
      if (recognized.length == 1) {
        final rt = recognized.first;
        final urgency = switch (rt.urgency) {
          '重要' => Urgency.important,
          '紧急' => Urgency.urgent,
          _ => Urgency.normal,
        };
        DateTime? planStart;
        DateTime? due;
        if (rt.planStartAt != null) {
          try {
            planStart = DateTime.parse(rt.planStartAt!);
          } catch (_) {}
        }
        if (rt.dueAt != null) {
          try {
            due = DateTime.parse(rt.dueAt!);
          } catch (_) {}
        }

        await _showAddDialog(
          initialTitle: rt.title,
          initialUrgency: urgency,
          initialPlanStartAt: planStart,
          initialDueAt: due,
          initialScreenshotPath: screenshotPath,
        );
      } else {
        // 多条：展示识别结果列表，用户可勾选/编辑后批量创建
        final selected = await showDialog<List<RecognizedTask>>(
          context: context,
          builder: (_) => RecognizeResultDialog(
            screenshot: cropped,
            initialTasks: recognized,
            onCreateTasks: (_) async => <Task>[],
          ),
        );
        if (selected == null || selected.isEmpty) return;

        for (final rt in selected) {
          final urgency = switch (rt.urgency) {
            '重要' => Urgency.important,
            '紧急' => Urgency.urgent,
            _ => Urgency.normal,
          };
          DateTime? planStart;
          DateTime? due;
          if (rt.planStartAt != null) {
            try {
              planStart = DateTime.parse(rt.planStartAt!);
            } catch (_) {}
          }
          if (rt.dueAt != null) {
            try {
              due = DateTime.parse(rt.dueAt!);
            } catch (_) {}
          }
          final sortOrder = await _nextSortOrder(TaskStatus.planned);
          final newTaskId = await _repo.insertTask(
            Task(
              title: rt.title,
              urgency: urgency,
              taskType: 1,
              createdAt: DateTime.now(),
              planStartAt: planStart,
              dueAt: due,
              sortOrder: sortOrder,
            ),
          );
          // 多条识别：每条任务都挂同一张截图
          if (screenshotPath != null) {
            await _attachPaths(
              Attachment.kindTask,
              newTaskId,
              [screenshotPath],
              screenshots: {screenshotPath},
            );
          }
        }
        _loadTasks();
        _syncAfterChange();
      }
    } catch (e, stack) {
      _screenshotLog('异常: $e\n$stack');
      // 上一次截图窗口还开着时再次触发热键：静默忽略，不打扰用户。
      if (e.toString().contains('已有截图窗口')) return;
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('截图识别失败: $e')));
      }
    }
  }

  /// 显示用户协议/隐私政策弹窗
  void _showAgreement(String type) {
    final isUser = type == 'user';
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(
          isUser ? '用户协议' : '隐私政策',
          style: const TextStyle(fontSize: 15),
        ),
        content: SizedBox(
          width: 500,
          height: 400,
          child: SingleChildScrollView(
            child: Text(
              isUser ? _userAgreementText : _privacyPolicyText,
              style: const TextStyle(fontSize: 12, height: 1.8),
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('关闭'),
          ),
        ],
      ),
    );
  }

  static const String _userAgreementText = '''欢迎使用极简工作日记！

1. 服务说明
本软件是一款个人任务管理工具，提供本地任务记录、云端同步、AI 总结、任务提醒等功能。

2. 账号与使用
- 您需要注册账号才能使用云端同步和 AI 功能
- 您应对自己的账号信息和任务内容负责
- 不得利用本软件从事违法违规活动

3. 功能限制
- AI 功能（截图识别、日报总结、周报总结）有每日使用次数限制
- 免费用户：截图识别 10 次/天，AI 日报 3 次/天，AI 周报 3 次/天

4. 免责声明
- 本软件按"现状"提供，不保证完全无故障
- 因网络故障、服务器维护等原因导致数据同步失败，开发者不承担数据丢失责任
- 重要数据请自行备份

5. 协议变更
开发者保留修改本协议的权利，修改后将在软件内提示。
''';

  static const String _privacyPolicyText = '''我们非常重视您的隐私。

1. 我们收集的信息
- 账号信息：邮箱地址（用于登录）
- 任务数据：您创建的任务标题、内容、时间等（存储在服务器）
- 使用日志：AI 功能调用次数、错误日志（用于服务改进）

2. 信息如何使用
- 任务数据：用于云端同步，让您在多设备间同步任务
- AI 功能：将您的任务内容发送给 AI 服务生成总结，生成后即删除
- 错误日志：仅用于排查问题，不会用于其他用途

3. 信息存储
- 任务数据存储在您自己的服务器上
- 我们不会将您的任务数据分享给任何第三方
- 我们不会将您的任务数据用于广告或其他商业用途

4. 您的权利
- 您可以随时删除自己的任务数据
- 您可以联系作者删除账号和所有数据

5. 联系我们
如有隐私相关问题，请联系作者微信：php100
''';

  /// 关于对话框：版式见 AppAboutDialog，协议正文仍留在本页。
  void _showAbout() {
    AppAboutDialog.show(context, onShowAgreement: _showAgreement);
  }

  /// 额度详情：显示登录用户 截图任务/AI日报总结/AI周报总结 的今日与本月使用情况
  void _showQuotaDetail() {
    showDialog(context: context, builder: (_) => const QuotaDetailDialog());
  }

  /// 手动 / 启动 / 登录成功后的同步入口（未登录时引导登录）
  Future<void> _syncToCloud() async {
    if (!AuthService.isLoggedIn) {
      Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) => LoginScreen(onLoginSuccess: _syncToCloud),
        ),
      );
      return;
    }
    await _performSync(showToast: true);
  }

  /// 本地数据变更后自动同步（任务/备忘共用）：登录才执行，防抖合并连续操作，不影响操作
  void _syncAfterChange() {
    if (!AuthService.isLoggedIn) return; // 未登录不做任何同步
    // 本地刚修改，3秒内忽略 WebSocket 推送的同步（避免覆盖刚创建的任务）
    _ignoreWsSyncUntil = DateTime.now().add(const Duration(seconds: 5));
    _syncDebounce?.cancel();
    _syncDebounce = Timer(
      const Duration(milliseconds: 1000),
      () => _performSync(showToast: true),
    );
  }

  /// 真正执行同步（并发保护：同步中又有变更则结束后补一次）
  Future<void> _performSync({required bool showToast}) async {
    if (!AuthService.isLoggedIn) return;
    // 登录可能是本次会话才完成的（initState 里只在启动时连过一次），
    // 这里补一次连接；已连接时是空操作。
    SyncWebSocket.instance.ensureConnected();
    if (_syncing) {
      _pendingSync = true;
      return;
    }
    setState(() => _syncing = true);
    try {
      // 记住本次同步开始的时间：这之后本地新建/修改的记录不在这次请求体里，
      // replaceAll 不能把它们当成"云端已删除"清掉。
      final syncStartedAt = DateTime.now();
      final allLocal = await _repo.getTasks();
      final localRules = await _repo.getRepeatRules();
      final result = await RemoteSyncService.syncTasks(
        AuthService.userId!,
        allLocal,
        repeatRules: localRules,
      );
      // 先落「云端已删除的循环实例」，再覆盖任务：这样紧随其后的
      // _loadTasks 补生成时就能跳过这些日期，不会把别的设备删掉的期补回来。
      await _repo.mergeRepeatSkips(result.skips);
      // 再落循环规则（含"已停止"状态）：换设备后规则不丢、停止能跨端生效
      await _repo.mergeRepeatRules(result.rules);
      // 再用本机账本过滤云端下发的实例：
      // - 本机已删掉的期次：别的设备补生成后又上传了，丢弃，否则会在本机复活
      // - 已停止循环的族：只保留本机已有的期次，新补出来的期次一律丢弃
      final skips = await _repo.getRepeatSkips();
      final incoming = RepeatTaskEngine.filterIncomingInstances(
        result.tasks,
        allLocal,
        skips: skips,
      );
      // 本轮收到永久删除墓碑时，云端可能还带着同族任务（旧服务端/删除尚未落库）。
      // mergeRepeatRules 已删过本地任务，这里再把它们从 replaceAll 的输入里剔掉，
      // 否则刚删掉的期次会被同一次同步写回来。
      final deletedGroups = result.rules.values
          .where((r) => r.deleted)
          .map((r) => r.repeatGroupId)
          .where((gid) => gid.isNotEmpty)
          .toSet();
      final incomingLive = deletedGroups.isEmpty
          ? incoming
          : incoming
              .where((t) =>
                  t.repeatGroupId == null ||
                  !deletedGroups.contains(t.repeatGroupId))
              .toList();
      await _repo.replaceAll(incomingLive, keepAfter: syncStartedAt);
      await _loadTasks();

      // 备忘同步（与任务同步并行通道，独立 box 独立接口）
      final localMemos = await _memoRepo.getMemos();
      final remoteMemos = await RemoteSyncService.syncMemos(
        AuthService.userId!,
        localMemos,
      );
      await _memoRepo.replaceAll(remoteMemos, keepAfter: syncStartedAt);
      await _loadMemos();

      // 附件元数据对账：必须排在任务/备忘之后，父记录的云端 id 是这两步才定下来的
      String? rejectedMsg;
      try {
        final taskLocalToRemote = <int, int>{
          for (final t in _allTasks)
            if (t.id != null && t.remoteId != null) t.id!: t.remoteId!,
        };
        final memoLocalToRemote = <int, int>{
          for (final m in _memos)
            if (m.id != null && m.remoteId != null) m.id!: m.remoteId!,
        };
        final summary = await AttachmentSyncService.instance.syncMetadata(
          taskLocalToRemote: taskLocalToRemote,
          memoLocalToRemote: memoLocalToRemote,
        );
        if (summary.hasRejections) {
          // 服务器拒收（类型/体积/数量超限）必须说出来，否则用户以为已经存好了
          final names = summary.rejectedNames.take(3).join('、');
          final more = summary.rejectedNames.length > 3
              ? ' 等 ${summary.rejectedNames.length} 个文件'
              : '';
          rejectedMsg = '附件未保存：$names$more';
        }
      } catch (e, st) {
        // 附件那一层失败不能把整次同步判成失败：任务与备忘已经落好了
        AppLogger.instance.error('附件元数据同步失败', e, st);
      }
      if (showToast && mounted) _showSyncToast('已同步到云端', error: false);
      if (rejectedMsg != null && mounted) {
        _showSyncToast(rejectedMsg, error: true, durationMs: 5000);
      }
    } catch (e) {
      if (mounted) _showSyncToast('同步失败', error: true);
    } finally {
      if (mounted) setState(() => _syncing = false);
      if (_pendingSync) {
        _pendingSync = false;
        _syncDebounce?.cancel();
        _syncDebounce = Timer(
          const Duration(milliseconds: 1000),
          () => _performSync(showToast: true),
        );
      }
    }
  }

  /// 非侵入轻提示：底部居中淡入淡出、自动消失，不拦截任何操作
  void _showSyncToast(String msg, {required bool error, int durationMs = 1800}) {
    _toastTimer?.cancel();
    setState(() {
      _syncToastMsg = msg;
      _syncToastError = error;
      _syncToastVisible = true;
    });
    _toastTimer = Timer(Duration(milliseconds: durationMs), () {
      if (mounted) setState(() => _syncToastVisible = false);
    });
  }
}

/// 修复 Windows 中文输入法 IME Bug 的多行 TextField
/// 问题根因：TextInputType.multiline 模式下，输入【】等中文标点会导致
/// IME 组合状态异常，删除键/方向键失效但仍能打字。
/// 解决方案：使用 TextInputType.text（避免多行 IME 组合状态问题）+
/// 手动监听回车键在光标位置插入换行符，保留多行输入能力。
class _ImeSafeTextField extends StatefulWidget {
  final TextEditingController controller;
  final String hintText;
  final int maxLines;
  final bool autofocus;
  final bool enableAutoConvert;
  final int? maxLength;
  final String? counterText;
  final EdgeInsets scrollPadding;

  const _ImeSafeTextField({
    required this.controller,
    required this.hintText,
    this.maxLines = 6,
    this.autofocus = false,
    this.enableAutoConvert = true,
    this.maxLength,
    this.counterText,
    this.scrollPadding = const EdgeInsets.only(bottom: 140),
  });

  @override
  State<_ImeSafeTextField> createState() => _ImeSafeTextFieldState();
}

class _ImeSafeTextFieldState extends State<_ImeSafeTextField> {
  final FocusNode _focusNode = FocusNode();
  final ScrollController _scrollController = ScrollController();

  @override
  void initState() {
    super.initState();
    // 自动转义：输入 1. 2. 开头的行 -> [ ] 子任务
    // 备忘编辑时关闭（避免与 Markdown 有序列表 1. 冲突）
    if (widget.enableAutoConvert) {
      widget.controller.addListener(_autoConvertNumbered);
    }
  }

  void _autoConvertNumbered() {
    final value = widget.controller.value;
    // 输入法预编辑中（如中文拼音未上屏）：跳过转换，避免整体重写文本打断
    // 输入法 composition 导致上屏文字与已写入文本叠加（打字重复）。
    // 拼音上屏后（composing 失效）会再次触发本监听器，此时正常转换。
    if (value.composing.isValid) return;
    final text = value.text;
    final converted = autoConvertNumberedToCheckbox(text);
    if (converted == text) return;
    final base = value.selection.baseOffset < 0 ? 0 : value.selection.baseOffset;
    final extent = value.selection.extentOffset < 0 ? base : value.selection.extentOffset;
    // 按光标前的文本单独做一次转换，其长度即新光标位置；
    // 多行时每个替换行各计入自身增量，光标不会整体偏移跳位。
    final nb = autoConvertNumberedToCheckbox(text.substring(0, base)).length;
    final ne = autoConvertNumberedToCheckbox(text.substring(0, extent)).length;
    widget.controller.value = TextEditingValue(
      text: converted,
      selection: TextSelection(baseOffset: nb, extentOffset: ne),
    );
  }

  @override
  void dispose() {
    widget.controller.removeListener(_autoConvertNumbered);
    _focusNode.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  /// 在光标位置插入换行符
  void _insertNewline() {
    final text = widget.controller.text;
    final selection = widget.controller.selection;
    final start = selection.start < 0 ? 0 : selection.start;
    final end = selection.end < 0 ? start : selection.end;
    final newText = text.replaceRange(start, end, '\n');
    widget.controller.value = TextEditingValue(
      text: newText,
      selection: TextSelection.collapsed(offset: start + 1),
    );
    // 等渲染完成后把光标行滚到可视区（Flutter 仅在打字时自动滚动，手动插入需补一次）
    WidgetsBinding.instance.addPostFrameCallback((_) => _ensureCaretVisible());
  }

  /// 回车换行后把光标所在行滚动到可视区
  void _ensureCaretVisible() {
    if (!mounted || !_focusNode.hasFocus) return;
    final renderEditable = _findRenderEditable(context);
    if (renderEditable == null || !_scrollController.hasClients) return;
    final pos = _scrollController.position;
    final caretRect = renderEditable.getLocalRectForCaret(
      TextPosition(offset: widget.controller.selection.baseOffset),
    );
    final caretBottom = caretRect.bottom;
    const bottomPad = 140.0;
    final viewportH = pos.viewportDimension;
    final targetBottom = caretBottom + bottomPad;
    if (targetBottom > pos.pixels + viewportH) {
      _scrollController.animateTo(
        targetBottom - viewportH,
        duration: const Duration(milliseconds: 120),
        curve: Curves.easeOut,
      );
    } else if (caretRect.top < pos.pixels) {
      _scrollController.animateTo(
        caretRect.top,
        duration: const Duration(milliseconds: 120),
        curve: Curves.easeOut,
      );
    }
  }

  /// 在组件树中查找文本编辑渲染对象（用于精确计算光标位置）
  RenderEditable? _findRenderEditable(BuildContext ctx) {
    RenderEditable? result;
    void visit(Element e) {
      if (result != null) return;
      if (e.renderObject is RenderEditable) {
        result = e.renderObject as RenderEditable;
        return;
      }
      e.visitChildren(visit);
    }

    ctx.visitChildElements((e) => visit(e));
    return result;
  }

  @override
  Widget build(BuildContext context) {
    return Focus(
      onKeyEvent: (node, event) {
        // 手动处理回车键：插入换行符（Alt+Enter 留给系统命令）
        // 输入法预编辑中（拼音选字/上屏）回车必须交给系统处理，否则会打断
        // IME 组合状态，导致上屏文字重复、光标错位（中文输入法经典 Bug）。
        if (event is KeyDownEvent &&
            event.logicalKey == LogicalKeyboardKey.enter &&
            !HardwareKeyboard.instance.isAltPressed &&
            !widget.controller.value.composing.isValid) {
          _insertNewline();
          return KeyEventResult.handled;
        }
        return KeyEventResult.ignored;
      },
      child: TextField(
        controller: widget.controller,
        focusNode: _focusNode,
        scrollController: _scrollController,
        scrollPadding: widget.scrollPadding,
        autofocus: widget.autofocus,
        maxLines: widget.maxLines,
        maxLength: widget.maxLength,
        maxLengthEnforcement: widget.maxLength != null
            ? MaxLengthEnforcement.enforced
            : MaxLengthEnforcement.none,
        // 关键：使用 text 而非 multiline，避免 Windows IME 组合状态 Bug
        keyboardType: TextInputType.text,
        decoration: InputDecoration(
          hintText: widget.hintText,
          counterText: widget.counterText ?? '',
          isDense: true,
          filled: true,
          fillColor: GlassPalette.of(context).fieldBg,
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(10),
            borderSide: BorderSide(color: GlassPalette.of(context).accent),
          ),
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(10),
            borderSide: BorderSide(color: GlassPalette.of(context).accent),
          ),
          focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(10),
            borderSide: BorderSide(color: GlassPalette.of(context).accent, width: 1.5),
          ),
        ),
      ),
    );
  }
}

/// 飞行小球：从卡片位置沿抛物线飞入目标标签
class _FlyingBall extends StatefulWidget {
  final double startX, startY, endX, endY;
  final Color color;
  final VoidCallback onComplete;

  const _FlyingBall({
    required this.startX,
    required this.startY,
    required this.endX,
    required this.endY,
    required this.color,
    required this.onComplete,
  });

  @override
  State<_FlyingBall> createState() => _FlyingBallState();
}

class _FlyingBallState extends State<_FlyingBall>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  late final Animation<double> _anim;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      duration: const Duration(milliseconds: 300),
      vsync: this,
    );
    _anim = CurvedAnimation(parent: _controller, curve: Curves.easeInOutCubic);
    _controller.forward().then((_) => widget.onComplete());
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _anim,
      builder: (context, child) {
        final t = _anim.value;
        final x = widget.startX + (widget.endX - widget.startX) * t;
        // 抛物线：中间向上拱起
        final y =
            widget.startY +
            (widget.endY - widget.startY) * t -
            60 * sin(t * pi);
        final size = 28 * (1 - t * 0.7);
        return Positioned(
          left: x - size / 2,
          top: y - size / 2,
          child: Container(
            width: size,
            height: size,
            decoration: BoxDecoration(
              color: widget.color,
              shape: BoxShape.circle,
              boxShadow: [
                BoxShadow(
                  color: widget.color.withValues(alpha: 0.5),
                  blurRadius: 10,
                  spreadRadius: 1,
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

/// 备忘卡片：隔行换色 + 左侧主题色竖条 + 悬停上浮/按钮显现 + 搜索关键词高亮
/// 新建选择弹窗（方案C：胶囊引导）
class _AddChoiceDialog extends StatefulWidget {
  const _AddChoiceDialog();

  @override
  State<_AddChoiceDialog> createState() => _AddChoiceDialogState();
}

class _AddChoiceDialogState extends State<_AddChoiceDialog> {
  @override
  Widget build(BuildContext context) {
    return TweenAnimationBuilder<double>(
      tween: Tween<double>(begin: 0.96, end: 1.0),
      duration: const Duration(milliseconds: 120),
      curve: Curves.easeOut,
      builder: (context, scale, child) =>
          Transform.scale(scale: scale, child: child),
      child: AlertDialog(
        backgroundColor: GlassPalette.of(context).surface,
        surfaceTintColor: Colors.transparent,
        elevation: 12,
        insetPadding: const EdgeInsets.symmetric(horizontal: 24, vertical: 24),
        titlePadding: const EdgeInsets.fromLTRB(18, 18, 18, 0),
        contentPadding: const EdgeInsets.fromLTRB(18, 14, 18, 16),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
        title: Row(
          children: [
            const Text(
              '新建',
              style: TextStyle(fontSize: 17, fontWeight: FontWeight.w700),
            ),
            const SizedBox(width: 8),
            Text(
              '选择一个类型',
              style: TextStyle(fontSize: 12, color: GlassPalette.of(context).inkTertiary),
            ),
          ],
        ),
        content: SizedBox(
          width: 364,
          child: DecoratedBox(
            // 顶部分隔线：标题和清单之间
            decoration: BoxDecoration(
              border: Border(top: BorderSide(color: GlassPalette.of(context).divider)),
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                _ChoiceRow(
                  deep: GlassPalette.of(context).accent,
                  light: GlassPalette.of(context).accentSoft,
                  icon: Icons.task_alt,
                  title: '新建任务',
                  subtitle: '带状态、紧急度、计划时间',
                  onTap: () => Navigator.of(context).pop('task'),
                ),
                _ChoiceRow(
                  deep: GlassPalette.of(context).warning,
                  light: GlassPalette.of(context).statsAmber,
                  icon: Icons.note_alt_outlined,
                  title: '新建备忘',
                  subtitle: '纯记录，支持搜索',
                  onTap: () => Navigator.of(context).pop('memo'),
                  showDivider: false,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// 清单式选择行。
///
/// 悬停只有一个动效：左侧 3px 色条从中心长出来（180ms, easeOut）。
/// 不做底色变化、不做缩放/旋转/回弹，文字和箭头都保持静态。
class _ChoiceRow extends StatefulWidget {
  final Color deep;
  final Color light;
  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback onTap;
  final bool showDivider;

  const _ChoiceRow({
    required this.deep,
    required this.light,
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onTap,
    this.showDivider = true,
  });

  @override
  State<_ChoiceRow> createState() => _ChoiceRowState();
}

class _ChoiceRowState extends State<_ChoiceRow> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final hovered = _hovered;
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: widget.onTap,
        child: Container(
          decoration: BoxDecoration(
            border: widget.showDivider
                ? Border(bottom: BorderSide(color: GlassPalette.of(context).divider))
                : null,
          ),
          child: Stack(
            children: [
              // 左侧色条：只长高度，不做整块铺色
              Positioned(
                left: 0,
                top: 0,
                bottom: 0,
                child: Center(
                  child: AnimatedContainer(
                    duration: const Duration(milliseconds: 180),
                    curve: Curves.easeOut,
                    width: 3,
                    height: hovered ? 26 : 0,
                    decoration: BoxDecoration(
                      color: widget.deep,
                      borderRadius: BorderRadius.circular(3),
                    ),
                  ),
                ),
              ),
              // 内容层
              Padding(
                padding: const EdgeInsets.fromLTRB(14, 13, 10, 13),
                child: Row(
                  children: [
                    Container(
                      width: 38,
                      height: 38,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        gradient: LinearGradient(
                          begin: Alignment.topLeft,
                          end: Alignment.bottomRight,
                          colors: [widget.light, widget.deep],
                        ),
                      ),
                      child: Icon(widget.icon, color: Colors.white, size: 19),
                    ),
                    const SizedBox(width: 13),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            widget.title,
                            style: TextStyle(
                              fontSize: 14.5,
                              fontWeight: FontWeight.w600,
                              color: GlassPalette.of(context).ink,
                            ),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            widget.subtitle,
                            style: TextStyle(
                              fontSize: 12,
                              color: GlassPalette.of(context).inkTertiary,
                            ),
                          ),
                        ],
                      ),
                    ),
                    Icon(
                      Icons.chevron_right,
                      size: 19,
                      color: GlassPalette.of(context).inkFaint,
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}


/// 任务卡片入场动画：按索引依次从下往上滑入 + 淡入（共享一个 AnimationController）
class _EntranceItem extends StatelessWidget {
  final AnimationController controller;
  final int index;
  final int total;
  final Widget child;

  const _EntranceItem({
    required this.controller,
    required this.index,
    required this.total,
    required this.child,
  });

  @override
  Widget build(BuildContext context) {
    if (total <= 1) return child;
    // 排队起点：前 55% 的时间用于依次入场，单张动画占 45%
    final start = (index / (total < 1 ? 1 : total)) * 0.55;
    final end = start + 0.45 < 1.0 ? start + 0.45 : 1.0;
    return AnimatedBuilder(
      animation: controller,
      builder: (context, _) {
        final raw = controller.value <= start
            ? 0.0
            : ((controller.value - start) / (end - start)).clamp(0.0, 1.0);
        final v = Curves.easeOutCubic.transform(raw);
        return Opacity(
          opacity: v,
          child: Transform.translate(
            offset: Offset(0, 20 * (1 - v)),
            child: child,
          ),
        );
      },
    );
  }
}

/// 设置菜单的整体条目：行内点击由面板自己处理，不触发 PopupMenu 的关闭逻辑。
class _SettingsMenuPanelEntry extends PopupMenuEntry<dynamic> {
  const _SettingsMenuPanelEntry({required this.child});

  final Widget child;

  @override
  double get height => 0;

  @override
  bool represents(dynamic value) => false;

  @override
  State<_SettingsMenuPanelEntry> createState() =>
      _SettingsMenuPanelEntryState();
}

class _SettingsMenuPanelEntryState extends State<_SettingsMenuPanelEntry> {
  @override
  Widget build(BuildContext context) => widget.child;
}

/// 设置菜单面板：所有开关 / 动作行都直接改本地状态，菜单不关闭。
class _SettingsMenuPanel extends StatefulWidget {
  const _SettingsMenuPanel({
    required this.hotkeyLabel,
    required this.onStats,
    required this.onRepeatManager,
    required this.onCheckUpdate,
    required this.onAbout,
    required this.onPickHotkey,
    required this.onQuickCapture,
    required this.onLogout,
    required this.onQuit,
  });

  final String Function() hotkeyLabel;
  final VoidCallback onStats;
  final VoidCallback onRepeatManager;
  final VoidCallback onCheckUpdate;
  final VoidCallback onAbout;
  final Future<void> Function() onPickHotkey;
  final Future<void> Function() onQuickCapture;
  final Future<void> Function() onLogout;
  final VoidCallback onQuit;

  @override
  State<_SettingsMenuPanel> createState() => _SettingsMenuPanelState();
}

class _SettingsMenuPanelState extends State<_SettingsMenuPanel> {
  Widget _trailingText(String text, GlassPalette g) => Text(
        text,
        style: TextStyle(fontSize: 11, color: g.inkTertiary),
      );

  Widget _toggleSwitch(GlassPalette g, bool on) {
    return Container(
      width: 36,
      height: 20,
      padding: const EdgeInsets.all(2),
      decoration: BoxDecoration(
        color: on ? g.accent : g.decoInk.withAlpha(g.isLight ? 30 : 36),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Align(
        alignment: on ? Alignment.centerRight : Alignment.centerLeft,
        child: Container(
          width: 16,
          height: 16,
          decoration: BoxDecoration(
            color: Colors.white,
            shape: BoxShape.circle,
            boxShadow: [
              BoxShadow(color: g.shadow, blurRadius: 2),
            ],
          ),
        ),
      ),
    );
  }

  Widget _groupDivider(GlassPalette g) => PopupMenuDivider(
        height: 6,
        thickness: 0.5,
        color: g.menuDivider.withAlpha(18),
      );

  @override
  Widget build(BuildContext context) {
    final g = GlassPalette.of(context);
    final reminderOn = TaskReminderService.instance.enabled;
    final bubbleOn = BubbleService.instance.enabled.value;
    final ambientOn = AmbientMotion.enabled.value;
    final autoStartOn = AutoStartService.isEnabled;
    final linkOn = AttachmentStore.linkByDefault;
    final quickCapture = QuickCaptureHotkey.instance;
    final hotkeyActive = HotkeyService.instance.isActive;

    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () {},
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // 数据与任务
          // 我的数据：个人看板（整页替换列表）
          _SettingsMenuRow(
            icon: Icon(
              Icons.insights_outlined,
              size: 18,
              color: g.statsPrimary,
            ),
            label: '我的数据',
            trailing: _trailingText('看板', g),
            onTap: widget.onStats,
          ),
          // 循环任务管理：集中查看 / 改规则 / 停止 / 恢复
          _SettingsMenuRow(
            icon: Icon(Icons.autorenew, size: 18, color: g.accent),
            label: '循环任务',
            trailing: _trailingText('日 / 周 / 月', g),
            onTap: widget.onRepeatManager,
          ),
          _groupDivider(g),
          // 偏好设置：外观档位 + 五个开关集中在一起
          // 外观：浅色 / 跟随系统 / 深色，整窗一起换档，面板本身也跟着变。
          _SettingsMenuRow(
            icon: Icon(Icons.contrast, size: 18, color: g.inkTertiary),
            label: '外观',
            trailing: const ThemeModeSwitch(),
          ),
          // 任务提醒开关
          _SettingsMenuRow(
            icon: Icon(
              Icons.notifications_active,
              size: 18,
              color: g.inkTertiary,
            ),
            label: '任务提醒',
            trailing: _toggleSwitch(g, reminderOn),
            onTap: () {
              TaskReminderService.instance.setEnabled(!reminderOn);
              setState(() {});
            },
          ),
          // 桌面气泡开关：关闭后最小化 / 托盘 / 长时间离开都不再弹气泡
          _SettingsMenuRow(
            icon: Icon(
              Icons.bubble_chart_outlined,
              size: 18,
              color: g.inkTertiary,
            ),
            label: '桌面气泡',
            trailing: _toggleSwitch(g, bubbleOn),
            onTap: () {
              BubbleService.instance.setEnabled(!bubbleOn);
              setState(() {});
            },
          ),
          // 动态背景开关
          _SettingsMenuRow(
            icon: Icon(Icons.auto_awesome, size: 18, color: g.inkTertiary),
            label: '动态背景',
            trailing: _toggleSwitch(g, ambientOn),
            onTap: () {
              AmbientMotion.setEnabled(!ambientOn);
              setState(() {});
            },
          ),
          // 附件默认引用原件：加桌面/拖进来的文件只记路径，改了原件会同步给别的机器；
          // 关掉则像以前那样复制一份进附件库，原件怎么动都不影响。
          _SettingsMenuRow(
            icon: Icon(Icons.link, size: 18, color: g.inkTertiary),
            label: '附件引用原件',
            trailing: _toggleSwitch(g, linkOn),
            onTap: () async {
              await AttachmentStore.setLinkByDefault(!linkOn);
              if (mounted) setState(() {});
            },
          ),
          // 开机自启
          _SettingsMenuRow(
            icon: Icon(Icons.autorenew, size: 18, color: g.inkTertiary),
            label: '开机自启',
            trailing: _toggleSwitch(g, autoStartOn),
            onTap: () async {
              await AutoStartService.toggle();
              if (mounted) setState(() {});
            },
          ),
          _groupDivider(g),
          // 快捷键
          // 截图热键设置
          _SettingsMenuRow(
            icon: Icon(Icons.keyboard, size: 18, color: g.inkTertiary),
            label: '截图热键',
            trailing: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 130),
              child: Text(
                widget.hotkeyLabel(),
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 11,
                  color: hotkeyActive ? g.inkTertiary : g.danger,
                ),
              ),
            ),
            onTap: () async {
              await widget.onPickHotkey();
              if (mounted) setState(() {});
            },
          ),
          // 快速录入热键（点击就等于按一次那个热键，方便发现和验证）
          _SettingsMenuRow(
            icon: Icon(Icons.bolt, size: 18, color: g.inkTertiary),
            label: '快速录入',
            trailing: Text(
              quickCapture.label,
              style: TextStyle(
                fontSize: 11,
                color: quickCapture.isActive ? g.inkTertiary : g.danger,
              ),
            ),
            onTap: () => widget.onQuickCapture(),
          ),
          _groupDivider(g),
          // 应用
          // 检查更新
          _SettingsMenuRow(
            icon: Icon(Icons.system_update, size: 18, color: g.inkTertiary),
            label: '检查更新',
            trailing: _trailingText(
              'v${UpgradeService.instance.currentVersion}',
              g,
            ),
            onTap: widget.onCheckUpdate,
          ),
          // 关于我们
          _SettingsMenuRow(
            icon: Icon(Icons.info_outline, size: 18, color: g.inkTertiary),
            label: '关于我们',
            onTap: widget.onAbout,
          ),
          _groupDivider(g),
          // 退出登录（登录后显示；退出后本行在菜单内直接消失）
          if (AuthService.isLoggedIn)
            _SettingsMenuRow(
              icon: Icon(Icons.logout, size: 18, color: g.inkTertiary),
              label: '退出登录（${AuthService.email}）',
              onTap: () async {
                await widget.onLogout();
                if (mounted) setState(() {});
              },
            ),
          // 退出软件
          _SettingsMenuRow(
            icon: Icon(Icons.power_settings_new, size: 18, color: g.danger),
            label: '退出软件',
            danger: true,
            onTap: widget.onQuit,
          ),
        ],
      ),
    );
  }
}

/// 菜单里的一行：高度、内边距、行高与原来的 PopupMenuItem 保持一致。
class _SettingsMenuRow extends StatelessWidget {
  const _SettingsMenuRow({
    required this.icon,
    required this.label,
    this.trailing,
    this.onTap,
    this.danger = false,
  });

  final Widget icon;
  final String label;
  final Widget? trailing;
  final VoidCallback? onTap;
  final bool danger;

  @override
  Widget build(BuildContext context) {
    final g = GlassPalette.of(context);
    return InkWell(
      onTap: onTap,
      child: SizedBox(
        height: 42,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: Row(
            children: [
              icon,
              const SizedBox(width: 10),
              Text(
                label,
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w500,
                  color: danger ? g.danger : g.menuText,
                ),
              ),
              const Spacer(),
              ?trailing,
            ],
          ),
        ),
      ),
    );
  }
}

/// 快速录入面板：两行输入 + 优先级，Enter 保存、Esc 取消。
///
/// 输入框固定 76 高、两行后内部滚动；Enter 由 done action 直接提交，
/// 不会往任务标题里写入真实换行符。
class _QuickCaptureDialog extends StatefulWidget {
  const _QuickCaptureDialog();

  @override
  State<_QuickCaptureDialog> createState() => _QuickCaptureDialogState();
}

class _QuickCaptureDialogState extends State<_QuickCaptureDialog> {
  final TextEditingController _ctrl = TextEditingController();
  final FocusNode _focusNode = FocusNode();
  Urgency _urgency = Urgency.normal;
  bool _focused = false;
  bool _hasText = false;

  @override
  void initState() {
    super.initState();
    _focusNode.addListener(_handleFocusChanged);
    _ctrl.addListener(_handleTextChanged);
  }

  @override
  void dispose() {
    _focusNode.removeListener(_handleFocusChanged);
    _ctrl.removeListener(_handleTextChanged);
    _focusNode.dispose();
    _ctrl.dispose();
    super.dispose();
  }

  void _handleFocusChanged() {
    if (!mounted || _focused == _focusNode.hasFocus) return;
    setState(() => _focused = _focusNode.hasFocus);
  }

  void _handleTextChanged() {
    final hasText = _ctrl.text.trim().isNotEmpty;
    if (!mounted || _hasText == hasText) return;
    setState(() => _hasText = hasText);
  }

  void _submit() {
    if (!_hasText) return;
    Navigator.of(context).pop((_ctrl.text.trim(), _urgency));
  }

  @override
  Widget build(BuildContext context) {
    final g = GlassPalette.of(context);
    final fieldFill = g.isLight ? g.menuDivider.withAlpha(10) : g.fieldBg;
    final fieldBorder = g.isLight ? g.menuDivider.withAlpha(30) : g.fieldBorder;
    final pillIdleBg = g.isLight ? g.menuDivider.withAlpha(8) : g.chipBg;
    final pillIdleBorder = g.isLight ? g.menuDivider.withAlpha(30) : g.chipBorder;

    Widget urgencyPill(Urgency u, String label) {
      final selected = _urgency == u;
      final color = TaskCard.urgencyColors(g)[u]!;
      return MouseRegion(
        cursor: SystemMouseCursors.click,
        child: GestureDetector(
          onTap: () => setState(() => _urgency = u),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 120),
            height: 30,
            padding: const EdgeInsets.symmetric(horizontal: 12),
            decoration: BoxDecoration(
              color: selected ? TaskCard.urgencyBgColors(g)[u] : pillIdleBg,
              borderRadius: BorderRadius.circular(8),
              border: Border.all(
                color: selected ? color.withAlpha(80) : pillIdleBorder,
              ),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  width: 6,
                  height: 6,
                  decoration: BoxDecoration(color: color, shape: BoxShape.circle),
                ),
                const SizedBox(width: 6),
                Text(
                  label,
                  style: TextStyle(
                    fontSize: 12,
                    height: 1.1,
                    fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
                    color: selected
                        ? (g.isLight ? g.menuText : GlassPalette.light.menuText)
                        : g.inkTertiary,
                  ),
                ),
              ],
            ),
          ),
        ),
      );
    }

    return Dialog(
      backgroundColor: Colors.transparent,
      elevation: 0,
      insetPadding: const EdgeInsets.symmetric(horizontal: 24, vertical: 24),
      child: Container(
        width: 420,
        padding: const EdgeInsets.all(22),
        decoration: BoxDecoration(
          color: g.surface,
          borderRadius: BorderRadius.circular(16),
          boxShadow: [
            BoxShadow(color: g.shadow, blurRadius: 40, offset: const Offset(0, 18)),
            BoxShadow(color: g.shadowSoft, blurRadius: 8, offset: const Offset(0, 2)),
          ],
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Container(
                  width: 28,
                  height: 28,
                  decoration: BoxDecoration(
                    color: g.accent.withAlpha(g.isLight ? 18 : 40),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Icon(Icons.bolt_rounded, size: 17, color: g.accent),
                ),
                const SizedBox(width: 10),
                Text(
                  '快速记一条',
                  style: TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w700,
                    height: 1.2,
                    color: g.menuText,
                  ),
                ),
                const Spacer(),
                Text(
                  'Enter 保存 · Esc 取消',
                  style: TextStyle(
                    fontSize: 11,
                    height: 1.2,
                    color: g.inkTertiary,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 18),
            AnimatedContainer(
              duration: const Duration(milliseconds: 120),
              height: 76,
              decoration: BoxDecoration(
                color: fieldFill,
                borderRadius: BorderRadius.circular(10),
                boxShadow: _focused
                    ? [
                        BoxShadow(
                          color: g.accent.withAlpha(g.isLight ? 26 : 55),
                          spreadRadius: 3,
                        ),
                      ]
                    : const [],
              ),
              child: TextField(
                controller: _ctrl,
                focusNode: _focusNode,
                autofocus: true,
                expands: true,
                minLines: null,
                maxLines: null,
                textAlignVertical: TextAlignVertical.top,
                keyboardType: TextInputType.text,
                textInputAction: TextInputAction.done,
                onSubmitted: (_) => _submit(),
                style: TextStyle(fontSize: 13, height: 1.45, color: g.menuText),
                cursorColor: g.accent,
                cursorWidth: 1.4,
                decoration: InputDecoration(
                  hintText: '记一件要做的事…',
                  hintStyle: TextStyle(
                    fontSize: 13,
                    height: 1.45,
                    color: g.inkTertiary,
                  ),
                  contentPadding: const EdgeInsets.fromLTRB(13, 13, 13, 13),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(10),
                    borderSide: BorderSide.none,
                  ),
                  enabledBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(10),
                    borderSide: BorderSide(color: fieldBorder),
                  ),
                  focusedBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(10),
                    borderSide: BorderSide(color: g.accent, width: 1.5),
                  ),
                ),
              ),
            ),
            const SizedBox(height: 16),
            Row(
              children: [
                Text(
                  '优先级',
                  style: TextStyle(
                    fontSize: 11,
                    height: 1.2,
                    color: g.inkTertiary,
                  ),
                ),
                const SizedBox(width: 10),
                urgencyPill(Urgency.normal, '一般'),
                const SizedBox(width: 6),
                urgencyPill(Urgency.urgent, '紧急'),
                const SizedBox(width: 6),
                urgencyPill(Urgency.important, '重要'),
              ],
            ),
            const SizedBox(height: 20),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                TextButton(
                  onPressed: () => Navigator.of(context).pop(),
                  style: TextButton.styleFrom(
                    foregroundColor: g.inkTertiary,
                    minimumSize: const Size(0, 36),
                    padding: const EdgeInsets.symmetric(horizontal: 14),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(8),
                    ),
                    textStyle: const TextStyle(
                      fontSize: 12.5,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                  child: const Text('取消'),
                ),
                const SizedBox(width: 6),
                FilledButton(
                  onPressed: _hasText ? _submit : null,
                  style: FilledButton.styleFrom(
                    backgroundColor: g.accent,
                    foregroundColor: Colors.white,
                    disabledBackgroundColor: g.accent.withAlpha(g.isLight ? 40 : 70),
                    disabledForegroundColor: Colors.white.withAlpha(170),
                    minimumSize: const Size(0, 36),
                    padding: const EdgeInsets.symmetric(horizontal: 20),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(8),
                    ),
                    textStyle: const TextStyle(
                      fontSize: 12.5,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  child: const Text('保存'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
