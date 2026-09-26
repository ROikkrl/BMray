package dev.flexvpn.flutter_singbox_vpn

import android.app.Activity
import android.content.Context
import android.content.Intent
import android.net.VpnService
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.net.ConnectivityManager
import android.net.NetworkCapabilities
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.embedding.engine.plugins.activity.ActivityAware
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.PluginRegistry
import io.nekohasekai.libbox.Libbox
import org.json.JSONObject
import java.io.File
import java.net.InetSocketAddress
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit

/** Bridges Flutter ⇄ the sing-box [SingBoxVpnService]. */
class FlutterSingboxVpnPlugin :
    FlutterPlugin,
    ActivityAware,
    MethodChannel.MethodCallHandler,
    EventChannel.StreamHandler,
    PluginRegistry.ActivityResultListener {

    private lateinit var context: Context
    private lateinit var methods: MethodChannel
    private lateinit var events: EventChannel

    private var activity: Activity? = null
    private var activityBinding: ActivityPluginBinding? = null

    private val mainHandler = Handler(Looper.getMainLooper())
    private val probes = Executors.newFixedThreadPool(3)
    private val probeSetupLock = Any()
    private var eventSink: EventChannel.EventSink? = null
    private var pendingConfig: String? = null
    private var pendingXrayConfig: String? = null
    private val vpnRequestCode = 0x0F1E

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        context = binding.applicationContext
        methods = MethodChannel(binding.binaryMessenger, "flutter_singbox_vpn/methods")
        methods.setMethodCallHandler(this)
        events = EventChannel(binding.binaryMessenger, "flutter_singbox_vpn/events")
        events.setStreamHandler(this)
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        probes.shutdownNow()
        methods.setMethodCallHandler(null)
        events.setStreamHandler(null)
        SingBoxVpnService.statusListener = null
    }

    // MARK: ActivityAware (needed for the VPN consent dialog)

    override fun onAttachedToActivity(binding: ActivityPluginBinding) = bindActivity(binding)
    override fun onReattachedToActivityForConfigChanges(binding: ActivityPluginBinding) = bindActivity(binding)
    override fun onDetachedFromActivityForConfigChanges() = unbindActivity()
    override fun onDetachedFromActivity() = unbindActivity()

    private fun bindActivity(binding: ActivityPluginBinding) {
        activity = binding.activity
        activityBinding = binding
        binding.addActivityResultListener(this)
    }

    private fun unbindActivity() {
        activityBinding?.removeActivityResultListener(this)
        activity = null
        activityBinding = null
    }

    // MARK: EventChannel

    override fun onListen(arguments: Any?, sink: EventChannel.EventSink?) {
        eventSink = sink
        SingBoxVpnService.statusListener = { state, message -> mainHandler.post { emit(state, message) } }
        emit(SingBoxVpnService.state, SingBoxVpnService.stateMessage)
    }

    override fun onCancel(arguments: Any?) {
        eventSink = null
        SingBoxVpnService.statusListener = null
    }

    private fun emit(state: String, message: String?) {
        val payload = HashMap<String, Any?>()
        payload["state"] = state
        if (message != null) payload["message"] = message
        SingBoxVpnService.connectedAtMillis?.let { payload["connectedAtMillis"] = it }
        eventSink?.success(payload)
    }

    // MARK: Method calls

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "start" -> {
                pendingConfig = call.argument<String>("config")
                pendingXrayConfig = call.argument<String>("xrayConfig")
                startVpnFlow()
                result.success(null)
            }
            "stop" -> { stopVpn(); result.success(null) }
            "status" -> result.success(mapOf(
                "state" to SingBoxVpnService.state,
                "connectedAtMillis" to SingBoxVpnService.connectedAtMillis,
            ))
            "coreVersion" -> {
                val v = try { Libbox.version() } catch (e: Exception) { "?" }
                result.success("sing-box $v")
            }
            "validateConfig" -> {
                val cfg = call.argument<String>("config") ?: ""
                try { Libbox.checkConfig(cfg); result.success(null) }
                catch (e: Exception) { result.success(e.message) }
            }
            "readLogs" -> result.success(readLogs())
            "clearLogs" -> { clearLogs(); result.success(null) }
            "probeProxyGet" -> {
                val cfg = call.argument<String>("config") ?: ""
                val xrayConfig = call.argument<String>("xrayConfig")
                val timeoutMillis = (call.argument<Int>("timeoutMillis") ?: 4000).coerceIn(1000, 15000)
                probes.execute {
                    var bridge: BoxPlatformInterface? = null
                    var sidecar: XraySidecar? = null
                    try {
                        val active = SingBoxVpnService.current?.takeIf {
                            SingBoxVpnService.state == "connected"
                        }
                        if (xrayConfig != null && active != null && !active.xrayActive) {
                            throw IllegalStateException("Отключите текущий VPN для проверки XHTTP")
                        }
                        if (xrayConfig != null) {
                            sidecar = XraySidecar(context, "probe-${Thread.currentThread().id}")
                            sidecar.start(xrayConfig)
                        }
                        if (active == null) {
                            synchronized(probeSetupLock) {
                                val root = context.filesDir
                                val setup = io.nekohasekai.libbox.SetupOptions()
                                setup.basePath = root.absolutePath
                                setup.workingPath = File(root, "work").apply { mkdirs() }.absolutePath
                                setup.tempPath = File(context.cacheDir, "box").apply { mkdirs() }.absolutePath
                                Libbox.setup(setup)
                            }
                        }
                        bridge = if (active != null) BoxPlatformInterface(active) else BoxPlatformInterface(context)
                        val delay = Libbox.probeProxyGET(
                            cfg,
                            "https://www.gstatic.com/generate_204\n" +
                                "https://cp.cloudflare.com/generate_204\n" +
                                "https://max.ru/",
                            timeoutMillis,
                            bridge,
                        )
                        mainHandler.post { result.success(mapOf("delay" to delay)) }
                    } catch (e: Exception) {
                        val detail = e.message?.lowercase() ?: ""
                        val reason = when {
                            "reality verification failed" in detail -> "Ошибка проверки REALITY"
                            "timeout" in detail || "deadline exceeded" in detail -> "Тайм-аут"
                            "unknown utls" in detail || "fingerprint" in detail -> "Неподдерживаемый fingerprint"
                            "dns" in detail || "lookup" in detail -> "Ошибка DNS"
                            "connection refused" in detail -> "Сервер отклонил соединение"
                            "invalid" in detail || "decode config" in detail -> "Ошибка конфигурации"
                            "отключите текущий vpn" in detail -> "Отключите текущий VPN для проверки XHTTP"
                            else -> "Нет ответа через прокси"
                        }
                        mainHandler.post { result.success(mapOf("reason" to reason)) }
                    } finally {
                        bridge?.closeMonitor()
                        sidecar?.stop()
                    }
                }
            }
            "probeTcp" -> {
                val host = call.argument<String>("host") ?: ""
                val port = call.argument<Int>("port") ?: 0
                probes.execute {
                    var delay: Int? = null
                    if (host.isNotBlank() && port in 1..65535) {
                        try {
                            val cm = context.getSystemService(ConnectivityManager::class.java)
                            val network = cm.allNetworks.firstOrNull {
                                val caps = cm.getNetworkCapabilities(it)
                                caps != null && caps.hasCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET) &&
                                    caps.hasCapability(NetworkCapabilities.NET_CAPABILITY_NOT_VPN)
                            }
                            if (network != null) {
                                val addresses = network.getAllByName(host)
                                val start = System.nanoTime()
                                network.socketFactory.createSocket().use { socket ->
                                    socket.connect(InetSocketAddress(addresses.first(), port), 3000)
                                }
                                delay = (TimeUnit.NANOSECONDS.toMillis(System.nanoTime() - start)).coerceAtLeast(1).toInt()
                            }
                        } catch (_: Exception) { }
                    }
                    mainHandler.post { result.success(delay) }
                }
            }
            else -> result.notImplemented()
        }
    }

    private fun startVpnFlow() {
        val config = pendingConfig ?: return
        val prepared = injectLogOutput(config)
        pendingConfig = prepared
        try { File(context.filesDir, "config.json").writeText(prepared) } catch (_: Exception) {}

        val consent = VpnService.prepare(context)
        if (consent != null) {
            val act = activity
            if (act != null) {
                act.startActivityForResult(consent, vpnRequestCode)
            } else {
                emit("error", "Для запроса VPN требуется открыть приложение")
            }
        } else {
            launchService(prepared, pendingXrayConfig)
            pendingConfig = null
            pendingXrayConfig = null
        }
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?): Boolean {
        if (requestCode != vpnRequestCode) return false
        val cfg = pendingConfig
        val xrayCfg = pendingXrayConfig
        pendingConfig = null
        pendingXrayConfig = null
        if (resultCode == Activity.RESULT_OK && cfg != null) {
            launchService(cfg, xrayCfg)
        } else {
            try { File(context.filesDir, "config.json").delete() } catch (_: Exception) {}
            emit("disconnected", "Разрешение VPN отклонено")
        }
        return true
    }

    private fun launchService(config: String, xrayConfig: String?) {
        val intent = Intent(context, SingBoxVpnService::class.java).apply {
            action = SingBoxVpnService.ACTION_START
            putExtra(SingBoxVpnService.EXTRA_CONFIG, config)
            if (xrayConfig != null) putExtra(SingBoxVpnService.EXTRA_XRAY_CONFIG, xrayConfig)
        }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            context.startForegroundService(intent)
        } else {
            context.startService(intent)
        }
    }

    private fun stopVpn() {
        context.startService(Intent(context, SingBoxVpnService::class.java).apply {
            action = SingBoxVpnService.ACTION_STOP
        })
    }

    private fun injectLogOutput(config: String): String = try {
        val obj = JSONObject(config)
        val log = obj.optJSONObject("log") ?: JSONObject()
        log.put("output", File(context.filesDir, "box.log").absolutePath)
        log.put("disabled", false)
        obj.put("log", log)
        obj.toString()
    } catch (e: Exception) {
        config
    }

    private fun readLogs(): String {
        val sb = StringBuilder()
        fun tail(file: File, max: Int, header: String) {
            if (!file.exists()) return
            val text = try { file.readText() } catch (_: Exception) { return }
            if (text.isEmpty()) return
            sb.append("===== ").append(header).append(" =====\n")
            sb.append(if (text.length > max) text.substring(text.length - max) else text).append('\n')
        }
        val boxTemp = File(context.cacheDir, "box")
        tail(File(boxTemp, "ext.log"), 16 * 1024, "extension")
        tail(File(boxTemp, "stderr.log"), 16 * 1024, "stderr")
        tail(File(context.filesDir, "box.log"), 48 * 1024, "sing-box")
        tail(File(context.cacheDir, "tunnel-xray.log"), 24 * 1024, "Xray")
        return sb.toString()
    }

    private fun clearLogs() {
        for (f in listOf("box/ext.log", "box/stderr.log")) {
            try { File(context.cacheDir, f).writeText("") } catch (_: Exception) {}
        }
        try { File(context.filesDir, "box.log").writeText("") } catch (_: Exception) {}
        try { File(context.cacheDir, "tunnel-xray.log").writeText("") } catch (_: Exception) {}
    }
}
