import 'dart:async';

import 'package:charge_guard/app/guard_controller.dart';
import 'package:charge_guard/domain/models.dart';
import 'package:charge_guard/domain/policy_engine.dart';
import 'package:charge_guard/domain/risk_engine.dart';
import 'package:charge_guard/platform/signal_source.dart';
import 'package:flutter_test/flutter_test.dart';

/// 可按测试需要逐帧推入快照的信号源。
class ScriptedSource implements PlatformSignalSource {
  ScriptedSource({CapabilityProfile caps = CapabilityProfile.unknown})
      : _caps = caps; // ignore: prefer_initializing_formals

  final CapabilityProfile _caps;
  final _controller = StreamController<SessionSnapshot>.broadcast(sync: true);
  final List<PlatformAction> applied = [];
  SessionSnapshot _current = SessionSnapshot.idle();

  @override
  Future<CapabilityProfile> probeCapabilities() async => _caps;

  @override
  SessionSnapshot get current => _current;

  @override
  Stream<SessionSnapshot> get snapshots => _controller.stream;

  void emit(SessionSnapshot s) {
    _current = s;
    _controller.add(s);
  }

  @override
  Future<void> applyAction(PlatformAction a) async => applied.add(a);

  @override
  Future<bool> blockUsbData() async {
    applied.add(PlatformAction.blockUsbData);
    return _caps.canDisableUsbDataSignaling;
  }

  @override
  Future<bool> allowUsbData() async {
    applied.add(PlatformAction.allowUsbData);
    return true;
  }

  @override
  Future<void> openUsbSettings() async {}

  @override
  Future<void> showAlertNotification(String title, String body) async {}

  @override
  Future<void> dispose() async => _controller.close();
}

void main() {
  final t0 = DateTime(2026, 11, 23, 10);

  SessionSnapshot mk({
    required PowerPlug plug,
    UsbPortState port = UsbPortState.empty,
    bool active = true,
    DateTime? startedAt,
    CapabilityProfile caps = CapabilityProfile.unknown,
    List<String> apps = const [],
  }) =>
      SessionSnapshot(
        capturedAt: t0,
        sessionActive: active,
        sessionStartedAt: active ? (startedAt ?? t0) : null,
        port: port,
        charging: ChargingContext(plug: plug),
        capabilities: caps,
        appsInstalledDuringSession: apps,
      );

  test('陌生端口暴露数据通道 → 判定为告警', () async {
    final source = ScriptedSource();
    final c = GuardController(source: source, store: InMemoryStore());
    await c.init();

    source.emit(mk(
      plug: PowerPlug.usb,
      port: UsbPortState(
        connected: true,
        configured: true,
        functions: {UsbFunction.mtp},
      ),
    ));
    await pumpEventQueue();

    expect(c.assessment.exposesDataChannel, isTrue);
    expect(c.decision.action, PolicyAction.alert);
    c.dispose();
  });

  test('信任会话后不再告警', () async {
    final source = ScriptedSource();
    final c = GuardController(source: source, store: InMemoryStore());
    await c.init();

    final snap = mk(
      plug: PowerPlug.usb,
      port: UsbPortState(
        connected: true,
        configured: true,
        functions: {UsbFunction.mtp},
      ),
    );
    source.emit(snap);
    await pumpEventQueue();
    expect(c.decision.action, PolicyAction.alert);

    await c.trustCurrentSession();
    expect(c.decision.action, PolicyAction.monitor);
    c.dispose();
  });

  test('会话结束归档一条历史记录', () async {
    final source = ScriptedSource();
    final c = GuardController(source: source, store: InMemoryStore());
    await c.init();

    source.emit(mk(plug: PowerPlug.usb));
    await pumpEventQueue();
    source.emit(mk(plug: PowerPlug.none, active: false));
    await pumpEventQueue();

    expect(c.history, hasLength(1));
    c.dispose();
  });

  test('设置与信任可持久化并在新实例中恢复', () async {
    final store = InMemoryStore();
    final source = ScriptedSource();
    final c1 = GuardController(source: source, store: store);
    await c1.init();
    await c1.updateSettings(const GuardSettings(alertWhileLocked: false));
    await c1.trustCurrentSession();
    // 等待异步持久化完成。
    await pumpEventQueue();

    final c2 = GuardController(source: ScriptedSource(), store: store);
    await c2.init();
    expect(c2.settings.alertWhileLocked, isFalse);
    expect(c2.trusts, isNotEmpty);
    c1.dispose();
    c2.dispose();
  });

  test('无阻断能力时 blockData 返回 false', () async {
    final source = ScriptedSource();
    final c = GuardController(source: source, store: InMemoryStore());
    await c.init();
    final ok = await c.blockData();
    expect(ok, isFalse);
    c.dispose();
  });

  test('具备能力时 blockData 返回 true', () async {
    const caps = CapabilityProfile(
      platform: 'android',
      sdkInt: 34,
      manufacturer: 'Test',
      brand: 'test',
      model: 'T',
      isDeviceOwner: true,
      canDisableUsbDataSignaling: true,
      usbStateObservable: true,
      canQueryInstalledPackages: false,
    );
    final source = ScriptedSource(caps: caps);
    final c = GuardController(source: source, store: InMemoryStore());
    await c.init();
    final ok = await c.blockData();
    expect(ok, isTrue);
    c.dispose();
  });

  test('风险等级随信号变化而更新', () async {
    final source = ScriptedSource();
    final c = GuardController(source: source, store: InMemoryStore());
    await c.init();

    source.emit(mk(plug: PowerPlug.ac));
    await pumpEventQueue();
    expect(c.assessment.level, RiskLevel.none);

    source.emit(mk(
      plug: PowerPlug.usb,
      port: UsbPortState(
        connected: true,
        configured: true,
        functions: {UsbFunction.rndis},
      ),
    ));
    await pumpEventQueue();
    expect(c.assessment.level, RiskLevel.high);
    c.dispose();
  });

  test('连接期间新增应用会升级为高风险', () async {
    final source = ScriptedSource();
    final c = GuardController(source: source, store: InMemoryStore());
    await c.init();

    source.emit(mk(
      plug: PowerPlug.usb,
      apps: ['com.malware.pkg'],
    ));
    await pumpEventQueue();
    expect(c.assessment.level, RiskLevel.high);
    expect(
      c.assessment.findings.map((f) => f.code),
      contains('appsInstalledWhileCharging'),
    );
    c.dispose();
  });
}
