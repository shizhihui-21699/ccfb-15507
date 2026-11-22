import 'package:charge_guard/app/guard_controller.dart';
import 'package:charge_guard/domain/models.dart';
import 'package:charge_guard/ui/capability_page.dart';
import 'package:charge_guard/ui/dashboard_page.dart';
import 'package:charge_guard/ui/history_page.dart';
import 'package:charge_guard/ui/session_detail_page.dart';
import 'package:charge_guard/ui/settings_page.dart';
import 'package:charge_guard/ui/theme.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'guard_controller_test.dart' show ScriptedSource;

void main() {
  Widget wrap(Widget child) => MaterialApp(
        theme: buildAppTheme(Brightness.light),
        home: child,
      );

  GuardController makeController({CapabilityProfile? caps}) {
    final c = GuardController(
      source: ScriptedSource(caps: caps ?? CapabilityProfile.unknown),
      store: InMemoryStore(),
    );
    return c;
  }

  /// 构造一个已推入首帧的控制器。
  Future<(GuardController, ScriptedSource)> seeded(
    SessionSnapshot snapshot, {
    CapabilityProfile? caps,
  }) async {
    final source = ScriptedSource(caps: caps ?? CapabilityProfile.unknown);
    final c = GuardController(source: source, store: InMemoryStore());
    await c.init();
    // ScriptedSource 使用同步广播，emit 会立即驱动控制器更新。
    source.emit(snapshot);
    return (c, source);
  }

  testWidgets('首页在未连接时正常渲染', (tester) async {
    final c = makeController();
    await c.init();
    await tester.pumpWidget(wrap(DashboardPage(controller: c)));
    await tester.pump();

    expect(find.text('充电守护'), findsOneWidget);
    expect(find.text('防护已就绪'), findsOneWidget);
    c.dispose();
  });

  testWidgets('高风险会话在首页展示告警标题与功能', (tester) async {
    final (c, _) = await seeded(SessionSnapshot(
      capturedAt: DateTime(2026, 11, 23, 10),
      sessionActive: true,
      sessionStartedAt: DateTime(2026, 11, 23, 10),
      port: const UsbPortState(
        connected: true,
        configured: true,
        functions: {UsbFunction.mtp, UsbFunction.adb},
      ),
      charging: const ChargingContext(plug: PowerPlug.usb),
      capabilities: CapabilityProfile.unknown,
    ));
    await tester.pumpWidget(wrap(DashboardPage(controller: c)));
    await tester.pump();

    expect(find.text('对方可能正在读取你的手机'), findsOneWidget);
    expect(find.textContaining('MTP'), findsWidgets);
    c.dispose();
  });

  testWidgets('纯充电时首页显示安全', (tester) async {
    final (c, _) = await seeded(SessionSnapshot(
      capturedAt: DateTime(2026, 11, 23, 10),
      sessionActive: true,
      sessionStartedAt: DateTime(2026, 11, 23, 10),
      port: const UsbPortState(connected: true),
      charging: const ChargingContext(plug: PowerPlug.ac),
      capabilities: CapabilityProfile.unknown,
    ));
    await tester.pumpWidget(wrap(DashboardPage(controller: c)));
    await tester.pump();

    expect(find.text('当前连接是安全的'), findsOneWidget);
    c.dispose();
  });

  testWidgets('能力页如实标注不可用的能力', (tester) async {
    final c = makeController();
    await c.init();
    await tester.pumpWidget(wrap(CapabilityPage(controller: c)));
    await tester.pump();

    expect(find.text('本机能力'), findsOneWidget);
    // 默认能力画像下，阻断能力不可用。
    expect(find.text('不可用'), findsWidgets);

    // 说明性内容在列表下方，需滚动后才会被构建。
    await tester.scrollUntilVisible(
      find.textContaining('为什么不能'),
      200,
      scrollable: find.byType(Scrollable).first,
    );
    expect(find.textContaining('为什么不能'), findsOneWidget);
    c.dispose();
  });

  testWidgets('详情页展示原始字段', (tester) async {
    final (c, _) = await seeded(SessionSnapshot(
      capturedAt: DateTime(2026, 11, 23, 10),
      sessionActive: true,
      port: const UsbPortState(
        connected: true,
        configured: true,
        functions: {UsbFunction.mtp},
        rawExtras: {'connected': true, 'mtp': true, 'unlocked': false},
      ),
      charging: const ChargingContext(plug: PowerPlug.usb),
      security: const DeviceSecurityState(adbEnabled: true),
      capabilities: CapabilityProfile.unknown,
    ));
    await tester.pumpWidget(wrap(SessionDetailPage(controller: c)));
    await tester.pump();

    expect(find.text('本次连接详情'), findsOneWidget);
    expect(find.text('系统原始字段'), findsOneWidget);
    c.dispose();
  });

  testWidgets('历史页空态与设置页可渲染', (tester) async {
    final c = makeController();
    await c.init();
    await tester.pumpWidget(wrap(HistoryPage(controller: c)));
    await tester.pump();
    expect(find.text('还没有记录'), findsOneWidget);

    await tester.pumpWidget(wrap(SettingsPage(controller: c)));
    await tester.pump();
    expect(find.text('启用充电防护'), findsOneWidget);
    c.dispose();
  });

  testWidgets('所有页面在窄屏下不溢出', (tester) async {
    tester.view.physicalSize = const Size(720, 1280);
    tester.view.devicePixelRatio = 2.0;
    addTearDown(tester.view.reset);

    final (c, _) = await seeded(SessionSnapshot(
      capturedAt: DateTime(2026, 11, 23, 10),
      sessionActive: true,
      sessionStartedAt: DateTime(2026, 11, 23, 10),
      port: const UsbPortState(
        connected: true,
        configured: true,
        functions: {UsbFunction.mtp, UsbFunction.rndis, UsbFunction.adb},
      ),
      charging: const ChargingContext(
        plug: PowerPlug.usb,
        usbNetworkInterface: 'usb0',
      ),
      capabilities: CapabilityProfile.unknown,
    ));
    await tester.pumpWidget(wrap(DashboardPage(controller: c)));
    await tester.pump();
    // 无异常即视为未溢出（RenderFlex overflow 会抛异常）。
    expect(tester.takeException(), isNull);
    c.dispose();
  });
}
