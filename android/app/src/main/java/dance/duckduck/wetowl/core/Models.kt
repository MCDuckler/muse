package dance.duckduck.wetowl.core

import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.booleanOrNull
import kotlinx.serialization.json.doubleOrNull
import kotlinx.serialization.json.longOrNull

// Every model is read by hand from a JsonObject, and every field but an id is optional.
// The house adds fields and occasionally changes a shape (a playlist's `items` is a
// count in a list and the songs on its own page); one odd field must cost that field,
// never the whole screen.

internal fun JsonObject.str(k: String): String? =
    (this[k] as? JsonPrimitive)?.takeIf { it.isString }?.content
        ?: (this[k] as? JsonPrimitive)?.takeIf { it !is JsonNull && !it.isString }?.content

internal fun JsonObject.int(k: String): Int? = (this[k] as? JsonPrimitive)?.longOrNull?.toInt()
    ?: (this[k] as? JsonPrimitive)?.doubleOrNull?.toInt()

internal fun JsonObject.dbl(k: String): Double? = (this[k] as? JsonPrimitive)?.doubleOrNull
internal fun JsonObject.bool(k: String): Boolean? = (this[k] as? JsonPrimitive)?.booleanOrNull
internal fun JsonObject.obj(k: String): JsonObject? = this[k] as? JsonObject
internal fun JsonObject.arr(k: String): JsonArray? = this[k] as? JsonArray
internal fun JsonObject.strings(k: String): List<String> =
    arr(k)?.mapNotNull { (it as? JsonPrimitive)?.content } ?: emptyList()

/** The objects in an array, each turned into a T; one that will not read is skipped. */
internal inline fun <T> JsonArray?.objects(read: (JsonObject) -> T?): List<T> =
    this?.mapNotNull { e -> (e as? JsonObject)?.let { runCatching { read(it) }.getOrNull() } }
        ?: emptyList()

/** A list answered bare, or wrapped as {"items": [...]}. */
internal fun JsonElement.listOf(): JsonArray? = when (this) {
    is JsonArray -> this
    is JsonObject -> arr("items")
    else -> null
}

data class Track(
    val id: Int,
    val title: String,
    val displayTitle: String? = null,
    val artists: List<String> = emptyList(),
    val album: String? = null,
    val durationMs: Long? = null,
    val state: String = "pending",
    val coverUrl: String? = null,
    val coverColor: String? = null,
    val coverVersion: String? = null,
    val streamUrl: String? = null,
    val gainDb: Double? = null,
    val failReason: String? = null,
    val itemId: Int? = null,
    val origin: String? = null,
    val source: String? = null,
) {
    /** The title without the artist or "(Official Video)" glued onto it. */
    val name: String get() = displayTitle?.takeIf { it.isNotBlank() } ?: title
    val artistLine: String get() = if (artists.isEmpty()) "Unknown artist" else artists.joinToString(", ")
    val isReady: Boolean get() = streamUrl != null && state == "ready"
    val isFailed: Boolean get() = state == "failed"

    /** Which row of a queue this is: a song can sit in one twice. */
    val rowKey: String get() = itemId?.let { "i$it" } ?: "t$id"

    companion object {
        fun from(o: JsonObject) = Track(
            id = o.int("id")!!,
            title = o.str("title") ?: "Untitled",
            displayTitle = o.str("display_title"),
            artists = o.strings("artists"),
            album = o.str("album"),
            durationMs = o.int("duration_ms")?.toLong(),
            state = o.str("state") ?: "pending",
            coverUrl = o.str("cover_url"),
            coverColor = o.str("cover_color"),
            coverVersion = o.str("cover_version"),
            streamUrl = o.str("stream_url"),
            gainDb = o.dbl("gain_db"),
            failReason = o.str("fail_reason"),
            itemId = o.int("item_id"),
            origin = o.str("origin"),
            source = o.str("source"),
        )
    }
}

enum class RepeatMode(val wire: String) {
    OFF("off"), ALL("all"), ONE("one");

    val next: RepeatMode get() = when (this) { OFF -> ALL; ALL -> ONE; ONE -> OFF }

    companion object {
        fun of(s: String?) = entries.firstOrNull { it.wire == s } ?: OFF
    }
}

data class QueueState(
    val id: Int,
    val name: String,
    val cursorIndex: Int = 0,
    val positionMs: Long = 0,
    val rev: Int = 0,
    val repeat: RepeatMode = RepeatMode.OFF,
    val total: Int = 0,
    val windowFrom: Int = 0,
    val items: List<Track> = emptyList(),
    val stationId: Int? = null,
    val sharedFrom: String? = null,
) {
    val isWindowed: Boolean get() = total > items.size
    val isStation: Boolean get() = stationId != null

    /** The cursor as a row of [items]. */
    val cursorRow: Int get() = (cursorIndex - windowFrom).coerceIn(0, (items.size - 1).coerceAtLeast(0))

    companion object {
        fun from(o: JsonObject): QueueState {
            val list = o.arr("items")
            val items = list.objects(Track::from)
            val count = if (list == null) o.int("items") ?: 0 else items.size
            return QueueState(
                id = o.int("id")!!,
                name = o.str("name") ?: "Queue",
                cursorIndex = o.int("cursor_index") ?: 0,
                positionMs = (o.int("position_ms") ?: 0).toLong(),
                rev = o.int("rev") ?: 0,
                repeat = RepeatMode.of(o.str("repeat")),
                total = o.int("total") ?: count,
                windowFrom = o.int("window_from") ?: 0,
                items = items,
                stationId = o.obj("station")?.int("id"),
                sharedFrom = o.str("shared_from"),
            )
        }
    }
}

