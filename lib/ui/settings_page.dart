import 'package:material_ui/material_ui.dart';

import '../app/guard_controller.dart';
import '../domain/policy_engine.dart';
import 'theme.dart';

/// 设置页：只暴露真正有意义、且用户能理解的开关。
class SettingsPage extends StatefulWidget {
  const SettingsPage({super.key, required this.controller});

  final GuardController controller;

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  late GuardSettings _local;

  @override
  void initState() {
    super.initState();
    _local = widget.controller.settings;
  }

  Future<void> _update(GuardSettings next) async {
    setState(() => _local = next);
    await widget.controller.updateSettings(next);
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final caps = widget.controller.capabilities;
    final trusts = widget.controller.trusts;

    return Scaffold(
      appBar: AppBar(title: const Text('设置')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 4, 16, 32),
        children: [
          const SectionHeader('防护'),
          Card(
            child: Column(
              children: [
                SwitchListTile(
                  value: _local.enabled,
                  onChanged: (v) => _update(GuardSettings(
                    enabled: v,
                    alertWhileLocked: _local.alertWhileLocked,
                    blockWhenDeviceOwner: _local.blockWhenDeviceOwner,
                    trustWindow: _local.trustWindow,
                    notifyOnlyOncePerSession: _local.notifyOnlyOncePerSession,
                  )),
                  title: const Text('启用充电防护'),
                  subtitle: const Text('关闭后不再检测和提醒'),
                ),
                const Divider(height: 1),
                SwitchListTile(
                  value: _local.alertWhileLocked,
                  onChanged: _local.enabled
                      ? (v) => _update(GuardSettings(
                            enabled: _local.enabled,
                            alertWhileLocked: v,
                            blockWhenDeviceOwner: _local.blockWhenDeviceOwner,
                            trustWindow: _local.trustWindow,
                            notifyOnlyOncePerSession:
                                _local.notifyOnlyOncePerSession,
                          ))
                      : null,
                  title: const Text('锁屏时也告警'),
                  subtitle: const Text('锁屏状态下发现数据通道时，以全屏方式提醒'),
                ),
                const Divider(height: 1),
                SwitchListTile(
                  value: _local.notifyOnlyOncePerSession,
                  onChanged: _local.enabled
                      ? (v) => _update(GuardSettings(
                            enabled: _local.enabled,
                            alertWhileLocked: _local.alertWhileLocked,
                            blockWhenDeviceOwner: _local.blockWhenDeviceOwner,
                            trustWindow: _local.trustWindow,
                            notifyOnlyOncePerSession: v,
                          ))
                      : null,
                  title: const Text('每次连接只提醒一次'),
                  subtitle: const Text('避免持续刷屏'),
                ),
              ],
            ),
          ),
          const SectionHeader('阻断'),
          Card(
            child: Column(
              children: [
                SwitchListTile(
                  value: _local.blockWhenDeviceOwner,
                  onChanged: _local.enabled && caps.canDisableUsbDataSignaling
                      ? (v) => _update(GuardSettings(
                            enabled: _local.enabled,
                            alertWhileLocked: _local.alertWhileLocked,
                            blockWhenDeviceOwner: v,
                            trustWindow: _local.trustWindow,
                            notifyOnlyOncePerSession:
                                _local.notifyOnlyOncePerSession,
                          ))
                      : null,
                  title: const Text('检测到风险时自动关断数据'),
                  subtitle: Text(
                    caps.canDisableUsbDataSignaling
                        ? '需设备所有者权限，本机已具备'
                        : '本机不具备该能力，开关不可用',
                    style: t.textTheme.bodySmall?.copyWith(
                      color: t.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ),
                const Divider(height: 1),
                ListTile(
                  leading: const Icon(Icons.timer_outlined),
                  title: const Text('信任有效期'),
                  subtitle: Text('确认"自己的设备"后，${_local.trustWindow.inMinutes} 分钟内不再提醒'),
                  trailing: DropdownButton<int>(
                    value: _local.trustWindow.inMinutes,
                    underline: const SizedBox.shrink(),
                    items: const [
                      DropdownMenuItem(value: 30, child: Text('30 分钟')),
                      DropdownMenuItem(value: 120, child: Text('2 小时')),
                      DropdownMenuItem(value: 480, child: Text('8 小时')),
                    ],
                    onChanged: (v) {
                      if (v == null) return;
                      _update(GuardSettings(
                        enabled: _local.enabled,
                        alertWhileLocked: _local.alertWhileLocked,
                        blockWhenDeviceOwner: _local.blockWhenDeviceOwner,
                        trustWindow: Duration(minutes: v),
                        notifyOnlyOncePerSession:
                            _local.notifyOnlyOncePerSession,
                      ));
                    },
                  ),
                ),
              ],
            ),
          ),
          SectionHeader('信任的记录', trailing: Text(
            '${trusts.length}',
            style: t.textTheme.bodySmall
                ?.copyWith(color: t.colorScheme.onSurfaceVariant),
          )),
          Card(
            child: trusts.isEmpty
                ? const ListTile(
                    leading: Icon(Icons.shield_outlined),
                    title: Text('暂无信任的设备'),
                    subtitle: Text('连接自己的电脑时可选择信任，之后就不会被反复提醒'),
                  )
                : Column(
                    children: [
                      for (var i = 0; i < trusts.length; i++) ...[
                        ListTile(
                          leading: Icon(
                            trusts[i].kind == TrustKind.hostDevice
                                ? Icons.computer_outlined
                                : Icons.lock_clock_outlined,
                          ),
                          title: Text(trusts[i].label),
                          subtitle: Text(
                            trusts[i].permanent
                                ? '永久信任'
                                : '有效期至 ${_fmt(trusts[i].expiresAt)}',
                          ),
                          trailing: IconButton(
                            tooltip: '移除',
                            icon: const Icon(Icons.delete_outline),
                            onPressed: () =>
                                widget.controller.removeTrust(trusts[i].id),
                          ),
                        ),
                        if (i != trusts.length - 1) const Divider(height: 1),
                      ],
                    ],
                  ),
          ),
          const SizedBox(height: 18),
          const ExplainerCard(
            icon: Icons.privacy_tip_outlined,
            title: '关于数据',
            body: '所有判定均在手机本地完成，不上传任何连接信息。'
                '序列号等可识别信息只保存哈希。',
          ),
        ],
      ),
    );
  }

  static String _fmt(DateTime? d) {
    if (d == null) return '—';
    String two(int n) => n.toString().padLeft(2, '0');
    return '${two(d.month)}-${two(d.day)} ${two(d.hour)}:${two(d.minute)}';
  }
}
