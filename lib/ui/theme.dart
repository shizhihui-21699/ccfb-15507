import 'package:material_ui/material_ui.dart';

import '../domain/risk_engine.dart';

/// 视觉与语义的统一映射：把风险等级翻译成颜色/图标/文案。
///
/// 抽出来集中管理，保证"同一等级在不同页面看到的是同一套颜色与措辞"。
class RiskVisual {
  const RiskVisual({
    required this.label,
    required this.shortLabel,
    required this.color,
    required this.icon,
    required this.headline,
  });

  final String label;
  final String shortLabel;
  final Color color;
  final IconData icon;

  /// 一句话结论，用于大字标题。
  final String headline;

  static RiskVisual of(RiskLevel level) {
    switch (level) {
      case RiskLevel.none:
        return const RiskVisual(
          label: '安全',
          shortLabel: '安全',
          color: Color(0xFF1B8A5A),
          icon: Icons.verified_user_outlined,
          headline: '当前连接是安全的',
        );
      case RiskLevel.low:
        return const RiskVisual(
          label: '低风险',
          shortLabel: '注意',
          color: Color(0xFFB8860B),
          icon: Icons.info_outline,
          headline: '有几项值得留意',
        );
      case RiskLevel.medium:
        return const RiskVisual(
          label: '中风险',
          shortLabel: '可疑',
          color: Color(0xFFD2691E),
          icon: Icons.warning_amber_rounded,
          headline: '检测到数据通道',
        );
      case RiskLevel.high:
        return const RiskVisual(
          label: '高风险',
          shortLabel: '危险',
          color: Color(0xFFC62828),
          icon: Icons.gpp_bad_outlined,
          headline: '对方可能正在读取你的手机',
        );
    }
  }
}

/// 应用主题。刻意选用沉稳的深青绿 + 中性灰，避免"安全类 App"常见的红色滥用——
/// 红色只留给真正的危险。
ThemeData buildAppTheme(Brightness brightness) {
  final scheme = ColorScheme.fromSeed(
    seedColor: const Color(0xFF146C5E),
    brightness: brightness,
  );
  return ThemeData(
    colorScheme: scheme,
    useMaterial3: true,
    scaffoldBackgroundColor: brightness == Brightness.light
        ? const Color(0xFFF6F7F5)
        : const Color(0xFF101413),
    cardTheme: CardThemeData(
      elevation: 0,
      margin: EdgeInsets.zero,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
      color: brightness == Brightness.light
          ? Colors.white
          : const Color(0xFF1A211F),
    ),
    appBarTheme: AppBarTheme(
      backgroundColor: Colors.transparent,
      elevation: 0,
      centerTitle: false,
      titleTextStyle: TextStyle(
        fontSize: 20,
        fontWeight: FontWeight.w600,
        color: scheme.onSurface,
      ),
    ),
  );
}

/// 小节标题。
class SectionHeader extends StatelessWidget {
  const SectionHeader(this.title, {super.key, this.trailing});

  final String title;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 20, 4, 10),
      child: Row(
        children: [
          Text(
            title,
            style: t.textTheme.titleSmall?.copyWith(
              fontWeight: FontWeight.w700,
              letterSpacing: 0.2,
              color: t.colorScheme.onSurfaceVariant,
            ),
          ),
          const Spacer(),
          ?trailing,
        ],
      ),
    );
  }
}

/// 带说明的卡片，用于"能力/限制"这类需要把话说清楚的场景。
class ExplainerCard extends StatelessWidget {
  const ExplainerCard({
    super.key,
    required this.icon,
    required this.title,
    required this.body,
    this.tone = ExplainerTone.neutral,
    this.actions = const [],
  });

  final IconData icon;
  final String title;
  final String body;
  final ExplainerTone tone;
  final List<Widget> actions;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final (bg, fg) = switch (tone) {
      ExplainerTone.neutral => (
          t.colorScheme.surfaceContainerHighest.withValues(alpha: 0.5),
          t.colorScheme.onSurfaceVariant,
        ),
      ExplainerTone.good => (
          const Color(0xFF1B8A5A).withValues(alpha: 0.10),
          const Color(0xFF12603E),
        ),
      ExplainerTone.caution => (
          const Color(0xFFD2691E).withValues(alpha: 0.12),
          const Color(0xFF8A3E00),
        ),
      ExplainerTone.critical => (
          const Color(0xFFC62828).withValues(alpha: 0.12),
          const Color(0xFF8B1A1A),
        ),
    };
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(16),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(icon, size: 22, color: fg),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  title,
                  style: t.textTheme.titleSmall?.copyWith(
                    fontWeight: FontWeight.w700,
                    color: fg,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            body,
            style: t.textTheme.bodyMedium?.copyWith(
              color: fg.withValues(alpha: 0.92),
              height: 1.5,
            ),
          ),
          if (actions.isNotEmpty) ...[
            const SizedBox(height: 12),
            Wrap(spacing: 8, runSpacing: 8, children: actions),
          ],
        ],
      ),
    );
  }
}

enum ExplainerTone { neutral, good, caution, critical }

/// 小号状态徽标。
class StatusPill extends StatelessWidget {
  const StatusPill({
    super.key,
    required this.text,
    required this.color,
    this.icon,
  });

  final String text;
  final Color color;
  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (icon != null) ...[
            Icon(icon, size: 14, color: color),
            const SizedBox(width: 5),
          ],
          Text(
            text,
            style: TextStyle(
              fontSize: 12.5,
              fontWeight: FontWeight.w600,
              color: color,
            ),
          ),
        ],
      ),
    );
  }
}
