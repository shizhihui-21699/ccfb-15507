/// 风险评估引擎——纯函数，无平台依赖，可完整单测。
///
/// 它回答一个问题：**"这次插入，对方有没有、或者说能不能，读到/写入手机数据？"**
/// 判定刻意区分"已暴露"与"有风险但未暴露"，避免把普通充电器吓成攻击者，
/// 也避免把"主机完成枚举但手机没开放任何功能"误报为风险。
library;

import 'models.dart';

/// 单条风险发现的严重度。
enum FindingSeverity {
  /// 仅信息补充，不影响结论。
  info,

  /// 低：值得记录，但通常不构成实质威胁。
  low,

  /// 中：存在数据通道，或存在较强异常信号。
  medium,

  /// 高：可被直接利用的数据通道（ADB / USB 网卡 / 连接期间装应用）。
  high,
}

/// 一条风险发现。
class Finding {
  const Finding({
    required this.code,
    required this.severity,
    required this.title,
    required this.detail,
    this.evidence = const {},
  });

  /// 稳定标识，便于测试与埋点（例如 `adbExposed`）。
  final String code;
  final FindingSeverity severity;
  final String title;
  final String detail;

  /// 支撑该结论的原始证据（键值对），诊断页与告警详情会展示。
  final Map<String, Object?> evidence;

  @override
  String toString() => 'Finding($code, ${severity.name})';
}

/// 总体风险等级。
enum RiskLevel { none, low, medium, high }

/// 一次评估的完整产物。
class RiskAssessment {
  const RiskAssessment({
    required this.level,
    required this.findings,
    this.score = 0,
    this.activeExposure = false,
  });

  final RiskLevel level;
  final List<Finding> findings;

  /// 加权分，仅用于排序/趋势展示，不作为唯一依据。
  final int score;

  /// 是否**此刻**确实存在正在被读取的数据通道（主机已连接并完成枚举）。
  ///
  /// 这与"启用了数据功能但无主机"是两回事：后者是安全姿态问题，
  /// 应提示但不应断言"对方正在读取"。策略层据此决定是否告警。
  final bool activeExposure;

  bool get hasFindings => findings.isNotEmpty;

  /// 是否发现了**此刻正在被读取**的数据通道（区别于"有隐患"或"通道空闲开启"）。
  ///
  /// 只有主机确实已连接并枚举才算；仅"数据功能处于开启状态"不算。
  bool get exposesDataChannel => activeExposure;

  /// 最高严重度。
  FindingSeverity get maxSeverity {
    var max = FindingSeverity.info;
    for (final f in findings) {
      if (f.severity.index > max.index) max = f.severity;
    }
    return max;
  }

  static const clean = RiskAssessment(level: RiskLevel.none, findings: []);
}

/// 风险评估引擎。
class RiskEngine {
  const RiskEngine();

  /// 对一次会话快照做评估。
  RiskAssessment assess(SessionSnapshot s) {
    final findings = <Finding>[];

    // 未在充电/未连接时，不产生任何会话风险。
    if (!s.sessionActive) {
      return RiskAssessment.clean;
    }

    _assessPowerSource(s, findings);
    _assessDeviceModeExposure(s, findings);
    _assessNetworkEvidence(s, findings);
    _assessInstalledApps(s, findings);
    _assessHostModePeripherals(s, findings);
    _assessSecurityPosture(s, findings);

    final score = _score(findings);
    // 只有"数据线已连接 + 主机已枚举 + 有数据功能"才算正在被读取。
    final active = s.port.isActivelyExposed;
    return RiskAssessment(
      level: _level(score, findings),
      findings: findings,
      score: score,
      activeExposure: active,
    );
  }

  // -- 供电来源 -------------------------------------------------------------

  void _assessPowerSource(SessionSnapshot s, List<Finding> findings) {
    switch (s.charging.plug) {
      case PowerPlug.ac:
      case PowerPlug.wireless:
      case PowerPlug.dock:
        // 纯供电通常无数据线对。但**不能只看供电类型**：部分底座/扩展坞
        // 会同时上报交流供电并暴露 USB 数据功能，此时仍须按数据通道处理。
        if (!s.port.exposesData && !s.port.configured) {
          findings.add(const Finding(
            code: 'powerOnlyCharger',
            severity: FindingSeverity.info,
            title: '纯供电连接',
            detail: '当前为交流/无线/底座供电，且未检测到 USB 数据通道，无需担心数据被读取。',
          ));
        }
        break;
      case PowerPlug.usb:
        // 数据线已连接，继续由下方规则细分。
        break;
      case PowerPlug.none:
      case PowerPlug.unknown:
        findings.add(const Finding(
          code: 'plugUnknown',
          severity: FindingSeverity.low,
          title: '供电方式未知',
          detail: '系统未明确上报供电类型，可能因厂商定制 ROM 差异，已按保守策略处理。',
        ));
        break;
    }
  }

