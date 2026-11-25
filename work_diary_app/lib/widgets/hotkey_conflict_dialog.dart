import 'package:flutter/material.dart';

import '../services/hotkey_service.dart';
import '../theme/glass_palette.dart';

/// 冲突弹窗的返回值。
enum HotkeyConflictChoice {
  /// 已经应用了新热键（或把临时热键固定下来）。
  changed,

  /// 用户选择“暂不设置”：同一个热键不再重复提示。
  later,
}

/// 截图热键冲突提示 / 热键选择对话框。
///
/// 两种用途共用一套 UI：
/// - 启动时热键被占用：[pickerMode] 为 false，告知冲突并引导换键；
/// - 设置菜单里主动更换：[pickerMode] 为 true，只做选择，不强调冲突。
///
/// 列表里的可用性是打开对话框时实时探测的（Windows 上 RegisterHotKey 探针），
/// 点已被占用的项不会关闭弹窗，而是就地提示。
class HotkeyConflictDialog extends StatefulWidget {
  const HotkeyConflictDialog({
    super.key,
    this.pickerMode = false,
    this.service,
  });

  final bool pickerMode;

  /// 仅测试时注入，运行时用全局单例。
  final HotkeyService? service;

  static Future<HotkeyConflictChoice?> show(
    BuildContext context, {
    bool pickerMode = false,
    HotkeyService? service,
  }) {
    return showDialog<HotkeyConflictChoice>(
      context: context,
      barrierDismissible: pickerMode,
      builder: (_) =>
          HotkeyConflictDialog(pickerMode: pickerMode, service: service),
    );
  }

  @override
  State<HotkeyConflictDialog> createState() => _HotkeyConflictDialogState();
}

class _HotkeyConflictDialogState extends State<HotkeyConflictDialog> {
  late final HotkeyService _service = widget.service ?? HotkeyService.instance;

  Map<String, bool> _availability = <String, bool>{};
  bool _probing = true;
  bool _busy = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  Future<void> _refresh() async {
    if (!_probing) {
      setState(() => _probing = true);
    }
    final list = await _service.probeAll();
    if (!mounted) return;
    setState(() {
      _availability = <String, bool>{
        for (final item in list) item.option.id: item.available,
      };
      _probing = false;
    });
  }

  Future<void> _apply(HotkeyOption option) async {
    setState(() {
      _busy = true;
      _error = null;
    });
    final ok = await _service.setHotkey(option.id);
    if (!mounted) return;
    if (ok) {
      Navigator.of(context).pop(HotkeyConflictChoice.changed);
      return;
    }
    setState(() {
      _busy = false;
      _error = _service.lastErrorCode == 1409
          ? '${option.label} 已被其他软件占用，请换一个。'
          : '切换失败，请先关闭占用该快捷键的软件后重试。';
    });
    await _refresh();
  }

  Future<void> _adoptActive() async {
    await _service.adoptActiveAsDesired();
    if (mounted) {
      Navigator.of(context).pop(HotkeyConflictChoice.changed);
    }
  }

  String _headline() {
    final active = _service.activeOption;
    final desired = _service.desiredOption;
    if (widget.pickerMode) {
      final hasAvailable = HotkeyService.presetHotkeys.any(
        (option) => _availability[option.id] == true,
      );
      if (!_probing && !hasAvailable) {
        return '暂时没有可用的组合键。微信、QQ 等软件默认占用 Ctrl+Alt+A，'
            '请先关闭或修改它们的快捷键，再重新打开这个窗口。';
      }
      return '选一个可用的组合键；标灰的组合键已被其它软件占用。';
    }
    if (_service.status == HotkeyStatus.allUnavailable) {
      // 用户可能刚关掉占用的软件，点“重试”后这里要能反映出来。
      final hasAvailable = HotkeyService.presetHotkeys.any(
        (option) => _availability[option.id] == true,
      );
      if (hasAvailable) {
        return '现在有可用的组合键了，点一下即可启用。';
      }
      return 'Ctrl+Alt+A / Ctrl+Shift+A / Ctrl+Alt+Q / Ctrl+Shift+Q 都被占用了。\n'
          '微信、QQ 等软件默认占用 Ctrl+Alt+A，请先关闭或修改它们的快捷键，再点“重试”。';
    }
    if (_service.status == HotkeyStatus.fallback) {
      return '${desired.label} 已被其他软件占用，已临时改用 ${active?.label ?? ''}。\n'
          '你可以直接使用它，或者换一个组合键。';
    }
    return '${desired.label} 已被其他软件占用，请换一个可用的组合键。';
  }

  @override
  Widget build(BuildContext context) {
    final active = _service.activeOption;
    final g = GlassPalette.of(context);
    return AlertDialog(
      title: Text(
        widget.pickerMode ? '选择截图热键' : '截图热键被占用',
        style: const TextStyle(fontSize: 16),
      ),
      content: SizedBox(
        width: 340,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              _headline(),
              style: const TextStyle(fontSize: 13, height: 1.5),
            ),
            const SizedBox(height: 12),
            if (_probing)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 12),
                child: LinearProgressIndicator(minHeight: 2),
              )
            else
              ...HotkeyService.presetHotkeys.map(_buildOption),
            if (_error != null)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(
                  _error!,
                  style: TextStyle(
                    fontSize: 12,
                    color: g.danger,
                  ),
                ),
              ),
          ],
        ),
      ),
      actions: _buildActions(active),
    );
  }

  Widget _buildOption(HotkeyOption option) {
    final g = GlassPalette.of(context);
    final available = _availability[option.id] ?? false;
    final isActive = _service.activeHotkeyId == option.id;
    final enabled = available && !isActive && !_busy;
    return InkWell(
      onTap: enabled ? () => _apply(option) : null,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 4),
        child: Row(
          children: [
            Icon(
              available ? Icons.keyboard : Icons.block,
              size: 16,
              color: available ? g.accent : g.inkTertiary,
            ),
            const SizedBox(width: 8),
            Text(
              option.label,
              style: TextStyle(
                fontSize: 13,
                color: available ? g.ink : g.inkTertiary,
                fontWeight: isActive ? FontWeight.w600 : FontWeight.normal,
              ),
            ),
            const Spacer(),
            Text(
              isActive ? '使用中' : (available ? '可用' : '已被占用'),
              style: TextStyle(
                fontSize: 11,
                color: isActive
                    ? g.accent
                    : (available ? g.inkTertiary : g.danger),
              ),
            ),
          ],
        ),
      ),
    );
  }

  List<Widget> _buildActions(HotkeyOption? active) {
    if (widget.pickerMode) {
      return [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('关闭'),
        ),
      ];
    }
    return [
      if (_service.status == HotkeyStatus.allUnavailable)
        TextButton(
          onPressed: _probing ? null : _refresh,
          child: const Text('重试'),
        ),
      if (_service.status == HotkeyStatus.fallback && active != null)
        TextButton(
          onPressed: _busy ? null : _adoptActive,
          child: Text('就用 ${active.label}'),
        ),
      TextButton(
        onPressed: () => Navigator.of(context).pop(HotkeyConflictChoice.later),
        child: const Text('暂不设置'),
      ),
    ];
  }
}
