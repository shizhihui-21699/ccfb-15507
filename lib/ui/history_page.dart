import 'package:material_ui/material_ui.dart';

import '../app/guard_controller.dart';
import 'theme.dart';

/// 充电记录：每次插入到拔出归档一条，供事后回溯。
class HistoryPage extends StatelessWidget {
  const HistoryPage({super.key, required this.controller});

  final GuardController controller;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: controller,
      builder: (context, _) {
        final history = controller.history;
        final t = Theme.of(context);
        return Scaffold(
          appBar: AppBar(title: const Text('充电记录')),
          body: history.isEmpty
              ? Center(
                  child: Padding(
                    padding: const EdgeInsets.all(32),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.history_toggle_off,
                            size: 56, color: t.colorScheme.outline),
                        const SizedBox(height: 14),
                        Text(
                          '还没有记录',
                          style: t.textTheme.titleMedium,
                        ),
                        const SizedBox(height: 6),
                        Text(
                          '拔掉充电器后，本次连接会自动归档到这里。',
                          textAlign: TextAlign.center,
                          style: t.textTheme.bodySmall?.copyWith(
                            color: t.colorScheme.onSurfaceVariant,
                          ),
                        ),
                      ],
                    ),
                  ),
                )
              : ListView.separated(
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
                  itemCount: history.length,
                  separatorBuilder: (_, _) => const SizedBox(height: 10),
                  itemBuilder: (context, i) {
                    final r = history[i];
                    final v = RiskVisual.of(r.peakRisk);
                    return Card(
                      child: Padding(
                        padding: const EdgeInsets.all(16),
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Icon(v.icon, color: v.color),
                            const SizedBox(width: 12),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Row(
                                    children: [
                                      Expanded(
                                        child: Text(
                                          r.trustLabel != null
                                              ? '已信任 · ${r.trustLabel}'
                                              : r.summary,
                                          style: t.textTheme.bodyLarge?.copyWith(
                                              fontWeight: FontWeight.w600),
                                        ),
                                      ),
                                      StatusPill(
                                          text: v.shortLabel, color: v.color),
                                    ],
                                  ),
                                  const SizedBox(height: 6),
                                  Text(
                                    '${_fmt(r.startedAt)} · 持续 ${_dur(r.startedAt, r.endedAt)}',
                                    style: t.textTheme.bodySmall?.copyWith(
                                      color: t.colorScheme.onSurfaceVariant,
                                    ),
                                  ),
                                  if (r.findings.isNotEmpty &&
                                      r.trustLabel == null) ...[
                                    const SizedBox(height: 6),
                                    Wrap(
                                      spacing: 6,
                                      runSpacing: 4,
                                      children: [
                                        for (final f in r.findings.take(4))
                                          Text(
                                            f,
                                            style: t.textTheme.labelSmall
                                                ?.copyWith(
                                              color:
                                                  t.colorScheme.onSurfaceVariant,
                                            ),
                                          ),
                                      ],
                                    ),
                                  ],
                                ],
                              ),
                            ),
                          ],
                        ),
                      ),
                    );
                  },
                ),
        );
      },
    );
  }

  static String _fmt(DateTime d) {
    String two(int n) => n.toString().padLeft(2, '0');
    return '${two(d.month)}-${two(d.day)} ${two(d.hour)}:${two(d.minute)}';
  }

  static String _dur(DateTime a, DateTime b) {
    final d = b.difference(a);
    if (d.inMinutes < 1) return '${d.inSeconds} 秒';
    if (d.inHours < 1) return '${d.inMinutes} 分钟';
    return '${d.inHours} 小时';
  }
}
