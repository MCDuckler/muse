package dance.duckduck.wetowl.core

import android.os.SystemClock
import dance.duckduck.wetowl.player.Playback
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.launch
import kotlinx.serialization.json.JsonObject

/**
 * Listening together. The host's player is the clock: it says what it is doing (on
 * every change, and every five seconds while playing) and carries out what anyone in
 * the room asks. A guest's player follows what the host says, and its buttons become
 * requests to the host.
 */
class JamRoom(private val api: Api, private val playback: Playback, private val scope: CoroutineScope,
              private val say: (String) -> Unit) {
    val jam = MutableStateFlow<Jam?>(null)
    private var heardSeq: Long? = null
    private var mySeq = 0L
    private var reporter: Job? = null

    suspend fun refresh() {
        val j = runCatching { api.currentJam() }.getOrNull()
        set(j)
        j?.playback?.let { if (!j.isHost) follow(it, SystemClock.elapsedRealtime() - it.ageMs) }
    }

    private fun set(j: Jam?) {
        jam.value = j
        playback.remote = if (j != null && !j.isHost) { action, pos ->
            scope.launch { runCatching { api.jamControl(j.id, action, pos, playback.now.value.track?.id) }
                .onFailure { say("The host did not get that") } }
        } else null
        reporter?.cancel()
        if (j != null && j.isHost) reporter = scope.launch {
            launch { playback.changed.collect { delay(300); report() } }
            while (true) { delay(5000); if (playback.exo.isPlaying) report() }
        }
    }

    private suspend fun report() {
        val j = jam.value ?: return
        if (!j.isHost) return
        val now = playback.now.value
        val t = SystemClock.elapsedRealtime()
        mySeq = maxOf(System.currentTimeMillis(), mySeq + 1)
        runCatching { api.pushJamPlayback(j.id, now.track?.id, now.track?.itemId, playback.positionMs, now.playing, mySeq) }
    }

    private suspend fun follow(p: JamPlayback, heardAt: Long) {
        val j = jam.value ?: return
        if (p.seq != null && heardSeq != null && p.seq < heardSeq!!) return
        heardSeq = p.seq ?: heardSeq
        val since = SystemClock.elapsedRealtime() - heardAt
        val pos = if (p.playing && since in 0..120_000) p.positionMs + since else p.positionMs
        runCatching { playback.follow(j.queueId, p.itemId, p.trackId, pos, p.playing) }
    }

    /** A "jam" event from the house. */
    suspend fun heard(d: JsonObject) {
        val j = jam.value
        val id = d.int("jam_id")
        when (d.str("what")) {
            "playback" -> if (j != null && id == j.id && !j.isHost) {
                JamPlayback.from(d)?.let { follow(it, SystemClock.elapsedRealtime()) }
            }
            "control" -> if (j != null && id == j.id && j.isHost) {
                when (d.str("action")) {
                    "play" -> playback.exo.play()
                    "pause" -> playback.exo.pause()
                    "next" -> playback.next()
                    "previous" -> playback.previous()
                    "seek" -> playback.exo.seekTo((d.int("position_ms") ?: 0).toLong())
                }
                d.str("by")?.let { by -> if (d.str("action") in setOf("next", "previous")) say("$by skipped") }
            }
            "moved" -> if (j != null && id == j.id) refresh()
            "ended" -> if (j != null && id == j.id) {
                val wasGuest = !j.isHost
                set(null)
                if (wasGuest) { playback.exo.pause(); say("The jam is over") }
            }
            "joined", "left", "started" -> if (j == null || id == j.id) {
                refresh()
                d.str("who")?.let { who -> if (j != null) say(if (d.str("what") == "joined") "$who joined" else "$who left") }
            }
        }
    }

    suspend fun start(queueId: Int) { set(api.startJam(queueId)) }
    suspend fun join(code: String) { set(api.joinJam(code.trim().uppercase())); refresh() }
    suspend fun leave() {
        val j = jam.value ?: return
        api.leaveJam(j.id)
        set(null)
        if (!j.isHost) playback.exo.pause()
    }
    fun clear() = set(null)
}
