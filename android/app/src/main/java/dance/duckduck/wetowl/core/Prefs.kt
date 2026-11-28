package dance.duckduck.wetowl.core

import android.content.Context
import android.content.SharedPreferences
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow

/**
 * The few things kept between launches. SharedPreferences rather than DataStore: they
 * are read once, at start, before the first frame, and a suspend read there is a frame
 * of nothing.
 */
class Prefs(context: Context) {
    private val p: SharedPreferences = context.getSharedPreferences("wetowl", Context.MODE_PRIVATE)

    var server: String
        get() = p.getString("server", null) ?: Api.DEFAULT_SERVER
        set(v) = p.edit().putString("server", v).apply()

    var token: String?
        get() = p.getString("token", null)
        set(v) = p.edit().putString("token", v).apply()

    var user: String?
        get() = p.getString("user", null)
        set(v) = p.edit().putString("user", v).apply()

    var activeQueue: Int
        get() = p.getInt("active_queue", 0)
        set(v) = p.edit().putInt("active_queue", v).apply()

    /** What was searched for lately, newest first. */
    var recentSearches: List<String>
        get() = p.getString("recent_searches", null)?.split('\n')?.filter { it.isNotBlank() } ?: emptyList()
        set(v) = p.edit().putString("recent_searches", v.take(12).joinToString("\n")).apply()

    /** Generic keyed flags for small settings (haptics, auto-download…). */
    fun flag(key: String, default: Boolean) = p.getBoolean(key, default)
    fun setFlag(key: String, on: Boolean) = p.edit().putBoolean(key, on).apply()
    fun string(key: String): String? = p.getString(key, null)
    fun setString(key: String, v: String?) = p.edit().putString(key, v).apply()

    private val _accent = MutableStateFlow(Accent.of(p.getString("accent", null)))
    /** The one colour the app is lit with. [Accent.WALLPAPER] takes it from the phone. */
    val accent: StateFlow<Accent> = _accent

    fun setAccent(a: Accent) {
        p.edit().putString("accent", a.id).apply()
        _accent.value = a
    }
}

/** The accents on offer: a handful that hold up on near-black, and the wallpaper's. */
enum class Accent(val id: String, val label: String, val argb: Long) {
    EMBER("ember", "Ember", 0xFFFF6B5B),
    AMBER("amber", "Amber", 0xFFFFB547),
    LIME("lime", "Lime", 0xFFB6E35A),
    MINT("mint", "Mint", 0xFF4FE0B0),
    SKY("sky", "Sky", 0xFF5CB8FF),
    IRIS("iris", "Iris", 0xFF9B8CFF),
    ORCHID("orchid", "Orchid", 0xFFE07BF0),
    WALLPAPER("wallpaper", "Wallpaper", 0xFF9B8CFF);

    companion object {
        fun of(id: String?) = entries.firstOrNull { it.id == id } ?: EMBER
    }
}
