package dev.flexvpn.flutter_singbox_vpn

import android.app.PendingIntent
import android.content.ComponentName
import android.content.Intent
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.service.quicksettings.Tile
import android.service.quicksettings.TileService
import java.lang.ref.WeakReference

/** A native toggle: it works when Flutter is not running after VPN consent. */
class BMrayQuickTileService : TileService() {
    companion object {
        const val ACTION_CONNECT_IN_APP = "com.bolvankamax.bmray.action.TILE_CONNECT"
        private var listeningTile: WeakReference<BMrayQuickTileService>? = null

        fun refresh(context: android.content.Context) {
            Handler(Looper.getMainLooper()).post {
                listeningTile?.get()?.updateState()
            }
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
        listeningTile = WeakReference(this)
        updateState()
    }

    override fun onStopListening() {
        listeningTile = null
        super.onStopListening()
    }

    override fun onClick() {
        super.onClick()
        QuickVpnToggle.toggle(this, ::openAppForConnection)
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
