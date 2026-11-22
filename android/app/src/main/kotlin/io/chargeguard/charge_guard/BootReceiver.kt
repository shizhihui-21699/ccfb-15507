package io.chargeguard.charge_guard

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent

/**
 * 开机后重新拉起守护服务。
 *
 * 现实约束：国产 ROM（MIUI/EMUI/ColorOS 等）通常默认禁止第三方应用自启，
 * 开机广播可能收不到。这里尽力而为，App 的能力页会如实提示用户
 * "如发现开机后未自动守护，请手动打开一次 App"。
 */
class BootReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        when (intent.action) {
            Intent.ACTION_BOOT_COMPLETED,
            Intent.ACTION_MY_PACKAGE_REPLACED -> {
                runCatching { GuardService.start(context) }
            }
        }
    }
}
