@file:androidx.annotation.OptIn(androidx.media3.common.util.UnstableApi::class)

package dance.duckduck.wetowl.player

import android.content.Context
import android.net.Uri
import androidx.media3.database.StandaloneDatabaseProvider
import androidx.media3.datasource.DataSource
import androidx.media3.datasource.cache.CacheDataSource
import androidx.media3.datasource.cache.NoOpCacheEvictor
import androidx.media3.datasource.cache.SimpleCache
import androidx.media3.datasource.okhttp.OkHttpDataSource
import androidx.media3.exoplayer.offline.Download
import androidx.media3.exoplayer.offline.DownloadManager
import androidx.media3.exoplayer.offline.DownloadRequest
import dance.duckduck.wetowl.core.Api
import dance.duckduck.wetowl.core.Track
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonArray
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.put
import java.io.File
import java.util.concurrent.Executors

/** A list kept on the phone: its name, and its songs as they were when last synced. */
data class KeptList(val key: String, val name: String, val tracks: List<Track>)

/** The cache key a song's audio is kept under: the same whatever address it streams from. */
fun cacheKey(trackId: Int) = "track-$trackId"

/**
 * Music kept on the phone, to play with no connection. A playlist (or a queue) is
 * "kept": every song on it is downloaded into a cache that is never evicted, and the
 * player reads through that cache first — so a kept song plays from the phone even
 * when the house can be reached. Songs on no kept list any more are let go.
 */
class Offline(private val context: Context, private val api: Api, private val scope: CoroutineScope) {
    /** Through the download service when the app runs for real; straight to the manager in tests. */
    var useService = true

    private val dir = File(context.filesDir, "offline")
    private val metaFile = File(dir, "kept.json")
    private val db = StandaloneDatabaseProvider(context)
    val cache = SimpleCache(File(dir, "audio"), NoOpCacheEvictor(), db)
    private val upstream = OkHttpDataSource.Factory(api.http)

    /** What the player reads through: the phone first, the house for anything not kept. */
    val dataSource: DataSource.Factory = CacheDataSource.Factory()
        .setCache(cache)
        .setUpstreamDataSourceFactory(upstream)
        // Only downloads go in; what is merely streamed is not kept.
        .setCacheWriteDataSinkFactory(null)
        .setFlags(CacheDataSource.FLAG_IGNORE_CACHE_ON_ERROR)

    val manager = DownloadManager(context, db, cache, upstream, Executors.newFixedThreadPool(2)).apply {
        maxParallelDownloads = 2
        minRetryCount = 3
    }

    val kept = MutableStateFlow<List<KeptList>>(emptyList())
    /** Songs whose audio is whole on the phone. */
    val onPhone = MutableStateFlow<Set<Int>>(emptySet())
    /** Songs being kept right now, and how far along (0–100). */
    val keeping = MutableStateFlow<Map<Int, Float>>(emptyMap())
    val bytes = MutableStateFlow(0L)

    init {
        dir.mkdirs()
        kept.value = readMeta()
        manager.addListener(object : DownloadManager.Listener {
            override fun onDownloadChanged(m: DownloadManager, d: Download, e: Exception?) = recount()
            override fun onDownloadRemoved(m: DownloadManager, d: Download) = recount()
            override fun onInitialized(m: DownloadManager) = recount()
        })
        manager.resumeDownloads()
        scope.launch {
            while (true) {
                if (manager.currentDownloads.isNotEmpty()) recount()
                kotlinx.coroutines.delay(1000)
            }
        }
    }

    private fun idOf(d: Download) = d.request.id.removePrefix("track-").toIntOrNull()

    private fun recount() {
        val done = mutableSetOf<Int>()
        val going = mutableMapOf<Int, Float>()
        runCatching {
            manager.downloadIndex.getDownloads().use { c ->
                while (c.moveToNext()) {
                    val d = c.download
                    val id = idOf(d) ?: continue
                    if (d.state == Download.STATE_COMPLETED) done += id
                }
            }
        }
        for (d in manager.currentDownloads) {
            val id = idOf(d) ?: continue
            if (d.state != Download.STATE_COMPLETED) going[id] = d.percentDownloaded.coerceAtLeast(0f)
        }
        onPhone.value = done
        keeping.value = going
        bytes.value = runCatching { cache.cacheSpace }.getOrDefault(0L)
    }

