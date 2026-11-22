# 充电守护（Charge Guard）

公共充电防护功能：当手机接上陌充电设备（机场/商场的公共充电口、共享充电宝）时，
识别对方是否在尝试**建立数据连接**，及时提醒用户，并在本机能力允许的范围内
尽量减少数据暴露——同时**不妨碍用户连接自己的电脑正常传文件**。

Dart / Flutter 实现，判定逻辑与 Android 平台层严格解耦。

---

## 这个功能到底能做什么、不能做什么（先读这段）

公共 USB 充电攻击（俗称 juice jacking）的实质是：**充电线里藏着数据线**，
对端主机可以枚举手机、读取照片/通讯录，甚至通过 ADB 安装应用。

一个普通第三方 App **无法在硬件层关断 USB 数据引脚**——这是系统底层的特权。
能在系统层关断的，只有被配置为「设备所有者（Device Owner）」的企业管理应用
（`DevicePolicyManager.setUsbDataSignalingEnabled`，API 31+），或自带该能力的定制系统。

因此本应用采取的是**「检测 → 分级告警 → 尽量阻断 → 引导用户」**的务实策略：

| 能力 | 谁都有 | 备注 |
|---|---|---|
| 识别对方是否在建立数据连接 | ✅ | 依据系统 `ACTION_USB_STATE` 广播（受保护广播，App 无法伪造，只能读取） |
| 分级提醒（含锁屏高优先级通知） | ✅ | 插入时用户常锁屏、不在 App 内，故用前台服务 + 通知 |
| 信任自己的设备，正常传文件不打扰 | ✅ | 见下文「不妨碍正常使用」 |
| 系统层直接关断 USB 数据 | ⚠️ 仅设备所有者 | 普通用户无法开启；界面会如实标注"不可用" |
| 识别连接期间被安装的应用 | ⚠️ 需授权 | 需 `QUERY_ALL_PACKAGES` 或设备所有者；默认如实显示"不可用" |

**结论：在绝大多数普通手机上，这个功能的定位是"可信的检测与提醒"，而不是"静默拦截"。**
App 的「本机能力」页会逐项如实展示当前手机支持到哪一步，绝不假装具备不存在的能力。

---

## 核心设计

### 1. 三层架构：信号 / 判定 / 处置

```
原生层 (Kotlin)               纯 Dart 判定层                   UI
─────────────────      ─────────────────────────      ──────────────
UsbSignalCollector  →   RiskEngine (风险评估)       →   Dashboard
  ACTION_USB_STATE      PolicyEngine (处置策略)          Capability
  供电 / 网络接口         ↑ 纯函数、零平台依赖               Details
  宿主设备枚举          SessionSnapshot (状态快照)          History
  ↕ MethodChannel
```
真正的难点是「不同厂商、不同 ROM、不同版本行为差异大」。为此：

- **判定全部放在纯 Dart 中**，`RiskEngine` / `PolicyEngine` 是无副作用的纯函数，
  可以用单元测试穷举各厂商的怪异上报组合，不依赖手头是否有对应真机。
- **每条系统信号独立可降级**：部分定制 ROM 不投递 `USB_STATE` 广播时，靠
  1.5s 轮询 + 供电广播兜底，功能降级而非全废；「USB 状态可观测」也会如实展示。
- **能力探测而非假设**：`isDeviceOwner` / `canUsbDataSignalingBeDisabled` /
  `QUERY_ALL_PACKAGES` 全部运行时探测。

### 2. 「正在被读取」与「通道空闲开启」是两回事

这是实现过程中通过真机观察修正的**关键语义**，也是避免告警疲劳的核心：

- `USB_STATE` 报告的是当前 gadget **功能配置**。即便没有主机连接
  （`connected=false`、`configured=false`），系统仍会保留 `adb=true`、`ptp=true`
  ——那是"上次连电脑留下的状态"。
- 因此判定「对方**正在**读取」必须同时满足：**数据线已连接 + 主机已完成枚举 + 开启了敏感数据功能**
  （`UsbPortState.isActivelyExposed`）。
- 仅"通道空闲开启"只作**安全姿态提示**（中风险、琥珀色、不告警），
  绝不断言"对方可能正在读取你的手机"。

对应的回归测试见 `test/risk_engine_test.dart` 与 `test/policy_engine_test.dart`
中标记「回归：」的用例，以及 `UsbPortState.isActivelyExposed` 的文档。

### 3. 不妨碍正常使用（硬性要求）

`PolicyEngine` 的第一优先级永远是"不打扰"：

- **纯供电**（交流/无线/底座）且确实无数据功能 → 直接放行，不告警。
  （注意：仍会检查数据功能——有些底座会以交流供电之名暴露数据通道。）