  // -- 设备模式：手机对外暴露了什么 -----------------------------------------

  void _assessDeviceModeExposure(SessionSnapshot s, List<Finding> findings) {
    final p = s.port;
    // 关键：判定依据是**实际是否启用了数据功能**，而不是"供电类型是不是 USB"。
    // 有些底座/充电器会以交流供电之名行数据连接之实，必须同等对待。
    if (!p.exposesData && !(p.configured && s.charging.plug == PowerPlug.usb)) {
      return;
    }

    // 主机已枚举，但手机没有开放任何数据功能：主机读不到东西。
    if (p.configured && !p.exposesData) {
      findings.add(const Finding(
        code: 'enumeratedNoData',
        severity: FindingSeverity.info,
        title: '已枚举但仅充电',
        detail: '对端主机完成了 USB 枚举，但手机未开放任何数据功能，无法读取数据。',
      ));
      return;
    }

    // 区分两种截然不同的情况：
    //   active  —— 数据线已连接、主机已枚举、数据功能开启：对方此刻确实能读。
    //   idle    —— 数据功能处于开启状态，但当前没有主机连接/枚举（系统保留了
    //              上一次的功能配置）。这是"安全姿态"问题，应提示，但绝不能
    //              断言"对方正在读取"，否则会造成虚假告警与告警疲劳。
    final active = p.isActivelyExposed;
    final severityFor = active
        ? (FindingSeverity s0) => s0
        : (FindingSeverity s0) => _downgradeIdle(s0);
    final whenText = active ? '当前连接已启用' : '系统当前保留开启状态（本次未检测到主机连接）';

    if (p.exposesDebug) {
      findings.add(Finding(
        code: active ? 'adbExposed' : 'adbEnabledIdle',
        severity: severityFor(FindingSeverity.high),
        title: active ? 'USB 调试通道正在被使用' : 'USB 调试已开启',
        detail: active
            ? '当前 USB 连接启用了 ADB，且主机已连接。对端可通过调试桥安装应用、'
                '读取通讯录/短信、截屏。请立即断开。'
            : '$whenText。平时应关闭开发者选项中的"USB 调试"，'
                '以免在陌生设备上误点"允许"后获得调试权限。',
        evidence: {'functions': p.functions.map((f) => f.name).toList()},
      ));
    }

    if (p.networkFunctions.isNotEmpty) {
      findings.add(Finding(
        code: active ? 'usbNetworkExposed' : 'usbNetworkIdle',
        severity: severityFor(FindingSeverity.high),
        title: active ? 'USB 网络共享正在生效' : 'USB 网络共享已开启',
        detail: active
            ? '手机正通过 USB 向对端提供网络（RNDIS/NCM）。这会建立一条隐藏网络通路，'
                '可被用于 DNS 劫持、中间人攻击或流量嗅探。'
            : '$whenText（RNDIS/NCM）。网络共享一旦连上陌生主机即可被利用，建议关闭。',
        evidence: {
          'functions': p.networkFunctions.map((f) => f.name).toList(),
        },
      ));
    }

    if (p.fileTransferFunctions.isNotEmpty) {
      final locked = s.security.deviceLocked;
      final names =
          p.fileTransferFunctions.map((f) => f.name.toUpperCase()).join('/');
      findings.add(Finding(
        code: p.fileTransferFunctions.contains(UsbFunction.mtp)
            ? 'mtpExposed'
            : 'ptpExposed',
        severity: active && locked
            ? FindingSeverity.high
            : severityFor(FindingSeverity.medium),
        title: active ? '文件传输通道正在被读取' : '文件传输模式已开启',
        detail: active
            ? (locked
                ? '锁屏状态下仍开放了 $names 文件通道，对端可能读取照片与文档。'
                : '已开放 $names 文件通道，且主机已连接；'
                    '若你并未主动选择"文件传输"，请立即断开。')
            : '$whenText（$names）。若你并未主动选择"文件传输"，建议改为"仅充电"。',
        evidence: {
          'functions': p.fileTransferFunctions.map((f) => f.name).toList(),
          'deviceLocked': locked,
          'activelyExposed': active,
        },
      ));
    }

    if (p.functions.contains(UsbFunction.accessory)) {
      findings.add(const Finding(
        code: 'accessoryExposed',
        severity: FindingSeverity.medium,
        title: 'USB 附件模式',
        detail: '手机以 USB 附件身份连接，对端可通过附件协议交换数据。',
      ));
    }

    final misc = p.functions.where((f) =>
        f == UsbFunction.midi || f == UsbFunction.audioSource);
    if (misc.isNotEmpty) {
      findings.add(Finding(
        code: 'miscDataChannel',
        severity: FindingSeverity.low,
        title: '其他数据通道',
        detail: '当前开放了 ${misc.map((f) => f.name).join('/')} 通道，一般无敏感数据风险。',
      ));
    }

    if (p.functions.contains(UsbFunction.other)) {
      findings.add(const Finding(
        code: 'unknownFunction',
        severity: FindingSeverity.medium,
        title: '未知 USB 功能',
        detail: '系统上报了本应用不认识的数据功能位，按数据通道保守处理。',
      ));
    }
  }

