/// 平台信号的来源抽象。
///
/// 这一层把"从哪里拿到 USB/供电状态"与"如何判定风险"隔离开：
/// - 真机上是 [MethodChannelPlatformSignalSource]，由 Kotlin 侧推送；
/// - 测试与演示用 [SimulatedPlatformSignalSource]，可精确复现各厂商行为。
///
/// 之所以这样分层，是因为**跨厂商/跨版本的系统行为差异是本功能最大的不确定性**，
/// 把它收敛到一个窄接口，就能用单元测试覆盖"某厂商上报 configured 但无 functions"
/// 这类真实存在的差异，而不必依赖手头是否有对应机型。
library;

import 'dart:async';
import 'dart:convert';

import 'package:flutter/services.dart';

import '../domain/models.dart';

/// 平台能力与信号的统一接口。
abstract class PlatformSignalSource {
  /// 一次性探测本机能力，供 UI 如实展示"能做什么/做不到什么"。
  Future<CapabilityProfile> probeCapabilities();

  /// 当前快照（用于首帧渲染，避免白屏）。
  SessionSnapshot get current;

  /// 状态流：每次系统信号变化推送一个新快照。
  Stream<SessionSnapshot> get snapshots;

  /// 用户做出处置决策时回传给原生层（例如"阻断数据"/"信任设备"）。
  Future<void> applyAction(PlatformAction action);

  /// 尝试在系统层关断 USB 数据，并**如实返回是否成功**。
  ///
  /// 只有设备所有者 + 厂商实现了 `setUsbDataSignalingEnabled` 时才可能成功；
  /// 调用方必须依据返回值决定是"已阻断"还是"引导用户手动处理"，
  /// 不允许把失败当作成功展示。
  Future<bool> blockUsbData();

  /// 恢复 USB 数据（撤销 [blockUsbData]）。
  Future<bool> allowUsbData();

  /// 打开系统 USB 设置页（引导用户手动关闭数据）。
  Future<void> openUsbSettings();

  /// 请求原生层发出高优先级告警通知（用户可能不在 App 内，尤其是锁屏时）。
  Future<void> showAlertNotification(String title, String body);

  Future<void> dispose();
}

/// 回传给原生层的动作。
class PlatformAction {
  const PlatformAction(this.type, {this.payload = const {}});

  final PlatformActionType type;
  final Map<String, Object?> payload;

  static const blockUsbData = PlatformAction(PlatformActionType.blockUsbData);
  static const allowUsbData = PlatformAction(PlatformActionType.allowUsbData);

  Map<String, Object?> toJson() => {
        'type': type.name,
        'payload': payload,
      };
}

enum PlatformActionType {
  /// 关断 USB 数据信号（需设备所有者）。
  blockUsbData,

  /// 恢复 USB 数据信号。
  allowUsbData,

  /// 记录一条用户信任。
  trustDevice,

  /// 刷新当前快照。
  refresh,
}

/// 真机实现：通过 MethodChannel 与 Kotlin 侧通信。
class MethodChannelPlatformSignalSource implements PlatformSignalSource {
  MethodChannelPlatformSignalSource({MethodChannel? channel})
      : _channel = channel ?? const MethodChannel(channelName) {
    _channel.setMethodCallHandler(_onNativeCall);
  }

  static const channelName = 'io.chargeguard/guard';

  final MethodChannel _channel;
  final _controller = StreamController<SessionSnapshot>.broadcast();
  SessionSnapshot _current = SessionSnapshot.idle();

  @override
  SessionSnapshot get current => _current;

  @override
  Stream<SessionSnapshot> get snapshots => _controller.stream;

  Future<dynamic> _onNativeCall(MethodCall call) async {
    switch (call.method) {
      case 'onSnapshot':
        final map = (call.arguments as Map).cast<String, Object?>();
        _current = SessionSnapshot.fromJson(map);
        _controller.add(_current);
        break;
      case 'onCapabilities':
        // 能力探测结果会通过 probeCapabilities 返回，这里仅缓存。
        break;
    }
  }

  @override
  Future<CapabilityProfile> probeCapabilities() async {
    try {
      final raw = await _channel.invokeMethod<Map>('probeCapabilities');
      if (raw == null) return CapabilityProfile.unknown;
      return CapabilityProfile.fromJson(raw.cast<String, Object?>());
    } on PlatformException {
      return CapabilityProfile.unknown;
    } on MissingPluginException {
      // 非 Android 平台（例如在桌面跑测试）。
      return CapabilityProfile.unknown;
    }
  }

