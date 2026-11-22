import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';
import 'package:material_ui/material_ui.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'app/guard_controller.dart';
import 'platform/signal_source.dart';
import 'ui/dashboard_page.dart';
import 'ui/theme.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const ChargeGuardApp());
}

class ChargeGuardApp extends StatefulWidget {
  const ChargeGuardApp({super.key});

  @override
  State<ChargeGuardApp> createState() => _ChargeGuardAppState();
}

class _ChargeGuardAppState extends State<ChargeGuardApp> {
  late final GuardController _controller;
  final ThemeMode _themeMode = ThemeMode.system;

  @override
  void initState() {
    super.initState();
    _controller = GuardController(
      source: _createSource(),
      store: PrefsStore(),
    );
    _controller.init();
  }

  /// 选择信号源：
  /// - Android 真机/模拟器：走 MethodChannel 与原生层通信；
  /// - 其他平台（桌面/Web 预览、在浏览器里看效果）：走可回放的模拟源，
  ///   这样无需真机也能完整查看界面与判定流程。
  PlatformSignalSource _createSource() {
    if (kIsWeb) return SimulatedPlatformSignalSource();
    if (Platform.isAndroid) return MethodChannelPlatformSignalSource();
    return SimulatedPlatformSignalSource();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: '充电守护',
      debugShowCheckedModeBanner: false,
      theme: buildAppTheme(Brightness.light),
      darkTheme: buildAppTheme(Brightness.dark),
      themeMode: _themeMode,
      home: DashboardPage(controller: _controller),
      builder: (context, child) {
        // 固定文字缩放上限，避免超大字号把关键信息挤出屏幕。
        final mq = MediaQuery.of(context);
        return MediaQuery(
          data: mq.copyWith(
            textScaler: mq.textScaler.clamp(maxScaleFactor: 1.3),
          ),
          child: child!,
        );
      },
    );
  }
}

/// 基于 shared_preferences 的键值存储。
class PrefsStore implements KeyValueStore {
  SharedPreferences? _prefs;

  Future<SharedPreferences> get _p async =>
      _prefs ??= await SharedPreferences.getInstance();

  @override
  Future<String?> read(String key) async => (await _p).getString(key);

  @override
  Future<void> write(String key, String value) async =>
      (await _p).setString(key, value);

  @override
  Future<void> remove(String key) async => (await _p).remove(key);
}
