package com.bolvankamax.bmray

import android.content.Intent
import android.content.ComponentName
import android.app.StatusBarManager
import android.graphics.drawable.Icon
import android.os.Build
import dev.flexvpn.flutter_singbox_vpn.BMrayQuickTileService
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private var tileChannel: MethodChannel? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        tileChannel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "bmray/quick_tile")
        tileChannel?.setMethodCallHandler { call, result ->
            when (call.method) {
                "consumeConnect" -> {
                    val requested = intent?.action == BMrayQuickTileService.ACTION_CONNECT_IN_APP
                    if (requested) intent?.action = Intent.ACTION_MAIN
                    result.success(requested)
                }
                "consumeDeepLink" -> {
                    val incoming = intent?.takeIf { it.action == Intent.ACTION_VIEW &&
                        it.data?.scheme.equals("bmray", ignoreCase = true) }?.dataString
                    if (incoming != null) {
                        intent?.action = Intent.ACTION_MAIN
                        intent?.data = null
                    }
                    result.success(incoming?.takeIf { it.length <= 1024 * 1024 })
                }
                "requestAdd" -> {
                    if (Build.VERSION.SDK_INT < 33) {
                        result.success(false)
                    } else {
                        try {
                            getSystemService(StatusBarManager::class.java).requestAddTileService(
                                ComponentName(this, BMrayQuickTileService::class.java),
                                "BMray VPN", Icon.createWithResource(this,
                                    dev.flexvpn.flutter_singbox_vpn.R.drawable.ic_bmray_tile),
                                mainExecutor
                            ) { code -> result.success(code == StatusBarManager.TILE_ADD_REQUEST_RESULT_TILE_ADDED ||
                                code == StatusBarManager.TILE_ADD_REQUEST_RESULT_TILE_ALREADY_ADDED) }
                        } catch (_: Exception) {
                            result.success(false)
                        }
                    }
                }
                else -> result.notImplemented()
            }
        }
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        if (intent.action == BMrayQuickTileService.ACTION_CONNECT_IN_APP) {
            tileChannel?.invokeMethod("connect", null)
        } else if (intent.action == Intent.ACTION_VIEW &&
            intent.data?.scheme.equals("bmray", ignoreCase = true)) {
            val link = intent.dataString?.takeIf { it.length <= 1024 * 1024 }
            intent.action = Intent.ACTION_MAIN
            intent.data = null
            if (link != null) tileChannel?.invokeMethod("deepLink", link)
        }
    }

    override fun cleanUpFlutterEngine(flutterEngine: FlutterEngine) {
        tileChannel?.setMethodCallHandler(null)
        tileChannel = null
        super.cleanUpFlutterEngine(flutterEngine)
    }
}
