package io.chargeguard.charge_guard

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import androidx.core.app.NotificationCompat

/**
 * 常驻前台服务：在后台持续监听 USB/供电变化。
 *
 * 为什么必须用前台服务：插入充电口时用户往往锁屏、不在 App 内，
 * 普通后台进程会被系统冻结，收不到广播。前台服务是唯一可靠方案，
 * 代价是要展示一条常驻通知——这本身也起到"当前处于防护状态"的提示作用。
 */
class GuardService : Service() {

    private lateinit var collector: UsbSignalCollector
    private val handler = Handler(Looper.getMainLooper())

    /** 上一次推送出去的快照 JSON，用于去重。 */
    private var lastPushed: String? = null

    /** 轮询兜底：部分 ROM 不投递 USB_STATE，靠轮询补足。 */
    private val pollIntervalMs = 1_500L

    private val pollRunnable = object : Runnable {
        override fun run() {
            pushSnapshotIfChanged()
            handler.postDelayed(this, pollIntervalMs)
        }
    }

    override fun onCreate() {
        super.onCreate()
        collector = UsbSignalCollector(applicationContext)
        collector.registerReceivers()
        createChannel()
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        startInForeground()
        handler.removeCallbacks(pollRunnable)
        handler.post(pollRunnable)
        return START_STICKY
    }

    private fun startInForeground() {
        val notification = buildNotification("正在守护 USB 充电连接", "连接陌生充电设备时会提醒你")
        // Android 14+ 必须声明并传入前台服务类型；更低版本传类型会抛异常。
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
            startForeground(
                NOTIFICATION_ID,
                notification,
                ServiceInfo.FOREGROUND_SERVICE_TYPE_SPECIAL_USE
            )
        } else {
            startForeground(NOTIFICATION_ID, notification)
        }
    }

    private fun createChannel() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val nm = getSystemService(NotificationManager::class.java)
            if (nm.getNotificationChannel(CHANNEL_ID) == null) {
                val channel = NotificationChannel(
                    CHANNEL_ID,
                    "充电防护",
                    NotificationManager.IMPORTANCE_LOW
                ).apply {
                    description = "显示当前 USB 连接的安全状态"
                    setShowBadge(false)
                }
                nm.createNotificationChannel(channel)
            }
        }
    }

    private fun buildNotification(title: String, text: String): Notification {
        val launch = packageManager.getLaunchIntentForPackage(packageName)
            ?.addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP)
        val pending = launch?.let {
            PendingIntent.getActivity(
                this, 0, it,
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
            )
        }
        return NotificationCompat.Builder(this, CHANNEL_ID)
            .setContentTitle(title)
            .setContentText(text)
            .setSmallIcon(android.R.drawable.stat_sys_warning)
            .setOngoing(true)
            .setPriority(NotificationCompat.PRIORITY_LOW)
            .setContentIntent(pending)
            .build()
    }

    private fun pushSnapshotIfChanged() {
        val snapshot = collector.buildSnapshot()
        val json = org.json.JSONObject(snapshot as Map<*, *>).toString()
        if (json == lastPushed) return
        lastPushed = json

        // 更新常驻通知文案，让用户瞥一眼通知就知道当前是否安全。
        val riskHint = when {
            !collector.sessionActive -> "当前未连接充电设备"
            else -> "正在守护 USB 充电连接"
        }
        val nm = getSystemService(NotificationManager::class.java)
        nm.notify(NOTIFICATION_ID, buildNotification(riskHint, "点按查看详情"))

        GuardBridge.deliverSnapshot(snapshot)
    }

    override fun onDestroy() {
        handler.removeCallbacks(pollRunnable)
        collector.unregisterReceivers()
        super.onDestroy()
    }

    override fun onBind(intent: Intent?): IBinder? = null

    companion object {
        const val CHANNEL_ID = "charge_guard_status"
        const val NOTIFICATION_ID = 4001
        const val ALERT_NOTIFICATION_ID = 4002
        const val ALERT_CHANNEL_ID = "charge_guard_alert"

        fun start(context: android.content.Context) {
            val intent = Intent(context, GuardService::class.java)
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                context.startForegroundService(intent)
            } else {
                context.startService(intent)
            }
        }
    }
}
