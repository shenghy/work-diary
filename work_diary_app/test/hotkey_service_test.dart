import 'package:flutter_test/flutter_test.dart';
import 'package:work_diary_app/services/hotkey_service.dart';

/// 假注册器：用 [occupied] 模拟“被其它软件占用”的组合键。
class _FakeRegistrar implements HotkeyRegistrar {
  _FakeRegistrar({Set<String>? occupied})
    : occupied = occupied ?? <String>{};

  final Set<String> occupied;

  /// 当前生效的热键（注册成功加入，注销后移除）。
  final List<String> active = <String>[];

  void Function()? _onTrigger;

  @override
  void bind(void Function() onTrigger) {
    _onTrigger = onTrigger;
  }

  void fire() => _onTrigger?.call();

  @override
  Future<HotkeyRegisterResult> register(HotkeyOption option) async {
    if (occupied.contains(option.id)) {
      return const HotkeyRegisterResult(false, 1409);
    }
    if (!active.contains(option.id)) {
      active.add(option.id);
    }
    return const HotkeyRegisterResult(true);
  }

  @override
  Future<void> unregister(HotkeyOption option) async {
    active.remove(option.id);
  }

  @override
  Future<bool> probe(HotkeyOption option) async =>
      !occupied.contains(option.id);
}

class _MemoryStore implements HotkeyStore {
  _MemoryStore([Map<String, String>? initial])
    : values = initial ?? <String, String>{};

  final Map<String, String> values;

  @override
  Future<String?> read(String key) async => values[key];

  @override
  Future<void> write(String key, String value) async {
    values[key] = value;
  }
}

HotkeyService _build(_FakeRegistrar registrar, [_MemoryStore? store]) {
  return HotkeyService(
    registrar: registrar,
    store: store ?? _MemoryStore(),
    detectConflicts: true,
  );
}

void main() {
  test('默认热键可用时直接注册', () async {
    final registrar = _FakeRegistrar();
    final service = _build(registrar);

    expect(await service.init(), HotkeyStatus.registered);
    expect(service.activeHotkeyId, HotkeyService.defaultHotkeyId);
    expect(registrar.active, <String>[HotkeyService.defaultHotkeyId]);
  });

  test('默认热键被占用时自动降级，且不篡改用户偏好', () async {
    final registrar = _FakeRegistrar(occupied: <String>{'ctrl+alt+a'});
    final store = _MemoryStore();
    final service = _build(registrar, store);

    expect(await service.init(), HotkeyStatus.fallback);
    expect(service.activeHotkeyId, 'ctrl+shift+a');
    expect(service.desiredHotkeyId, 'ctrl+alt+a');
    expect(store.values.containsKey('screenshot_hotkey'), isFalse);
  });

  test('四个预设都被占用时标记为不可用', () async {
    final registrar = _FakeRegistrar(
      occupied: <String>{
        'ctrl+alt+a',
        'ctrl+shift+a',
        'ctrl+alt+q',
        'ctrl+shift+q',
      },
    );
    final service = _build(registrar);

    expect(await service.init(), HotkeyStatus.allUnavailable);
    expect(service.isActive, isFalse);
    expect(service.activeHotkeyId, isNull);
  });

  test('换到被占用的热键失败时保留原热键', () async {
    final registrar = _FakeRegistrar();
    final service = _build(registrar);
    await service.init();
    final before = service.activeHotkeyId;

    registrar.occupied.add('ctrl+alt+q');
    final ok = await service.setHotkey('ctrl+alt+q');

    expect(ok, isFalse);
    expect(service.lastErrorCode, 1409);
    expect(service.activeHotkeyId, before);
    expect(registrar.active, <String>[before!]);
  });

  test('换键成功会持久化并注销旧热键', () async {
    final registrar = _FakeRegistrar();
    final store = _MemoryStore();
    final service = _build(registrar, store);
    await service.init();

    expect(await service.setHotkey('ctrl+shift+q'), isTrue);
    expect(service.activeHotkeyId, 'ctrl+shift+q');
    expect(service.desiredHotkeyId, 'ctrl+shift+q');
    expect(service.status, HotkeyStatus.registered);
    expect(store.values['screenshot_hotkey'], 'ctrl+shift+q');
    expect(registrar.active, <String>['ctrl+shift+q']);
  });

  test('已保存的偏好优先于默认值', () async {
    final registrar = _FakeRegistrar();
    final store = _MemoryStore(<String, String>{
      'screenshot_hotkey': 'ctrl+alt+q',
    });
    final service = _build(registrar, store);

    expect(await service.init(), HotkeyStatus.registered);
    expect(service.activeHotkeyId, 'ctrl+alt+q');
  });

  test('降级后可以把当前临时热键固定下来', () async {
    final registrar = _FakeRegistrar(occupied: <String>{'ctrl+alt+a'});
    final store = _MemoryStore();
    final service = _build(registrar, store);
    await service.init();

    await service.adoptActiveAsDesired();

    expect(service.desiredHotkeyId, 'ctrl+shift+a');
    expect(service.status, HotkeyStatus.registered);
    expect(store.values['screenshot_hotkey'], 'ctrl+shift+a');
  });

  test('冲突提示只忽略一次：换了热键要重新提示', () async {
    final store = _MemoryStore();
    final first = _build(
      _FakeRegistrar(occupied: <String>{'ctrl+alt+a'}),
      store,
    );
    await first.init();

    expect(await first.isConflictAcknowledged(), isFalse);
    await first.acknowledgeConflict();
    expect(await first.isConflictAcknowledged(), isTrue);

    // 同一份“忽略记录”只对当时的期望热键有效。
    final second = _build(
      _FakeRegistrar(occupied: <String>{'ctrl+alt+q'}),
      _MemoryStore(<String, String>{
        'screenshot_hotkey': 'ctrl+alt+q',
        'screenshot_hotkey_conflict_ack': 'ctrl+alt+a',
      }),
    );
    await second.init();
    expect(await second.isConflictAcknowledged(), isFalse);
  });

  test('探测结果里当前生效的热键始终可用', () async {
    final registrar = _FakeRegistrar(occupied: <String>{'ctrl+alt+a'});
    final service = _build(registrar);
    await service.init();

    final list = await service.probeAll();
    final active = list.firstWhere(
      (item) => item.option.id == service.activeHotkeyId,
    );
    expect(active.available, isTrue);
    final desired = list.firstWhere(
      (item) => item.option.id == 'ctrl+alt+a',
    );
    expect(desired.available, isFalse);
  });

  test('注册成功后可以触发 onTrigger 回调', () async {
    final registrar = _FakeRegistrar();
    final service = _build(registrar);
    var triggered = 0;
    service.onTrigger = () => triggered++;
    await service.init();

    registrar.fire();
    expect(triggered, 1);
  });
}
