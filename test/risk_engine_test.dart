import 'package:charge_guard/domain/models.dart';
import 'package:charge_guard/domain/risk_engine.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const engine = RiskEngine();
  final t0 = DateTime(2026, 11, 23, 10);

  SessionSnapshot snap({
    required PowerPlug plug,
    UsbPortState port = UsbPortState.empty,
    ChargingContext? charging,
    DeviceSecurityState security = DeviceSecurityState.unknown,
    List<UsbDeviceInfo> hostDevices = const [],
    List<String> apps = const [],
    bool active = true,
  }) {
    return SessionSnapshot(
      capturedAt: t0,
      sessionActive: active,
      sessionStartedAt: active ? t0 : null,
      port: port,
      charging: charging ??
          ChargingContext(
            plug: plug,
            usbNetworkInterface:
                port.networkFunctions.isNotEmpty ? 'usb0' : null,
          ),
      security: security,
      hostDevices: hostDevices,
      appsInstalledDuringSession: apps,
    );
  }

  Set<UsbFunction> fns(List<UsbFunction> l) => l.toSet();

  group('供电类型', () {
    test('纯交流充电判定为安全', () {
      final r = engine.assess(snap(plug: PowerPlug.ac));
      expect(r.level, RiskLevel.none);
      expect(r.exposesDataChannel, isFalse);
      expect(r.findings.single.code, 'powerOnlyCharger');
    });

    test('无线充电判定为安全', () {
      final r = engine.assess(snap(plug: PowerPlug.wireless));
      expect(r.level, RiskLevel.none);
      expect(r.exposesDataChannel, isFalse);
    });

    test('USB 已连接但未开放任何功能：不误报', () {
      final r = engine.assess(snap(
        plug: PowerPlug.usb,
        port: const UsbPortState(connected: true, configured: true),
      ));
      expect(r.exposesDataChannel, isFalse);
      expect(r.level, RiskLevel.none);
      expect(r.findings.single.code, 'enumeratedNoData');
    });

    test('供电未知时不判定为安全（保守）', () {
      final r = engine.assess(snap(plug: PowerPlug.unknown));
      expect(r.level, RiskLevel.low);
    });

    test('回归：交流供电但暴露数据功能，绝不判定为"安全"', () {
      // 真机/底座实测会出现的组合：系统上报交流供电，同时 USB 仍开放 ADB/PTP。
      // 若按供电类型直接判安全，会在界面上给出"当前连接是安全的"的错误保证。
      final r = engine.assess(snap(
        plug: PowerPlug.ac,
        port: UsbPortState(
          connected: true,
          configured: true,
          functions: fns([UsbFunction.adb, UsbFunction.ptp]),
        ),
      ));
      expect(r.exposesDataChannel, isTrue);
      expect(r.level, RiskLevel.high);
      expect(r.findings.map((f) => f.code), contains('adbExposed'));
      // 不应再出现"纯供电连接"这条会造成反向误导的结论。
      expect(r.findings.map((f) => f.code), isNot(contains('powerOnlyCharger')));
    });
  });

  group('设备模式数据通道', () {
    test('MTP 暴露 → 中风险', () {
      final r = engine.assess(snap(
        plug: PowerPlug.usb,
        port: UsbPortState(
          connected: true,
          configured: true,
          functions: fns([UsbFunction.mtp]),
        ),
      ));
      expect(r.level, RiskLevel.medium);
      expect(r.exposesDataChannel, isTrue);
      expect(r.findings.map((f) => f.code), contains('mtpExposed'));
    });

    test('锁屏下 MTP 暴露 → 高风险', () {
      final r = engine.assess(snap(
        plug: PowerPlug.usb,
        security: const DeviceSecurityState(deviceLocked: true),
        port: UsbPortState(
          connected: true,
          configured: true,
          functions: fns([UsbFunction.mtp]),
        ),
      ));
      expect(r.findings.first.code, 'mtpExposed');
      expect(r.findings.first.severity, FindingSeverity.high);
      expect(r.level, RiskLevel.high);
    });

    test('ADB 暴露 → 高风险', () {
      final r = engine.assess(snap(
        plug: PowerPlug.usb,
        port: UsbPortState(
          connected: true,
          configured: true,
          functions: fns([UsbFunction.adb]),
        ),
      ));
      expect(r.level, RiskLevel.high);
      expect(r.findings.map((f) => f.code), contains('adbExposed'));
    });

    test('RNDIS 网络通道 → 高风险，并识别虚拟网卡', () {
      final r = engine.assess(snap(
        plug: PowerPlug.usb,
        port: UsbPortState(
          connected: true,
          configured: true,
          functions: fns([UsbFunction.rndis]),
        ),
      ));
      expect(r.level, RiskLevel.high);
      final codes = r.findings.map((f) => f.code).toList();
      expect(codes, containsAll(['usbNetworkExposed', 'usbNetworkInterfaceUp']));
    });

    test('未知功能位按数据通道处理', () {
      final r = engine.assess(snap(
        plug: PowerPlug.usb,
        port: UsbPortState(
          connected: true,
          configured: true,
          functions: fns([UsbFunction.other]),
        ),
      ));
      expect(r.findings.map((f) => f.code), contains('unknownFunction'));
      expect(r.level, RiskLevel.medium);
    });

    test('MIDI 等低危通道只算低风险', () {
      final r = engine.assess(snap(
        plug: PowerPlug.usb,
        port: UsbPortState(
          connected: true,
          configured: true,
          functions: fns([UsbFunction.midi]),
        ),
      ));
      expect(r.level, RiskLevel.low);
      expect(r.exposesDataChannel, isFalse);
    });

    test('回归：启用 ADB 但无主机连接 → 姿态提示，不算"正在读取"', () {
      // 真机上常见：开发者选项开着、上次连过电脑，USB_STATE 里 adb=true，
      // 但当前 connected=false、configured=false，并没有主机在连接。
      // 此时若断言"对方可能正在读取你的手机"，就是虚假告警。
      final r = engine.assess(snap(
        plug: PowerPlug.ac,
        port: UsbPortState(
          connected: false,
          configured: false,
          functions: fns([UsbFunction.adb, UsbFunction.ptp]),
        ),
      ));
      expect(r.activeExposure, isFalse);
      expect(r.exposesDataChannel, isFalse);
      expect(r.level, isNot(RiskLevel.high));
      // 仍应给出姿态提示，而不是完全沉默。
      final codes = r.findings.map((f) => f.code).toList();
      expect(codes, contains('adbEnabledIdle'));
      expect(codes, isNot(contains('adbExposed')));
    });
  });

  group('连接期间安装应用', () {
    test('新增应用 → 高风险', () {
      final r = engine.assess(snap(
        plug: PowerPlug.usb,
        apps: ['com.evil.payload'],
      ));
      expect(r.level, RiskLevel.high);
      final f = r.findings.firstWhere((f) => f.code == 'appsInstalledWhileCharging');
      expect(f.severity, FindingSeverity.high);
      expect((f.evidence['packages'] as List), contains('com.evil.payload'));
    });
  });

  group('宿主模式外设', () {
    test('USB 网卡 → 高风险', () {
      final r = engine.assess(snap(
        plug: PowerPlug.none,
        hostDevices: const [
          UsbDeviceInfo(
            deviceName: '/dev/bus/usb/001/002',
            vendorId: 0x0bda,
            productId: 0x8153,
            deviceClass: 0x02,
            deviceSubclass: 0,
            deviceProtocol: 0,
          ),
        ],
      ));
      expect(r.level, RiskLevel.high);
      expect(r.findings.map((f) => f.code), contains('hostNetworkAdapter'));
    });

    test('HID 设备 → 中风险（防按键注入）', () {
      final r = engine.assess(snap(
        plug: PowerPlug.none,
        hostDevices: const [
          UsbDeviceInfo(
            deviceName: '/dev/bus/usb/001/003',
            vendorId: 0x1234,
            productId: 0x5678,
            deviceClass: 0x03,
            deviceSubclass: 0,
            deviceProtocol: 0,
          ),
        ],
      ));
      expect(r.level, RiskLevel.medium);
      expect(r.findings.map((f) => f.code), contains('hostHidAttached'));
    });

    test('存储设备 → 低风险', () {
      final r = engine.assess(snap(
        plug: PowerPlug.none,
        hostDevices: const [
          UsbDeviceInfo(
            deviceName: '/dev/bus/usb/001/004',
            vendorId: 0x1111,
            productId: 0x2222,
            deviceClass: 0x08,
            deviceSubclass: 0,
            deviceProtocol: 0,
          ),
        ],
      ));
      expect(r.level, RiskLevel.low);
      expect(r.findings.map((f) => f.code), contains('hostMassStorage'));
    });
  });

  group('安全姿态', () {
    test('USB 调试开启但未对本次连接开放 → 低风险提示', () {
      final r = engine.assess(snap(
        plug: PowerPlug.usb,
        security: const DeviceSecurityState(
          adbEnabled: true,
          developerOptionsEnabled: true,
        ),
        port: const UsbPortState(connected: true, configured: true),
      ));
      final codes = r.findings.map((f) => f.code).toList();
      expect(codes, contains('adbEnabledStandby'));
      expect(r.level, RiskLevel.low);
    });

    test('同一发现不重复计分', () {
      final r = engine.assess(snap(
        plug: PowerPlug.usb,
        port: UsbPortState(
          connected: true,
          configured: true,
          functions: fns([UsbFunction.rndis, UsbFunction.ncm]),
        ),
      ));
      // 网络类只产生一条网络暴露发现（外加网卡证据），分数不应随功能个数翻倍。
      expect(r.score, lessThanOrEqualTo(14));
    });
  });

  group('会话未激活', () {
    test('未连接时不产生任何发现', () {
      final r = engine.assess(SessionSnapshot(
        capturedAt: t0,
        sessionActive: false,
      ));
      expect(r.level, RiskLevel.none);
      expect(r.findings, isEmpty);
    });
  });

  group('序列化', () {
    test('快照 JSON 往返保持一致', () {
      final original = snap(
        plug: PowerPlug.usb,
        security: const DeviceSecurityState(deviceLocked: true, adbEnabled: true),
        port: UsbPortState(
          connected: true,
          configured: true,
          functions: fns([UsbFunction.mtp, UsbFunction.adb]),
        ),
        hostDevices: const [
          UsbDeviceInfo(
            deviceName: '/dev/x',
            vendorId: 1,
            productId: 2,
            deviceClass: 3,
            deviceSubclass: 0,
            deviceProtocol: 0,
            productName: 'Test',
          ),
        ],
        apps: ['a.b'],
      );
      final round = SessionSnapshot.fromJson(original.toJson());
      expect(round.port.functions, original.port.functions);
      expect(round.security.deviceLocked, isTrue);
      expect(round.hostDevices.single.productName, 'Test');
      expect(round.appsInstalledDuringSession, ['a.b']);
      expect(round.charging.plug, PowerPlug.usb);
    });
  });
}
