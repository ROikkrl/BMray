package dev.flexvpn.flutter_singbox_vpn

import android.app.PendingIntent
import android.content.ComponentName
import android.content.Intent
import android.net.VpnService
import android.os.Build
import android.service.quicksettings.Tile
import android.service.quicksettings.TileService

/** A native toggle: it works when Flutter is not running after VPN consent. */
class BMrayQuickTileService : TileService() {
    companion object {
        const val ACTION_CONNECT_IN_APP = "com.bolvankamax.bmray.action.TILE_CONNECT"

        fun refresh(context: android.content.Context) {
            try {
                TileService.requestListeningState(context,
                    ComponentName(context, BMrayQuickTileService::class.java))
            } catch (_: Exception) {
                // The tile has not been added or the system is not listening.
            }
        }
    }

    override fun onStartListening() {
        super.onStartListening()
        updateState()
    }

    override fun onClick() {
        super.onClick()
        when (SingBoxVpnService.state) {
            "connected", "connecting", "reasserting" -> {
                startService(Intent(this, SingBoxVpnService::class.java).apply {
                    action = SingBoxVpnService.ACTION_STOP
                })
            }
            "disconnecting" -> return
            else -> {
                val profile = QuickTileProfile.load(this)
                val permissionGranted = try { VpnService.prepare(this) == null }
                    catch (_: Exception) { false }
                if (profile == null || !permissionGranted) {
                    openAppForConnection()
                    return
                }
                val intent = Intent(this, SingBoxVpnService::class.java).apply {
                    action = SingBoxVpnService.ACTION_START
                    putExtra(SingBoxVpnService.EXTRA_CONFIG, profile.singBox)
                    profile.xray?.let { putExtra(SingBoxVpnService.EXTRA_XRAY_CONFIG, it) }
                }
                try {
                    if (Build.VERSION.SDK_INT >= 26) startForegroundService(intent)
                    else startService(intent)
                } catch (_: Exception) {
                    openAppForConnection()
                }
            }
        }
        updateState()
    }

    private fun openAppForConnection() {
        val intent = Intent(ACTION_CONNECT_IN_APP).apply {
            setClassName(packageName, "com.bolvankamax.bmray.MainActivity")
            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP or
                Intent.FLAG_ACTIVITY_CLEAR_TOP)
        }
        if (Build.VERSION.SDK_INT >= 34) {
            val pending = PendingIntent.getActivity(this, 7, intent,
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
            startActivityAndCollapse(pending)
        } else {
            @Suppress("DEPRECATION")
            startActivityAndCollapse(intent)
        }
    }

    private fun updateState() {
        val tile = qsTile ?: return
        val connected = SingBoxVpnService.state == "connected"
        tile.state = when (SingBoxVpnService.state) {
            "connecting", "disconnecting", "reasserting" -> Tile.STATE_UNAVAILABLE
            "connected" -> Tile.STATE_ACTIVE
            else -> Tile.STATE_INACTIVE
        }
        tile.label = "BMray VPN"
        if (Build.VERSION.SDK_INT >= 29) {
            tile.subtitle = getString(if (connected) R.string.bmray_tile_connected
                else R.string.bmray_tile_disconnected)
        }
        tile.updateTile()
    }
}
