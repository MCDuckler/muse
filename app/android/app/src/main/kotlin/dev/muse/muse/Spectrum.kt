package dev.muse.muse

import android.Manifest
import android.app.Activity
import android.content.pm.PackageManager
import android.media.audiofx.Visualizer
import android.os.Handler
import android.os.Looper
import androidx.core.app.ActivityCompat
import androidx.core.content.ContextCompat
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel
import kotlin.math.hypot
import kotlin.math.log10
import kotlin.math.min

/**
 * The shape of what is coming out of the speaker.
 *
 * Android will only tell an app about its own audio through the Visualizer, and only
 * with the microphone permission — the same permission a recording app asks for, which
 * is why it is asked for at the moment somebody switches the bars on and not before.
 * Nothing is recorded and nothing leaves the device: what crosses this channel is a
 * handful of numbers per frame, which is the same information the bars draw.
 */
class Spectrum(private val activity: Activity) : EventChannel.StreamHandler {

    private var visualizer: Visualizer? = null
    private var events: EventChannel.EventSink? = null
    private val main = Handler(Looper.getMainLooper())

    /**
     * How many bands the app draws. Enough that the shape of a chord is visible rather
     * than a row of blocks, and few enough that each one is still a bar with a gap.
     */
    private val bands = 64

    fun hasPermission(): Boolean =
        ContextCompat.checkSelfPermission(activity, Manifest.permission.RECORD_AUDIO) ==
            PackageManager.PERMISSION_GRANTED

    fun askForPermission(result: MethodChannel.Result) {
        if (hasPermission()) {
            result.success(true)
            return
        }
        pending = result
        ActivityCompat.requestPermissions(
            activity, arrayOf(Manifest.permission.RECORD_AUDIO), REQUEST
        )
    }

    fun onPermissionAnswer(requestCode: Int, granted: Boolean) {
        if (requestCode != REQUEST) return
        pending?.success(granted)
        pending = null
    }

    override fun onListen(arguments: Any?, sink: EventChannel.EventSink?) {
        events = sink
        val sessionId = (arguments as? Map<*, *>)?.get("session") as? Int ?: 0
        if (!hasPermission()) {
            sink?.error("no-permission", "the microphone permission is needed", null)
            return
        }
        try {
            visualizer = Visualizer(sessionId).apply {
                captureSize = Visualizer.getCaptureSizeRange()[1]
                setDataCaptureListener(
                    object : Visualizer.OnDataCaptureListener {
                        override fun onWaveFormDataCapture(
                            v: Visualizer?, waveform: ByteArray?, rate: Int
                        ) = Unit

                        override fun onFftDataCapture(
                            v: Visualizer?, fft: ByteArray?, rate: Int
                        ) {
                            if (fft == null) return
                            main.post { events?.success(bandsFrom(fft)) }
                        }
                    },
                    // As fast as the platform will report. It is around twenty a
                    // second; the drawing side eases between them, so this is the
                    // difference between the bars following the music and lagging it.
                    Visualizer.getMaxCaptureRate(),
                    false,
                    true
                )
                enabled = true
            }
        } catch (e: Throwable) {
            sink?.error("no-visualizer", e.message, null)
        }
    }

    override fun onCancel(arguments: Any?) {
        visualizer?.enabled = false
        visualizer?.release()
        visualizer = null
        events = null
    }

    /**
     * The FFT, folded into a few bands.
     *
     * Android hands over interleaved real and imaginary parts. The magnitudes are
     * turned into decibels because that is how loud things sound, grouped in widening
     * bands because that is how pitch is heard, and normalised into 0..1 because what
     * is on the other end is a row of bars rather than a measurement.
     */
    private fun bandsFrom(fft: ByteArray): DoubleArray {
        val out = DoubleArray(bands)
        val bins = fft.size / 2
        if (bins < 2) return out

        // Bands spaced by ratio rather than by width, because that is how pitch is
        // heard: an octave is a doubling wherever it sits. Spreading sixty-four bands
        // evenly across the bins would spend most of them on the top two octaves,
        // where music has almost nothing, and give the bass a single bar.
        val ratio = Math.pow(bins.toDouble(), 1.0 / bands)
        var low = 1
        for (band in 0 until bands) {
            val high = min(bins, maxOf(low + 1, Math.pow(ratio, (band + 1).toDouble()).toInt()))
            var sum = 0.0
            var peak = 0.0
            for (bin in low until high) {
                val real = fft[bin * 2].toDouble()
                val imaginary = fft[bin * 2 + 1].toDouble()
                val magnitude = hypot(real, imaginary)
                sum += magnitude
                peak = maxOf(peak, magnitude)
            }
            // Peak and average together: the peak alone twitches, the average alone is
            // flat. Two thirds of the way towards the peak keeps the movement without
            // the jitter.
            val width = (high - low).coerceAtLeast(1)
            val level = (sum / width) * 0.35 + peak * 0.65
            val db = if (level <= 0) 0.0 else 20 * log10(level / 128.0) + 62
            out[band] = (db / 62.0).coerceIn(0.0, 1.0)
            low = high
            if (low >= bins) break
        }
        return out
    }

    companion object {
        const val REQUEST = 4711
        private var pending: MethodChannel.Result? = null
    }
}
