package dance.duckduck.wetowl

import android.content.Context
import android.os.Build
import dance.duckduck.wetowl.core.Api
import dance.duckduck.wetowl.core.ApiError
import dance.duckduck.wetowl.core.PickSection
import dance.duckduck.wetowl.core.Playlist
import dance.duckduck.wetowl.core.Prefs
import dance.duckduck.wetowl.core.QueueState
import dance.duckduck.wetowl.core.Track
import dance.duckduck.wetowl.core.dislikes
import dance.duckduck.wetowl.core.int
import dance.duckduck.wetowl.core.str
import dance.duckduck.wetowl.core.dbl
import dance.duckduck.wetowl.core.bool
import dance.duckduck.wetowl.core.obj
import dance.duckduck.wetowl.core.devices
import dance.duckduck.wetowl.core.reportState
import dance.duckduck.wetowl.core.redeem
import dance.duckduck.wetowl.core.folders
import dance.duckduck.wetowl.core.setDislike
import dance.duckduck.wetowl.player.Playback
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.launch

/** Who is signed in, and what the app holds about them between screens. */
class Store(context: Context, val api: Api = Api()) {
    val prefs = Prefs(context)
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)

    val offline: dance.duckduck.wetowl.player.Offline by lazy { dance.duckduck.wetowl.player.Offline(context, api, scope) }

    val eq by lazy { dance.duckduck.wetowl.player.Eq(prefs) }

    val playback: Playback by lazy {
        Playback(context, api, offline.dataSource) { id -> prefs.activeQueue = id }.also { p ->
            // The tone controls follow the player's sound wherever it goes.
            p.exo.addListener(object : androidx.media3.common.Player.Listener {
                override fun onAudioSessionIdChanged(audioSessionId: Int) = eq.attach(audioSessionId)
            })
            eq.attach(p.exo.audioSessionId)
        }
    }

    private val _user = MutableStateFlow(prefs.user.takeIf { prefs.token != null })
    val user: StateFlow<String?> = _user

    val playlists = MutableStateFlow<List<Playlist>>(emptyList())
    val queues = MutableStateFlow<List<QueueState>>(emptyList())
    val favourites = MutableStateFlow<Set<Int>>(emptySet())
    val dislikes = MutableStateFlow<Set<Int>>(emptySet())
    val folders = MutableStateFlow<List<dance.duckduck.wetowl.core.Folder>>(emptyList())
    val home = MutableStateFlow<List<PickSection>>(emptyList())
    val history = MutableStateFlow<List<Track>>(emptyList())

    val events = dance.duckduck.wetowl.core.Events(api, scope)

    /** Songs the house is fetching right now, and how far along. */
    val fetching = MutableStateFlow<Map<Int, dance.duckduck.wetowl.core.Fetching>>(emptyMap())

    val jams by lazy { dance.duckduck.wetowl.core.JamRoom(api, playback, scope) { playback.notes.tryEmit(it) } }

    /** Songs picked out with a long press, to act on together. */
    val selection = MutableStateFlow<List<Track>>(emptyList())

    fun toggleSelected(t: Track) {
        val now = selection.value
        selection.value = if (now.any { it.rowKey == t.rowKey }) now.filter { it.rowKey != t.rowKey } else now + t
    }

    /** Text shared into the app from elsewhere, waiting for the screens. */
    val shared = kotlinx.coroutines.flow.MutableSharedFlow<String>(replay = 1, extraBufferCapacity = 1)

    /** Somebody nodding at what you are playing: shown, then gone. */
    val reactions = kotlinx.coroutines.flow.MutableSharedFlow<Pair<String, String>>(extraBufferCapacity = 4)

    /** This account's devices; [thisDevice] is the phone in hand. */
    val devices = MutableStateFlow<List<dance.duckduck.wetowl.core.Device>>(emptyList())
    var thisDevice: Int? = null
        private set
    private var reporter: kotlinx.coroutines.Job? = null

    suspend fun refreshDevices() {
        runCatching {
            val (me, list) = api.devices(); thisDevice = me; devices.value = list
        }
    }

    /** Say what this phone is doing: on every change (gathered), and every 15 s while playing. */
    private fun startReporting() {
        reporter?.cancel()
        reporter = scope.launch {
            launch {
                playback.changed.collect {
                    kotlinx.coroutines.delay(600)
                    report()
                }
            }
            while (true) {
                kotlinx.coroutines.delay(15_000)
                if (playback.exo.isPlaying) report()
            }
        }
    }

    private suspend fun report() {
        val now = playback.now.value
        if (now.queue == null || thisDevice == null && devices.value.isEmpty() && !now.playing) return
        runCatching {
            api.reportState(now.playing, playback.positionMs, now.track?.id, now.queue.id, now.track?.itemId)
        }
    }

    /** Another device asked this one to do something. */
    private suspend fun obey(d: kotlinx.serialization.json.JsonObject) {
        val me = thisDevice ?: run { refreshDevices(); thisDevice } ?: return
        val to = d.int("to")
        val action = d.str("action") ?: return
        if (action == "yield") {
            if (d.int("except") != me && playback.exo.isPlaying) playback.exo.pause()
            return
        }
        if (to != me) return
        when (action) {
            "play" -> playback.exo.play()
            "pause", "stop" -> playback.exo.pause()
            "next" -> playback.next()
            "previous" -> playback.previous()
            "seek" -> playback.seek((d.int("position_ms") ?: 0).toLong())
            "take" -> {
                val q = d.int("queue_id") ?: return
                val track = d.int("track_id")
                val pos = (d.int("position_ms") ?: 0).toLong()
                playback.take(q, track, pos)
            }
        }
    }

    /** Bumped whenever the house says a list of this person's changed elsewhere. */
    val libraryTick = MutableStateFlow(0)

    /** Songs edited since the lists on screen were read: rows lay these over theirs. */
    val edited = MutableStateFlow<Map<Int, Track>>(emptyMap())

    init {
        scope.launch { events.events.collect { e -> runCatching { heard(e) } } }
        scope.launch { events.connected.collect { if (_user.value != null) { playback.refresh(); refreshQueues(); jams.refresh() } } }
        api.base = prefs.server
        api.token = prefs.token
        api.onUnauthorized = { scope.launch { signOut() } }
    }

    val device: String get() = "${Build.MANUFACTURER.replaceFirstChar { it.uppercase() }} ${Build.MODEL}"

    suspend fun signIn(server: String, user: String, password: String) {
        api.base = Api.normalise(server)
        val (token, name) = api.login(user.trim(), password, device)
        prefs.server = api.base
        prefs.token = token
        prefs.user = name
        _user.value = name
        start()
    }

    suspend fun redeem(server: String, code: String, user: String, password: String) {
        api.base = Api.normalise(server)
        val (token, name) = api.redeem(code.trim(), user.trim(), password, device)
        prefs.server = api.base
        prefs.token = token
        prefs.user = name
        _user.value = name
        start()
    }

    fun signOut() {
        events.stop()
        jams.clear()
        reporter?.cancel()
        playback.exo.stop()
        playback.exo.clearMediaItems()
        prefs.token = null
        api.token = null
        _user.value = null
        playlists.value = emptyList()
        queues.value = emptyList()
    }

    /** After signing in, and on every launch signed in: everything the first screens need. */
    fun start() {
        events.start()
        // Kept lists brought up to date with the house, then their songs fetched.
        scope.launch {
            offline.refresh { key ->
                val id = key.removePrefix("playlist:").toIntOrNull() ?: return@refresh null
                val p = api.playlist(id); p.shownName to p.tracks.orEmpty()
            }
        }
        scope.launch { refreshDevices() }
        scope.launch { jams.refresh() }
        startReporting()
        scope.launch {
            refreshQueues()
            val id = prefs.activeQueue.takeIf { id -> queues.value.any { it.id == id } }
                ?: queues.value.firstOrNull { it.sharedFrom == null }?.id
            if (id != null && playback.now.value.queue == null) {
                runCatching { playback.open(id, autoplay = false) }
            }
        }
        scope.launch { refreshPlaylists() }
        scope.launch { runCatching { favourites.value = api.favourites() } }
        scope.launch { runCatching { dislikes.value = api.dislikes() } }
        scope.launch { refreshHome() }
    }

    suspend fun refreshQueues() { runCatching { queues.value = api.queues() } }
    suspend fun refreshPlaylists() {
        runCatching { playlists.value = api.playlists() }
        runCatching { folders.value = api.folders() }
    }

    suspend fun refreshHome() {
        runCatching { history.value = api.history() }
        runCatching { home.value = api.home() }
    }

    private var lastProgressFlush = 0L
    private val pendingProgress = HashMap<Int, dance.duckduck.wetowl.core.Fetching?>()

    /** What the house says while the app is open. */
    private suspend fun heard(e: dance.duckduck.wetowl.core.Event) {
        val d = e.data
        val id = d.int("track_id")
        when (e.name) {
            "track_progress" -> if (id != null) {
                // Several a second per song: gathered and handed to the screens at most
                // four times a second.
                pendingProgress[id] = dance.duckduck.wetowl.core.Fetching(d.str("stage") ?: "",
                    d.dbl("percent")?.toFloat())
                val now = System.currentTimeMillis()
                if (now - lastProgressFlush > 250) flushProgress()
                else scope.launch { kotlinx.coroutines.delay(260); flushProgress() }
            }
            "track_ready", "track_failed" -> if (id != null) {
                pendingProgress[id] = null; flushProgress()
                playback.trackChanged(id)
            }
            "track_updated" -> if (id != null) {
                if (edited.value.containsKey(id)) runCatching { trackEdited(api.track(id)) }
                playback.trackChanged(id)
            }
            "queue_changed" -> {
                val q = d.int("queue_id")
                if (q != null) playback.queueChanged(q, d.int("rev"))
                refreshQueues()
            }
            "playlists", "playlist_changed", "library" -> { refreshPlaylists(); libraryTick.value++ }
            "device_command" -> obey(d)
            "jam" -> jams.heard(d)
            "reaction" -> reactions.tryEmit((d.str("from") ?: "Someone") to (d.str("emoji") ?: "❤️"))
            "devices" -> {
                val dev = d.int("device_id")
                val known = devices.value.any { it.id == dev }
                if (!known) refreshDevices() else devices.value = devices.value.map {
                    if (it.id != dev) it else it.copy(playing = d.bool("playing") ?: false, live = true,
                        positionMs = (d.int("position_ms") ?: 0).toLong(), ageMs = 0, queue = d.str("queue"),
                        queueId = d.int("queue_id"), itemId = d.int("item_id"),
                        track = d.obj("track")?.let { t -> runCatching { Track.from(t) }.getOrNull() })
                }
            }
        }
        others.tryEmit(e)
    }

    /** Every event, for the parts of the app that listen for their own (devices, jams). */
    val others = kotlinx.coroutines.flow.MutableSharedFlow<dance.duckduck.wetowl.core.Event>(extraBufferCapacity = 32)

    private fun flushProgress() {
        if (pendingProgress.isEmpty()) return
        lastProgressFlush = System.currentTimeMillis()
        val next = fetching.value.toMutableMap()
        for ((k, v) in pendingProgress) if (v == null) next.remove(k) else next[k] = v
        pendingProgress.clear()
        fetching.value = next
    }

    fun isFavourite(id: Int) = id in favourites.value

    suspend fun setFavourite(t: Track, on: Boolean) {
        favourites.value = if (on) favourites.value + t.id else favourites.value - t.id
        try {
            api.setFavourite(t.id, on)
        } catch (e: ApiError) {
            favourites.value = if (on) favourites.value - t.id else favourites.value + t.id
            throw e
        }
    }

    suspend fun setDislike(t: Track, on: Boolean) {
        dislikes.value = if (on) dislikes.value + t.id else dislikes.value - t.id
        try {
            api.setDislike(t.id, on)
        } catch (e: ApiError) {
            dislikes.value = if (on) dislikes.value - t.id else dislikes.value + t.id
            throw e
        }
    }

    fun edited(t: Track): Track = edited.value[t.id]?.let {
        t.copy(title = it.title, displayTitle = it.displayTitle, artists = it.artists, album = it.album,
            coverUrl = it.coverUrl, coverVersion = it.coverVersion, coverColor = it.coverColor)
    } ?: t

    fun trackEdited(t: Track) {
        edited.value = edited.value + (t.id to t)
        playback.tookDetails(t)
    }

    /** Play a list: into the queue named after it. */
    fun play(tracks: List<Track>, start: Int, name: String) {
        scope.launch {
            try {
                playback.playList(tracks, start, name, queues.value)
                refreshQueues()
            } catch (e: ApiError) {
                // No house: whatever of it is on the phone plays from here.
                val here = offline.onPhone.value
                val local = tracks.filter { it.id in here }
                if (e.isOffline && local.isNotEmpty()) {
                    val at = local.indexOfFirst { it.id == tracks.getOrNull(start)?.id }.coerceAtLeast(0)
                    playback.playLocal(local, at, name)
                } else playback.notes.tryEmit(if (e.isOffline) "${e.message} — and none of this is on the phone" else e.message)
            }
        }
    }

    /** A song found out there, brought in and played next — or now, with nothing on. */
    fun launch(block: suspend () -> Unit) = scope.launch {
        try { block() } catch (e: ApiError) { playback.notes.tryEmit(e.message) }
    }
}
