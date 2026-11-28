package dance.duckduck.wetowl.core

import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.buildJsonArray
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put

// Discover: lists made for you, news from who you follow, stations, genres, acts to try.

data class MadeList(val slug: String, val name: String, val blurb: String, val count: Int, val minutes: Int?,
                    val kind: String, val tracks: List<Track>) {
    companion object {
        fun from(o: JsonObject) = MadeList(o.str("slug") ?: "", o.str("name") ?: "", o.str("blurb") ?: "",
            o.int("count") ?: 0, o.int("minutes"), o.str("kind") ?: "", o.arr("tracks").objects(Track::from))
    }
}

data class FeedItem(val source: String, val provider: String, val albumId: String?, val title: String,
                    val artist: String, val cover: String?, val releaseDate: String?, val recordType: String?,
                    val unseen: Boolean, val inLibrary: Boolean, val genre: String?, val releaseMbid: String?,
                    val via: String?, val upcoming: Boolean) {
    companion object {
        fun from(o: JsonObject) = FeedItem(o.str("source") ?: "artist", o.str("provider") ?: "deezer", o.str("album_id"),
            o.str("title") ?: "", o.str("artist") ?: "", o.str("cover"), o.str("release_date"), o.str("record_type"),
            o.bool("unseen") ?: false, o.bool("in_library") ?: false, o.str("genre"), o.str("release_mbid"),
            o.str("via"), o.bool("upcoming") ?: false)
    }
}

data class StationRow(val id: Int, val playlistId: Int, val name: String, val kind: String, val count: Int, val coverTrack: Int?)
data class Starter(val name: String, val coverTrack: Int?)
data class Genre(val genre: String, val following: Boolean)
data class ActToTry(val name: String, val because: List<String>)

data class DiscoverPage(
    val lists: List<MadeList>,
    val building: Boolean,
    val yourStations: List<StationRow>,
    val starterArtists: List<Starter>,
    val starterTracks: List<Track>,
    val genres: List<Genre>,
    val feed: List<FeedItem>,
    val suggestedGenres: List<String>,
    val acts: List<ActToTry>,
)

data class Follow(val provider: String, val remoteId: String, val name: String, val image: String?, val isLabel: Boolean)

suspend fun Api.discover(): DiscoverPage {
    val tz = java.util.TimeZone.getDefault().getOffset(System.currentTimeMillis()) / 60_000
    val o = obj("GET", "/discover", mapOf("tz" to "$tz"))
    val st = o.obj("stations")
    val feed = o.obj("feed")
    val g = o.obj("genres")
    return DiscoverPage(
        lists = o.arr("lists").objects(MadeList::from),
        building = o.bool("building") ?: false,
        yourStations = st?.arr("yours").objects {
            StationRow(it.int("id")!!, it.int("playlist_id")!!, it.str("name") ?: "", it.str("kind") ?: "",
                it.int("count") ?: 0, it.int("cover_track"))
        },
        starterArtists = st?.arr("artists").objects { Starter(it.str("name") ?: return@objects null, it.int("cover_track")) },
        starterTracks = st?.arr("tracks").objects(Track::from),
        genres = st?.arr("genres").objects { Genre(it.str("genre") ?: return@objects null, it.bool("following") ?: false) },
        feed = (feed?.arr("items") ?: o.arr("feed")).objects(FeedItem::from),
        suggestedGenres = g?.arr("suggested").objects { it.str("genre") },
        acts = o.arr("artists").objects { ActToTry(it.str("name") ?: return@objects null, listOfNotNull(it.str("because"))) },
    )
}

suspend fun Api.madeList(slug: String): MadeList = MadeList.from(obj("GET", "/discover/lists/" + android.net.Uri.encode(slug)))
suspend fun Api.keepMadeList(slug: String): Int? = obj("POST", "/discover/lists/" + android.net.Uri.encode(slug) + "/keep").int("playlist_id")
suspend fun Api.rebuildMadeLists() { raw("POST", "/discover/lists/rebuild") }

suspend fun Api.genres(q: String?): Triple<List<String>, List<String>, List<String>> {
    val o = obj("GET", "/discover/genres", mapOf("q" to q))
    fun names(k: String) = o.arr(k)?.mapNotNull {
        (it as? JsonObject)?.str("genre") ?: (it as? kotlinx.serialization.json.JsonPrimitive)?.content
    } ?: emptyList()
    return Triple(names("following"), names("suggested"), names("found"))
}
suspend fun Api.followGenre(g: String) { raw("PUT", "/discover/genres/" + android.net.Uri.encode(g)) }
suspend fun Api.unfollowGenre(g: String) { raw("DELETE", "/discover/genres/" + android.net.Uri.encode(g)) }

suspend fun Api.feedSeen(items: List<FeedItem>) {
    if (items.isEmpty()) return
    raw("POST", "/discover/feed/seen", json = buildJsonObject {
        put("items", buildJsonArray {
            items.forEach { i -> add(buildJsonObject {
                i.albumId?.let { put("album_id", it) }; put("provider", i.provider)
                i.releaseMbid?.let { put("release_mbid", it) }
            }) }
        })
    })
}
suspend fun Api.feedRefresh() { raw("POST", "/feed/refresh") }

