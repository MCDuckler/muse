package dev.muse.muse

import android.content.Context
import android.net.wifi.WifiManager

/**
 * Keeping the radio awake while a song is streaming.
 *
 * audio_service already takes a partial wake lock, so the CPU stays up — but a phone
 * with the screen off also parks its WiFi, and a stream that is being read a few
 * seconds at a time is exactly the traffic pattern that gets starved by it. The player
 * then buffers, and buffering that never ends is a song that stopped in the middle for
 * no reason anybody can see.
 *
 * ExoPlayer has this built in as WAKE_MODE_NETWORK, but neither just_audio nor
 * just_audio_background turns it on and neither exposes the player to reach it. This
 * is the same lock, held from our side and released the moment nothing is playing.
 *
 * Held on the application context rather than the activity: the whole point is the
 * stretch when the activity is gone and the service is not.
 */
object Keepalive {
    private var lock: WifiManager.WifiLock? = null

    fun set(context: Context, on: Boolean) {
        if (on) acquire(context) else release()
    }

    private fun acquire(context: Context) {
        val held = lock ?: create(context)?.also { lock = it } ?: return
        if (!held.isHeld) held.acquire()
    }

    private fun release() {
        val held = lock ?: return
        if (held.isHeld) held.release()
    }

    private fun create(context: Context): WifiManager.WifiLock? {
        val wifi = context.applicationContext
            .getSystemService(Context.WIFI_SERVICE) as? WifiManager ?: return null
        // LOW_LATENCY where the platform has it; HIGH_PERF is the same idea on older
        // versions and is what the deprecated constant still maps to.
        val mode = if (android.os.Build.VERSION.SDK_INT >= 29) {
            WifiManager.WIFI_MODE_FULL_LOW_LATENCY
        } else {
            @Suppress("DEPRECATION")
            WifiManager.WIFI_MODE_FULL_HIGH_PERF
        }
        return wifi.createWifiLock(mode, "muse:stream").apply {
            setReferenceCounted(false)
        }
    }
}
