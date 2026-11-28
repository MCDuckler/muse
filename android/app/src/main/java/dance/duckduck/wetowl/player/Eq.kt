package dance.duckduck.wetowl.player

import android.media.audiofx.BassBoost
import android.media.audiofx.Equalizer
import dance.duckduck.wetowl.core.Prefs
import kotlinx.coroutines.flow.MutableStateFlow

/**
 * The tone controls: the phone's equalizer, on this player's sound only. What is set is
 * kept, and laid on again whenever the player gets a new audio session.
 */
class Eq(private val prefs: Prefs) {
    private var eq: Equalizer? = null
    private var bass: BassBoost? = null

    /** Each band: its centre (Hz) and level (millibels). */
    data class Band(val centreHz: Int, val level: Int)
    data class State(val on: Boolean, val bands: List<Band>, val range: IntRange, val presets: List<String>,
                     val preset: Int, val bass: Int, val available: Boolean)

    val state = MutableStateFlow(State(false, emptyList(), -1500..1500, emptyList(), -1, 0, false))

    fun attach(session: Int) = runCatching { attachNow(session) }.let { }

    private fun attachNow(session: Int) {
        runCatching { eq?.release(); bass?.release() }
        eq = null; bass = null
        if (session == 0) return
        runCatching {
            val e = Equalizer(0, session)
            eq = e
            bass = runCatching { BassBoost(0, session) }.getOrNull()
            val saved = prefs.string("eq_levels")?.split(',')?.mapNotNull { it.toIntOrNull() }
            if (saved != null && saved.size == e.numberOfBands.toInt()) saved.forEachIndexed { i, l -> e.setBandLevel(i.toShort(), l.toShort()) }
            val p = prefs.string("eq_preset")?.toIntOrNull() ?: -1
            if (p >= 0 && saved == null) e.usePreset(p.toShort())
            val on = prefs.flag("eq_on", false)
            e.enabled = on
            bass?.let { b -> if (b.strengthSupported) b.setStrength((prefs.string("eq_bass")?.toIntOrNull() ?: 0).toShort()); b.enabled = on }
        }
        publish()
    }

    private fun publish() {
        runCatching { publishNow() }.onFailure { state.value = state.value.copy(available = false) }
    }

    private fun publishNow() {
        val e = eq ?: run { state.value = state.value.copy(available = false); return }
        val (lo, hi) = e.bandLevelRange.let { it[0].toInt() to it[1].toInt() }
        state.value = State(
            on = e.enabled,
            bands = (0 until e.numberOfBands).map { Band(e.getCenterFreq(it.toShort()) / 1000, e.getBandLevel(it.toShort()).toInt()) },
            range = lo..hi,
            presets = (0 until e.numberOfPresets).map { e.getPresetName(it.toShort()) },
            preset = prefs.string("eq_preset")?.toIntOrNull() ?: -1,
            bass = prefs.string("eq_bass")?.toIntOrNull() ?: 0,
            available = true,
        )
    }

    fun setOn(on: Boolean) {
        prefs.setFlag("eq_on", on)
        runCatching { eq?.enabled = on; bass?.enabled = on }
        publish()
    }

    fun setBand(i: Int, level: Int) {
        val e = eq ?: return
        runCatching { e.setBandLevel(i.toShort(), level.toShort()) }
        prefs.setString("eq_levels", (0 until e.numberOfBands).joinToString(",") { e.getBandLevel(it.toShort()).toString() })
        prefs.setString("eq_preset", null)
        publish()
    }

    fun usePreset(p: Int) {
        val e = eq ?: return
        runCatching { e.usePreset(p.toShort()) }
        prefs.setString("eq_preset", "$p")
        prefs.setString("eq_levels", (0 until e.numberOfBands).joinToString(",") { e.getBandLevel(it.toShort()).toString() })
        publish()
    }

    /** 0–1000. */
    fun setBass(strength: Int) {
        prefs.setString("eq_bass", "$strength")
        runCatching { bass?.setStrength(strength.toShort()) }
        publish()
    }

    fun flat() {
        val e = eq ?: return
        (0 until e.numberOfBands).forEach { runCatching { e.setBandLevel(it.toShort(), 0) } }
        prefs.setString("eq_levels", null); prefs.setString("eq_preset", null)
        setBass(0)
    }
}
