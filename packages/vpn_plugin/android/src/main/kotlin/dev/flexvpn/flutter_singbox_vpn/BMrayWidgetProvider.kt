package dev.flexvpn.flutter_singbox_vpn

import android.app.PendingIntent
import android.appwidget.AppWidgetManager
import android.appwidget.AppWidgetProvider
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.content.res.ColorStateList
import android.graphics.Color
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.util.SizeF
import android.view.View
import android.widget.RemoteViews
import java.util.UUID

/** Home-screen VPN toggle, updated by both theme changes and native VPN state. */
class BMrayWidgetProvider : AppWidgetProvider() {
    companion object {
        private const val ACTION_TOGGLE = "com.bolvankamax.bmray.action.WIDGET_TOGGLE"
        private const val PREFS = "bmray-widget-colors"

        private fun clickToken(context: Context): String {
            val prefs = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
            prefs.getString("click_token", null)?.let { return it }
            val token = UUID.randomUUID().toString()
            prefs.edit().putString("click_token", token).commit()
            return token
        }

        fun setTheme(context: Context, background: Int?, foreground: Int?,
            accent: Int?, buttonText: Int?, subtitle: Int?, icon: Int?) {
            val editor = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE).edit()
            background?.let { editor.putInt("background", it) }
            foreground?.let { editor.putInt("foreground", it) }
            accent?.let { editor.putInt("accent", it) }
            buttonText?.let { editor.putInt("buttonText", it) }
            subtitle?.let { editor.putInt("subtitle", it) }
            icon?.let { editor.putInt("icon", it) }
            editor.apply()
            refresh(context)
        }

        fun refresh(context: Context) {
            val manager = AppWidgetManager.getInstance(context)
            val component = ComponentName(context, BMrayWidgetProvider::class.java)
            val ids = manager.getAppWidgetIds(component)
            if (ids.isNotEmpty()) update(context, manager, ids)
        }