data class Playlist(
    val id: Int,
    val name: String,
    val kind: String = "local",
    val count: Int = 0,
    val tracks: List<Track>? = null,
    val coverUrl: String? = null,
    val coverVersion: String? = null,
    val pinned: Boolean = false,
    val saved: Boolean = false,
    val ownerName: String? = null,
    val stationId: Int? = null,
    val editable: Boolean? = null,
    val folderId: Int? = null,
    val sort: String? = null,
    val lastOpenedAt: String? = null,
    /** A station's mix: 0 all familiar, 1 all new. */
    val stationFresh: Float? = null,
    /** Songs on a mirrored list nothing was found for. */
    val unmatched: Int = 0,
) {
    val isFavourites get() = kind == "favourites"
    val shownName get() = if (isFavourites) "Favourites" else name
    val canEdit get() = editable ?: (!saved && kind in setOf("local", "favourites", "station"))

    companion object {
        fun from(o: JsonObject): Playlist {
            val list = o.arr("items")
            val tracks = list?.let { it.objects(Track::from) }
            return Playlist(
                id = o.int("id")!!,
                name = o.str("name") ?: "",
                kind = o.str("kind") ?: "local",
                count = tracks?.size ?: o.int("items") ?: 0,
                tracks = tracks,
                coverUrl = o.str("cover_url"),
                coverVersion = o.str("cover_version"),
                pinned = o.bool("pinned") ?: false,
                saved = o.bool("saved") ?: false,
                ownerName = o.str("owner_name"),
                stationId = o.obj("station")?.int("id"),
                editable = o.bool("editable"),
                folderId = o.int("folder_id"),
                sort = o.str("sort"),
                lastOpenedAt = o.str("last_opened_at"),
                stationFresh = o.obj("station")?.dbl("fresh")?.toFloat(),
                unmatched = (o["unmatched"] as? kotlinx.serialization.json.JsonArray)?.size ?: o.int("unmatched") ?: 0,
            )
        }
    }
}

data class RemoteHit(
    val videoId: String,
    val title: String,
    val artists: List<String>,
    val album: String? = null,
    val durationMs: Long? = null,
    val coverUrl: String? = null,
) {
    val artistLine get() = if (artists.isEmpty()) "Unknown artist" else artists.joinToString(", ")

    companion object {
        fun from(o: JsonObject) = RemoteHit(
            videoId = o.str("video_id")!!,
            title = o.str("title") ?: o.str("video_id")!!,
            artists = o.strings("artists"),
            album = o.str("album"),
            durationMs = o.int("duration_ms")?.toLong(),
            coverUrl = o.str("cover_url"),
        )
    }
}

data class ArtistHit(val name: String, val tracks: Int)

data class SearchResults(
    val local: List<Track>,
    val remote: List<RemoteHit>,
    val artists: List<ArtistHit>,
    val remoteError: String?,
) {
    companion object {
        fun from(o: JsonObject) = SearchResults(
            local = o.arr("local").objects(Track::from),
            remote = o.arr("remote").objects(RemoteHit::from),
            artists = o.arr("artists").objects { ArtistHit(it.str("name")!!, it.int("tracks") ?: 0) },
            remoteError = o.str("remote_error"),
        )
    }
}

/** One thing the house suggests: a song here, or one out there. */
data class Pick(val why: String, val track: Track?, val hit: RemoteHit?) {
    val key get() = track?.let { "t${it.id}" } ?: "v${hit?.videoId}"
    val title get() = track?.name ?: hit?.title ?: ""
    val artistLine get() = track?.artistLine ?: hit?.artistLine ?: ""
}

data class PickSection(val id: String, val name: String, val items: List<Pick>)

data class ArtistSummary(val name: String, val tracks: Int, val albums: Int, val coverUrl: String?) {
    companion object {
        fun from(o: JsonObject) = ArtistSummary(
            o.str("name")!!, o.int("tracks") ?: 0, o.int("albums") ?: 0, o.str("cover_url"))
    }
}

data class AlbumSummary(
    val name: String, val artist: String, val tracks: Int, val year: Int?, val coverUrl: String?,
) {
    companion object {
        fun from(o: JsonObject) = AlbumSummary(
            o.str("name")!!, o.str("artist") ?: "", o.int("tracks") ?: 0, o.int("year"), o.str("cover_url"))
    }
}