suspend fun Api.follows(): List<Follow> = obj("GET", "/follows").arr("items").objects {
    Follow(it.str("provider") ?: "deezer", it.str("remote_id") ?: return@objects null, it.str("name") ?: "",
        it.str("image"), it.bool("is_label") ?: false)
}
suspend fun Api.followSources(): List<Pair<String, String>> = obj("GET", "/follows/sources").arr("items").objects {
    (it.str("provider") ?: return@objects null) to listOfNotNull(it.str("label"), it.str("handle")).joinToString(" · ")
}
/** Followed elsewhere, followed here: how many were taken, and who could not be found. */
suspend fun Api.importFollows(provider: String): Pair<Int, List<String>> {
    val o = obj("POST", "/follows/import", json = buildJsonObject { put("provider", provider) })
    return (o.int("followed") ?: 0) to o.strings("not_found")
}

suspend fun Api.startStationOf(kind: String, genre: String? = null, artist: String? = null, album: String? = null): Playlist =
    Playlist.from(obj("POST", "/stations", json = buildJsonObject {
        put("kind", kind); genre?.let { put("genre", it) }; artist?.let { put("artist", it) }; album?.let { put("album", it) }
    }))

/** A song's cover by its id alone, as the house serves it. */
fun Api.trackCover(id: Int?, small: Boolean = true): String? =
    id?.let { url("/tracks/$it/cover", mapOf("size" to if (small) "sm" else "lg")).toString() }

// ------------------------------------------------------------------ Bandcamp
data class BandPage(val url: String, val name: String, val isLabel: Boolean, val image: String?, val about: String?,
                    val roster: List<Pair<String, String>>, val records: List<Release>, val following: Boolean)

suspend fun Api.bandcampBand(url: String): BandPage {
    val o = obj("GET", "/sources/bandcamp/band", mapOf("url" to url))
    return BandPage(o.str("url") ?: url, o.str("name") ?: "", o.bool("is_label") ?: false, o.str("image"), o.str("about"),
        o.arr("roster").objects { (it.str("name") ?: return@objects null) to (it.str("url") ?: "") },
        o.arr("records").objects(Release::from), o.bool("following") ?: false)
}

data class SourceHit(val provider: String, val providerId: String, val title: String, val artists: List<String>,
                     val album: String?, val durationMs: Long?, val url: String?, val streamable: Boolean, val track: Track?)

data class RecordPreview(val album: String?, val artist: String?, val tracks: List<SourceHit>, val unavailable: Int)

suspend fun Api.previewRecord(url: String): RecordPreview {
    val o = obj("GET", "/sources/preview", mapOf("url" to url))
    return RecordPreview(o.str("album"), o.str("artist"), o.arr("tracks").objects {
        SourceHit(it.str("provider") ?: "bandcamp", it.str("provider_id") ?: "", it.str("title") ?: "", it.strings("artists"),
            it.str("album"), it.int("duration_ms")?.toLong(), it.str("url"), it.bool("streamable") ?: true,
            it.obj("track")?.let(Track::from))
    }, o.int("unavailable") ?: 0)
}

/** A whole record in, in order, as a playlist of its own. */
suspend fun Api.importRecord(url: String): Int? = obj("POST", "/sources/import", json = buildJsonObject { put("url", url) }).int("playlist_id")

suspend fun Api.resolveSource(h: SourceHit): Track = Track.from(obj("POST", "/sources/resolve", json = buildJsonObject {
    put("provider", h.provider); put("provider_id", h.providerId); put("title", h.title)
    put("artists", buildJsonArray { h.artists.forEach { add(kotlinx.serialization.json.JsonPrimitive(it)) } })
    h.album?.let { put("album", it) }; h.durationMs?.let { put("duration_ms", it) }; h.url?.let { put("url", it) }
}))

// ------------------------------------------------------------------ cards: one song at a time
data class Card(val track: Track, val list: String, val listName: String, val why: String, val service: String?)
data class CardComment(val name: String, val text: String, val avatar: String?)
data class CardDetails(val genres: List<String>, val comments: List<CardComment>, val about: String?, val source: String?, val url: String?)

suspend fun Api.cards(offset: Int, service: String?): Pair<List<Card>, Int> {
    val o = obj("GET", "/discover/cards", mapOf("offset" to "$offset", "limit" to "20", "service" to service))
    return o.arr("items").objects {
        Card(Track.from(it.obj("track")!!), it.str("list") ?: "", it.str("list_name") ?: "", it.str("why") ?: "", it.str("service"))
    } to (o.int("total") ?: 0)
}
suspend fun Api.cardDetails(trackId: Int): CardDetails {
    val o = obj("GET", "/discover/cards/$trackId")
    return CardDetails(o.strings("genres"), o.arr("comments").objects {
        CardComment(it.str("name") ?: "", it.str("text") ?: "", it.str("avatar"))
    }, o.str("about"), o.str("source"), o.str("url"))
}