        private fun update(context: Context, manager: AppWidgetManager, ids: IntArray) {
            val prefs = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
            val background = prefs.getInt("background", Color.rgb(16, 24, 39))
            val foreground = prefs.getInt("foreground", Color.WHITE)
            val accent = prefs.getInt("accent", Color.rgb(29, 37, 56))
            val subtitle = prefs.getInt("subtitle", Color.rgb(157, 174, 199))
            val buttonText = prefs.getInt("buttonText", Color.WHITE)
            val icon = prefs.getInt("icon", Color.WHITE)
            val connected = SingBoxVpnService.state == "connected"
            val busy = SingBoxVpnService.state in listOf("connecting", "disconnecting", "reasserting")
            val token = clickToken(context)
            val server = QuickTileProfile.load(context)?.name.orEmpty()
            val elapsed = SingBoxVpnService.connectedAtMillis?.let {
                ((System.currentTimeMillis() - it) / 1000).coerceAtLeast(0)
            } ?: 0
            val timer = "%02d:%02d:%02d".format(elapsed / 3600,
                elapsed % 3600 / 60, elapsed % 60)
            val label = when {
                busy -> context.getString(R.string.bmray_widget_connecting)
                connected -> context.getString(R.string.bmray_tile_connected)
                else -> context.getString(R.string.bmray_tile_disconnected)
            }
            for (id in ids) {
                fun render(layout: Int): RemoteViews {
                    val views = RemoteViews(context.packageName, layout)
                    val compact = layout == R.layout.bmray_widget_compact
                    val tall = layout == R.layout.bmray_widget_tall
                    val rootColor = if (compact) accent else background
                    if (Build.VERSION.SDK_INT >= 31) {
                        views.setColorStateList(R.id.widget_root, "setBackgroundTintList",
                            ColorStateList.valueOf(rootColor))
                        if (!compact) views.setColorStateList(R.id.widget_action,
                            "setBackgroundTintList", ColorStateList.valueOf(accent))
                    } else {
                        views.setInt(R.id.widget_root, "setBackgroundColor", rootColor)
                        if (!compact) views.setInt(R.id.widget_action,
                            "setBackgroundColor", accent)
                    }
                    if (compact) {
                        views.setInt(R.id.widget_power, "setColorFilter", buttonText)
                        views.setContentDescription(R.id.widget_root, context.getString(
                            if (connected) R.string.bmray_widget_disconnect
                            else R.string.bmray_widget_connect))
                    } else {
                        views.setTextColor(R.id.widget_title, foreground)
                        views.setTextColor(R.id.widget_status, subtitle)
                        views.setTextColor(R.id.widget_action, buttonText)
                        views.setTextViewText(R.id.widget_status, label)
                        views.setTextViewText(R.id.widget_action, context.getString(
                            if (tall && connected) R.string.bmray_widget_disconnect
                            else if (tall) R.string.bmray_widget_connect
                            else if (connected) R.string.bmray_widget_off
                            else R.string.bmray_widget_on))
                        views.setInt(R.id.widget_logo, "setColorFilter", icon)
                        views.setTextColor(R.id.widget_timer, foreground)
                        views.setTextViewText(R.id.widget_timer, timer)
                        views.setViewVisibility(R.id.widget_timer,
                            if (connected) View.VISIBLE else View.GONE)
                        if (tall) {
                            views.setTextColor(R.id.widget_server, foreground)
                            views.setTextViewText(R.id.widget_server, server)
                            views.setViewVisibility(R.id.widget_server,
                                if (connected && server.isNotBlank()) View.VISIBLE else View.GONE)
                        }
                    }
                    val click = PendingIntent.getBroadcast(context, id,
                        Intent(context, BMrayWidgetProvider::class.java).apply {
                            action = ACTION_TOGGLE
                            data = Uri.parse("bmray-widget://toggle/$id/$token")
                            putExtra(AppWidgetManager.EXTRA_APPWIDGET_ID, id)
                        }, PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
                    views.setOnClickPendingIntent(R.id.widget_root, click)
                    return views
                }
                val views = if (Build.VERSION.SDK_INT >= 31) {
                    RemoteViews(mapOf(
                        SizeF(40f, 40f) to render(R.layout.bmray_widget_compact),
                        SizeF(110f, 40f) to render(R.layout.bmray_widget),
                        SizeF(110f, 105f) to render(R.layout.bmray_widget_tall),
                    ))
                } else {
                    val options = manager.getAppWidgetOptions(id)
                    val width = options.getInt(AppWidgetManager.OPTION_APPWIDGET_MIN_WIDTH, 110)
                    val height = options.getInt(AppWidgetManager.OPTION_APPWIDGET_MIN_HEIGHT, 40)
                    render(if (width < 100) R.layout.bmray_widget_compact
                        else if (height >= 100) R.layout.bmray_widget_tall
                        else R.layout.bmray_widget)
                }
                manager.updateAppWidget(id, views)
            }
        }
    }

    override fun onUpdate(context: Context, manager: AppWidgetManager, ids: IntArray) {
        update(context, manager, ids)
    }

    override fun onAppWidgetOptionsChanged(context: Context,
        manager: AppWidgetManager, id: Int, newOptions: Bundle) {
        update(context, manager, intArrayOf(id))
    }

    override fun onReceive(context: Context, intent: Intent) {
        super.onReceive(context, intent)
        if (intent.action != ACTION_TOGGLE) return
        if (intent.data?.lastPathSegment != clickToken(context)) return
        QuickVpnToggle.toggle(context) {
            context.startActivity(Intent(BMrayQuickTileService.ACTION_CONNECT_IN_APP).apply {
                setClassName(context.packageName, "com.bolvankamax.bmray.MainActivity")
                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP or
                    Intent.FLAG_ACTIVITY_CLEAR_TOP)
            })
        }
        refresh(context)
    }
}
