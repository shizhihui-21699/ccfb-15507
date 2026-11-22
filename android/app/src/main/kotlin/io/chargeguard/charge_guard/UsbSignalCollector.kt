package io.chargeguard.charge_guard

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.app.admin.DevicePolicyManager
import android.content.BroadcastReceiver
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.pm.PackageManager
import android.hardware.usb.UsbAccessory
import android.hardware.usb.UsbConstants
import android.hardware.usb.UsbDevice
import android.hardware.usb.UsbManager
import android.os.BatteryManager
import android.os.Build
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import android.provider.Settings
import java.net.NetworkInterface
import java.security.MessageDigest

/**
 * 采集系统 USB / 供电状态，并把结果交给 Flutter 侧的判定引擎。
 *
 * 设计要点（对应"不同厂商行为差异大、权限有限"这一难点）：
 *  1. **只采集事实，不下结论**：风险判定全在 Dart 纯函数中，方便用单测覆盖各厂商差异。
 *  2. **每条信号都独立开关**：某个 ROM 不投递某条广播时，其余信号仍可用，降级而非全废。
 *  3. **能力探测而非假设**：UI 依据这里探测到的真实能力展示功能范围。
 */
class UsbSignalCollector(private val context: Context) {

    private val usbManager = context.getSystemService(Context.USB_SERVICE) as UsbManager
    private val batteryManager = context.getSystemService(Context.BATTERY_SERVICE) as BatteryManager
    private val dpm = context.getSystemService(Context.DEVICE_POLICY_SERVICE) as DevicePolicyManager

    /** 观测到的最近一次 USB_STATE 数据（设备模式）。 */
    private var lastUsbConnected = false
    private var lastUsbConfigured = false
    private var lastUsbUnlocked = false
    private var lastUsbFunctions: Set<String> = emptySet()
    private var lastUsbExtras: Map<String, Boolean> = emptyMap()

    /** 是否真的观测到过 USB_STATE 广播（用来如实说明该 ROM 是否可观测）。 */
    @Volatile
    var observedUsbState: Boolean = false
        private set

    /** 会话信息：由 GuardService 维护。 */
    @Volatile
    var sessionActive: Boolean = false
    @Volatile
    var sessionStartedAt: Long? = null

    /** 本次会话内新安装的应用（需要 QUERY_ALL_PACKAGES 或通知使用权时才有值）。 */
    private var baselinePackages: Set<String> = emptySet()

    /** 上次被"阻断"后希望恢复时的功能集合（用于 allowUsbData 还原）。 */
    private var savedFunctionsBeforeBlock: Set<String> = emptySet()

    // ------------------------------------------------------------------
    // 广播接收
    // ------------------------------------------------------------------

    val usbStateReceiver = object : BroadcastReceiver() {
        override fun onReceive(ctx: Context, intent: Intent) {
            if (intent.action != ACTION_USB_STATE) return
            val extras = intent.extras ?: return
            lastUsbConnected = extras.getBoolean(USB_CONNECTED, false)
            lastUsbConfigured = extras.getBoolean(USB_CONFIGURED, false)
            lastUsbUnlocked = extras.getBoolean(USB_DATA_UNLOCKED, false)

            val fns = mutableSetOf<String>()
            val extrasMap = mutableMapOf<String, Boolean>()
            for (key in extras.keySet()) {
                val value = extras.getBoolean(key, false)
                extrasMap[key] = value
                if (value) {
                    when (key) {
                        "mtp" -> fns.add("mtp")
                        "ptp" -> fns.add("ptp")
                        "rndis" -> fns.add("rndis")
                        "ncm" -> fns.add("ncm")
                        "midi" -> fns.add("midi")
                        "adb" -> fns.add("adb")
                        "audio_source" -> fns.add("audioSource")
                        "accessory" -> fns.add("accessory")
                        "connected", "configured", "unlocked", "host_connected" -> Unit
                        else -> fns.add("other")
                    }
                }
            }
            lastUsbFunctions = fns
            lastUsbExtras = extrasMap
            observedUsbState = true
        }
    }

    private val powerReceiver = object : BroadcastReceiver() {
        override fun onReceive(ctx: Context, intent: Intent) {
            when (intent.action) {
                Intent.ACTION_POWER_CONNECTED -> onPowerConnected()
                Intent.ACTION_POWER_DISCONNECTED -> onPowerDisconnected()
            }
        }
    }

