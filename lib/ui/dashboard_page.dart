import 'package:material_ui/material_ui.dart';

import '../app/guard_controller.dart';
import '../domain/models.dart';
import '../domain/risk_engine.dart';
import 'capability_page.dart';
import 'history_page.dart';
import 'session_detail_page.dart';
import 'settings_page.dart';
import 'theme.dart';

/// 首页：一屏说清"现在安不安全、发生了什么、该怎么办"。
class DashboardPage extends StatelessWidget {
  const DashboardPage({super.key, required this.controller});

  final GuardController controller;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: controller,
      builder: (context, _) {
        final s = controller.snapshot;
        final assessment = controller.assessment;
        final visual = RiskVisual.of(assessment.level);

        return Scaffold(
          appBar: AppBar(
            title: const Text('充电守护'),
            actions: [
              if (controller.isDemoMode)
                Padding(
                  padding: const EdgeInsets.only(right: 4),
                  child: Center(
                    child: StatusPill(
                      text: '演示',
                      color: Theme.of(context).colorScheme.tertiary,
                      icon: Icons.play_circle_outline,
                    ),
                  ),
                ),
              IconButton(
                tooltip: '设置',
                icon: const Icon(Icons.settings_outlined),
                onPressed: () => Navigator.of(context).push(MaterialPageRoute(
                  builder: (_) => SettingsPage(controller: controller),
                )),
              ),
            ],
          ),
          body: RefreshIndicator(
            onRefresh: () async {
              // 触发一次重读（模拟源会推进一帧）。
              controller.demoPush(controller.snapshot);
            },
            child: ListView(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 32),
              children: [
                _StatusHero(
                  controller: controller,
                  visual: visual,
                  snapshot: s,
                  assessment: assessment,
                ),
                const SizedBox(height: 16),
                if (!s.sessionActive)
                  _IdleCard(controller: controller)
                else ...[
                  _ActionRow(controller: controller, snapshot: s),
                  const SizedBox(height: 16),
                  if (assessment.findings.isNotEmpty)
                    _FindingsList(assessment: assessment),
                ],
                const SizedBox(height: 8),
                _QuickLinks(controller: controller),
              ],
            ),
          ),
        );
      },
    );
  }
}

class _StatusHero extends StatelessWidget {
  const _StatusHero({
    required this.controller,
    required this.visual,
    required this.snapshot,
    required this.assessment,
  });

  final GuardController controller;
  final RiskVisual visual;
  final SessionSnapshot snapshot;
  final RiskAssessment assessment;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final s = snapshot;
    final subtitle = _subtitle(s, assessment);
    // 只有"此刻有主机正在读取"才用红色断言；否则用姿态提示，避免虚假告警。
    final headline = _headline(s, assessment, visual);

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(22),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(24),
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            visual.color.withValues(alpha: 0.16),
            visual.color.withValues(alpha: 0.04),
          ],
        ),
        border: Border.all(color: visual.color.withValues(alpha: 0.25)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 52,
                height: 52,
                decoration: BoxDecoration(
                  color: visual.color.withValues(alpha: 0.16),
                  shape: BoxShape.circle,
                ),
                child: Icon(visual.icon, color: visual.color, size: 28),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      headline,
                      style: t.textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.w700,
                        height: 1.3,
                      ),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      subtitle,
                      style: t.textTheme.bodySmall?.copyWith(
                        color: t.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          if (s.sessionActive) ...[
            const SizedBox(height: 18),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                StatusPill(
                  text: visual.label,
                  color: visual.color,
                  icon: visual.icon,
                ),
                if (s.port.exposesData)
                  StatusPill(
                    text: _functionsText(s.port),
                    color: visual.color,
                    icon: Icons.swap_horiz,
                  )
                else if (s.charging.plug == PowerPlug.ac ||
                    s.charging.plug == PowerPlug.wireless ||
                    s.charging.plug == PowerPlug.dock)
                  StatusPill(
                    text: '仅供电',
                    color: t.colorScheme.primary,
                    icon: Icons.bolt_outlined,
                  ),
                if (controller.decision.trustedBy != null)
                  StatusPill(
                    text: '已信任',
                    color: const Color(0xFF1B8A5A),
                    icon: Icons.verified_outlined,
                  ),
              ],
            ),
          ],
        ],
      ),
    );
  }

  String _subtitle(SessionSnapshot s, RiskAssessment a) {
    if (!s.sessionActive) {
      return '插上充电器后，这里会显示实时判定结果';
    }
    final session = s.sessionDuration;
    final dur = session == null ? '' : ' · 已连接 ${_fmtDur(session)}';
    return '${controller.decision.reason}$dur';
  }

  /// 结论标题。区分"正在被读取"与"通道已开启但当前无主机"，
  /// 避免在仅开启数据功能、并无主机连接时吓到用户。
  String _headline(
      SessionSnapshot s, RiskAssessment a, RiskVisual visual) {
    if (!s.sessionActive) return visual.headline;
    if (a.activeExposure) return visual.headline;
    if (s.port.dataEnabledButIdle) return '数据通道已开启，当前无主机读取';
    if (s.charging.plug == PowerPlug.ac ||
        s.charging.plug == PowerPlug.wireless ||
        s.charging.plug == PowerPlug.dock) {
      return '当前连接是安全的';
    }
    return visual.headline;
  }

  String _functionsText(UsbPortState p) {
    final names = p.functions.map((f) => f.name.toUpperCase()).toList()..sort();
    if (names.isEmpty) return '仅充电';
    return names.join(' + ');
  }
}

