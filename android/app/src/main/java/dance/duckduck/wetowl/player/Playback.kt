package dance.duckduck.wetowl.player

import android.content.Context
import android.net.Uri
import android.os.Bundle
import android.os.SystemClock
import androidx.media3.common.AudioAttributes
import androidx.media3.common.C
import androidx.media3.common.MediaItem
import androidx.media3.common.MediaMetadata
import androidx.media3.common.PlaybackException
import androidx.media3.common.Player
import androidx.media3.datasource.okhttp.OkHttpDataSource
import androidx.media3.exoplayer.ExoPlayer
import androidx.media3.exoplayer.source.DefaultMediaSourceFactory
import dance.duckduck.wetowl.core.Api
import dance.duckduck.wetowl.core.ApiError
import dance.duckduck.wetowl.core.QueueState
import dance.duckduck.wetowl.core.RepeatMode
import dance.duckduck.wetowl.core.Track
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlin.math.pow

/** What the screens draw from: the queue, the row playing, and whether it is. */
data class NowPlaying(
    val queue: QueueState? = null,
    /** The row of [QueueState.items] playing. */
    val row: Int = -1,
    val playing: Boolean = false,
    val buffering: Boolean = false,
    val error: String? = null,
) {
    val track: Track? get() = queue?.items?.getOrNull(row)
}

/**
 * The music. One ExoPlayer for the process, holding the songs of the queue that can be
 * played; the house holds the queue itself.
 *
 * Every change goes to the house first and its answer is what the list becomes, laid
 * onto the player by [reconcile] — which never touches the item playing, so moving,
 * adding and removing rows around a song never interrupts it. The notification and
 * the lock screen drive the same ExoPlayer, and what they do comes back here through
 * its listener: the cursor is written, the listen is counted.
 */
