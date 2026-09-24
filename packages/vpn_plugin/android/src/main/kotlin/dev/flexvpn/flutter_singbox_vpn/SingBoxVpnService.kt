package dev.flexvpn.flutter_singbox_vpn

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.content.Intent
import android.content.pm.ServiceInfo
import android.net.VpnService
import android.os.Build
import android.os.ParcelFileDescriptor
import io.nekohasekai.libbox.CommandServer
import io.nekohasekai.libbox.Libbox
import io.nekohasekai.libbox.OverrideOptions
import io.nekohasekai.libbox.SetupOptions
import java.io.File
import java.util.concurrent.Executors

/// Runs the sing-box core (libbox) inside an Android VpnService.
class SingBoxVpnService : VpnService() {

    companion object {
        const val ACTION_START = "com.bolvankamax.bmray.action.START"
        const val ACTION_STOP = "com.bolvankamax.bmray.action.STOP"
        const val EXTRA_CONFIG = "config"

        private const val CHANNEL_ID = "flexvpn"
        private const val NOTIF_ID = 0x1F1

        @Volatile
        var state: String = "disconnected"
            private set

        @Volatile
        var stateMessage: String? = null
            private set

        /// Set by MainActivity to forward status (state, message) to Flutter.
        var statusListener: ((String, String?) -> Unit)? = null
    }

    private var commandServer: CommandServer? = null
    private var platform: BoxPlatformInterface? = null
    private val worker = Executors.newSingleThreadExecutor()
    var tunFd: ParcelFileDescriptor? = null

    @Volatile
    private var stopping = false

    private val boxTempDir: File get() = File(cacheDir, "box").apply { mkdirs() }

    private fun setState(value: String, message: String? = null) {
        state = value
        stateMessage = message
        statusListener?.invoke(value, message)
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        // A null intent means a sticky redelivery — do NOT silently resurrect a
        // VPN the user never re-armed.
        if (intent == null) {
            stopSelf()
            return START_NOT_STICKY
        }
        if (intent.action == ACTION_STOP) {
            stopTunnel()
            return START_NOT_STICKY
        }
        startForegroundNotification()
        val config = intent.getStringExtra(EXTRA_CONFIG) ?: readSharedConfig()
        if (config.isNullOrEmpty()) {
            setState("error", "missing config")
            stopForeground(STOP_FOREGROUND_REMOVE)
            stopSelf()
            return START_NOT_STICKY
        }
        worker.execute {
            if (!stopping) {
                try {
                    startBox(config)
                } catch (e: Exception) {
                    writeExtLog("startTunnel FAILED: ${e.message}")
                    setState("error", e.message)
                    teardownBox()
                    stopForeground(STOP_FOREGROUND_REMOVE)
                    stopSelf()
                }
            }
        }
        return START_NOT_STICKY
    }

    private fun startBox(config: String) {
        // A reconnect must tear the previous tunnel down first, otherwise the old
        // CommandServer / network callback / tun fd leak and the command socket is hijacked.
        if (commandServer != null) teardownBox()

        setState("connecting")
        File(filesDir, "work").mkdirs()

        val setup = SetupOptions()
        setup.setBasePath(filesDir.absolutePath)
        setup.setWorkingPath(File(filesDir, "work").absolutePath)
        setup.setTempPath(boxTempDir.absolutePath)
        setup.setLogMaxLines(3000)
        Libbox.setup(setup)
        try { Libbox.redirectStderr(File(boxTempDir, "stderr.log").absolutePath) } catch (_: Exception) {}
        Libbox.setMemoryLimit(true)
        writeExtLog("setup ok")

        val bridge = BoxPlatformInterface(this)
        platform = bridge
        val server = Libbox.newCommandServer(bridge, bridge)
        commandServer = server
        server.start()
        writeExtLog("command server started")

        server.startOrReloadService(config, OverrideOptions())
        writeExtLog("tunnel started OK")
        if (!stopping) setState("connected")
    }

    /// Release the box / monitor / tun fd without touching the service lifecycle.
    private fun teardownBox() {
        try { commandServer?.closeService() } catch (_: Exception) {}
        platform?.closeMonitor()
        try {
            commandServer?.let {
                Thread.sleep(100)
                it.close()
            }
        } catch (_: Exception) {}
        commandServer = null
        platform = null
        try { tunFd?.close() } catch (_: Exception) {}
        tunFd = null
    }

    fun stopTunnel() {
        if (stopping) return
        stopping = true
        // Tear down off the main thread (closeService/close + settle delay).
        worker.execute {
            teardownBox()
            try { File(filesDir, "config.json").delete() } catch (_: Exception) {}
            if (state != "error") setState("disconnected")
            stopForeground(STOP_FOREGROUND_REMOVE)
            stopSelf()
        }
    }

    override fun onRevoke() {
        stopTunnel()
    }

    override fun onDestroy() {
        stopping = true
        worker.execute {
            teardownBox()
            if (state != "error") setState("disconnected")
        }
        worker.shutdown()
        super.onDestroy()
    }

    fun writeExtLog(message: String) {
        try {
            File(boxTempDir, "ext.log").appendText("[ext] $message\n")
        } catch (_: Exception) {}
    }

    private fun readSharedConfig(): String? = try {
        File(filesDir, "config.json").let { if (it.exists()) it.readText() else null }
    } catch (_: Exception) {
        null
    }

    private fun startForegroundNotification() {
        val nm = getSystemService(NotificationManager::class.java)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            nm.createNotificationChannel(
                NotificationChannel(CHANNEL_ID, "BMray", NotificationManager.IMPORTANCE_LOW)
            )
        }
        val builder = if (Build.VERSION.SDK_INT >= 26) Notification.Builder(this, CHANNEL_ID)
            else Notification.Builder(this)
        val notif: Notification = builder
            .setContentTitle("BMray")
            .setContentText("VPN подключён")
            .setSmallIcon(android.R.drawable.ic_lock_lock)
            .setOngoing(true)
            .build()
        if (Build.VERSION.SDK_INT >= 34) {
            startForeground(NOTIF_ID, notif, ServiceInfo.FOREGROUND_SERVICE_TYPE_SPECIAL_USE)
        } else {
            startForeground(NOTIF_ID, notif)
        }
    }
}
