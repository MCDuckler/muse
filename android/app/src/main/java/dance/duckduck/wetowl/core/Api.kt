package dance.duckduck.wetowl.core

import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonArray
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.put
import okhttp3.FormBody
import okhttp3.HttpUrl
import okhttp3.HttpUrl.Companion.toHttpUrlOrNull
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody
import okhttp3.RequestBody.Companion.toRequestBody
import java.io.IOException
import java.net.SocketTimeoutException
import java.net.UnknownHostException
import java.util.concurrent.TimeUnit

class ApiError(val status: Int, override val message: String) : Exception(message) {
    /** No answer at all: no signal, the box down, a timeout. */
    val isOffline get() = status == 0
}

/**
 * Talks to one WetOwl house. [base] and [token] can change under it (sign in, a new
 * server address); everything reads them per request.
 */
class Api(
    @Volatile var base: String = DEFAULT_SERVER,
    @Volatile var token: String? = null,
    client: OkHttpClient? = null,
) {
    /** Called on a 401 for anything but signing in: the token is gone. */
    @Volatile var onUnauthorized: (() -> Unit)? = null

    val http: OkHttpClient = client ?: OkHttpClient.Builder()
        .connectTimeout(10, TimeUnit.SECONDS)
        .readTimeout(25, TimeUnit.SECONDS)
        .writeTimeout(60, TimeUnit.SECONDS)
        .addInterceptor { chain ->
            val r = chain.request()
            val t = token
            // Only to our own house: a cover from elsewhere never sees the token.
            if (t != null && r.header("Authorization") == null && r.url.host == base.toHttpUrlOrNull()?.host) {
                chain.proceed(r.newBuilder().header("Authorization", "Bearer $t").build())
            } else chain.proceed(r)
        }
        .build()

    fun url(path: String, query: Map<String, String?> = emptyMap()): HttpUrl {
        val b = (base + path).toHttpUrlOrNull()?.newBuilder()
            ?: throw ApiError(-1, "Bad server address")
        for ((k, v) in query) if (v != null) b.addQueryParameter(k, v)
        return b.build()
    }

    /** A path the house gave (a cover, a stream), made whole. */
    fun absolute(path: String?): String? = when {
        path == null -> null
        path.startsWith("http") -> path
        else -> base + path
    }

    fun coverUrl(t: Track, small: Boolean = true): String? = t.coverUrl?.let {
        url(it, mapOf("size" to if (small) "sm" else "lg", "v" to t.coverVersion)).toString()
    }

    fun coverUrl(p: Playlist): String? = p.coverUrl?.let { url(it, mapOf("v" to p.coverVersion)).toString() }

    fun streamUrl(t: Track): String? = t.streamUrl?.let { absolute(it) }

    // ------------------------------------------------------------------ plumbing
    suspend fun raw(
        method: String,
        path: String,
        query: Map<String, String?> = emptyMap(),
        json: JsonElement? = null,
        form: Map<String, String>? = null,
        bytes: ByteArray? = null,
    ): String = withContext(Dispatchers.IO) {
        val body: RequestBody? = when {
            json != null -> json.toString().toRequestBody(JSON_TYPE)
            form != null -> FormBody.Builder().apply { form.forEach { (k, v) -> add(k, v) } }.build()
            bytes != null -> bytes.toRequestBody("application/octet-stream".toMediaType())
            method in setOf("POST", "PUT", "PATCH") -> "{}".toRequestBody(JSON_TYPE)
            else -> null
        }
        val req = Request.Builder().url(url(path, query)).method(method, body).build()
        val res = try {
            http.newCall(req).execute()
        } catch (e: UnknownHostException) {
            throw ApiError(0, "Can't reach the house")
        } catch (e: SocketTimeoutException) {
            throw ApiError(0, "The house took too long to answer")
        } catch (e: IOException) {
            throw ApiError(0, e.message ?: "No connection")
        }
        res.use {
            val text = it.body.string()
            if (it.code == 401 && path != "/auth/login") {
                onUnauthorized?.invoke()
                throw ApiError(401, "Signed out. Sign in again.")
            }
            if (it.code >= 400) throw ApiError(it.code, detail(text, it.code))
            text
        }
    }

    suspend fun obj(method: String, path: String, query: Map<String, String?> = emptyMap(),
                    json: JsonElement? = null, form: Map<String, String>? = null,
                    bytes: ByteArray? = null): JsonObject =
        parse(raw(method, path, query, json, form, bytes)).jsonObject

    suspend fun element(path: String, query: Map<String, String?> = emptyMap()): JsonElement =
        parse(raw("GET", path, query))

    private fun parse(text: String): JsonElement = try {
        JSON.parseToJsonElement(text.ifBlank { "{}" })
    } catch (e: Exception) {
        throw ApiError(-1, "The house answered in a way this app does not understand")
    }

    // ------------------------------------------------------------------ account
    suspend fun login(user: String, password: String, device: String): Pair<String, String> {
        val o = obj("POST", "/auth/login",
            form = mapOf("user" to user, "password" to password, "device" to device, "platform" to "android"))
        val t = o.str("token") ?: throw ApiError(-1, "No token in the answer")
        token = t
        return t to (o.str("user") ?: user)
    }

    suspend fun me(): String? = obj("GET", "/me").str("user")

    // ------------------------------------------------------------------ queues
    suspend fun queues(): List<QueueState> = element("/queues").listOf().objects(QueueState::from)

    suspend fun queue(id: Int, around: Int? = null): QueueState =
        QueueState.from(obj("GET", "/queues/$id", mapOf("around" to around?.toString())))

    suspend fun createQueue(name: String, stationId: Int? = null): QueueState =
        QueueState.from(obj("POST", "/queues", json = buildJsonObject {
            put("name", name); stationId?.let { put("station_id", it) }
        }))

    /** The whole queue replaced. Without [rev] it is unconditional — "play this list". */
    suspend fun replaceQueue(id: Int, trackIds: List<Int>, cursor: Int, rev: Int? = null): QueueState =
        QueueState.from(obj("PUT", "/queues/$id", json = buildJsonObject {
            rev?.let { put("rev", it) }
            put("items", ids(trackIds))
            put("cursor_index", cursor)
        }))

    suspend fun addToQueue(id: Int, trackIds: List<Int>, next: Boolean): QueueState =
        QueueState.from(obj("POST", "/queues/$id/items", json = buildJsonObject {
            put("track_ids", ids(trackIds)); put("mode", if (next) "next" else "end")
        }))

    suspend fun moveInQueue(id: Int, from: Int, to: Int): QueueState =
        QueueState.from(obj("POST", "/queues/$id/move", json = buildJsonObject {
            put("from", from); put("to", to)
        }))

    suspend fun removeFromQueue(id: Int, pos: Int): QueueState =
        QueueState.from(obj("DELETE", "/queues/$id/items/$pos"))

    suspend fun clearQueue(id: Int, origin: String? = null): QueueState = QueueState.from(obj("POST", "/queues/$id/clear",
        json = buildJsonObject { origin?.let { put("origin", it) } }))

    suspend fun shuffleQueue(id: Int): QueueState = QueueState.from(obj("POST", "/queues/$id/shuffle"))

    suspend fun renameQueue(id: Int, name: String): QueueState =
        QueueState.from(obj("PATCH", "/queues/$id", json = buildJsonObject { put("name", name) }))

    suspend fun setRepeat(id: Int, mode: RepeatMode): QueueState =
        QueueState.from(obj("PATCH", "/queues/$id", json = buildJsonObject { put("repeat", mode.wire) }))

    suspend fun deleteQueue(id: Int) { raw("DELETE", "/queues/$id") }

    suspend fun setCursor(id: Int, index: Int, positionMs: Long) {
        raw("PATCH", "/queues/$id/cursor", json = buildJsonObject {
            put("cursor_index", index); put("position_ms", positionMs)
        })
    }

    suspend fun prioritise(id: Int) { raw("POST", "/queues/$id/prioritise") }

    suspend fun extendStation(stationId: Int, queueId: Int): QueueState? =
        obj("POST", "/stations/$stationId/extend", json = buildJsonObject {
            put("queue_id", queueId); put("count", 20)
        }).obj("queue")?.let(QueueState::from)

    suspend fun startStation(trackId: Int? = null, artist: String? = null): Playlist =
        Playlist.from(obj("POST", "/stations", json = buildJsonObject {
            put("kind", if (artist != null) "artist" else "track")
            trackId?.let { put("track_id", it) }
            artist?.let { put("artist", it) }
        }))

    // ------------------------------------------------------------------ songs
    suspend fun track(id: Int): Track = Track.from(obj("GET", "/tracks/$id"))

    suspend fun resolve(h: RemoteHit): Track = Track.from(obj("POST", "/tracks/resolve", json = buildJsonObject {
        put("video_id", h.videoId); put("title", h.title); put("artists", strs(h.artists))
        h.album?.let { put("album", it) }; h.durationMs?.let { put("duration_ms", it) }
    }))

    /** A song known only by name (an album row, a top song) into the house. */
    suspend fun resolveByName(title: String, artists: List<String>, album: String?, durationMs: Long?): Track =
        Track.from(obj("POST", "/tracks/resolve", json = buildJsonObject {
            put("query", (listOf(title) + artists.take(1)).joinToString(" "))
            put("title", title); put("artists", strs(artists))
            album?.let { put("album", it) }; durationMs?.let { put("duration_ms", it) }
        }))

    suspend fun search(q: String, remote: Boolean = true): SearchResults =
        SearchResults.from(obj("GET", "/search", mapOf("q" to q, "limit" to "20",
            "remote" to if (remote) null else "false")))

    suspend fun history(): List<Track> = element("/history", mapOf("limit" to "30")).listOf().objects(Track::from)

    suspend fun home(): List<PickSection> = obj("GET", "/recommend/home").arr("sections").objects { s ->
        PickSection(s.str("id") ?: s.str("name") ?: "", s.str("name") ?: "", s.arr("items").objects { p ->
            Pick(p.str("why") ?: "", p.obj("track")?.let(Track::from), p.obj("hit")?.let(RemoteHit::from))
        })
    }

    suspend fun favourites(): Set<Int> = obj("GET", "/favourites").arr("track_ids")
        ?.mapNotNull { (it as? JsonPrimitive)?.content?.toIntOrNull() }?.toSet() ?: emptySet()

    suspend fun setFavourite(trackId: Int, on: Boolean): Boolean =
        obj("POST", "/favourites/$trackId", json = buildJsonObject { put("favourite", on) }).bool("favourite") ?: on

    suspend fun listen(trackId: Int, ms: Long, completed: Boolean) {
        raw("POST", "/listens", json = buildJsonObject {
            put("track_id", trackId); put("ms_played", ms); put("completed", completed)
        })
    }

    suspend fun dislike(trackId: Int) {
        raw("POST", "/recommend/dislike", json = buildJsonObject { put("track_id", trackId) })
    }

    suspend fun editTrack(id: Int, title: String, artists: List<String>, album: String?): Track =
        Track.from(obj("PATCH", "/tracks/$id", json = buildJsonObject {
            put("title", title); put("artists", strs(artists))
            if (album == null) put("album", JsonNull) else put("album", album)
        }))

    suspend fun copyCover(id: Int, from: Int): Track =
        Track.from(obj("PATCH", "/tracks/$id", json = buildJsonObject { put("cover_from", from) }))

    suspend fun setCover(id: Int, bytes: ByteArray): Track = Track.from(obj("PUT", "/tracks/$id/cover", bytes = bytes))

    // ------------------------------------------------------------------ library
    suspend fun playlists(): List<Playlist> = element("/playlists").listOf().objects(Playlist::from)

    suspend fun playlist(id: Int): Playlist = Playlist.from(obj("GET", "/playlists/$id"))

    suspend fun createPlaylist(name: String): Int =
        obj("POST", "/playlists", json = buildJsonObject { put("name", name) }).int("id") ?: 0

    suspend fun addToPlaylist(id: Int, trackIds: List<Int>) {
        raw("POST", "/playlists/$id/items", json = buildJsonObject { put("track_ids", ids(trackIds)) })
    }

    suspend fun saveQueueAsPlaylist(queueId: Int, name: String) {
        raw("POST", "/queues/$queueId/save-as-playlist", json = buildJsonObject { put("name", name) })
    }

    suspend fun artists(offset: Int): Page<ArtistSummary> = page("/library/artists",
        mapOf("offset" to "$offset", "limit" to "200", "sort" to "name"), ArtistSummary::from)

    suspend fun albums(offset: Int): Page<AlbumSummary> = page("/library/albums",
        mapOf("offset" to "$offset", "limit" to "200"), AlbumSummary::from)

    suspend fun songs(offset: Int, sort: String = "added"): Page<Track> = page("/library/tracks",
        mapOf("offset" to "$offset", "limit" to "200", "sort" to sort), Track::from)

    suspend fun artist(name: String, act: String? = null): ArtistDetail =
        ArtistDetail.from(obj("GET", "/library/artists/detail", mapOf("artist" to name, "act" to act)))

    suspend fun album(name: String?, artist: String?, remoteId: String? = null): AlbumDetail =
        AlbumDetail.from(obj("GET", "/library/albums/detail",
            mapOf("album" to name, "artist" to artist, "remote_id" to remoteId)))

    suspend fun follow(remoteId: String, name: String, provider: String = "deezer") {
        raw("POST", "/follows", json = buildJsonObject {
            put("remote_id", remoteId); put("name", name); put("provider", provider)
        })
    }

    suspend fun unfollow(remoteId: String, provider: String = "deezer") {
        raw("DELETE", "/follows/" + android.net.Uri.encode(remoteId), query = mapOf("provider" to provider))
    }

    private suspend fun <T> page(path: String, q: Map<String, String?>, read: (JsonObject) -> T): Page<T> {
        val o = obj("GET", path, q)
        val items = o.arr("items").objects(read)
        return Page(items, o.int("total") ?: items.size)
    }

    companion object {
        const val DEFAULT_SERVER = "https://89-58-49-140.nip.io"
        val JSON = Json { ignoreUnknownKeys = true; isLenient = true }
        private val JSON_TYPE = "application/json".toMediaType()

        fun normalise(s: String): String {
            var v = s.trim()
            if (v.isEmpty()) return DEFAULT_SERVER
            if (!v.startsWith("http://") && !v.startsWith("https://")) v = "https://$v"
            return v.trimEnd('/')
        }

        private fun ids(list: List<Int>): JsonArray = buildJsonArray { list.forEach { add(JsonPrimitive(it)) } }
        private fun strs(list: List<String>): JsonArray = buildJsonArray { list.forEach { add(JsonPrimitive(it)) } }

        fun detail(text: String, status: Int): String {
            runCatching {
                val o = JSON.parseToJsonElement(text).jsonObject
                when (val d = o["detail"]) {
                    is JsonPrimitive -> return d.content
                    is JsonArray -> d.mapNotNull { (it as? JsonObject)?.str("msg") }
                        .takeIf { it.isNotEmpty() }?.let { return it.joinToString(". ") }
                    is JsonObject -> d.str("reason")?.let { return it }
                    else -> {}
                }
            }
            if (text.trimStart().startsWith("<")) return "The house answered with a web page ($status)"
            return "Request failed ($status)"
        }
    }
}