data class Release(
    val remoteId: String,
    val title: String,
    val cover: String?,
    val releaseDate: String?,
    val recordType: String?,
    val have: Int,
    /** 'bandcamp' for a record only the act's Bandcamp page lists, opened at [url]. */
    val source: String?,
    val url: String?,
) {
    val year get() = releaseDate?.take(4)
    val onBandcamp get() = source == "bandcamp" && url != null

    companion object {
        fun from(o: JsonObject) = Release(
            o.str("remote_id") ?: o.str("url")!!, o.str("title") ?: "", o.str("cover"),
            o.str("release_date"), o.str("record_type"), o.int("have") ?: 0,
            o.str("source"), o.str("url"))
    }
}

data class TopSong(val title: String, val artists: List<String>, val cover: String?, val track: Track?)

data class Namesake(val key: String, val label: String, val songs: Int)

data class ArtistDetail(
    val name: String,
    val image: String?,
    val fans: Int?,
    val remoteId: String?,
    val following: Boolean,
    val bandcampUrl: String?,
    val unavailable: String?,
    val albums: List<Release>,
    val top: List<TopSong>,
    val tracks: List<Track>,
    val namesakes: List<Namesake>,
) {
    companion object {
        fun from(o: JsonObject): ArtistDetail {
            val a = o.obj("artist") ?: JsonObject(emptyMap())
            return ArtistDetail(
                name = a.str("name") ?: "",
                image = a.str("image"),
                fans = a.int("fans"),
                remoteId = a.str("remote_id"),
                following = a.bool("following") ?: false,
                bandcampUrl = a.str("bandcamp_url"),
                unavailable = a.str("unavailable"),
                albums = o.arr("albums").objects(Release::from),
                top = o.arr("top").objects {
                    TopSong(it.str("title") ?: "", it.strings("artists"), it.str("cover"),
                        it.obj("track")?.let(Track::from))
                },
                tracks = o.arr("tracks").objects(Track::from),
                namesakes = o.arr("namesakes").objects {
                    Namesake(it.str("key")!!, it.str("label") ?: "", it.int("songs") ?: 0)
                },
            )
        }
    }
}

data class AlbumRow(val pos: Int, val title: String, val artists: List<String>, val durationMs: Long?, val track: Track?)

data class AlbumDetail(
    val name: String?,
    val artist: String?,
    val cover: String?,
    val year: String?,
    val recordType: String?,
    val rows: List<AlbumRow>,
    val extra: List<Track>,
) {
    val playable get() = rows.mapNotNull { it.track } + extra

    companion object {
        fun from(o: JsonObject): AlbumDetail {
            val a = o.obj("album") ?: JsonObject(emptyMap())
            return AlbumDetail(
                name = a.str("name") ?: a.str("release_name"),
                artist = a.str("artist"),
                cover = a.str("cover"),
                year = a.str("release_date")?.take(4),
                recordType = a.str("record_type"),
                rows = o.arr("tracks").objects {
                    AlbumRow(it.int("pos") ?: 0, it.str("title") ?: "", it.strings("artists"),
                        it.int("duration_ms")?.toLong(), it.obj("track")?.let(Track::from))
                },
                extra = o.arr("extra").objects(Track::from),
            )
        }
    }
}

data class Page<T>(val items: List<T>, val total: Int)

data class Folder(val id: Int, val name: String, val count: Int) {
    companion object {
        fun from(o: JsonObject) = Folder(o.int("id")!!, o.str("name") ?: "", o.int("count") ?: 0)
    }
}

/** A list the house keeps of your own library: never played, most played, the 90s… */
data class SmartList(val id: String, val name: String, val blurb: String, val count: Int)

data class ChartRow(val name: String, val sub: String?, val plays: Int, val cover: String?, val track: Track?)

data class Stats(
    val since: String,
    val plays: Int,
    val minutes: Int,
    val tracks: Int,
    val songs: List<ChartRow>,
    val artists: List<ChartRow>,
    val albums: List<ChartRow>,
)

/** One row of a search everywhere: a song, record, artist, playlist… from wherever. */
data class Found(
    val kind: String,
    val place: String,
    val id: String,
    val title: String,
    val subtitle: String,
    val coverUrl: String?,
    val durationMs: Long?,
    val track: Track?,
    val known: Boolean,
    val mine: Boolean,
    val lyric: String?,
    val tracks: Int?,
    val album: String?,
    val url: String?,
    val year: String?,
) {
    val plays get() = kind == "song" || kind == "video"

    companion object {
        fun from(o: JsonObject) = Found(
            kind = o.str("kind") ?: "song",
            place = o.str("place") ?: "library",
            id = o.str("id") ?: "",
            title = o.str("title") ?: "",
            subtitle = o.str("subtitle") ?: "",
            coverUrl = o.str("cover_url"),
            durationMs = o.int("duration_ms")?.toLong(),
            track = o.obj("track")?.let { runCatching { Track.from(it) }.getOrNull() },
            known = o.bool("known") ?: false,
            mine = o.bool("mine") ?: false,
            lyric = o.str("lyric"),
            tracks = o.int("tracks"),
            album = o.str("album"),
            url = o.str("url"),
            year = o.str("year"),
        )
    }
}

data class FoundAlbum(val title: String, val artist: String?, val year: String?, val coverUrl: String?, val tracks: List<Found>)
