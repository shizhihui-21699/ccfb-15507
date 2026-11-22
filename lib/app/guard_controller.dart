/// 应用状态中心：把"信号 → 判定 → 处置"串起来，并维持界面的可观察状态。
///
/// 它刻意不依赖 Flutter Widget 层（只用 ChangeNotifier），
/// 因此可以在纯 Dart 测试里驱动完整的判定链路。
library;

import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../domain/models.dart';
import '../domain/policy_engine.dart';
import '../domain/risk_engine.dart';
import '../platform/signal_source.dart';

/// 一条历史记录（插入到拔出）。
class SessionRecord {
  const SessionRecord({
    required this.startedAt,
    required this.endedAt,
    required this.peakRisk,
    required this.summary,
    required this.findings,
    this.trustLabel,
  });

  final DateTime startedAt;
  final DateTime endedAt;
  final RiskLevel peakRisk;
  final String summary;
  final List<String> findings;
  final String? trustLabel;

  Map<String, Object?> toJson() => {
        'startedAt': startedAt.toIso8601String(),
        'endedAt': endedAt.toIso8601String(),
        'peakRisk': peakRisk.name,
        'summary': summary,
        'findings': findings,
        'trustLabel': trustLabel,
      };

  static SessionRecord fromJson(Map<String, Object?> j) => SessionRecord(
        startedAt: DateTime.parse(j['startedAt'] as String),
        endedAt: DateTime.parse(j['endedAt'] as String),
        peakRisk: RiskLevel.values.firstWhere(
          (r) => r.name == j['peakRisk'],
          orElse: () => RiskLevel.none,
        ),
        summary: j['summary'] as String? ?? '',
        findings: ((j['findings'] as List?) ?? const [])
            .map((e) => e as String)
            .toList(),
        trustLabel: j['trustLabel'] as String?,
      );
}

/// 简单的本地存储接口，避免直接依赖 shared_preferences 于状态层。
abstract class KeyValueStore {
  Future<String?> read(String key);
  Future<void> write(String key, String value);
  Future<void> remove(String key);
}

/// 内存实现（测试用）。
class InMemoryStore implements KeyValueStore {
  final Map<String, String> _m = {};
  @override
  Future<String?> read(String key) async => _m[key];
  @override
  Future<void> write(String key, String value) async => _m[key] = value;
  @override
  Future<void> remove(String key) async => _m.remove(key);
}

/// 全局状态。
class GuardController extends ChangeNotifier {
  GuardController({
    required PlatformSignalSource source,
    KeyValueStore? store,
    RiskEngine riskEngine = const RiskEngine(),
    PolicyEngine policyEngine = const PolicyEngine(),
    GuardSettings settings = const GuardSettings(),
    List<TrustRecord> trusts = const [],
  })  : _source = source, // ignore: prefer_initializing_formals
        _store = store ?? InMemoryStore(),
        _risk = riskEngine,
        _policy = policyEngine,
        _settings = settings, // ignore: prefer_initializing_formals
        _trusts = List.of(trusts) {
    _sub = _source.snapshots.listen(_onSnapshot);
  }

  final PlatformSignalSource _source;
  final KeyValueStore _store;
  final RiskEngine _risk;
  final PolicyEngine _policy;

  StreamSubscription<SessionSnapshot>? _sub;

  SessionSnapshot _snapshot = SessionSnapshot.idle();
  CapabilityProfile _capabilities = CapabilityProfile.unknown;
  RiskAssessment _assessment = RiskAssessment.clean;
  PolicyDecision _decision = const PolicyDecision(
    action: PolicyAction.monitor,
    reason: '等待连接',
  );
  GuardSettings _settings;
  final List<TrustRecord> _trusts;
  final List<SessionRecord> _history = [];

  /// 同一次插入只强提醒一次。
  bool _alertedThisSession = false;
  DateTime? _lastSessionStartedAt;

  /// 最近一次触发告警的时间，供 UI 高亮。
  DateTime? lastAlertAt;

