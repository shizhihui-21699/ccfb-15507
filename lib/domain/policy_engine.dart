/// 处置策略引擎——纯 Dart，可单测。
///
/// 风险引擎回答"有没有风险"，策略引擎回答"**该做什么**"。它的第一优先级
/// 始终是**不妨碍正常使用**：
///
/// 1. 插自己的电脑、正常传文件时，绝不弹告警、绝不干预；
/// 2. 只有在"已暴露数据通道"或用户主动开启强提醒时，才升级为告警；
/// 3. 真正阻断（关断数据信号）只在明确获得设备所有者权限时才尝试，
///    且默认要求用户显式确认——不搞静默接管。
library;

import 'models.dart';
import 'risk_engine.dart';

/// 应用可采取的处置动作，按强度递增。
enum PolicyAction {
  /// 静默记录，不打扰用户（插入可信设备/纯供电时的正常态）。
  monitor,

  /// 仅更新常驻通知里的状态，不弹窗。
  inform,

  /// 发送高优先级通知，震动/响铃提醒用户检查。
  alert,

  /// 弹全屏告警（锁屏也可见），要求用户立即处理。
  urgentAlert,

  /// 在硬件层关断 USB 数据信号（仅设备所有者可用）。
  blockData,
}

/// 用户可配置项。
class GuardSettings {
  const GuardSettings({
    this.enabled = true,
    this.alertWhileLocked = true,
    this.blockWhenDeviceOwner = false,
    this.trustWindow = const Duration(hours: 2),
    this.notifyOnlyOncePerSession = true,
  });

  /// 总开关。
  final bool enabled;

  /// 锁屏时是否也要告警（有些用户希望锁屏时更敏感）。
  final bool alertWhileLocked;

  /// 具备设备所有者权限时，是否在风险为高时自动关断数据。
  /// 默认关闭——阻断是重操作，需用户明确开启。
  final bool blockWhenDeviceOwner;

  /// 用户点"这是我自己的电脑"后，本次设备指纹的信任有效期。
  final Duration trustWindow;

  /// 同一次插入只强提醒一次，避免刷屏。
  final bool notifyOnlyOncePerSession;

  Map<String, Object?> toJson() => {
        'enabled': enabled,
        'alertWhileLocked': alertWhileLocked,
        'blockWhenDeviceOwner': blockWhenDeviceOwner,
        'trustWindowSeconds': trustWindow.inSeconds,
        'notifyOnlyOncePerSession': notifyOnlyOncePerSession,
      };

  static GuardSettings fromJson(Map<String, Object?> json) => GuardSettings(
        enabled: json['enabled'] as bool? ?? true,
        alertWhileLocked: json['alertWhileLocked'] as bool? ?? true,
        blockWhenDeviceOwner: json['blockWhenDeviceOwner'] as bool? ?? false,
        trustWindow: Duration(
            seconds: (json['trustWindowSeconds'] as num?)?.toInt() ?? 7200),
        notifyOnlyOncePerSession:
            json['notifyOnlyOncePerSession'] as bool? ?? true,
      );
}

/// 一条信任记录。
///
/// 设备模式下手机**无法获知充电端的身份**（USB 反向连接不传递主机标识），
/// 因此信任只能建立在两类对象上：
/// - 宿主模式外设：按 VID/PID/序列号指纹信任（真正的"认识这台设备"）；
/// - 设备模式：按"刚刚是我主动确认过的那次连接"临时放行（会话级信任）。
class TrustRecord {
  const TrustRecord({
    required this.id,
    required this.label,
    required this.kind,
    this.fingerprint,
    this.createdAt,
    this.expiresAt,
    this.permanent = false,
  });

  final String id;
  final String label;
  final TrustKind kind;

  /// 宿主模式下的设备指纹；会话级信任为空。
  final String? fingerprint;
  final DateTime? createdAt;
  final DateTime? expiresAt;

  /// 永久信任（仅用于用户明确"始终信任此电脑"的场景）。
  final bool permanent;

  bool isExpiredAt(DateTime now) =>
      !permanent && expiresAt != null && !now.isBefore(expiresAt!);

  Map<String, Object?> toJson() => {
        'id': id,
        'label': label,
        'kind': kind.name,
        'fingerprint': fingerprint,
        'createdAt': createdAt?.toIso8601String(),
        'expiresAt': expiresAt?.toIso8601String(),
        'permanent': permanent,
      };

  static TrustRecord fromJson(Map<String, Object?> json) => TrustRecord(
        id: json['id'] as String,
        label: json['label'] as String? ?? '',
        kind: TrustKind.values.firstWhere((k) => k.name == json['kind'],
            orElse: () => TrustKind.session),
        fingerprint: json['fingerprint'] as String?,
        createdAt: json['createdAt'] == null
            ? null
            : DateTime.parse(json['createdAt'] as String),
        expiresAt: json['expiresAt'] == null
            ? null
            : DateTime.parse(json['expiresAt'] as String),
        permanent: json['permanent'] as bool? ?? false,
      );
}

enum TrustKind {
  /// 本次插入临时放行，拔线即失效。
  session,