  /// 空闲态（无主机连接）降级：高危 → 中危，中危 → 低危。
  FindingSeverity _downgradeIdle(FindingSeverity s) => switch (s) {
        FindingSeverity.high => FindingSeverity.medium,
        FindingSeverity.medium => FindingSeverity.low,
        _ => s,
      };

  // -- 网络侧证据 -----------------------------------------------------------

  void _assessNetworkEvidence(SessionSnapshot s, List<Finding> findings) {
    final iface = s.charging.usbNetworkInterface;
    if (iface == null) return;
    // 若已在网络功能中报过，避免重复计分，但仍记录接口名。
    findings.add(Finding(
      code: 'usbNetworkInterfaceUp',
      severity: FindingSeverity.high,
      title: '检测到 USB 虚拟网卡',
      detail: '连接后出现网络接口 "$iface"，说明对端已与手机建立 IP 网络通路。',
      evidence: {'interface': iface},
    ));
  }

  // -- 连接期间安装应用 -----------------------------------------------------

  void _assessInstalledApps(SessionSnapshot s, List<Finding> findings) {
    final apps = s.appsInstalledDuringSession;
    if (apps.isEmpty) return;
    findings.add(Finding(
      code: 'appsInstalledWhileCharging',
      severity: FindingSeverity.high,
      title: '连接期间安装了应用',
      detail: '本次插入期间新增了 ${apps.length} 个应用，'
          '这可能是通过调试通道被静默安装的，请立即检查。',
      evidence: {'packages': apps},
    ));
  }

  // -- 宿主模式外设 ---------------------------------------------------------

  void _assessHostModePeripherals(SessionSnapshot s, List<Finding> findings) {
    for (final d in s.hostDevices) {
      if (d.isNetwork) {
        findings.add(Finding(
          code: 'hostNetworkAdapter',
          severity: FindingSeverity.high,
          title: '接入 USB 网卡',
          detail: '"${d.displayName}" 提供网络接口，可能被伪装成充电线或充电头，'
              '用于把手机流量导向攻击者。',
          evidence: {'device': d.toJson()},
        ));
      } else if (d.isHid) {
        findings.add(Finding(
          code: 'hostHidAttached',
          severity: FindingSeverity.medium,
          title: '接入 HID 设备',
          detail: '"${d.displayName}" 是键盘/鼠标类设备，可能被用于模拟按键、代替你点击授权弹窗。',
          evidence: {'device': d.toJson()},
        ));
      } else if (d.isMassStorage) {
        findings.add(Finding(
          code: 'hostMassStorage',
          severity: FindingSeverity.low,
          title: '接入存储设备',
          detail: '"${d.displayName}" 为存储类设备，注意其中可能含恶意文件。',
        ));
      }
    }
  }

  // -- 系统安全姿态 ---------------------------------------------------------

  void _assessSecurityPosture(SessionSnapshot s, List<Finding> findings) {
    final sec = s.security;
    if (sec.adbEnabled && s.charging.plug == PowerPlug.usb &&
        !s.port.exposesDebug) {
      // 已开启调试但当前未对本次连接开放：仍需提示。
      findings.add(const Finding(
        code: 'adbEnabledStandby',
        severity: FindingSeverity.low,
        title: 'USB 调试处于开启状态',
        detail: '开发者选项中的 USB 调试已开启。在陌生端口上，一旦误点"允许"，'
            '对方即可获得调试权限。建议平时关闭。',
      ));
    }
    if (sec.developerOptionsEnabled && !sec.adbEnabled) {
      findings.add(const Finding(
        code: 'developerOptionsOn',
        severity: FindingSeverity.info,
        title: '开发者选项已开启',
        detail: '开发者选项当前开启，但 USB 调试本身未启用。',
      ));
    }
  }

  // -- 计分 ---------------------------------------------------------------

  int _score(List<Finding> findings) {
    var score = 0;
    final counted = <String>{};
    for (final f in findings) {
      // 同一条发现只计一次（网络证据可能重复上报）。
      if (!counted.add(f.code)) continue;
      score += switch (f.severity) {
        FindingSeverity.info => 0,
        FindingSeverity.low => 1,
        FindingSeverity.medium => 3,
        FindingSeverity.high => 7,
      };
    }
    return score;
  }

  RiskLevel _level(int score, List<Finding> findings) {
    final highCount =
        findings.where((f) => f.severity == FindingSeverity.high).length;
    if (highCount > 0) return RiskLevel.high;
    if (score >= 6) return RiskLevel.high;
    if (score >= 3) return RiskLevel.medium;
    if (score >= 1) return RiskLevel.low;
    return RiskLevel.none;
  }
}
