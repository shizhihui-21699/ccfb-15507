/// 公共充电防护的领域模型。
///
/// 设计原则：**所有判定逻辑都在纯 Dart 中完成，与 Android SDK 解耦。**
/// Kotlin 层只负责把系统信号翻译成 [SessionSnapshot]；风险评分（risk_engine）
/// 与处置策略（policy_engine）都是纯函数，因此可以针对各厂商、各系统版本的
/// 行为差异写单元测试，而不必依赖真机。
library;

// ---------------------------------------------------------------------------
// 供电与 USB 端口状态
// ---------------------------------------------------------------------------

/// 系统上报的供电方式。区分它是判断"是否可能建立数据连接"的第一道过滤。
///
/// - [ac]/[wireless]：纯供电，物理上没有数据线对，可判定为安全。
/// - [usb]：数据线已连接，对端可能是充电器、也可能是一台能枚举设备的主机。
enum PowerPlug { none, usb, ac, wireless, dock, unknown }

/// 手机作为 USB **设备**（被插入方）时对外暴露的 gadget 功能。
///
/// 名称与 Android `UsbManager.USB_FUNCTION_*` 一致。公共充电场景下，
/// 这些功能是"攻击者能看到什么"的直接体现：
/// - [mtp]/[ptp]：文件传输，可读取照片、文档。
/// - [rndis]/[ncm]：USB 网卡，建立一条隐蔽网络通路（DNS 劫持、中间人）。
/// - [adb]：调试桥，可安装应用、读通讯录、截屏。
/// - [midi]/[audioSource]/[accessory]：其他数据通道。
enum UsbFunction {
  mtp,
  ptp,
  rndis,
  ncm,
  midi,
  adb,
  audioSource,
  accessory,

  /// 系统上报了未知功能位，保守地按"数据通道"处理。
  other,
}

extension UsbFunctionX on UsbFunction {
  bool get isFileTransfer => this == UsbFunction.mtp || this == UsbFunction.ptp;
  bool get isNetwork => this == UsbFunction.rndis || this == UsbFunction.ncm;
  bool get isDebug => this == UsbFunction.adb;
}

/// 设备模式下 USB 端口的即时状态，来自系统 `ACTION_USB_STATE` 粘性广播。
///
/// 注意：该广播是受保护广播，普通应用**不能伪造**，只能接收/读取粘性值，
/// 因此可作为可信信号源。
class UsbPortState {
  const UsbPortState({
    this.connected = false,
    this.configured = false,
    this.dataUnlocked = false,
    this.functions = const {},
    this.rawExtras = const {},
  });

  /// 数据线已连接（`USB_STATE.connected`）。
  final bool connected;

  /// 主机已完成枚举与配置（`USB_STATE.configured`）。
  /// 注意：configured 为真但 [functions] 为空时，手机并未开放任何数据功能，
  /// 主机实际上读不到东西——这不是风险，应避免误报。
  final bool configured;

  /// 系统认为当前允许数据传输（`USB_STATE.unlocked`）。
  final bool dataUnlocked;

  /// 当前启用的 gadget 功能集合。
  final Set<UsbFunction> functions;

  /// 原始附加字段，用于诊断页展示与"厂商差异"取证。
  final Map<String, bool> rawExtras;

  /// 是否启用了数据通道（功能位非空）。
  ///
  /// 注意：**启用了功能 ≠ 正在被读取**。`USB_STATE` 报告的是当前 gadget
  /// 功能配置，即便没有主机连接（`connected=false`）也会保留。
  bool get exposesData => functions.isNotEmpty;

  /// 是否含有**敏感**数据通道（可能被用于读取照片/通讯录、安装应用或劫持网络）。
  ///
  /// MIDI、音频、未知功能位不计入——它们通常不涉及敏感数据，不应据此
  /// 断言"对方正在读取你的手机"。
  bool get hasSensitiveDataChannel =>
      functions.contains(UsbFunction.adb) ||
      functions.contains(UsbFunction.mtp) ||
      functions.contains(UsbFunction.ptp) ||
      functions.contains(UsbFunction.rndis) ||
      functions.contains(UsbFunction.ncm) ||
      functions.contains(UsbFunction.accessory);

  /// 是否**此刻**确有主机在读取敏感数据：数据线已连接、主机已完成枚举、
  /// 且开启了敏感数据功能。
  ///
  /// 这是判定"对方正在读取你的手机"的唯一依据。区分它与 [exposesData]
  /// 很重要：前者是正在进行的数据暴露，后者只是"数据通道处于开启状态"的
  /// 安全姿态问题。把姿态问题误报成"正在被读取"会造成告警疲劳。
  bool get isActivelyExposed => connected && configured && hasSensitiveDataChannel;

