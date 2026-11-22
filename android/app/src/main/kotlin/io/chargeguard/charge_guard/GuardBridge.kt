package io.chargeguard.charge_guard

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.os.Build
import androidx.core.app.NotificationCompat
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/**
 * Flutter <-> 原生 的唯一桥。
 *
 * Flutter 侧通过 MethodChannel('io.chargeguard/guard') 调用：
 *  - start            启动前台服务并返回当前快照
 *  - probeCapabilities 探测本机真实能力
 *  - applyAction      处置动作（阻断/恢复/信任）
 *  - openUsbSettings  打开系统设置引导用户
 *
 * 原生侧通过同一 channel 的 onSnapshot 反向推送状态。
 */
object GuardBridge {
    const val CHANNEL = "io.chargeguard/guard"

    private var channel: MethodChannel? = null
    private var appContext: Context? = null
    private lateinit var collector: UsbSignalCollector

    fun attach(messenger: BinaryMessenger, context: Context) {
        appContext = context.applicationContext
        collector = UsbSignalCollector(appContext!!)
        val ch = MethodChannel(messenger, CHANNEL)
        channel = ch
        ch.setMethodCallHandler { call, result -> handle(call, result) }
    }

    fun detach() {
        channel?.setMethodCallHandler(null)
        channel = null
    }

    /** 由 GuardService 调用，把最新快照推给 Flutter。 */
    fun deliverSnapshot(snapshot: Map<String, Any?>) {
        channel?.invokeMethod("onSnapshot", snapshot)
    }

    private fun handle(call: MethodCall, result: MethodChannel.Result) {
        val ctx = appContext ?: run {
            result.error("no_context", "bridge 未初始化", null)
            return
        }
        when (call.method) {
            "start" -> {
                GuardService.start(ctx)
                result.success(collector.buildSnapshot())
            }
            "probeCapabilities" -> result.success(collector.probeCapabilities())
            "applyAction" -> {
                @Suppress("UNCHECKED_CAST")
                val args = call.arguments as? Map<String, Any?> ?: emptyMap()
                val type = args["type"] as? String
                when (type) {
                    "blockUsbData" -> {
                        val ok = collector.blockUsbData()
                        if (!ok) {
                            // 没有设备所有者权限时，给出明确原因，不假装成功。
                            showAlertNotification(
                                ctx,
                                "无法在系统层阻断 USB 数据",
                                "当前未获得设备所有者权限，请在详情页按引导手动关闭连接。"
                            )
                        }
                        result.success(ok)
                    }
                    "allowUsbData" -> result.success(collector.allowUsbData())
                    "trustDevice" -> result.success(true)
                    "refresh" -> result.success(collector.buildSnapshot())
                    else -> result.success(false)
                }
            }
            "openUsbSettings" -> {
                collector.openUsbSettings()
                result.success(null)
            }
            "showAlert" -> {
                val title = call.argument<String>("title") ?: "检测到可疑充电连接"
                val body = call.argument<String>("body") ?: "请立即断开或检查连接。"
                showAlertNotification(ctx, title, body)
                result.success(null)
            }
            else -> result.notImplemented()
        }
    }

    /** 高优先级告警通知（锁屏可见，必要时全屏）。 */
    fun showAlertNotification(ctx: Context, title: String, body: String) {
        val nm = ctx.getSystemService(NotificationManager::class.java)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val channel = NotificationChannel(
                GuardService.ALERT_CHANNEL_ID,
                "充电安全告警",
                NotificationManager.IMPORTANCE_HIGH
            ).apply {
                description = "检测到可疑 USB 数据连接时的高优先级提醒"
                enableVibration(true)
                lockscreenVisibility = Notification.VISIBILITY_PUBLIC
            }
            nm.createNotificationChannel(channel)
        }

        val launch = ctx.packageManager.getLaunchIntentForPackage(ctx.packageName)
            ?.addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP)
        val contentIntent = launch?.let {
            PendingIntent.getActivity(
                ctx, 10, it,
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
            )
        }
        val fullScreenIntent = launch?.let {
            PendingIntent.getActivity(
                ctx, 11, it,
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
            )
        }

        val builder = NotificationCompat.Builder(ctx, GuardService.ALERT_CHANNEL_ID)
            .setContentTitle(title)
            .setContentText(body)
            .setStyle(NotificationCompat.BigTextStyle().bigText(body))
            .setSmallIcon(android.R.drawable.stat_sys_warning)
            .setPriority(NotificationCompat.PRIORITY_MAX)
            .setCategory(NotificationCompat.CATEGORY_ALARM)
            .setAutoCancel(true)
            .setVisibility(NotificationCompat.VISIBILITY_PUBLIC)
            .setContentIntent(contentIntent)

        if (fullScreenIntent != null) {
            builder.setFullScreenIntent(fullScreenIntent, true)
        }
        nm.notify(GuardService.ALERT_NOTIFICATION_ID, builder.build())
    }
}
