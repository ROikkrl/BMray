package dev.flexvpn.flutter_singbox_vpn

import android.content.Context
import android.content.Intent
import android.net.VpnService
import android.os.Build

/** Shared direct VPN toggle for the Quick Settings tile and home-screen widget. */
internal object QuickVpnToggle {
    fun toggle(context: Context, needsApp: () -> Unit) {
        when (SingBoxVpnService.state) {
            "connected", "connecting", "reasserting" -> {
                context.startService(Intent(context, SingBoxVpnService::class.java).apply {
                    action = SingBoxVpnService.ACTION_STOP
                })
            }
            "disconnecting" -> return
            else -> {
                val profile = QuickTileProfile.load(context)
                val permissionGranted = try { VpnService.prepare(context) == null }
                    catch (_: Exception) { false }
                if (profile == null || !permissionGranted) {
                    needsApp()
                    return
                }
                val intent = Intent(context, SingBoxVpnService::class.java).apply {
                    action = SingBoxVpnService.ACTION_START
                    putExtra(SingBoxVpnService.EXTRA_CONFIG, profile.singBox)
                    profile.xray?.let { putExtra(SingBoxVpnService.EXTRA_XRAY_CONFIG, it) }
                }
                try {
                    if (Build.VERSION.SDK_INT >= 26) context.startForegroundService(intent)
                    else context.startService(intent)
                } catch (_: Exception) {
                    needsApp()
                }
            }
        }
    }
}