  /// 启用了数据功能，但当前没有主机在读取（姿态风险）。
  bool get dataEnabledButIdle => functions.isNotEmpty && !isActivelyExposed;

  Set<UsbFunction> get fileTransferFunctions =>
      functions.where((f) => f.isFileTransfer).toSet();
  Set<UsbFunction> get networkFunctions =>
      functions.where((f) => f.isNetwork).toSet();
  bool get exposesDebug => functions.contains(UsbFunction.adb);

  UsbPortState copyWith({
    bool? connected,
    bool? configured,
    bool? dataUnlocked,
    Set<UsbFunction>? functions,
    Map<String, bool>? rawExtras,
  }) {
    return UsbPortState(
      connected: connected ?? this.connected,
      configured: configured ?? this.configured,
      dataUnlocked: dataUnlocked ?? this.dataUnlocked,
      functions: functions ?? this.functions,
      rawExtras: rawExtras ?? this.rawExtras,
    );
  }

  Map<String, Object?> toJson() => {
        'connected': connected,
        'configured': configured,
        'dataUnlocked': dataUnlocked,
        'functions': functions.map((f) => f.name).toList(),
        'rawExtras': rawExtras,
      };

  static UsbPortState fromJson(Map<String, Object?> json) {
    final rawFunctions = (json['functions'] as List?) ?? const [];
    final rawExtras = (json['rawExtras'] as Map?) ?? const {};
    return UsbPortState(
      connected: json['connected'] as bool? ?? false,
      configured: json['configured'] as bool? ?? false,
      dataUnlocked: json['dataUnlocked'] as bool? ?? false,
      functions: rawFunctions
          .map((n) => _functionFromName(n as String))
          .whereType<UsbFunction>()
          .toSet(),
      rawExtras: rawExtras.map((k, v) => MapEntry(k as String, v as bool)),
    );
  }

  static UsbFunction? _functionFromName(String name) {
    for (final f in UsbFunction.values) {
      if (f.name == name) return f;
    }
    // Kotlin 侧可能上报系统新增的功能位。
    return UsbFunction.other;
  }

  static const empty = UsbPortState();
}

/// 与供电相关的附加上下文。
class ChargingContext {
  const ChargingContext({
    this.plug = PowerPlug.none,
    this.usbNetworkInterface,
    this.chargeCurrentMa,
  });

  final PowerPlug plug;

  /// 若连接后出现了一张 USB/以太网虚拟网卡（如 `usb0`），其名称会记录在此。
  /// 这是 RNDIS/NCM 数据通路已建立的最强证据。
  final String? usbNetworkInterface;

  /// 充电电流（毫安），供诊断页展示；部分机型不可读，可为空。
  final int? chargeCurrentMa;

  bool get hasUsbNetwork => usbNetworkInterface != null;

  Map<String, Object?> toJson() => {
        'plug': plug.name,
        'usbNetworkInterface': usbNetworkInterface,
        'chargeCurrentMa': chargeCurrentMa,
      };

  static ChargingContext fromJson(Map<String, Object?> json) {
    return ChargingContext(
      plug: PowerPlug.values.firstWhere(
        (p) => p.name == json['plug'],
        orElse: () => PowerPlug.unknown,
      ),
      usbNetworkInterface: json['usbNetworkInterface'] as String?,
      chargeCurrentMa: (json['chargeCurrentMa'] as num?)?.toInt(),
    );
  }

  static const none = ChargingContext();
}

/// 系统安全状态。
class DeviceSecurityState {
  const DeviceSecurityState({
    this.adbEnabled = false,
    this.developerOptionsEnabled = false,
    this.deviceLocked = false,
    this.screenOn = false,
  });

  /// 开发者选项中的"USB 调试"是否开启。开启时接入陌生端口风险显著上升。
  final bool adbEnabled;

  /// 开发者选项本身是否开启。
  final bool developerOptionsEnabled;

  /// 锁屏加密状态（`KeyguardManager.isDeviceLocked`）。
  /// 锁屏时系统通常仍会阻止 MTP 读取，因此"锁屏 + MTP 暴露"比解锁时更危险
  /// 的是"用户误点允许"这条路径。
  final bool deviceLocked;