  SessionSnapshot get snapshot => _snapshot;
  CapabilityProfile get capabilities => _capabilities;
  RiskAssessment get assessment => _assessment;
  PolicyDecision get decision => _decision;
  GuardSettings get settings => _settings;
  List<TrustRecord> get trusts => List.unmodifiable(_trusts);
  List<SessionRecord> get history => List.unmodifiable(_history);

  bool get isDemoMode => _source is SimulatedPlatformSignalSource;

  /// 初始化：探测能力、读取持久化数据、启动原生监听。
  Future<void> init() async {
    _capabilities = await _source.probeCapabilities();
    await _loadPersisted();
    final source = _source;
    if (source is MethodChannelPlatformSignalSource) {
      _onSnapshot(await source.start());
    }
    if (source is SimulatedPlatformSignalSource) {
      source.startDemo();
    }
    notifyListeners();
  }

  // -- 持久化 ---------------------------------------------------------------

  static const _kSettings = 'guard.settings';
  static const _kTrusts = 'guard.trusts';
  static const _kHistory = 'guard.history';

  Future<void> _loadPersisted() async {
    try {
      final s = await _store.read(_kSettings);
      if (s != null) {
        _settings = GuardSettings.fromJson(
            (jsonDecode(s) as Map).cast<String, Object?>());
      }
      final t = await _store.read(_kTrusts);
      if (t != null) {
        _trusts
          ..clear()
          ..addAll(((jsonDecode(t) as List))
              .map((e) => TrustRecord.fromJson((e as Map).cast<String, Object?>())));
      }
      final h = await _store.read(_kHistory);
      if (h != null) {
        _history
          ..clear()
          ..addAll(((jsonDecode(h) as List))
              .map((e) => SessionRecord.fromJson((e as Map).cast<String, Object?>())));
      }
    } catch (_) {
      // 数据损坏时以默认值启动，不影响防护。
    }
  }

  Future<void> _persistSettings() =>
      _store.write(_kSettings, jsonEncode(_settings.toJson()));
  Future<void> _persistTrusts() => _store.write(
      _kTrusts, jsonEncode(_trusts.map((t) => t.toJson()).toList()));
  Future<void> _persistHistory() => _store.write(
      _kHistory, jsonEncode(_history.map((h) => h.toJson()).toList()));

  // -- 信号处理 -------------------------------------------------------------

  void _onSnapshot(SessionSnapshot s) {
    // 会话结束：归档一条历史记录。
    final wasActive = _snapshot.sessionActive;
    if (wasActive && !s.sessionActive) {
      _archiveSession(_snapshot);
    }
    // 新会话开始：重置告警去重。
    if (s.sessionActive &&
        (_lastSessionStartedAt == null ||
            s.sessionStartedAt != _lastSessionStartedAt)) {
      _lastSessionStartedAt = s.sessionStartedAt;
      _alertedThisSession = false;
    }

    _snapshot = s;
    // 用最新能力画像覆盖（能力可能随用户授权变化）。
    _capabilities = s.capabilities.platform != 'unknown'
        ? s.capabilities
        : _capabilities;

    _assessment = _risk.assess(s);
    _decision = _policy.decide(
      snapshot: s,
      assessment: _assessment,
      trusts: _trusts,
      settings: _settings,
    );

    _maybeFireAlert();
    notifyListeners();
  }

  void _maybeFireAlert() {
    final action = _decision.action;
    final needsAlert = action == PolicyAction.alert ||
        action == PolicyAction.urgentAlert ||
        action == PolicyAction.blockData;
    if (!needsAlert) return;
    if (_alertedThisSession && _settings.notifyOnlyOncePerSession) return;
    _alertedThisSession = true;
    lastAlertAt = DateTime.now();

    // 交给原生层发高优先级通知——用户往往锁屏、不在 App 内，
    // 只有系统级通知才可能被看到。
    final topFinding = _assessment.findings
        .where((f) => f.severity.index >= FindingSeverity.medium.index)
        .map((f) => f.title)
        .take(2)
        .join('、');
    _source.showAlertNotification(
      action == PolicyAction.urgentAlert ? '锁屏中检测到可疑数据连接' : '检测到可疑充电连接',
      topFinding.isEmpty ? '请立即检查并考虑断开连接。' : '$topFinding。请立即检查并考虑断开连接。',
    );

    // blockData 由策略决定，需用户已开启自动阻断，直接执行。
    if (action == PolicyAction.blockData) {
      blockData();
    }
  }