    fun isKept(key: String) = kept.value.any { it.key == key }

    /** Keep this list on the phone (again: its songs as they are now). */
    fun keep(key: String, name: String, tracks: List<Track>) {
        val list = KeptList(key, name, tracks.filter { it.isReady || it.id in onPhone.value })
        kept.value = kept.value.filter { it.key != key } + list
        writeMeta()
        sync()
    }

    fun forget(key: String) {
        kept.value = kept.value.filter { it.key != key }
        writeMeta()
        sync()
    }

    fun forgetAll() {
        kept.value = emptyList()
        writeMeta()
        manager.removeAllDownloads()
    }

    /** Every song on a kept list asked for; every song on none let go. */
    fun sync() {
        val want = kept.value.flatMap { it.tracks }.associateBy { it.id }
        for ((id, t) in want) {
            val url = api.streamUrl(t) ?: continue
            if (id in onPhone.value) continue
            val req = DownloadRequest.Builder(cacheKey(id), Uri.parse(url))
                .setCustomCacheKey(cacheKey(id)).setData(t.name.toByteArray()).build()
            if (useService) runCatching {
                androidx.media3.exoplayer.offline.DownloadService.sendAddDownload(context, OfflineService::class.java, req, false)
            }.onFailure { manager.addDownload(req) }
            else manager.addDownload(req)
        }
        runCatching {
            manager.downloadIndex.getDownloads().use { c ->
                val drop = mutableListOf<String>()
                while (c.moveToNext()) { val d = c.download; if (idOf(d) !in want.keys) drop += d.request.id }
                drop.forEach(manager::removeDownload)
            }
        }
        recount()
    }

    /** Kept lists read again from the house, for the ones that are playlists. */
    suspend fun refresh(read: suspend (String) -> Pair<String, List<Track>>?) {
        for (k in kept.value) {
            val fresh = runCatching { read(k.key) }.getOrNull() ?: continue
            kept.value = kept.value.map { if (it.key == k.key) KeptList(k.key, fresh.first, fresh.second.filter { t -> t.isReady }) else it }
        }
        writeMeta()
        sync()
    }

    /** Every kept song, once each, for playing with nothing else to go on. */
    fun keptTracks(): List<Track> = kept.value.flatMap { it.tracks }.distinctBy { it.id }.filter { it.id in onPhone.value }

    // ------------------------------------------------------------------ meta on disk
    private fun writeMeta() {
        val lists = kept.value
        scope.launch(Dispatchers.IO) {
            val json = buildJsonArray {
                lists.forEach { l ->
                    add(buildJsonObject {
                        put("key", l.key); put("name", l.name)
                        put("tracks", buildJsonArray { l.tracks.forEach { add(trackJson(it)) } })
                    })
                }
            }
            runCatching { metaFile.writeText(json.toString()) }
        }
    }

    private fun readMeta(): List<KeptList> = runCatching {
        Api.JSON.parseToJsonElement(metaFile.readText()).jsonArray.map { e ->
            val o = e.jsonObject
            KeptList((o["key"] as JsonPrimitive).content, (o["name"] as JsonPrimitive).content,
                (o["tracks"] as JsonArray).map { Track.from(it.jsonObject) })
        }
    }.getOrDefault(emptyList())

    private fun trackJson(t: Track): JsonObject = buildJsonObject {
        put("id", t.id); put("title", t.title); t.displayTitle?.let { put("display_title", it) }
        put("artists", buildJsonArray { t.artists.forEach { add(JsonPrimitive(it)) } })
        t.album?.let { put("album", it) }; t.durationMs?.let { put("duration_ms", it) }
        put("state", t.state); t.coverUrl?.let { put("cover_url", it) }; t.coverColor?.let { put("cover_color", it) }
        t.coverVersion?.let { put("cover_version", it) }; t.streamUrl?.let { put("stream_url", it) }
        t.gainDb?.let { put("gain_db", it) }
    }

    suspend fun clearAll() = withContext(Dispatchers.Main) { forgetAll() }
}