  final bool screenOn;

  Map<String, Object?> toJson() => {
        'adbEnabled': adbEnabled,
        'developerOptionsEnabled': developerOptionsEnabled,
        'deviceLocked': deviceLocked,
        'screenOn': screenOn,
      };

  static DeviceSecurityState fromJson(Map<String, Object?> json) =>
      DeviceSecurityState(
        adbEnabled: json['adbEnabled'] as bool? ?? false,
        developerOptionsEnabled:
            json['developerOptionsEnabled'] as bool? ?? false,
        deviceLocked: json['deviceLocked'] as bool? ?? false,
        screenOn: json['screenOn'] as bool? ?? false,
      );

  static const unknown = DeviceSecurityState();
}

/// 单个 USB 接口描述（宿主模式下用于识别外设类型）。
class UsbInterfaceInfo {
  const UsbInterfaceInfo({
    required this.interfaceClass,
    required this.interfaceSubclass,
    required this.interfaceProtocol,
  });

  final int interfaceClass;
  final int interfaceSubclass;
  final int interfaceProtocol;

  /// USB HID（人机接口，典型为键盘/鼠标）：可能被用于注入按键。
  bool get isHid => interfaceClass == 0x03;

  /// CDC 数据 / 通信类：典型为 USB 网卡。
  bool get isCdc => interfaceClass == 0x02 || interfaceClass == 0x0A;

  /// 大容量存储：U 盘、伪装成存储的读卡器。
  bool get isMassStorage => interfaceClass == 0x08;

  Map<String, Object?> toJson() => {
        'interfaceClass': interfaceClass,
        'interfaceSubclass': interfaceSubclass,
        'interfaceProtocol': interfaceProtocol,
      };

  static UsbInterfaceInfo fromJson(Map<String, Object?> json) =>
      UsbInterfaceInfo(
        interfaceClass: (json['interfaceClass'] as num?)?.toInt() ?? 0,
        interfaceSubclass: (json['interfaceSubclass'] as num?)?.toInt() ?? 0,
        interfaceProtocol: (json['interfaceProtocol'] as num?)?.toInt() ?? 0,
      );
}

/// 宿主模式（手机作为主机，例如插入 OTG 读卡器/伪装成充电头的网卡）下的外设信息。
///
/// 与设备模式相反，这里**可以**拿到真实的 VID/PID/序列号，因此信任列表
/// 在宿主模式下是基于设备身份的，而不是基于用户意图。
class UsbDeviceInfo {
  const UsbDeviceInfo({
    required this.deviceName,
    required this.vendorId,
    required this.productId,
    required this.deviceClass,
    required this.deviceSubclass,
    required this.deviceProtocol,
    this.manufacturerName,
    this.productName,
    this.serialHash,
    this.interfaces = const [],
  });

  final String deviceName;
  final int vendorId;
  final int productId;
  final int deviceClass;
  final int deviceSubclass;
  final int deviceProtocol;
  final String? manufacturerName;
  final String? productName;

  /// 序列号只保存哈希，避免把可识别设备的原始序列号落盘。
  final String? serialHash;
  final List<UsbInterfaceInfo> interfaces;

  bool get isHid =>
      deviceClass == 0x03 || interfaces.any((i) => i.isHid);
  bool get isNetwork =>
      deviceClass == 0x02 ||
      deviceClass == 0x0A ||
      interfaces.any((i) => i.isCdc);
  bool get isMassStorage =>
      deviceClass == 0x08 || interfaces.any((i) => i.isMassStorage);

  /// 稳定的设备指纹：VID/PID + 序列号哈希（若有）。
  String get fingerprint {
    final base =
        '${vendorId.toRadixString(16).padLeft(4, '0')}:${productId.toRadixString(16).padLeft(4, '0')}';
    return serialHash == null ? base : '$base#$serialHash';
  }

  String get displayName {
    final name = productName?.trim();
    if (name != null && name.isNotEmpty) return name;
    return 'USB 设备 ${vendorId.toRadixString(16)}:${productId.toRadixString(16)}';
  }

  Map<String, Object?> toJson() => {
        'deviceName': deviceName,
        'vendorId': vendorId,
        'productId': productId,
        'deviceClass': deviceClass,
        'deviceSubclass': deviceSubclass,
        'deviceProtocol': deviceProtocol,
        'manufacturerName': manufacturerName,
        'productName': productName,
        'serialHash': serialHash,
        'interfaces': interfaces.map((i) => i.toJson()).toList(),
      };

