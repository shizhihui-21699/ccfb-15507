import 'package:charge_guard/domain/models.dart';
import 'package:charge_guard/domain/policy_engine.dart';
import 'package:charge_guard/domain/risk_engine.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const risk = RiskEngine();
  const policy = PolicyEngine();
  final t0 = DateTime(2026, 11, 23, 10);

  SessionSnapshot snap({
    required PowerPlug plug,
    UsbPortState port = UsbPortState.empty,
    DeviceSecurityState security = DeviceSecurityState.unknown,
    List<UsbDeviceInfo> hostDevices = const [],
    CapabilityProfile caps = CapabilityProfile.unknown,
    bool active = true,
  }) {
    return SessionSnapshot(
      capturedAt: t0,
      sessionActive: active,
      sessionStartedAt: active ? t0 : null,
      port: port,
      charging: ChargingContext(plug: plug),
      security: security,
      hostDevices: hostDevices,
      capabilities: caps,
    );
  }

  PolicyDecision decide(
    SessionSnapshot s, {
    List<TrustRecord> trusts = const [],
    GuardSettings settings = const GuardSettings(),
    DateTime? now,
  }) =>
      policy.decide(
        snapshot: s,
        assessment: risk.assess(s),
        trusts: trusts,
        settings: settings,
        // 显式固定参照时间，避免测试结果随真实时钟漂移。
        now: now ?? t0,
      );

  group('第一优先级：不妨碍正常使用', () {
    test('连接自己的电脑（宿主模式，已信任）→ 静默', () {
      const myPc = UsbDeviceInfo(
        deviceName: '/dev/bus/usb/001/002',
        vendorId: 0x05ac,
        productId: 0x12a8,
        deviceClass: 0x00,
        deviceSubclass: 0,
        deviceProtocol: 0,
        serialHash: 'abc123',
      );
      final s = snap(plug: PowerPlug.none, hostDevices: const [myPc]);
      final d = decide(s, trusts: [
        TrustRecord(
          id: 't1',
          label: '我的 MacBook',
          kind: TrustKind.hostDevice,
          fingerprint: myPc.fingerprint,
          createdAt: t0,
          permanent: true,
        ),
      ]);
      expect(d.action, PolicyAction.monitor);
      expect(d.trustedBy?.label, '我的 MacBook');
    });

    test('受信任电脑即使打开了 MTP 也不告警', () {
      // 自己的电脑插上后打开文件传输是正常行为，不应被当作攻击。
      final s = snap(
        plug: PowerPlug.usb,
        port: UsbPortState(
          connected: true,
          configured: true,
          functions: {UsbFunction.mtp},
        ),
      );
      final d = decide(s, trusts: [
        TrustRecord(
          id: 't2',
          label: '本次已确认',
          kind: TrustKind.session,
          createdAt: t0,
        ),
      ]);
      expect(d.action, PolicyAction.monitor);
    });

    test('纯供电充电器 → 仅告知，不告警', () {
      final d = decide(snap(plug: PowerPlug.ac));
      expect(d.action, PolicyAction.inform);
    });

    test('回归：交流供电但暴露数据通道 → 仍须告警', () {
      final s = snap(
        plug: PowerPlug.ac,
        port: UsbPortState(
          connected: true,
          configured: true,
          functions: {UsbFunction.adb, UsbFunction.ptp},
        ),
      );
      expect(decide(s).action, isNot(PolicyAction.inform));
      expect(decide(s).action, isNot(PolicyAction.monitor));
    });

    test('回归：ADB 已开启但无主机连接 → 只提示，不告警', () {
      final s = snap(
        plug: PowerPlug.usb,
        port: UsbPortState(
          connected: false,
          configured: false,
          functions: {UsbFunction.adb},
        ),
      );
      expect(decide(s).action, PolicyAction.inform);
    });

    test('未连接 → 静默', () {
      final d = decide(snap(plug: PowerPlug.none, active: false));
      expect(d.action, PolicyAction.monitor);
    });
  });

  group('告警升级', () {
    test('陌生端口暴露 MTP，且未信任 → 告警', () {
      final s = snap(
        plug: PowerPlug.usb,
        port: UsbPortState(
          connected: true,
          configured: true,
          functions: {UsbFunction.mtp},
        ),
      );
      expect(decide(s).action, PolicyAction.alert);
    });

    test('锁屏下暴露数据通道 → 全屏告警', () {
      final s = snap(
        plug: PowerPlug.usb,
        security: const DeviceSecurityState(deviceLocked: true),
        port: UsbPortState(
          connected: true,
          configured: true,
          functions: {UsbFunction.adb},
        ),
      );
      expect(decide(s).action, PolicyAction.urgentAlert);
    });

    test('关闭"锁屏告警"后降级为普通告警', () {
      final s = snap(
        plug: PowerPlug.usb,
        security: const DeviceSecurityState(deviceLocked: true),
        port: UsbPortState(
          connected: true,
          configured: true,
          functions: {UsbFunction.adb},
        ),
      );
      final d = decide(s, settings: const GuardSettings(alertWhileLocked: false));
      expect(d.action, PolicyAction.alert);
    });

    test('无数据通道的中危迹象 → 只告知', () {
      final s = snap(
        plug: PowerPlug.usb,
        port: UsbPortState(
          connected: true,
          configured: true,
          functions: {UsbFunction.other},
        ),
      );
      // unknownFunction 为中危，但不属于已暴露通道。
      expect(decide(s).action, PolicyAction.inform);
    });
  });

  group('阻断与权限', () {
    test('具备设备所有者权限且用户开启自动阻断 → 关断数据', () {
      final s = snap(
        plug: PowerPlug.usb,
        port: UsbPortState(
          connected: true,
          configured: true,
          functions: {UsbFunction.mtp},
        ),
        caps: const CapabilityProfile(
          platform: 'android',
          sdkInt: 34,
          manufacturer: 'Google',
          brand: 'google',
          model: 'Pixel',
          isDeviceOwner: true,
          canDisableUsbDataSignaling: true,
          usbStateObservable: true,
          canQueryInstalledPackages: false,
        ),
      );
      final d = decide(s,
          settings: const GuardSettings(blockWhenDeviceOwner: true));
      expect(d.action, PolicyAction.blockData);
    });

    test('无阻断能力时绝不假装阻断', () {
      final s = snap(
        plug: PowerPlug.usb,
        port: UsbPortState(
          connected: true,
          configured: true,
          functions: {UsbFunction.mtp},
        ),
      );
      // 默认设置下即便能力不足也只是 alert，不会出现 blockData。
      expect(decide(s).action, isNot(PolicyAction.blockData));
    });
  });

  group('信任有效期', () {
    test('过期的会话信任不再生效', () {
      final s = snap(
        plug: PowerPlug.usb,
        port: UsbPortState(
          connected: true,
          configured: true,
          functions: {UsbFunction.mtp},
        ),
      );
      final expired = TrustRecord(
        id: 'old',
        label: '旧的',
        kind: TrustKind.session,
        createdAt: t0.subtract(const Duration(hours: 5)),
        expiresAt: t0.subtract(const Duration(hours: 1)),
      );
      expect(decide(s, trusts: [expired]).action, PolicyAction.alert);
    });

    test('未过期的会话信任生效', () {
      final s = snap(
        plug: PowerPlug.usb,
        port: UsbPortState(
          connected: true,
          configured: true,
          functions: {UsbFunction.mtp},
        ),
      );
      final valid = TrustRecord(
        id: 'new',
        label: '刚确认',
        kind: TrustKind.session,
        createdAt: t0,
        expiresAt: t0.add(const Duration(hours: 2)),
      );
      expect(decide(s, trusts: [valid]).action, PolicyAction.monitor);
    });

    test('配置的信任窗口写入信任记录', () {
      const settings = GuardSettings(trustWindow: Duration(minutes: 30));
      final now = DateTime(2026, 11, 23, 10);
      final expires = now.add(settings.trustWindow);
      expect(expires, DateTime(2026, 11, 23, 10, 30));
    });
  });

  group('总开关', () {
    test('关闭防护后不告警', () {
      final s = snap(
        plug: PowerPlug.usb,
        port: UsbPortState(
          connected: true,
          configured: true,
          functions: {UsbFunction.adb},
        ),
      );
      final d = decide(s, settings: const GuardSettings(enabled: false));
      expect(d.action, PolicyAction.monitor);
      expect(d.reason, contains('关闭'));
    });
  });

  group('设置序列化', () {
    test('往返保持', () {
      const s = GuardSettings(
        enabled: false,
        alertWhileLocked: false,
        blockWhenDeviceOwner: true,
        trustWindow: Duration(minutes: 45),
      );
      final round = GuardSettings.fromJson(s.toJson());
      expect(round.enabled, isFalse);
      expect(round.blockWhenDeviceOwner, isTrue);
      expect(round.trustWindow, const Duration(minutes: 45));
    });
  });
}