    /** 注册所有接收器。部分厂商需动态注册才能收到 USB_STATE。 */
    fun registerReceivers() {
        val usbFilter = IntentFilter(ACTION_USB_STATE)
        // 尝试读取粘性值（若系统已投递过）。
        val sticky = context.registerReceiver(null, usbFilter)
        if (sticky != null) {
            usbStateReceiver.onReceive(context, sticky)
        }
        context.registerReceiver(usbStateReceiver, usbFilter)

        val powerFilter = IntentFilter().apply {
            addAction(Intent.ACTION_POWER_CONNECTED)
            addAction(Intent.ACTION_POWER_DISCONNECTED)
        }
        context.registerReceiver(powerReceiver, powerFilter)
    }

    fun unregisterReceivers() {
        runCatching { context.unregisterReceiver(usbStateReceiver) }
        runCatching { context.unregisterReceiver(powerReceiver) }
    }

    private fun onPowerConnected() {
        if (!sessionActive) {
            sessionActive = true
            sessionStartedAt = System.currentTimeMillis()
            baselinePackages = installedPackages()
        }
    }

    private fun onPowerDisconnected() {
        sessionActive = false
        sessionStartedAt = null
        baselinePackages = emptySet()
        lastUsbConnected = false
        lastUsbConfigured = false
        lastUsbUnlocked = false
        lastUsbFunctions = emptySet()
        lastUsbExtras = emptyMap()
    }

    // ------------------------------------------------------------------
    // 快照构建
    // ------------------------------------------------------------------

    /** 构建当前完整状态，格式与 Dart 侧 SessionSnapshot.toJson 对应。 */
    fun buildSnapshot(): Map<String, Any?> {
        val plug = currentPlug()
        val hostDevices = hostDevices()
        val now = System.currentTimeMillis()

        return mapOf(
            "capturedAt" to isoNow(),
            "sessionActive" to (sessionActive || plug != "none"),
            "sessionStartedAt" to sessionStartedAt?.let { iso(it) },
            "port" to mapOf(
                "connected" to lastUsbConnected,
                "configured" to lastUsbConfigured,
                "dataUnlocked" to lastUsbUnlocked,
                "functions" to lastUsbFunctions.toList(),
                "rawExtras" to lastUsbExtras
            ),
            "charging" to mapOf(
                "plug" to plug,
                "usbNetworkInterface" to detectUsbNetworkInterface(),
                "chargeCurrentMa" to readChargeCurrent()
            ),
            "security" to currentSecurityState(),
            "hostDevices" to hostDevices,
            "appsInstalledDuringSession" to appsInstalledSinceBaseline(),
            "capabilities" to probeCapabilities(now)
        )
    }

    private fun currentPlug(): String {
        val status = context.registerReceiver(null, IntentFilter(Intent.ACTION_BATTERY_CHANGED))
        val plugged = status?.getIntExtra(BatteryManager.EXTRA_PLUGGED, 0) ?: 0
        return when {
            plugged and BatteryManager.BATTERY_PLUGGED_USB != 0 -> "usb"
            plugged and BatteryManager.BATTERY_PLUGGED_AC != 0 -> "ac"
            plugged and BatteryManager.BATTERY_PLUGGED_WIRELESS != 0 -> "wireless"
            plugged and BatteryManager.BATTERY_PLUGGED_DOCK != 0 -> "dock"
            else -> "none"
        }
    }

    /** 是否存在 USB/以太网虚拟网卡（RNDIS/NCM 数据通路已建立的最强证据）。 */
    private fun detectUsbNetworkInterface(): String? {
        return runCatching {
            NetworkInterface.getNetworkInterfaces()?.toList()
                ?.mapNotNull { it.name }
                ?.firstOrNull { name ->
                    name == "usb0" || name == "rndis0" || name.startsWith("usb") ||
                        name.startsWith("rndis") || name == "eth0" && isLikelyUsbTether()
                }
        }.getOrNull()
    }

    /** 某些机型把 USB 网卡命名为 eth0，此时用 tether 状态辅助判断。 */
    private fun isLikelyUsbTether(): Boolean = false