  static UsbDeviceInfo fromJson(Map<String, Object?> json) => UsbDeviceInfo(
        deviceName: json['deviceName'] as String? ?? '',
        vendorId: (json['vendorId'] as num?)?.toInt() ?? 0,
        productId: (json['productId'] as num?)?.toInt() ?? 0,
        deviceClass: (json['deviceClass'] as num?)?.toInt() ?? 0,
        deviceSubclass: (json['deviceSubclass'] as num?)?.toInt() ?? 0,
        deviceProtocol: (json['deviceProtocol'] as num?)?.toInt() ?? 0,
        manufacturerName: json['manufacturerName'] as String?,
        productName: json['productName'] as String?,
        serialHash: json['serialHash'] as String?,
        interfaces: ((json['interfaces'] as List?) ?? const [])
            .map((e) => UsbInterfaceInfo.fromJson(e as Map<String, Object?>))
            .toList(),
      );
}

// ---------------------------------------------------------------------------
// 能力画像
// ---------------------------------------------------------------------------

/// 当前设备/系统允许本应用做到什么。
///
/// 这是应对"各厂商差异大、权限有限"的核心：**不假设，运行时探测**。
/// 界面会据此展示真实可用能力，而不是画饼。
class CapabilityProfile {
  const CapabilityProfile({
    required this.platform,
    required this.sdkInt,
    required this.manufacturer,
    required this.brand,
    required this.model,
    required this.isDeviceOwner,
    required this.canDisableUsbDataSignaling,
    required this.usbStateObservable,
    required this.canQueryInstalledPackages,
    this.notes = const [],
  });

  /// `android` / `ios` / `unknown`。
  final String platform;
  final int sdkInt;
  final String manufacturer;
  final String brand;
  final String model;

  /// 是否已作为"设备所有者"（Device Owner）被配置。这是唯一能真正
  /// 在硬件层关断 USB 数据引脚的普通途径。
  final bool isDeviceOwner;

  /// 是否支持用 `DevicePolicyManager.setUsbDataSignalingEnabled(false)`
  /// 关断数据信号（需 API 31+、设备所有者、且厂商实现了该能力）。
  final bool canDisableUsbDataSignaling;

  /// 运行期是否真的观测到了 `ACTION_USB_STATE`（部分定制 ROM 可能不投递）。
  final bool usbStateObservable;

  /// 是否具备查询已安装应用的权限（用于"连接期间被装应用"检测，需用户显式授权）。
  final bool canQueryInstalledPackages;

  /// 面向用户的补充说明（按厂商/版本动态生成）。
  final List<String> notes;

  /// 能否在本机真正阻断数据（否则只能告警 + 引导）。
  bool get canBlockData => canDisableUsbDataSignaling;

  /// 是否为本应用完全无法介入的平台（如 iOS）。
  bool get isSupported => platform == 'android';

  Map<String, Object?> toJson() => {
        'platform': platform,
        'sdkInt': sdkInt,
        'manufacturer': manufacturer,
        'brand': brand,
        'model': model,
        'isDeviceOwner': isDeviceOwner,
        'canDisableUsbDataSignaling': canDisableUsbDataSignaling,
        'usbStateObservable': usbStateObservable,
        'canQueryInstalledPackages': canQueryInstalledPackages,
        'notes': notes,
      };

  static CapabilityProfile fromJson(Map<String, Object?> json) =>
      CapabilityProfile(
        platform: json['platform'] as String? ?? 'unknown',
        sdkInt: (json['sdkInt'] as num?)?.toInt() ?? 0,
        manufacturer: json['manufacturer'] as String? ?? '',
        brand: json['brand'] as String? ?? '',
        model: json['model'] as String? ?? '',
        isDeviceOwner: json['isDeviceOwner'] as bool? ?? false,
        canDisableUsbDataSignaling:
            json['canDisableUsbDataSignaling'] as bool? ?? false,
        usbStateObservable: json['usbStateObservable'] as bool? ?? false,
        canQueryInstalledPackages:
            json['canQueryInstalledPackages'] as bool? ?? false,
        notes: ((json['notes'] as List?) ?? const [])
            .map((e) => e as String)
            .toList(),
      );

  static const unknown = CapabilityProfile(
    platform: 'unknown',
    sdkInt: 0,
    manufacturer: '',
    brand: '',
    model: '',
    isDeviceOwner: false,
    canDisableUsbDataSignaling: false,
    usbStateObservable: false,
    canQueryInstalledPackages: false,
  );
}