String _fmtDur(Duration d) {
  if (d.inMinutes < 1) return '${d.inSeconds} 秒';
  if (d.inHours < 1) return '${d.inMinutes} 分钟';
  return '${d.inHours} 小时 ${d.inMinutes % 60} 分';
}

class _IdleCard extends StatelessWidget {
  const _IdleCard({required this.controller});

  final GuardController controller;

  @override
  Widget build(BuildContext context) {
    final caps = controller.capabilities;
    final t = Theme.of(context);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.shield_outlined, color: t.colorScheme.primary),
                const SizedBox(width: 10),
                Text(
                  '防护已就绪',
                  style: t.textTheme.titleMedium
                      ?.copyWith(fontWeight: FontWeight.w700),
                ),
              ],
            ),
            const SizedBox(height: 10),
            Text(
              caps.canBlockData
                  ? '当前设备已具备系统层阻断能力。插入陌生充电设备时，若发现数据通道会自动关断。'
                  : '插入陌生充电设备时，若检测到对方在建立数据连接，会立即提醒你。',
              style: t.textTheme.bodyMedium
                  ?.copyWith(color: t.colorScheme.onSurfaceVariant, height: 1.55),
            ),
            const SizedBox(height: 14),
            FilledButton.tonalIcon(
              onPressed: () => Navigator.of(context).push(MaterialPageRoute(
                builder: (_) => HistoryPage(controller: controller),
              )),
              icon: const Icon(Icons.history),
              label: Text('查看历史记录（${controller.history.length}）'),
            ),
          ],
        ),
      ),
    );
  }
}

class _ActionRow extends StatelessWidget {
  const _ActionRow({required this.controller, required this.snapshot});

  final GuardController controller;
  final SessionSnapshot snapshot;

  @override
  Widget build(BuildContext context) {
    final exposed = controller.assessment.exposesDataChannel;
    final canBlock = snapshot.capabilities.canDisableUsbDataSignaling;
    return Wrap(
      spacing: 10,
      runSpacing: 10,
      children: [
        if (exposed && canBlock)
          FilledButton.icon(
            style: FilledButton.styleFrom(
              backgroundColor: const Color(0xFFC62828),
            ),
            onPressed: () async {
              final ok = await controller.blockData();
              if (!context.mounted) return;
              ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                content: Text(ok ? '已在系统层关断 USB 数据' : '本机不支持系统层阻断，请手动断开'),
                behavior: SnackBarBehavior.floating,
              ));
            },
            icon: const Icon(Icons.block),
            label: const Text('立即阻断数据'),
          ),
        OutlinedButton.icon(
          onPressed: () => _confirmTrust(context),
          icon: const Icon(Icons.lock_open_outlined),
          label: const Text('这是我自己的设备'),
        ),
        TextButton.icon(
          onPressed: controller.openUsbSettings,
          icon: const Icon(Icons.settings_suggest_outlined),
          label: const Text('系统 USB 设置'),
        ),
      ],
    );
  }

  Future<void> _confirmTrust(BuildContext context) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('确认信任本次连接？'),
        content: const Text(
          '确认后，本次插入不再提醒你。\n\n'
          '请只在你确实认识对端时使用——例如你自己的电脑。'
          '在机场、商场的公共充电口，不要选择这一项。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('确认信任'),
          ),
        ],
      ),
    );
    if (ok == true) {
      await controller.trustCurrentSession();
    }
  }
}