  void _archiveSession(SessionSnapshot ended) {
    final assessment = _risk.assess(ended);
    final trust = _policy.matchingTrust(ended, _trusts);
    _history.insert(
      0,
      SessionRecord(
        startedAt: ended.sessionStartedAt ?? ended.capturedAt,
        endedAt: ended.capturedAt,
        peakRisk: assessment.level,
        summary: _summarize(assessment),
        findings: assessment.findings.map((f) => f.title).toList(),
        trustLabel: trust?.label,
      ),
    );
    if (_history.length > 50) _history.removeRange(50, _history.length);
    _persistHistory();
  }

  String _summarize(RiskAssessment a) {
    if (a.findings.isEmpty) return '未发现异常';
    if (a.level == RiskLevel.high) {
      return a.findings
          .where((f) => f.severity == FindingSeverity.high)
          .map((f) => f.title)
          .join('、');
    }
    return a.findings.map((f) => f.title).take(3).join('、');
  }

  // -- 用户动作 -------------------------------------------------------------

  /// 用户确认"这是可信设备/我已了解"，本次插入不再打扰。
  Future<void> trustCurrentSession() async {
    final now = DateTime.now();
    _trusts.add(TrustRecord(
      id: 'session-${now.millisecondsSinceEpoch}',
      label: '本次确认的连接',
      kind: TrustKind.session,
      createdAt: now,
      expiresAt: now.add(_settings.trustWindow),
    ));
    // 会话级信任只保留一条，避免累积。
    _trusts.removeWhere((t) => t.kind == TrustKind.session && t.id != _trusts.last.id);
    await _persistTrusts();
    _decision = _policy.decide(
      snapshot: _snapshot,
      assessment: _assessment,
      trusts: _trusts,
      settings: _settings,
    );
    notifyListeners();
  }

  /// 信任一台宿主模式的设备（自己的电脑），永久。
  Future<void> trustHostDevice(UsbDeviceInfo device) async {
    _trusts.add(TrustRecord(
      id: 'host-${device.fingerprint}',
      label: device.displayName,
      kind: TrustKind.hostDevice,
      fingerprint: device.fingerprint,
      createdAt: DateTime.now(),
      permanent: true,
    ));
    await _persistTrusts();
    notifyListeners();
  }

  Future<void> removeTrust(String id) async {
    _trusts.removeWhere((t) => t.id == id);
    await _persistTrusts();
    notifyListeners();
  }

  /// 尝试在系统层关断 USB 数据（需设备所有者）。
  /// 返回是否真正成功——失败时如实返回 false，UI 据此引导手动操作。
  Future<bool> blockData() async {
    final ok = await _source.blockUsbData();
    notifyListeners();
    return ok;
  }

  Future<void> allowData() async {
    await _source.allowUsbData();
    notifyListeners();
  }

  Future<void> openUsbSettings() => _source.openUsbSettings();

  Future<void> updateSettings(GuardSettings s) async {
    _settings = s;
    await _persistSettings();
    _decision = _policy.decide(
      snapshot: _snapshot,
      assessment: _assessment,
      trusts: _trusts,
      settings: _settings,
    );
    notifyListeners();
  }

  /// 演示模式：切换到指定场景（仅模拟源可用）。
  void demoPush(SessionSnapshot s) {
    final src = _source;
    if (src is SimulatedPlatformSignalSource) {
      src.push(s);
    }
  }

  @override
  void dispose() {
    _sub?.cancel();
    _source.dispose();
    super.dispose();
  }
}
