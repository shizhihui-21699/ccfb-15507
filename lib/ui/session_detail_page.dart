import 'package:material_ui/material_ui.dart';

import '../app/guard_controller.dart';
import '../domain/models.dart';
import '../domain/risk_engine.dart';

/// 本次连接详情：把系统采集到的原始事实全部摊开。
///
/// 公共充电防护最怕"黑箱"——用户只看到"危险"却不知道为什么。
/// 这一页给出判定所依据的每一项证据，用户可据此自行复核。
class SessionDetailPage extends StatelessWidget {
  const SessionDetailPage({super.key, required this.controller});

  final GuardController controller;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: controller,
      builder: (context, _) {
        final s = controller.snapshot;
        final t = Theme.of(context);
        return Scaffold(
          appBar: AppBar(title: const Text('本次连接详情')),
          body: ListView(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 32),
            children: [
              _Group(
                title: '供电',
                rows: [
                  _Row('供电方式', _plugLabel(s.charging.plug)),
                  if (s.charging.chargeCurrentMa != null)
                    _Row('充电电流', '${s.charging.chargeCurrentMa} mA'),
                  if (s.charging.usbNetworkInterface != null)
                    _Row('USB 虚拟网卡', s.charging.usbNetworkInterface!,
                        danger: true),
                  _Row('会话状态', s.sessionActive ? '连接中' : '未连接'),
                ],
              ),
              _Group(
                title: 'USB 端口（手机作为设备）',
                rows: [
                  _Row('数据线连接', s.port.connected ? '是' : '否'),
                  _Row('主机已发现设备', s.port.configured ? '是' : '否'),
                  _Row('数据传输已解锁', s.port.dataUnlocked ? '是' : '否',
                      danger: s.port.dataUnlocked && s.port.exposesData),
                  _Row(
                    '开放的功能',
                    s.port.functions.isEmpty
                        ? '无（仅充电）'
                        : s.port.functions.map((f) => f.name).join('、'),
                    danger: s.port.exposesData,
                  ),
                ],
              ),
              if (s.port.rawExtras.isNotEmpty)
                _Group(
                  title: '系统原始字段',
                  dense: true,
                  rows: [
                    for (final e in s.port.rawExtras.entries)
                      _Row(e.key, e.value ? 'true' : 'false'),
                  ],
                ),
              if (s.hostDevices.isNotEmpty)
                _Group(
                  title: '外接设备（手机作为主机）',
                  rows: [
                    for (final d in s.hostDevices) _Row(d.displayName, _devDesc(d)),
                  ],
                ),
              _Group(
                title: '系统安全状态',
                rows: [
                  _Row('USB 调试', s.security.adbEnabled ? '已开启' : '已关闭',
                      danger: s.security.adbEnabled),
                  _Row('开发者选项',
                      s.security.developerOptionsEnabled ? '已开启' : '已关闭'),
                  _Row('锁屏', s.security.deviceLocked ? '已锁定' : '未锁定'),
                  _Row('屏幕', s.security.screenOn ? '亮屏' : '息屏'),
                ],
              ),
              _Group(
                title: '本机能力',
                rows: [
                  _Row('设备所有者', s.capabilities.isDeviceOwner ? '是' : '否'),
                  _Row('可关断数据信号',
                      s.capabilities.canDisableUsbDataSignaling ? '是' : '否'),
                  _Row('USB 状态可观测',
                      s.capabilities.usbStateObservable ? '是' : '否（部分定制 ROM 不投递）'),
                ],
              ),
              const SizedBox(height: 18),
              Text(
                '采集时间：${_fmtTime(s.capturedAt)}',
                textAlign: TextAlign.center,
                style: t.textTheme.bodySmall
                    ?.copyWith(color: t.colorScheme.onSurfaceVariant),
              ),
              const SizedBox(height: 6),
              Text(
                '以上均为本机系统上报的事实，判定在设备本地完成。',
                textAlign: TextAlign.center,
                style: t.textTheme.bodySmall
                    ?.copyWith(color: t.colorScheme.onSurfaceVariant),
              ),
            ],
          ),
        );
      },
    );
  }

  static String _plugLabel(PowerPlug p) => switch (p) {
        PowerPlug.usb => 'USB（数据线）',
        PowerPlug.ac => '交流电（纯充电）',
        PowerPlug.wireless => '无线充电（纯充电）',
        PowerPlug.dock => '底座（纯充电）',
        PowerPlug.none => '未连接',
        PowerPlug.unknown => '未知',
      };

  static String _devDesc(UsbDeviceInfo d) {
    final parts = <String>[];
    if (d.isNetwork) parts.add('网卡');
    if (d.isHid) parts.add('输入设备');
    if (d.isMassStorage) parts.add('存储');
    final hex =
        '${d.vendorId.toRadixString(16).padLeft(4, '0')}:${d.productId.toRadixString(16).padLeft(4, '0')}';
    return '${parts.isEmpty ? "外设" : parts.join("、")} · $hex';
  }

  static String _fmtTime(DateTime d) {
    String two(int n) => n.toString().padLeft(2, '0');
    return '${d.year}-${two(d.month)}-${two(d.day)} ${two(d.hour)}:${two(d.minute)}:${two(d.second)}';
  }
}

class _Row {
  const _Row(this.label, this.value, {this.danger = false});
  final String label;
  final String value;
  final bool danger;
}

class _Group extends StatelessWidget {
  const _Group({required this.title, required this.rows, this.dense = false});

  final String title;
  final List<_Row> rows;
  final bool dense;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(4, 20, 4, 8),
          child: Text(
            title,
            style: t.textTheme.titleSmall?.copyWith(
              fontWeight: FontWeight.w700,
              color: t.colorScheme.onSurfaceVariant,
            ),
          ),
        ),
        Card(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
            child: Column(
              children: [
                for (final r in rows)
                  Padding(
                    padding: EdgeInsets.symmetric(
                        vertical: dense ? 5 : 9),
                    child: Row(
                      children: [
                        Expanded(
                          flex: 4,
                          child: Text(
                            r.label,
                            style: t.textTheme.bodySmall?.copyWith(
                              color: t.colorScheme.onSurfaceVariant,
                              fontFamily: dense ? 'monospace' : null,
                            ),
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          flex: 6,
                          child: Text(
                            r.value,
                            textAlign: TextAlign.right,
                            style: t.textTheme.bodyMedium?.copyWith(
                              fontWeight:
                                  r.danger ? FontWeight.w700 : FontWeight.w500,
                              color: r.danger
                                  ? const Color(0xFFC62828)
                                  : t.colorScheme.onSurface,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

/// 供历史页复用的风险等级换算。
RiskLevel riskOfName(String? name) => RiskLevel.values.firstWhere(
      (r) => r.name == name,
      orElse: () => RiskLevel.none,
    );