class _FindingsList extends StatelessWidget {
  const _FindingsList({required this.assessment});

  final RiskAssessment assessment;

  @override
  Widget build(BuildContext context) {
    final sorted = List<Finding>.of(assessment.findings)
      ..sort((a, b) => b.severity.index.compareTo(a.severity.index));
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SectionHeader('检测详情'),
        Card(
          child: Column(
            children: [
              for (var i = 0; i < sorted.length; i++) ...[
                _FindingTile(finding: sorted[i]),
                if (i != sorted.length - 1) const Divider(height: 1),
              ],
            ],
          ),
        ),
      ],
    );
  }
}

class _FindingTile extends StatelessWidget {
  const _FindingTile({required this.finding});

  final Finding finding;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final (color, icon) = switch (finding.severity) {
      FindingSeverity.info => (t.colorScheme.primary, Icons.info_outline),
      FindingSeverity.low => (const Color(0xFFB8860B), Icons.info_outline),
      FindingSeverity.medium => (const Color(0xFFD2691E), Icons.warning_amber_rounded),
      FindingSeverity.high => (const Color(0xFFC62828), Icons.dangerous_outlined),
    };
    return ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
      leading: Icon(icon, color: color),
      title: Text(
        finding.title,
        style: t.textTheme.bodyLarge?.copyWith(fontWeight: FontWeight.w600),
      ),
      subtitle: Padding(
        padding: const EdgeInsets.only(top: 4),
        child: Text(
          finding.detail,
          style: t.textTheme.bodySmall?.copyWith(
            color: t.colorScheme.onSurfaceVariant,
            height: 1.5,
          ),
        ),
      ),
    );
  }
}

class _QuickLinks extends StatelessWidget {
  const _QuickLinks({required this.controller});

  final GuardController controller;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SectionHeader('更多'),
        Card(
          child: Column(
            children: [
              ListTile(
                leading: const Icon(Icons.usb_outlined),
                title: const Text('本次连接详情'),
                subtitle: const Text('完整的 USB 状态、接口与供电信息'),
                trailing: const Icon(Icons.chevron_right),
                onTap: () => Navigator.of(context).push(MaterialPageRoute(
                  builder: (_) => SessionDetailPage(controller: controller),
                )),
              ),
              const Divider(height: 1),
              ListTile(
                leading: const Icon(Icons.phone_android_outlined),
                title: const Text('本机能力'),
                subtitle: const Text('这台手机上，防护能做到什么、做不到什么'),
                trailing: const Icon(Icons.chevron_right),
                onTap: () => Navigator.of(context).push(MaterialPageRoute(
                  builder: (_) => CapabilityPage(controller: controller),
                )),
              ),
              const Divider(height: 1),
              ListTile(
                leading: const Icon(Icons.history),
                title: const Text('充电记录'),
                subtitle: Text('共 ${controller.history.length} 条'),
                trailing: const Icon(Icons.chevron_right),
                onTap: () => Navigator.of(context).push(MaterialPageRoute(
                  builder: (_) => HistoryPage(controller: controller),
                )),
              ),
            ],
          ),
        ),
        const SizedBox(height: 18),
        Text(
          '数据仅保存在本机，不会上传。',
          textAlign: TextAlign.center,
          style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
        ),
      ],
    );
  }
}
