package dev.muse.muse

import android.media.audiofx.DynamicsProcessing
import android.os.Build

/**
 * The booth's three bands on Android, as a mixer's EQ rather than a tone control.
 *
 * The system's own Equalizer is a *graphic* one: the phone's maker chooses how many
 * bands there are and where they sit, and its range is whatever that maker allows —
 * commonly fifteen decibels either way. So the booth's kill, which on a desk takes a
 * band out of the sound entirely, arrived on a phone as "fifteen decibels down and
 * spread over whichever of the maker's bands happen to overlap". A bass swap made
 * with that does not swap the bass; it leans on it.
 *
 * DynamicsProcessing (Android 9) has what is wanted: an equalizer whose band count and
 * crossover frequencies *we* choose, with a gain per band. Three bands split at the
 * same places the desk splits them, and a kill is the band turned off.
 *
 * Older than Android 9 keeps the graphic equalizer, and the app is told so rather than
 * left to assume: see AndroidMixer.
 */
object Bands {

    /** Where the bands divide. The same as DesktopMixer.lowCross / highCross. */
    private const val LOW_CROSS = 300f
    private const val HIGH_CROSS = 3000f

    /** The top of the last band: everything above the high crossover. */
    private const val TOP = 20000f

    private val held = HashMap<Int, DynamicsProcessing>()

    val usable: Boolean get() = Build.VERSION.SDK_INT >= Build.VERSION_CODES.P

    /**
     * [session]'s three bands, in decibels. Returns false where this phone cannot do
     * it, so the app can fall back rather than play on believing the kill landed.
     */
    fun set(session: Int, low: Float, mid: Float, high: Float): Boolean {
        if (!usable || session == 0) return false
        val dp = held[session] ?: make(session) ?: return false
        return try {
            for ((index, gain) in listOf(0 to low, 1 to mid, 2 to high)) {
                val band = dp.getPreEqBandByChannelIndex(0, index)
                band.isEnabled = true
                band.gain = gain
                dp.setPreEqBandAllChannelsTo(index, band)
            }
            true
        } catch (e: Throwable) {
            // A phone that says it has this and then will not do it: let go of the
            // effect rather than keep asking something that throws every time.
            drop(session)
            false
        }
    }

    private fun make(session: Int): DynamicsProcessing? = try {
        val config = DynamicsProcessing.Config.Builder(
            DynamicsProcessing.VARIANT_FAVOR_FREQUENCY_RESOLUTION,
            CHANNELS,
            /* preEqInUse = */ true, /* preEqBandCount = */ 3,
            /* mbcInUse = */ false, /* mbcBandCount = */ 0,
            /* postEqInUse = */ false, /* postEqBandCount = */ 0,
            /* limiterInUse = */ false,
        ).build()
        val dp = DynamicsProcessing(0, session, config)
        // The crossovers, once. A band's "cutoff" here is the top of it, so the three
        // read as "up to 300", "up to 3k", "the rest".
        for ((index, top) in listOf(0 to LOW_CROSS, 1 to HIGH_CROSS, 2 to TOP)) {
            val band = dp.getPreEqBandByChannelIndex(0, index)
            band.isEnabled = true
            band.cutoffFrequency = top
            band.gain = 0f
            dp.setPreEqBandAllChannelsTo(index, band)
        }
        dp.enabled = true
        held[session] = dp
        dp
    } catch (e: Throwable) {
        null
    }

    /** Let go of the effect on [session]: a deck that has finished with its engine. */
    fun drop(session: Int) {
        try {
            held.remove(session)?.release()
        } catch (e: Throwable) {
            // Already gone.
        }
    }

    fun dropAll() {
        for (session in held.keys.toList()) drop(session)
    }

    private const val CHANNELS = 2
}