  /// 启动原生监听并取回当前快照。
  Future<SessionSnapshot> start() async {
    try {
      final raw = await _channel.invokeMethod<Map>('start');
      if (raw != null) {
        _current = SessionSnapshot.fromJson(raw.cast<String, Object?>());
        _controller.add(_current);
      }
    } on PlatformException {
      // 忽略：将由后续推送更新。
    } on MissingPluginException {
      // 无需原生层时静默。
    }
    return _current;
  }

  @override
  Future<void> applyAction(PlatformAction action) async {
    try {
      await _channel.invokeMethod<void>('applyAction', action.toJson());
    } on PlatformException {
      // 原生层拒绝（例如无设备所有者权限）时静默，UI 会依据下一次快照刷新。
    } on MissingPluginException {
      // 忽略。
    }
  }

  @override
  Future<bool> blockUsbData() async {
    try {
      final ok = await _channel.invokeMethod<bool>('applyAction', {
        'type': PlatformActionType.blockUsbData.name,
        'payload': const <String, Object?>{},
      });
      return ok ?? false;
    } on PlatformException {
      return false;
    } on MissingPluginException {
      return false;
    }
  }

  @override
  Future<bool> allowUsbData() async {
    try {
      final ok = await _channel.invokeMethod<bool>('applyAction', {
        'type': PlatformActionType.allowUsbData.name,
        'payload': const <String, Object?>{},
      });
      return ok ?? false;
    } on PlatformException {
      return false;
    } on MissingPluginException {
      return false;
    }
  }

  @override
  Future<void> openUsbSettings() async {
    try {
      await _channel.invokeMethod<void>('openUsbSettings');
    } on PlatformException {
      // 忽略。
    } on MissingPluginException {
      // 忽略。
    }
  }

  @override
  Future<void> showAlertNotification(String title, String body) async {
    try {
      await _channel.invokeMethod<void>('showAlert', {
        'title': title,
        'body': body,
      });
    } on PlatformException {
      // 忽略：通知权限可能被拒，App 内界面仍会提示。
    } on MissingPluginException {
      // 忽略。
    }
  }

  @override
  Future<void> dispose() async {
    _channel.setMethodCallHandler(null);
    await _controller.close();
  }
}

/// 模拟信号源：用于演示模式、预览与集成测试。
///
/// 它刻意实现为"可回放一组历史快照"，这样 UI 与判定链路都可以在没有
/// 真机/模拟器 USB 事件的情况下被完整验证。
class SimulatedPlatformSignalSource implements PlatformSignalSource {
  SimulatedPlatformSignalSource({
    CapabilityProfile capabilities = demoCapabilities,
    List<SessionSnapshot>? script,
    Duration frameInterval = const Duration(seconds: 3),
  })  : _capabilities = capabilities, // ignore: prefer_initializing_formals
        _script = script ?? demoScript(),
        _frameInterval = frameInterval; // ignore: prefer_initializing_formals

  final CapabilityProfile _capabilities;
  final List<SessionSnapshot> _script;
  final Duration _frameInterval;

  final _controller = StreamController<SessionSnapshot>.broadcast();
  SessionSnapshot _current = SessionSnapshot.idle();
  Timer? _timer;
  int _index = 0;
  bool _looping = false;

  static const demoCapabilities = CapabilityProfile(
    platform: 'android',
    sdkInt: 34,
    manufacturer: 'Demo',
    brand: 'demo',
    model: 'Simulated Pixel',
    isDeviceOwner: false,
    canDisableUsbDataSignaling: false,
    usbStateObservable: true,
    canQueryInstalledPackages: false,
    notes: [
      '当前为演示数据：未连接真实 USB 设备。',
      '真机上会依据系统上报的实际状态判定。',
    ],
  );

  @override
  SessionSnapshot get current => _current;

  @override
  Stream<SessionSnapshot> get snapshots => _controller.stream;

  @override
  Future<CapabilityProfile> probeCapabilities() async => _capabilities;

  /// 开始按脚本轮播（循环）。
  void startDemo({bool loop = true}) {
    _looping = loop;
    _emitNext();
    _timer?.cancel();
    _timer = Timer.periodic(_frameInterval, (_) => _emitNext());
  }

