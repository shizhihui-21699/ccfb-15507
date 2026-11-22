import 'package:material_ui/material_ui.dart';

import '../app/guard_controller.dart';
import '../domain/models.dart';
import 'theme.dart';

/// 本机能力页——这一页是整个产品"讲真话"的地方。
///
/// 公共充电防护的实现强依赖系统与厂商，绝大多数手机**不给**第三方应用
/// 在硬件层关断数据的权限。与其画饼，不如把每台手机的真实边界讲清楚：
/// 已具备什么、缺什么、用户可以怎么补。
class CapabilityPage extends StatelessWidget {
  const CapabilityPage({super.key, required this.controller});

  final GuardController controller;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: controller,
      builder: (context, _) {
        final caps = controller.capabilities;
        final t = Theme.of(context);
        return Scaffold(
          appBar: AppBar(title: const Text('本机能力')),
          body: ListView(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 32),
            children: [
              _DeviceHeader(caps: caps),
              const SectionHeader('这台手机上能做到'),
              Card(
                child: Column(
                  children: [
                    _CapabilityRow(
                      icon: Icons.visibility_outlined,
                      title: '识别对方是否在建立数据连接',
                      state: _State.always,
                      detail: '依据系统 USB 功能状态判断对方是否能读取数据。',
                    ),
                    const Divider(height: 1),
                    _CapabilityRow(
                      icon: Icons.notifications_active_outlined,
                      title: '立即提醒与锁屏告警',
                      state: _State.always,
                      detail: '检测到数据通道时发高优先级通知，必要时全屏提醒。',
                    ),
                    const Divider(height: 1),
                    _CapabilityRow(
                      icon: Icons.verified_outlined,
                      title: '信任你自己的设备',
                      state: _State.always,
                      detail: '连接自己的电脑传文件时不会打扰你。',
                    ),
                    const Divider(height: 1),
                    _CapabilityRow(
                      icon: Icons.block_outlined,
                      title: '系统层直接关断 USB 数据',
                      state: caps.canDisableUsbDataSignaling
                          ? _State.available
                          : _State.unavailable,
                      detail: caps.canDisableUsbDataSignaling
                          ? '已获得设备所有者权限，可直接关断数据引脚。'
                          : caps.isDeviceOwner
                              ? '已是设备所有者，但本机厂商未实现该能力。'
                              : '需要企业级"设备所有者"配置，普通用户无法开启。',
                    ),
                    const Divider(height: 1),
                    _CapabilityRow(
                      icon: Icons.inventory_2_outlined,
                      title: '识别连接期间被安装的应用',
                      state: caps.canQueryInstalledPackages
                          ? _State.available
                          : _State.unavailable,
                      detail: caps.canQueryInstalledPackages
                          ? '已获得查询应用列表的权限。'
                          : '需要授权查询已安装应用，默认未开启。',
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 16),
              const ExplainerCard(
                icon: Icons.lightbulb_outline,
                title: '为什么不能"一键只充电"？',
                tone: ExplainerTone.caution,
                body: 'USB 是否开启数据通道，由手机系统底层决定，第三方应用无权直接改写。'
                    '绝大多数手机上，我们能做的是"发现并提醒"，而不是"静默拦截"。\n\n'
                    '真正能在硬件层关断数据的，只有企业统一管理的"设备所有者"应用，'
                    '或其自带该功能的系统（如部分隐私系统）。',
              ),
              if (caps.notes.isNotEmpty) ...[
                const SizedBox(height: 12),
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          '本机探测到的情况',
                          style: t.textTheme.titleSmall
                              ?.copyWith(fontWeight: FontWeight.w700),
                        ),
                        const SizedBox(height: 8),
                        for (final n in caps.notes)
                          Padding(
                            padding: const EdgeInsets.only(bottom: 6),
                            child: Row(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                const Text('•  '),
                                Expanded(
                                  child: Text(
                                    n,
                                    style: t.textTheme.bodySmall?.copyWith(
                                      color: t.colorScheme.onSurfaceVariant,
                                      height: 1.5,
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
              const SizedBox(height: 12),
              const ExplainerCard(
                icon: Icons.shield_outlined,
                title: '最可靠的做法',
                tone: ExplainerTone.good,
                body: '在公共场合使用充电口时：\n'
                    '1. 优先使用"仅充电"数据线（无数据线芯）；\n'
                    '2. 或使用充电宝自带线、自己携带充电头；\n'
                    '3. 锁屏时不要点击陌生的"允许访问"弹窗；\n'
                    '4. 平时关闭开发者选项中的"USB 调试"。',
              ),
            ],
          ),
        );
      },
    );
  }
}

enum _State { always, available, unavailable }

class _DeviceHeader extends StatelessWidget {
  const _DeviceHeader({required this.caps});

  final CapabilityProfile caps;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final name = [caps.manufacturer, caps.model]
        .where((e) => e.isNotEmpty)
        .join(' ');
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Row(
          children: [
            Container(
              width: 46,
              height: 46,
              decoration: BoxDecoration(
                color: t.colorScheme.primary.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Icon(Icons.phone_android, color: t.colorScheme.primary),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    name.isEmpty ? '未知设备' : name,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: t.textTheme.titleMedium
                        ?.copyWith(fontWeight: FontWeight.w700),
                  ),
                  const SizedBox(height: 3),
                  Text(
                    'Android ${caps.sdkInt} · ${caps.brand.isEmpty ? "—" : caps.brand}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: t.textTheme.bodySmall
                        ?.copyWith(color: t.colorScheme.onSurfaceVariant),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _CapabilityRow extends StatelessWidget {
  const _CapabilityRow({
    required this.icon,
    required this.title,
    required this.state,
    required this.detail,
  });

  final IconData icon;
  final String title;
  final _State state;
  final String detail;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final (label, color) = switch (state) {
      _State.always => ('已启用', const Color(0xFF1B8A5A)),
      _State.available => ('可用', const Color(0xFF1B8A5A)),
      _State.unavailable => ('不可用', t.colorScheme.outline),
    };
    return ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
      leading: Icon(icon, color: t.colorScheme.onSurfaceVariant),
      title: Row(
        children: [
          Expanded(
            child: Text(
              title,
              style: t.textTheme.bodyLarge
                  ?.copyWith(fontWeight: FontWeight.w600),
            ),
          ),
          StatusPill(text: label, color: color),
        ],
      ),
      subtitle: Padding(
        padding: const EdgeInsets.only(top: 4),
        child: Text(
          detail,
          style: t.textTheme.bodySmall?.copyWith(
            color: t.colorScheme.onSurfaceVariant,
            height: 1.5,
          ),
        ),
      ),
    );
  }
}
