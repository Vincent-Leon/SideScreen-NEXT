package com.sidescreen.app

import android.content.Context
import android.content.SharedPreferences
import org.json.JSONArray
import org.json.JSONObject

data class Preset(
    val host: String,
    val port: Int,
    val label: String? = null,
)

class PreferencesManager(
    context: Context,
) {
    private val prefs: SharedPreferences = context.getSharedPreferences("app_prefs", Context.MODE_PRIVATE)

    var showStatsOverlay: Boolean
        get() = prefs.getBoolean("show_stats", true)
        set(value) = prefs.edit().putBoolean("show_stats", value).apply()

    var overlayOpacity: Float
        get() = prefs.getFloat("overlay_opacity", 0.8f)
        set(value) = prefs.edit().putFloat("overlay_opacity", value).apply()

    var overlayX: Float
        get() = prefs.getFloat("overlay_x", -1f)
        set(value) = prefs.edit().putFloat("overlay_x", value).apply()

    var overlayY: Float
        get() = prefs.getFloat("overlay_y", -1f)
        set(value) = prefs.edit().putFloat("overlay_y", value).apply()

    var settingsButtonX: Float
        get() = prefs.getFloat("settings_x", -1f)
        set(value) = prefs.edit().putFloat("settings_x", value).apply()

    var settingsButtonY: Float
        get() = prefs.getFloat("settings_y", -1f)
        set(value) = prefs.edit().putFloat("settings_y", value).apply()

    // Corner position: 0=bottom-right, 1=bottom-left, 2=top-right, 3=top-left
    var settingsButtonCorner: Int
        get() = prefs.getInt("settings_corner", 0)
        set(value) = prefs.edit().putInt("settings_corner", value).apply()

    // Last successful host:port (used to prefill the connect form on next launch).
    var lastHost: String
        get() = prefs.getString("last_host", "") ?: ""
        set(value) = prefs.edit().putString("last_host", value).apply()

    var lastPort: Int
        get() = prefs.getInt("last_port", 8888)
        set(value) = prefs.edit().putInt("last_port", value).apply()

    // Saved presets — every successful non-loopback connection upserts here.
    var presets: List<Preset>
        get() {
            val raw = prefs.getString("presets", "[]") ?: "[]"
            return try {
                val arr = JSONArray(raw)
                (0 until arr.length()).map { i ->
                    val o = arr.getJSONObject(i)
                    Preset(
                        host = o.getString("host"),
                        port = o.getInt("port"),
                        label = o.optString("label").takeIf { it.isNotBlank() },
                    )
                }
            } catch (_: Exception) {
                emptyList()
            }
        }
        set(value) {
            val arr = JSONArray()
            value.forEach { p ->
                val o = JSONObject().apply {
                    put("host", p.host)
                    put("port", p.port)
                    if (p.label != null) put("label", p.label)
                }
                arr.put(o)
            }
            prefs.edit().putString("presets", arr.toString()).apply()
        }

    /** Add or replace a preset matching host+port; loopback hosts are silently skipped. */
    fun upsertPreset(p: Preset) {
        if (p.host == "127.0.0.1" || p.host.equals("localhost", ignoreCase = true)) return
        val list = presets.toMutableList()
        val idx = list.indexOfFirst { it.host == p.host && it.port == p.port }
        if (idx >= 0) list[idx] = p else list.add(p)
        presets = list
    }
}
