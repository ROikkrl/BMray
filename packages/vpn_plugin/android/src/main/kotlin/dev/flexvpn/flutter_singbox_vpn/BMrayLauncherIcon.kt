package dev.flexvpn.flutter_singbox_vpn

import android.content.ComponentName
import android.content.Context
import android.content.pm.PackageManager

/** Switches the visible launcher alias without stopping an active VPN. */
internal object BMrayLauncherIcon {
    private const val PREFS = "bmray-launcher-icon"
    private val variants = mapOf(
        "classic" to "LauncherClassic",
        "monochrome" to "LauncherMonochrome",
        "purple" to "LauncherPurple",
        "cyan" to "LauncherCyan",
    )

    fun current(context: Context): String = context.getSharedPreferences(PREFS,
        Context.MODE_PRIVATE).getString("variant", "classic") ?: "classic"

    fun set(context: Context, variant: String) {
        require(variants.containsKey(variant)) { "Unknown launcher icon" }
        val pm = context.packageManager
        val selected = variants.getValue(variant)
        // Enable the new entry first so the launcher always sees an entry point.
        pm.setComponentEnabledSetting(
            ComponentName(context.packageName, "${context.packageName}.$selected"),
            PackageManager.COMPONENT_ENABLED_STATE_ENABLED, PackageManager.DONT_KILL_APP)
        for (alias in variants.values) {
            if (alias == selected) continue
            pm.setComponentEnabledSetting(
                ComponentName(context.packageName, "${context.packageName}.$alias"),
                PackageManager.COMPONENT_ENABLED_STATE_DISABLED, PackageManager.DONT_KILL_APP)
        }
        context.getSharedPreferences(PREFS, Context.MODE_PRIVATE).edit()
            .putString("variant", variant).apply()
    }
}
