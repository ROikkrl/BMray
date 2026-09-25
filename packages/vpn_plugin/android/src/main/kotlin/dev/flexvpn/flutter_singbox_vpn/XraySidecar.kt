package dev.flexvpn.flutter_singbox_vpn

import android.content.Context
import org.json.JSONObject
import java.io.File
import java.net.InetSocketAddress
import java.net.Socket

/** Xray CLI runs outside gomobile's Go runtime; both cores can coexist. */
internal class XraySidecar(private val context: Context, private val prefix: String) {
    private var process: Process? = null
    private val configFile = File(context.filesDir, "$prefix-xray.json")
    val logFile = File(context.cacheDir, "$prefix-xray.log")

    fun start(config: String) {
        val parsed = JSONObject(config)
        val inbound = parsed.getJSONArray("inbounds").getJSONObject(0)
        require(inbound.getString("listen") == "127.0.0.1" && inbound.getString("protocol") == "socks") {
            "Xray must listen on loopback SOCKS"
        }
        val port = inbound.getInt("port")
        val binary = File(context.applicationInfo.nativeLibraryDir, "libxraycli.so")
        check(binary.exists()) { "Xray Android binary is missing for this ABI" }
        configFile.writeText(config)
        val builder = ProcessBuilder(binary.absolutePath, "run", "-config", configFile.absolutePath)
            .directory(context.filesDir)
            .redirectErrorStream(true)
            .redirectOutput(ProcessBuilder.Redirect.to(logFile))
        process = builder.start()
        for (attempt in 0 until 60) {
            if (!running()) throw IllegalStateException("Xray stopped: ${logFile.takeLast(600)}")
            try {
                Socket().use { it.connect(InetSocketAddress("127.0.0.1", port), 100) }
                return
            } catch (_: Exception) {
                Thread.sleep(50)
            }
        }
        stop()
        throw IllegalStateException("Xray SOCKS did not start")
    }

    fun stop() {
        process?.destroy()
        if (running()) process?.destroyForcibly()
        process = null
        configFile.delete()
    }

    private fun running(): Boolean = try {
        process?.exitValue()
        false
    } catch (_: IllegalThreadStateException) { true }
}

private fun File.takeLast(max: Int): String = try {
    readText().takeLast(max)
} catch (_: Exception) { "no log" }
