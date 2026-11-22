package io.chargeguard.charge_guard

import android.os.Build
import android.os.Bundle
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine

class MainActivity : FlutterActivity() {
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        GuardBridge.attach(flutterEngine.dartExecutor.binaryMessenger, applicationContext)
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        // 通知权限（Android 13+）用于展示充电告警。
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            requestPermissions(arrayOf(android.Manifest.permission.POST_NOTIFICATIONS), 1001)
        }
    }

    override fun onDestroy() {
        GuardBridge.detach()
        super.onDestroy()
    }
}