- **命中信任**（自己的电脑/读卡器，按 VID/PID/序列号指纹）→ 静默，
  哪怕它打开了 MTP/ADB 也不告警——自己的电脑本来就会打开这些。
- 只有在"此刻确有主机在读取敏感数据"且不被信任时，才升级为高优先级告警；
  锁屏 + 开启"锁屏告警"时升级为全屏告警。

信任分两类，因为**设备模式下手机无法获知充电端身份**（USB 反向连接不传递主机标识）：
- 宿主模式外设：按设备指纹永久信任（真正的"认识这台设备"）；
- 设备模式：仅"本次会话临时放行"，拔线即失效。

### 4. 隐私

所有判定在本机完成，不上传任何连接信息；USB 设备序列号只保存 SHA-256 前 6 字节哈希。

---

## 目录结构

```
lib/
  domain/
    models.dart          # 领域模型：UsbPortState / SessionSnapshot / CapabilityProfile …
    risk_engine.dart     # 风险评估（纯函数）：Finding / RiskLevel / RiskAssessment
    policy_engine.dart   # 处置策略（纯函数）：PolicyAction / GuardSettings / TrustRecord
  platform/
    signal_source.dart   # 信号源抽象 + MethodChannel 真机实现 + 可回放模拟源
  app/
    guard_controller.dart# 状态中心：信号 → 判定 → 处置 + 历史归档 + 持久化
  ui/
    dashboard_page.dart  # 首页：一屏说清"安不安全 / 发生了什么 / 怎么办"
    capability_page.dart # 本机能力页：如实说明能做什么、做不到什么
    session_detail_page.dart # 原始证据页：判定依据全部摊开
    history_page.dart    # 充电记录
    settings_page.dart   # 设置与信任管理
    theme.dart           # 主题与风险视觉映射
android/app/src/main/kotlin/io/chargeguard/charge_guard/
  UsbSignalCollector.kt  # 采集 USB/供电/能力事实（不下结论）
  GuardService.kt        # 前台服务：后台持续监听 + 常驻通知
  GuardBridge.kt         # MethodChannel 桥：start/probeCapabilities/applyAction/openUsbSettings/showAlert
  BootReceiver.kt        # 开机拉起（部分国产 ROM 会拦截，属系统限制）
test/
  risk_engine_test.dart      # 风险评估单测（含厂商差异 / 回归用例）
  policy_engine_test.dart    # 处置策略单测（含"不妨碍正常使用"用例）
  guard_controller_test.dart # 状态中心集成测试
  ui_smoke_test.dart         # 各页面渲染 / 窄屏不溢出
```

## 运行

```bash
# 需要 Flutter 3.50+ / Android SDK。首次构建会下载 Android NDK 等依赖。
flutter pub get
flutter test                 # 52 个单元 / 集成 / UI 测试
flutter run -d <device>      # Android 真机或模拟器

flutter build apk --debug    # 产物：build/app/outputs/flutter-apk/app-debug.apk
```

在桌面/Web 上运行会自动使用「模拟信号源」，按脚本回放
「纯充电 → 陌生端口 MTP → 网卡+ADB → 恢复纯充电」四种场景，便于无真机地查看界面。

## 测试覆盖与验证记录

- `flutter analyze`：0 issue。
- `flutter test`：**52 passed**。
- 已在 Android 15（API 35）模拟器上实机运行，验证了：
  Kotlin 采集 → MethodChannel → Dart 判定 → 前台服务 + 高优先级通知的完整链路；
  并通过截图核对了两处**真机才暴露的判定错误**并修正：
  1. 系统上报"交流供电"但实际 `adb/ptp` 功能开启 → 曾被误判为"安全"（已修，见 `powerOnly*` 回归用例）；
  2. `adb/ptp` 功能开启但 `connected=false`（无主机）→ 曾被误报为"对方正在读取"（已修，改为姿态提示）。

## 已知限制（诚实说明）

1. **无法在普通手机上于系统层阻断**：这是 Android 权限模型的硬限制，非实现缺陷。
   界面会引导用户改用「仅充电」线/自带充电头/锁屏不点「允许」，并可在设备所有者部署下自动关断。
2. **不同厂商行为差异**：部分定制 ROM 不投递 `USB_STATE`，或供电类型上报不准；
   已用轮询 + 多信号降级兜底，并在能力页标注可观测性。开机自启在部分国产 ROM 上会被拦截。
3. **检测的是"启用了哪些数据功能"**：若厂商在系统层对某个端口做了额外限制（如锁屏禁用 MTP），
   `USB_STATE` 未必反映其全部细节；本应用不声称能看到加密或内核层面的全部行为。
4. 宿主模式下序列号可能因权限不可读，此时信任只能基于 VID/PID。