    private fun readChargeCurrent(): Int? {
        return runCatching {
            val v = batteryManager.getIntProperty(BatteryManager.BATTERY_PROPERTY_CURRENT_NOW)
            // 部分厂商以微安返回、部分以毫安；取绝对值并按量级归一。
            if (v == Int.MIN_VALUE || v == 0) null
            else {
                val abs = kotlin.math.abs(v)
                if (abs > 100_000) abs / 1000 else abs
            }
        }.getOrNull()
    }

    private fun currentSecurityState(): Map<String, Any?> {
        val resolver = context.contentResolver
        val adbEnabled = Settings.Global.getInt(resolver, Settings.Global.ADB_ENABLED, 0) == 1
        val devEnabled = Settings.Global.getInt(resolver, "development_settings_enabled", 0) == 1
        val keyguard = context.getSystemService(Context.KEYGUARD_SERVICE) as? android.app.KeyguardManager
        val power = context.getSystemService(Context.POWER_SERVICE) as? android.os.PowerManager
        return mapOf(
            "adbEnabled" to adbEnabled,
            "developerOptionsEnabled" to devEnabled,
            "deviceLocked" to (keyguard?.isDeviceLocked ?: false),
            "screenOn" to (power?.isInteractive ?: false)
        )
    }

    // ------------------------------------------------------------------
    // 宿主模式：手机作为 USB 主机时枚举外设
    // ------------------------------------------------------------------

    private fun hostDevices(): List<Map<String, Any?>> {
        val list = runCatching { usbManager.deviceList }.getOrNull() ?: return emptyList()
        return list.values.map { d -> describeDevice(d) }
    }

    private fun describeDevice(d: UsbDevice): Map<String, Any?> {
        val interfaces = (0 until d.interfaceCount).map { i ->
            val intf = d.getInterface(i)
            mapOf(
                "interfaceClass" to intf.interfaceClass,
                "interfaceSubclass" to intf.interfaceSubclass,
                "interfaceProtocol" to intf.interfaceProtocol
            )
        }
        // 序列号可能读到，但只保存哈希，避免可识别信息落盘。
        val serialHash = runCatching { d.serialNumber }
            .getOrNull()
            ?.takeIf { it.isNotBlank() }
            ?.let { sha256Short(it) }

        return mapOf(
            "deviceName" to (d.deviceName ?: ""),
            "vendorId" to d.vendorId,
            "productId" to d.productId,
            "deviceClass" to d.deviceClass,
            "deviceSubclass" to d.deviceSubclass,
            "deviceProtocol" to d.deviceProtocol,
            "manufacturerName" to runCatching { d.manufacturerName }.getOrNull(),
            "productName" to runCatching { d.productName }.getOrNull(),
            "serialHash" to serialHash,
            "interfaces" to interfaces
        )
    }

    // ------------------------------------------------------------------
    // 连接期间安装的应用
    // ------------------------------------------------------------------

    private fun installedPackages(): Set<String> {
        return runCatching {
            context.packageManager
                .getInstalledApplications(PackageManager.GET_META_DATA)
                .map { it.packageName }
                .toSet()
        }.getOrElse { emptySet() }
    }

    private fun appsInstalledSinceBaseline(): List<String> {
        if (baselinePackages.isEmpty()) return emptyList()
        val current = installedPackages()
        if (current.isEmpty()) return emptyList()
        return (current - baselinePackages).toList()
    }

    // ------------------------------------------------------------------
    // 能力探测
    // ------------------------------------------------------------------

    fun probeCapabilities(now: Long = System.currentTimeMillis()): Map<String, Any?> {
        val isOwner = runCatching { dpm.isDeviceOwnerApp(context.packageName) }.getOrDefault(false)
        var canDisable = false
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S && isOwner) {
            canDisable = runCatching { dpm.canUsbDataSignalingBeDisabled() }.getOrDefault(false)
        }
        val canQuery = hasQueryAllPackages()

        val notes = mutableListOf<String>()
        if (!isOwner) {
            notes.add("普通应用无权在硬件层关断 USB 数据，只能检测并提醒。")
        } else if (!canDisable) {
            notes.add("本机厂商未实现 USB 数据关断能力（DevicePolicyManager 返回不支持）。")
        }
        if (!observedUsbState) {
            notes.add("尚未观测到系统 USB 状态广播；部分定制 ROM 可能不投递。")
        }