// ---------------------------------------------------------------------------
// 会话快照
// ---------------------------------------------------------------------------

/// 一次"插入"从插上到拔下的全过程状态快照。
///
/// 风险引擎以此为单位做判定；每次信号变化都会生成新快照。
class SessionSnapshot {
  const SessionSnapshot({
    required this.capturedAt,
    this.sessionActive = false,
    this.sessionStartedAt,
    this.port = UsbPortState.empty,
    this.charging = ChargingContext.none,
    this.security = DeviceSecurityState.unknown,
    this.hostDevices = const [],
    this.appsInstalledDuringSession = const [],
    this.capabilities = CapabilityProfile.unknown,
  });

  final DateTime capturedAt;
  final bool sessionActive;
  final DateTime? sessionStartedAt;
  final UsbPortState port;
  final ChargingContext charging;
  final DeviceSecurityState security;
  final List<UsbDeviceInfo> hostDevices;

  /// 本次插入期间新安装的应用包名（需用户授权查询权限后才有内容）。
  final List<String> appsInstalledDuringSession;

  final CapabilityProfile capabilities;

  /// 手机作为 USB 设备（插入充电口）。
  bool get isDeviceMode => charging.plug != PowerPlug.none;
  /// 手机作为 USB 主机（插入了外设）。
  bool get isHostMode => hostDevices.isNotEmpty;

  Duration? get sessionDuration => sessionStartedAt == null
      ? null
      : capturedAt.difference(sessionStartedAt!);

  SessionSnapshot copyWith({
    DateTime? capturedAt,
    bool? sessionActive,
    DateTime? sessionStartedAt,
    UsbPortState? port,
    ChargingContext? charging,
    DeviceSecurityState? security,
    List<UsbDeviceInfo>? hostDevices,
    List<String>? appsInstalledDuringSession,
    CapabilityProfile? capabilities,
  }) {
    return SessionSnapshot(
      capturedAt: capturedAt ?? this.capturedAt,
      sessionActive: sessionActive ?? this.sessionActive,
      sessionStartedAt: sessionStartedAt ?? this.sessionStartedAt,
      port: port ?? this.port,
      charging: charging ?? this.charging,
      security: security ?? this.security,
      hostDevices: hostDevices ?? this.hostDevices,
      appsInstalledDuringSession:
          appsInstalledDuringSession ?? this.appsInstalledDuringSession,
      capabilities: capabilities ?? this.capabilities,
    );
  }

  Map<String, Object?> toJson() => {
        'capturedAt': capturedAt.toIso8601String(),
        'sessionActive': sessionActive,
        'sessionStartedAt': sessionStartedAt?.toIso8601String(),
        'port': port.toJson(),
        'charging': charging.toJson(),
        'security': security.toJson(),
        'hostDevices': hostDevices.map((d) => d.toJson()).toList(),
        'appsInstalledDuringSession': appsInstalledDuringSession,
        'capabilities': capabilities.toJson(),
      };

  static SessionSnapshot fromJson(Map<String, Object?> json) =>
      SessionSnapshot(
        capturedAt: DateTime.parse(json['capturedAt'] as String),
        sessionActive: json['sessionActive'] as bool? ?? false,
        sessionStartedAt: json['sessionStartedAt'] == null
            ? null
            : DateTime.parse(json['sessionStartedAt'] as String),
        port: UsbPortState.fromJson(
            (json['port'] as Map?)?.cast<String, Object?>() ?? const {}),
        charging: ChargingContext.fromJson(
            (json['charging'] as Map?)?.cast<String, Object?>() ?? const {}),
        security: DeviceSecurityState.fromJson(
            (json['security'] as Map?)?.cast<String, Object?>() ?? const {}),
        hostDevices: ((json['hostDevices'] as List?) ?? const [])
            .map((e) => UsbDeviceInfo.fromJson(e as Map<String, Object?>))
            .toList(),
        appsInstalledDuringSession:
            ((json['appsInstalledDuringSession'] as List?) ?? const [])
                .map((e) => e as String)
                .toList(),
        capabilities: CapabilityProfile.fromJson(
            (json['capabilities'] as Map?)?.cast<String, Object?>() ?? const {}),
      );

  static SessionSnapshot idle({CapabilityProfile? capabilities}) =>
      SessionSnapshot(
        capturedAt: DateTime.now(),
        capabilities: capabilities ?? CapabilityProfile.unknown,
      );
}