  /// 手动推入一个快照（测试用）。
  void push(SessionSnapshot s) {
    _current = s;
    _controller.add(s);
  }

  void _emitNext() {
    if (_script.isEmpty) return;
    if (_index >= _script.length) {
      if (!_looping) {
        _timer?.cancel();
        return;
      }
      _index = 0;
    }
    _current = _script[_index];
    _index++;
    _controller.add(_current);
  }

  @override
  Future<void> applyAction(PlatformAction action) async {
    // 模拟模式下，阻断动作体现为把当前快照的数据功能清空。
    if (action.type == PlatformActionType.blockUsbData) {
      push(_current.copyWith(
        port: _current.port.copyWith(functions: const {}),
      ));
    } else if (action.type == PlatformActionType.allowUsbData) {
      // 恢复为上一次脚本帧（若已到末尾则退回第 1 帧）。
      final frame = _script.isEmpty
          ? _current
          : _script[(_index - 1).clamp(0, _script.length - 1)];
      push(frame);
    }
  }

  @override
  Future<bool> blockUsbData() async {
    await applyAction(PlatformAction.blockUsbData);
    // 模拟环境中总是"成功"，以便演示阻断后的界面效果。
    return true;
  }

  @override
  Future<bool> allowUsbData() async {
    await applyAction(PlatformAction.allowUsbData);
    return true;
  }

  @override
  Future<void> openUsbSettings() async {}

  @override
  Future<void> showAlertNotification(String title, String body) async {
    // 模拟模式下不弹系统通知，由 UI 内联展示。
  }

  @override
  Future<void> dispose() async {
    _timer?.cancel();
    await _controller.close();
  }

  /// 演示脚本：依次呈现几种典型场景。
  static List<SessionSnapshot> demoScript() {
    final base = DateTime.now();
    SessionSnapshot at(int sec) => SessionSnapshot(
          capturedAt: base.add(Duration(seconds: sec)),
          sessionActive: true,
          sessionStartedAt: base,
          capabilities: demoCapabilities,
        );

    return [
      // 1) 纯充电：安全。
      at(0).copyWithSession(
        port: const UsbPortState(connected: true),
        charging: const ChargingContext(plug: PowerPlug.ac, chargeCurrentMa: 1800),
      ),
      // 2) 陌生端口暴露 MTP：中风险。
      at(6).copyWithSession(
        port: UsbPortState(
          connected: true,
          configured: true,
          functions: {UsbFunction.mtp},
        ),
        charging: const ChargingContext(plug: PowerPlug.usb, chargeCurrentMa: 500),
      ),
      // 3) 出现 USB 网卡 + ADB：高风险。
      at(12).copyWithSession(
        port: UsbPortState(
          connected: true,
          configured: true,
          functions: {UsbFunction.mtp, UsbFunction.rndis, UsbFunction.adb},
        ),
        charging:
            const ChargingContext(plug: PowerPlug.usb, usbNetworkInterface: 'usb0'),
      ),
      // 4) 恢复为纯充电。
      at(18).copyWithSession(
        port: const UsbPortState(connected: true),
        charging: const ChargingContext(plug: PowerPlug.ac, chargeCurrentMa: 2000),
      ),
    ];
  }
}

extension on SessionSnapshot {
  /// 便于构造演示数据的辅助方法。
  SessionSnapshot copyWithSession({
    UsbPortState? port,
    ChargingContext? charging,
    DeviceSecurityState? security,
    List<UsbDeviceInfo>? hostDevices,
    List<String>? appsInstalledDuringSession,
    bool? sessionActive,
    bool? blocked,
  }) {
    final newPort = blocked == true
        ? (port ?? this.port).copyWith(functions: const {})
        : (port ?? this.port);
    return SessionSnapshot(
      capturedAt: capturedAt,
      sessionActive: sessionActive ?? this.sessionActive,
      sessionStartedAt: sessionStartedAt,
      port: newPort,
      charging: charging ?? this.charging,
      security: security ?? this.security,
      hostDevices: hostDevices ?? this.hostDevices,
      appsInstalledDuringSession:
          appsInstalledDuringSession ?? this.appsInstalledDuringSession,
      capabilities: capabilities,
    );
  }
}

/// 提供一个把 `Map` 编码成 JSON 字符串的简单工具，供调试导出使用。
String encodeSnapshot(SessionSnapshot s) =>
    const JsonEncoder.withIndent('  ').convert(s.toJson());