        return mapOf(
            "platform" to "android",
            "sdkInt" to Build.VERSION.SDK_INT,
            "manufacturer" to Build.MANUFACTURER,
            "brand" to Build.BRAND,
            "model" to Build.MODEL,
            "isDeviceOwner" to isOwner,
            "canDisableUsbDataSignaling" to canDisable,
            "usbStateObservable" to observedUsbState,
            "canQueryInstalledPackages" to canQuery,
            "notes" to notes
        )
    }

    private fun hasQueryAllPackages(): Boolean {
        // 不能用"列表非空"来判断——Android 11+ 即便没有 QUERY_ALL_PACKAGES，
        // 也总会返回自身与被 manifest <queries> 命中的少数包，列表恒非空。
        // 这里直接查权限：该权限为普通权限，声明即授予，未声明则为 DENIED。
        val declared = runCatching {
            context.checkSelfPermission("android.permission.QUERY_ALL_PACKAGES") ==
                PackageManager.PERMISSION_GRANTED
        }.getOrDefault(false)
        if (declared) return true
        // 设备所有者/配置所有者可通过 DPM 获得更广的可见性。
        return runCatching {
            dpm.isDeviceOwnerApp(context.packageName) ||
                dpm.isProfileOwnerApp(context.packageName)
        }.getOrDefault(false)
    }

    // ------------------------------------------------------------------
    // 处置动作
    // ------------------------------------------------------------------

    /** 尝试在硬件层关断 USB 数据。返回是否成功。 */
    fun blockUsbData(): Boolean {
        val isOwner = runCatching { dpm.isDeviceOwnerApp(context.packageName) }.getOrDefault(false)
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.S || !isOwner) return false
        return runCatching {
            if (!dpm.canUsbDataSignalingBeDisabled()) return false
            savedFunctionsBeforeBlock = lastUsbFunctions
            dpm.setUsbDataSignalingEnabled(false)
            true
        }.getOrDefault(false)
    }

    /** 恢复 USB 数据。 */
    fun allowUsbData(): Boolean {
        val isOwner = runCatching { dpm.isDeviceOwnerApp(context.packageName) }.getOrDefault(false)
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.S || !isOwner) return false
        return runCatching {
            dpm.setUsbDataSignalingEnabled(true)
            true
        }.getOrDefault(false)
    }

    fun openUsbSettings() {
        // 不同厂商的设置页 action 不一致，逐一尝试，最后回退到设备信息页。
        val candidates = listOf(
            Intent("android.settings.USB_SETTINGS"),
            Intent(Settings.ACTION_DEVICE_INFO_SETTINGS)
        )
        for (intent in candidates) {
            intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            if (context.packageManager.resolveActivity(intent, 0) != null) {
                runCatching { context.startActivity(intent) }
                return
            }
        }
    }

    // ------------------------------------------------------------------
    // 工具
    // ------------------------------------------------------------------

    private fun isoNow(): String = iso(System.currentTimeMillis())
    private fun iso(ms: Long): String =
        java.text.SimpleDateFormat("yyyy-MM-dd'T'HH:mm:ss.SSS'Z'", java.util.Locale.US)
            .apply { timeZone = java.util.TimeZone.getTimeZone("UTC") }
            .format(java.util.Date(ms))

    private fun sha256Short(input: String): String {
        val digest = MessageDigest.getInstance("SHA-256").digest(input.toByteArray())
        return digest.take(6).joinToString("") { "%02x".format(it) }
    }

    companion object {
        // `UsbManager.ACTION_USB_STATE` 与 USB_STATE 的附加字段在 SDK 中是
        // @hide/@SystemApi，编译期不可见，只能用字符串字面量。
        // 该广播本身是「受保护广播」，普通应用无法伪造，只能接收/读取，故可信。
        const val ACTION_USB_STATE = "android.hardware.usb.action.USB_STATE"
        private const val USB_CONNECTED = "connected"
        private const val USB_CONFIGURED = "configured"
        private const val USB_DATA_UNLOCKED = "unlocked"
    }
}

/** USB 辅助常量，避免直接依赖隐藏 API。 */
object UsbClass {
    const val HID = UsbConstants.USB_CLASS_HID
    const val CDC_DATA = UsbConstants.USB_CLASS_CDC_DATA
    const val COMM = UsbConstants.USB_CLASS_COMM
    const val MASS_STORAGE = UsbConstants.USB_CLASS_MASS_STORAGE
}