  /// 宿主模式下的某台设备（自己的电脑/读卡器）。
  hostDevice,

  /// 用户手动标记为安全的某个位置/场景。
  location,
}

/// 一次策略裁决的结果。
class PolicyDecision {
  const PolicyDecision({
    required this.action,
    required this.reason,
    this.trustedBy,
    this.shouldShowInApp = true,
  });

  final PolicyAction action;
  final String reason;

  /// 若被信任放行，是哪条信任记录放行的（便于解释"为什么没报警"）。
  final TrustRecord? trustedBy;

  /// 是否在 App 内展示（被信任时仍可能在首页留一行状态）。
  final bool shouldShowInApp;

  @override
  String toString() => 'PolicyDecision(${action.name}: $reason)';
}

/// 策略引擎。
class PolicyEngine {
  const PolicyEngine();

  /// 判断快照是否命中信任记录。
  ///
  /// - 宿主模式：任一外设指纹命中未过期的信任记录 → 视为可信。
  /// - 设备模式：只有会话级信任生效（无法识别主机身份）。
  ///
  /// [now] 用于判断有效期，默认取当前时间。刻意**不用**快照自带的
  /// `capturedAt`——那是"状态采集时刻"，而信任是否过期应对照真实当下，
  /// 两者在回放/测试场景下可能不同。
  TrustRecord? matchingTrust(
    SessionSnapshot s,
    List<TrustRecord> trusts, {
    DateTime? now,
  }) {
    final ref = now ?? DateTime.now();
    final active = trusts.where((t) => !t.isExpiredAt(ref));

    if (s.isHostMode) {
      for (final t in active) {
        if (t.kind != TrustKind.hostDevice || t.fingerprint == null) continue;
        if (s.hostDevices.any((d) => d.fingerprint == t.fingerprint)) {
          return t;
        }
      }
      return null;
    }

    // 设备模式：只认会话级信任。
    for (final t in active) {
      if (t.kind == TrustKind.session) return t;
    }
    return null;
  }

  /// 裁决。
  PolicyDecision decide({
    required SessionSnapshot snapshot,
    required RiskAssessment assessment,
    required List<TrustRecord> trusts,
    required GuardSettings settings,
    DateTime? now,
  }) {
    if (!settings.enabled) {
      return const PolicyDecision(
        action: PolicyAction.monitor,
        reason: '防护已关闭',
        shouldShowInApp: true,
      );
    }

    if (!snapshot.sessionActive) {
      return const PolicyDecision(
        action: PolicyAction.monitor,
        reason: '当前未连接充电设备',
      );
    }

    // 纯供电且**确实没有任何数据功能**：直接放行，绝不打扰。
    // 注意必须同时检查数据功能——部分底座/扩展坞以交流供电之名暴露数据通道。
    final powerOnly = snapshot.charging.plug == PowerPlug.ac ||
        snapshot.charging.plug == PowerPlug.wireless ||
        snapshot.charging.plug == PowerPlug.dock;
    final port = snapshot.port;
    if (powerOnly && !port.exposesData) {
      return const PolicyDecision(
        action: PolicyAction.inform,
        reason: '纯供电连接，无数据风险',
      );
    }

    final trust = matchingTrust(snapshot, trusts, now: now);
    final active = assessment.activeExposure;

    // 命中信任：无论风险如何都不打扰用户（受信任的设备本来就会打开 MTP/ADB，
    // 例如自己的电脑）。这正是"不妨碍正常传文件"的关键。
    if (trust != null) {
      return PolicyDecision(
        action: PolicyAction.monitor,
        reason: '已信任：${trust.label}',
        trustedBy: trust,
        shouldShowInApp: active,
      );
    }

    if (!active) {
      // 此刻没有主机在读取数据。
      //  - 数据功能闲置开启（如 ADB 开着但没连电脑）：安全姿态提示，不告警。
      //  - 其余中危迹象：同样只提示。
      if (port.dataEnabledButIdle) {
        return const PolicyDecision(
          action: PolicyAction.inform,
          reason: '数据功能处于开启状态，但当前没有主机在读取',
        );
      }
      final hasMedium = assessment.findings
          .any((f) => f.severity == FindingSeverity.medium);
      return PolicyDecision(
        action: hasMedium ? PolicyAction.inform : PolicyAction.monitor,
        reason: hasMedium ? '存在可疑迹象，但未开放数据通道' : '未检测到数据通道',
      );
    }

    // 此刻确实有主机在读取数据：决定告警强度。
    final locked = snapshot.security.deviceLocked;
    final canBlock = snapshot.capabilities.canDisableUsbDataSignaling;

    if (settings.blockWhenDeviceOwner && canBlock) {
      return const PolicyDecision(
        action: PolicyAction.blockData,
        reason: '检测到数据通道，已按设置自动关断 USB 数据',
      );
    }

    if (locked && settings.alertWhileLocked) {
      return const PolicyDecision(
        action: PolicyAction.urgentAlert,
        reason: '锁屏状态下有主机正在读取数据，需要立即处理',
      );
    }

    return const PolicyDecision(
      action: PolicyAction.alert,
      reason: '有主机正在读取数据',
    );
  }
}