class Playback(
    context: Context,
    private val api: Api,
    dataSource: androidx.media3.datasource.DataSource.Factory = OkHttpDataSource.Factory(api.http),
    private val onQueueSaved: (Int) -> Unit,
) {
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
    private val ops = Mutex()

    val exo: ExoPlayer = ExoPlayer.Builder(context)
        .setMediaSourceFactory(DefaultMediaSourceFactory(dataSource))
        .setAudioAttributes(
            AudioAttributes.Builder().setUsage(C.USAGE_MEDIA).setContentType(C.AUDIO_CONTENT_TYPE_MUSIC).build(),
            /* handleAudioFocus = */ true)
        .setHandleAudioBecomingNoisy(true)
        .setWakeMode(C.WAKE_MODE_NETWORK)
        .build()

    /** What the player did, newest last: kept to look at, and to send when something goes wrong. */
    val log = MutableStateFlow<List<String>>(emptyList())
    private val clock = java.text.SimpleDateFormat("HH:mm:ss.SSS", java.util.Locale.ROOT)
    fun note(line: String) {
        val l = log.value
        log.value = (if (l.size >= 400) l.drop(l.size - 399) else l) + "${clock.format(java.util.Date())}  $line"
    }

    private val _now = MutableStateFlow(NowPlaying())
    val now: StateFlow<NowPlaying> = _now

    /** Something to say about a change that went wrong, for a snackbar. */
    val notes = MutableSharedFlow<String>(extraBufferCapacity = 4)

    private var listenStartedAt = 0L
    private var listenTrack: Int? = null
    private var listenMs = 0L
    private var saver: Job? = null

    init {
        exo.addListener(object : Player.Listener {
            override fun onMediaItemTransition(item: MediaItem?, reason: Int) {
                note("song → ${item?.mediaMetadata?.title} (${item?.mediaId}) reason=$reason")
                closeListen(completed = reason == Player.MEDIA_ITEM_TRANSITION_REASON_AUTO)
                val row = rowOf(item)
                publish(row = row)
                openListen()
                applyGain()
                if (reason != Player.MEDIA_ITEM_TRANSITION_REASON_PLAYLIST_CHANGED) saveCursor()
                topUp()
            }

            override fun onIsPlayingChanged(isPlaying: Boolean) {
                note(if (isPlaying) "playing at ${exo.currentPosition} ms" else "stopped at ${exo.currentPosition} ms (state ${exo.playbackState}, wanted ${exo.playWhenReady})")
                if (isPlaying) openListen() else pauseListen()
                publish()
                if (!isPlaying) saveCursor()
            }

            override fun onPositionDiscontinuity(old: Player.PositionInfo, new: Player.PositionInfo, reason: Int) {
                if (reason == Player.DISCONTINUITY_REASON_SEEK) changed.tryEmit(Unit)
            }

            override fun onPlaybackStateChanged(state: Int) {
                note("state ${when (state) { Player.STATE_IDLE -> "idle"; Player.STATE_BUFFERING -> "buffering"; Player.STATE_READY -> "ready"; else -> "ended" }}")
                publish()
                if (state == Player.STATE_ENDED) closeListen(completed = true)
            }

            override fun onPlayerError(error: PlaybackException) {
                note("ERROR ${error.errorCodeName}: ${error.message} ${error.cause?.message ?: ""}")
                _now.value = _now.value.copy(error = error.errorCodeName)
                // On to the next one — playing only if the music was on. A song that will
                // not load while paused is said, and waits there; it never starts the music.
                // In someone else's jam the host keeps time: a song that fails here is not
                // a reason for this phone to go on without the room.
                val wanted = exo.playWhenReady && remote == null
                if (wanted) notes.tryEmit("Could not play ${_now.value.track?.name ?: "that"} — skipping")
                if (wanted && exo.hasNextMediaItem()) {
                    exo.seekToNextMediaItem()
                    exo.prepare()
                    exo.play()
                }
            }
        })
        // The position, every fifteen seconds while playing, so another device — or this
        // one after a restart — picks up where it was.
        saver = scope.launch {
            while (isActive) {
                delay(15_000)
                if (exo.isPlaying) saveCursor()
            }
        }
    }

    // ------------------------------------------------------------------ reading
    val positionMs: Long get() = exo.currentPosition.coerceAtLeast(0)
    val durationMs: Long get() = exo.duration.takeIf { it != C.TIME_UNSET } ?: (_now.value.track?.durationMs ?: 0)

    private fun rowOf(item: MediaItem?): Int {
        val q = _now.value.queue ?: return -1
        val id = item?.mediaId ?: return -1
        return q.items.indexOfFirst { it.rowKey == id }
    }

    private fun publish(queue: QueueState? = _now.value.queue, row: Int? = null) {
        val r = row ?: rowOf(exo.currentMediaItem).takeIf { it >= 0 } ?: _now.value.row
        _now.value = NowPlaying(
            queue = queue,
            row = r,
            playing = exo.isPlaying || (exo.playWhenReady && exo.playbackState == Player.STATE_BUFFERING),
            buffering = exo.playbackState == Player.STATE_BUFFERING,
        )
        changed.tryEmit(Unit)
    }

    /** Something another device would want to know changed: playing, the song, a seek. */
    val changed = MutableSharedFlow<Unit>(extraBufferCapacity = 1, onBufferOverflow = kotlinx.coroutines.channels.BufferOverflow.DROP_OLDEST)

    // ------------------------------------------------------------------ the list
    private fun itemFor(t: Track): MediaItem {
        val meta = MediaMetadata.Builder()
            .setTitle(t.name)
            .setArtist(t.artistLine)
            .setAlbumTitle(t.album)
            .setArtworkUri(api.coverUrl(t, small = false)?.let(Uri::parse))
            .setIsPlayable(true)
            .setIsBrowsable(false)
            .setExtras(Bundle().apply { putInt("track_id", t.id) })
            .build()
        return MediaItem.Builder()
            .setMediaId(t.rowKey)
            .setUri(api.streamUrl(t))
            .setCustomCacheKey(cacheKey(t.id))
            .setMediaMetadata(meta)
            .build()
    }

    /**
     * Lay [q] onto the player. The playable rows become its items; the song playing
     * stays exactly where it is (the items around it are swapped out from under it) when
     * it is still in the queue. [startRow] / [autoplay] are for putting a queue on.
     */
    private fun reconcile(q: QueueState, startRow: Int? = null, startMs: Long = 0, autoplay: Boolean? = null) {
        val playable = q.items.filter { it.isReady }
        val current = exo.currentMediaItem?.mediaId
        val keepAt = if (startRow == null && current != null) playable.indexOfFirst { it.rowKey == current } else -1
        _now.value = _now.value.copy(queue = q)
        if (keepAt >= 0) {
            val at = exo.currentMediaItemIndex
            if (at + 1 < exo.mediaItemCount) exo.removeMediaItems(at + 1, exo.mediaItemCount)
            if (at > 0) exo.removeMediaItems(0, at)
            val before = playable.subList(0, keepAt).map(::itemFor)
            val after = playable.subList(keepAt + 1, playable.size).map(::itemFor)
            if (before.isNotEmpty()) exo.addMediaItems(0, before)
            if (after.isNotEmpty()) exo.addMediaItems(after)
        } else {
            val want = (startRow ?: q.cursorRow).coerceIn(0, (q.items.size - 1).coerceAtLeast(0))
            // The first playable row at or after the one asked for.
            val startKey = q.items.drop(want).firstOrNull { it.isReady }?.rowKey
            val index = playable.indexOfFirst { it.rowKey == startKey }.coerceAtLeast(0)
            val wasPlaying = exo.isPlaying
            exo.setMediaItems(playable.map(::itemFor), index, if (startRow == null) startMs else 0)
            exo.prepare()
            if (autoplay ?: wasPlaying) exo.play()
        }
        exo.repeatMode = when (q.repeat) {
            RepeatMode.OFF -> Player.REPEAT_MODE_OFF
            RepeatMode.ALL -> Player.REPEAT_MODE_ALL
            RepeatMode.ONE -> Player.REPEAT_MODE_ONE
        }
        publish(queue = q)
        applyGain()
    }

    /** Run a change against the house, one at a time, and take its answer. */
    private fun change(what: String, op: suspend () -> QueueState?) {
        if (isLocal) { notes.tryEmit("Playing from the phone: the queue changes again once the house is back"); return }
        scope.launch {
            ops.withLock {
                try {
                    op()?.let { reconcile(it) }
                } catch (e: ApiError) {
                    notes.tryEmit("$what: ${e.message}")
                    refresh()
                }
            }
        }
    }

    // ------------------------------------------------------------------ putting music on
    /** Put a queue on, from its own place or from [row]. */
    suspend fun open(id: Int, row: Int? = null, autoplay: Boolean = true) {
        ops.withLock {
            val q = api.queue(id)
            onQueueSaved(id)
            reconcile(q, startRow = row, startMs = if (row == null) q.positionMs else 0, autoplay = autoplay)
            if (q.items.any { !it.isReady }) prioritise(id)
        }
    }

    /**
     * [tracks] from [start], into the queue named [name] (made if there is none; the
     * same list played twice lands in the same place rather than leaving a trail).
     */
    suspend fun playList(tracks: List<Track>, start: Int, name: String, queues: List<QueueState>) {
        if (tracks.isEmpty()) return
        ops.withLock {
            val id = queues.firstOrNull { it.name == name && it.sharedFrom == null }?.id
                ?: api.createQueue(name).id
            val q = api.replaceQueue(id, tracks.map { it.id }, cursor = start)
            onQueueSaved(id)
            reconcile(q, startRow = start, autoplay = true)
            if (tracks.any { !it.isReady }) prioritise(id)
        }
    }

    /** Handed the music by another device: this queue, at this song, this far in. */
    suspend fun take(queueId: Int, trackId: Int?, positionMs: Long) {
        ops.withLock {
            val q = api.queue(queueId)
            onQueueSaved(queueId)
            val row = q.items.indexOfFirst { it.id == trackId }.takeIf { it >= 0 } ?: q.cursorRow
            reconcile(q, startRow = row, autoplay = true)
            if (positionMs > 0) exo.seekTo(positionMs)
        }
    }

    /** Its songs fetched by the house before anything else waiting — outside the lock:
     *  it changes nothing about the queue, and the next change should not wait on it. */
    private fun prioritise(id: Int) {
        scope.launch { runCatching { api.prioritise(id) } }
    }

    fun playNext(t: Track) = add(listOf(t), next = true)
    fun addToEnd(t: Track) = add(listOf(t), next = false)

    fun add(tracks: List<Track>, next: Boolean) {
        val id = _now.value.queue?.id ?: return notes.tryEmit("Put something on first").let { }
        change("Adding") { api.addToQueue(id, tracks.map { it.id }, next) }
    }

    /** Play this row of the queue on now. */
    fun jumpTo(row: Int) {
        val q = _now.value.queue ?: return
        val key = q.items.getOrNull(row)?.rowKey ?: return
        val index = (0 until exo.mediaItemCount).firstOrNull { exo.getMediaItemAt(it).mediaId == key }
        if (index == null) {
            notes.tryEmit("That one is still on its way")
            return
        }
        exo.seekTo(index, 0)
        exo.prepare()
        exo.play()
    }

    fun move(from: Int, to: Int) {
        val q = _now.value.queue ?: return
        if (from == to) return
        // On screen at once; the house's answer replaces it a moment later.
        val items = q.items.toMutableList().apply { add(to, removeAt(from)) }
        _now.value = _now.value.copy(queue = q.copy(items = items), row = items.indexOfFirst {
            it.rowKey == _now.value.track?.rowKey
        })
        change("Moving") { api.moveInQueue(q.id, q.windowFrom + from, q.windowFrom + to) }
    }

    fun remove(row: Int) {
        val q = _now.value.queue ?: return
        change("Removing") { api.removeFromQueue(q.id, q.windowFrom + row) }
    }

    fun shuffle() {
        val q = _now.value.queue ?: return
        change("Shuffling") { api.shuffleQueue(q.id) }
    }

    fun cycleRepeat() {
        val q = _now.value.queue ?: return
        change("Repeat") { api.setRepeat(q.id, q.repeat.next) }
    }

    fun clear(origin: String? = null) {
        val q = _now.value.queue ?: return
        change("Clearing") { api.clearQueue(q.id, origin) }
    }

    /** The queue read again: after an error, or on coming back to the app. */
    fun refresh() {
        val id = _now.value.queue?.id?.takeIf { it > 0 } ?: return
        scope.launch {
            ops.withLock {
                // Only if that is still the queue on: something else (a handover, a jam)
                // may have put another on while this was waiting its turn.
                if (_now.value.queue?.id != id) return@withLock
                runCatching { api.queue(id, around = _now.value.queue?.let { it.windowFrom + _now.value.row }) }
                    .onSuccess { if (_now.value.queue?.id == id) reconcile(it) }
            }
        }
    }


    /** When the music stops by itself: a time (ms since boot clock), -1 for the song's end. */
    val sleep = MutableStateFlow<Long?>(null)
    private var sleepJob: Job? = null

    fun sleepIn(ms: Long?) {
        sleepJob?.cancel()
        if (ms == null) { sleep.value = null; return }
        val at = System.currentTimeMillis() + ms
        sleep.value = at
        sleepJob = scope.launch {
            kotlinx.coroutines.delay(ms)
            // The last half minute fades out rather than cutting.
            fadeAndPause()
        }
    }

    fun sleepAtEndOfSong() {
        sleepJob?.cancel()
        sleep.value = -1
        sleepJob = scope.launch {
            val id = exo.currentMediaItem?.mediaId
            while (exo.currentMediaItem?.mediaId == id && exo.playbackState != Player.STATE_ENDED) {
                val left = exo.duration - exo.currentPosition
                if (exo.duration > 0 && left in 0..400) break
                kotlinx.coroutines.delay(200)
            }
            exo.pause()
            sleep.value = null
        }
    }

    private suspend fun fadeAndPause() {
        val from = exo.volume
        for (i in 30 downTo 0) { exo.volume = from * i / 30f; kotlinx.coroutines.delay(500) }
        exo.pause()
        exo.volume = from
        sleep.value = null
    }

    private var rereadJob: Job? = null

    /** A song in the queue became playable, failed, or got new details: read it again, once. */
    fun trackChanged(id: Int) {
        val q = _now.value.queue ?: return
        if (q.items.none { it.id == id }) return
        reread()
    }

    private fun reread() {
        val q = _now.value.queue?.takeIf { it.id > 0 } ?: return
        rereadJob?.cancel()
        rereadJob = scope.launch {
            kotlinx.coroutines.delay(400)
            ops.withLock {
                runCatching { api.queue(q.id, around = q.windowFrom + _now.value.row.coerceAtLeast(0)) }
                    .onSuccess { if (_now.value.queue?.id == q.id) reconcile(it) }
            }
        }
    }

    /** Another device (or this one) changed a queue. Only a newer one is read. */
    fun queueChanged(id: Int, rev: Int?) {
        val q = _now.value.queue ?: return
        if (id != q.id || (rev != null && rev <= q.rev)) return
        reread()
    }

    /** Taken from another screen that already holds the house's answer. */
    fun adopt(q: QueueState) {
        if (q.id == _now.value.queue?.id) scope.launch { ops.withLock { reconcile(q) } }
    }

    /** Details of a song changed (an edit): every copy of it in the queue shows them. */
    fun tookDetails(t: Track) {
        val q = _now.value.queue ?: return
        if (q.items.none { it.id == t.id }) return
        _now.value = _now.value.copy(queue = q.copy(items = q.items.map {
            if (it.id == t.id) t.copy(itemId = it.itemId, origin = it.origin) else it
        }))
    }

    /**
     * In someone else's jam the host's player keeps time: the buttons here ask it to
     * (action, position) rather than acting on this player.
     */
    @Volatile var remote: ((String, Long?) -> Unit)? = null

    fun toggle() {
        remote?.let { it(if (_now.value.playing) "pause" else "play", null); return }
        if (exo.isPlaying) exo.pause() else {
            if (exo.playbackState == Player.STATE_IDLE) exo.prepare()
            if (exo.playbackState == Player.STATE_ENDED) exo.seekToDefaultPosition()
            exo.play()
        }
    }

    fun next() {
        remote?.let { it("next", null); return }
        if (exo.hasNextMediaItem()) exo.seekToNextMediaItem()
    }

    /** Back to the start of the song, unless it has only just begun. */
    fun previous() {
        remote?.let { it("previous", null); return }
        if (exo.currentPosition > 4_000 || !exo.hasPreviousMediaItem()) exo.seekTo(0) else exo.seekToPreviousMediaItem()
    }

    fun seek(ms: Long) {
        remote?.let { it("seek", ms); return }
        exo.seekTo(ms)
    }

    /**
     * A guest keeping step with the host: this queue, this row, this far in, playing or
     * not. Only what differs is touched — a drift under a second and a half is left be.
     */
    suspend fun follow(queueId: Int, itemId: Int?, trackId: Int?, positionMs: Long, playing: Boolean) {
        ops.withLock {
            if (_now.value.queue?.id != queueId) {
                reconcile(api.queue(queueId), autoplay = false)
            }
            var q = _now.value.queue ?: return
            var row = q.items.indexOfFirst { itemId != null && it.itemId == itemId }
                .takeIf { it >= 0 } ?: q.items.indexOfFirst { it.id == trackId }
            if (row < 0 && trackId != null) {
                // Outside the window this phone holds: read it around the host's song.
                q = api.queue(queueId); reconcile(q)
                row = q.items.indexOfFirst { it.id == trackId }
            }
            if (row >= 0) {
                val key = q.items[row].rowKey
                val index = (0 until exo.mediaItemCount).firstOrNull { exo.getMediaItemAt(it).mediaId == key }
                if (index != null && index != exo.currentMediaItemIndex) exo.seekTo(index, positionMs)
                else if (kotlin.math.abs(exo.currentPosition - positionMs) > 1500) exo.seekTo(positionMs)
            }
            if (exo.playbackState == Player.STATE_IDLE) exo.prepare()
            exo.playWhenReady = playing
        }
    }

    // ------------------------------------------------------------------ the house's side
    /** Playing a list kept on the phone, with the house out of reach: a queue of its own. */
    val isLocal get() = (_now.value.queue?.id ?: 0) < 0

    fun playLocal(tracks: List<Track>, start: Int, name: String) {
        if (tracks.isEmpty()) return
        val q = QueueState(id = -1, name = "$name · on this phone", items = tracks.map { it.copy(itemId = null) },
            total = tracks.size, cursorIndex = start)
        scope.launch { ops.withLock { reconcile(q, startRow = start, autoplay = true) } }
    }

    private fun saveCursor() {
        val q = _now.value.queue ?: return
        if (q.id < 0) return
        val row = _now.value.row.takeIf { it >= 0 } ?: return
        val pos = exo.currentPosition
        scope.launch { runCatching { api.setCursor(q.id, q.windowFrom + row, pos) } }
    }

    /** A station's queue topped up, and a long queue's window moved, as the end nears. */
    private fun topUp() {
        val q = _now.value.queue ?: return
        if (q.id < 0) return
        val left = q.items.size - 1 - _now.value.row
        if (left > 3) return
        scope.launch {
            ops.withLock {
                runCatching {
                    when {
                        q.stationId != null -> api.extendStation(q.stationId, q.id)
                        q.isWindowed && q.windowFrom + q.items.size < q.total ->
                            api.queue(q.id, around = q.windowFrom + _now.value.row)
                        else -> null
                    }
                }.getOrNull()?.let { reconcile(it) }
            }
        }
    }

    /** Loudness: a loud master is turned down to the house's level, never a quiet one up. */
    private fun applyGain() {
        val g = _now.value.track?.gainDb ?: 0.0
        exo.volume = 10.0.pow(g.coerceAtMost(0.0) / 20).toFloat()
    }

    private fun openListen() {
        val t = _now.value.track ?: return
        if (listenTrack != t.id) {
            listenTrack = t.id
            listenMs = 0
        }
        if (exo.isPlaying && listenStartedAt == 0L) listenStartedAt = SystemClock.elapsedRealtime()
    }

    private fun pauseListen() {
        if (listenStartedAt != 0L) listenMs += SystemClock.elapsedRealtime() - listenStartedAt
        listenStartedAt = 0
    }

    /** A song left: counted, when it was listened to for more than a few seconds. */
    private fun closeListen(completed: Boolean) {
        pauseListen()
        val id = listenTrack ?: return
        val ms = listenMs
        listenTrack = null
        listenMs = 0
        if (ms < 5_000 && !completed) return
        scope.launch { runCatching { api.listen(id, ms, completed) } }
    }

    fun release() {
        closeListen(false)
        saver?.cancel()
        exo.release()
    }
}
