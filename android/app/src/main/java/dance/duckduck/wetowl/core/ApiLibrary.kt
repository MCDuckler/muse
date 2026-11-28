package dance.duckduck.wetowl.core

import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonArray
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.MultipartBody
import okhttp3.Request
import okhttp3.RequestBody.Companion.toRequestBody
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext

// The library, past playing it: folders and pins, smart lists, playlists looked after,
// what is liked and what is not, history, the listening charts.

private fun ids(list: List<Int>): JsonArray = buildJsonArray { list.forEach { add(JsonPrimitive(it)) } }

suspend fun Api.folders(): List<Folder> = obj("GET", "/playlist-folders").arr("items").objects(Folder::from)

suspend fun Api.createFolder(name: String): Folder =
    Folder.from(obj("POST", "/playlist-folders", json = buildJsonObject { put("name", name) }))

suspend fun Api.renameFolder(id: Int, name: String) {
    raw("PATCH", "/playlist-folders/$id", json = buildJsonObject { put("name", name) })
}

suspend fun Api.deleteFolder(id: Int) { raw("DELETE", "/playlist-folders/$id") }

suspend fun Api.folderTracks(id: Int): List<Track> = element("/playlist-folders/$id/tracks").listOf().objects(Track::from)

/** Into a folder (null: out of every folder). */
suspend fun Api.placePlaylist(id: Int, folderId: Int?) {
    raw("POST", "/playlists/$id/place", json = buildJsonObject {
        if (folderId == null) put("folder_id", JsonNull) else put("folder_id", folderId)
    })
}

suspend fun Api.pinPlaylist(id: Int, pinned: Boolean) {
    raw("POST", "/playlists/$id/pin", json = buildJsonObject { put("pinned", pinned) })
}

suspend fun Api.renamePlaylist(id: Int, name: String): Playlist =
    Playlist.from(obj("PATCH", "/playlists/$id", json = buildJsonObject { put("name", name) }))

suspend fun Api.sortPlaylist(id: Int, sort: String): Playlist =
    Playlist.from(obj("PATCH", "/playlists/$id", json = buildJsonObject { put("sort", sort) }))

suspend fun Api.deletePlaylist(id: Int) { raw("DELETE", "/playlists/$id") }

suspend fun Api.removeFromPlaylist(id: Int, trackIds: List<Int>): Playlist =
    Playlist.from(obj("POST", "/playlists/$id/items/remove", json = buildJsonObject { put("track_ids", ids(trackIds)) }))

suspend fun Api.movePlaylistItem(id: Int, from: Int, to: Int) {
    raw("POST", "/playlists/$id/move", json = buildJsonObject { put("from", from); put("to", to) })
}

suspend fun Api.setPlaylistCover(id: Int, bytes: ByteArray) { raw("POST", "/playlists/$id/cover", bytes = bytes) }
suspend fun Api.clearPlaylistCover(id: Int) { raw("DELETE", "/playlists/$id/cover") }

suspend fun Api.savePlaylist(id: Int) { raw("POST", "/playlists/$id/save") }
suspend fun Api.unsavePlaylist(id: Int) { raw("DELETE", "/playlists/$id/save") }

/** Get the audio of everything on the list the house does not have yet. */
suspend fun Api.fetchPlaylist(id: Int): Int = obj("POST", "/playlists/$id/download").int("queued") ?: 0

suspend fun Api.suggestedFor(id: Int): List<Track> = obj("GET", "/playlists/$id/suggested").arr("items").objects(Track::from)

suspend fun Api.smartLists(): List<SmartList> {
    val o = obj("GET", "/library/smart")
    fun read(k: String) = o.arr(k).objects {
        SmartList(it.str("id")!!, it.str("name") ?: "", it.str("blurb") ?: "", it.int("count") ?: 0)
    }
    return read("lists") + read("decades")
}

suspend fun Api.smartList(id: String): Pair<SmartList, List<Track>> {
    val o = obj("GET", "/library/smart/$id")
    val items = o.arr("items").objects(Track::from)
    return SmartList(id, o.str("name") ?: "", o.str("blurb") ?: "", items.size) to items
}

suspend fun Api.dislikes(): Set<Int> = obj("GET", "/recommend/dislikes").arr("track_ids")
    ?.mapNotNull { (it as? JsonPrimitive)?.content?.toIntOrNull() }?.toSet() ?: emptySet()

suspend fun Api.setDislike(trackId: Int, on: Boolean) {
    raw("POST", "/recommend/dislike", json = buildJsonObject { put("track_id", trackId); put("undo", !on) })
}

suspend fun Api.dismissPick(trackId: Int?, videoId: String?) {
    raw("POST", "/recommend/dismiss", json = buildJsonObject {
        trackId?.let { put("track_id", it) }; videoId?.let { put("video_id", it) }
    })
}

/** Out of the library for good: off this person's lists and queues too. */
suspend fun Api.removeFromLibrary(trackIds: List<Int>): Int =
    obj("POST", "/library/remove", json = buildJsonObject { put("track_ids", ids(trackIds)) }).int("removed") ?: trackIds.size

suspend fun Api.fillAlbum(album: String?, artist: String?, remoteId: String?): Int =
    obj("POST", "/library/albums/fill", json = buildJsonObject {
        album?.let { put("album", it) }; artist?.let { put("artist", it) }; remoteId?.let { put("remote_id", it) }
    }).int("queued") ?: 0

suspend fun Api.artistAbout(name: String, bandcamp: String?): String? =
    obj("GET", "/library/artists/about", mapOf("artist" to name, "bandcamp" to bandcamp)).str("text")

suspend fun Api.fullHistory(): List<Track> = obj("GET", "/library/history", mapOf("limit" to "200")).arr("items").objects(Track::from)
suspend fun Api.clearHistory() { raw("DELETE", "/library/history") }

suspend fun Api.stats(since: String): Stats {
    val o = obj("GET", "/library/stats", mapOf("since" to since))
    val t = o.obj("totals")
    fun chart(k: String, sub: (kotlinx.serialization.json.JsonObject) -> String?) = o.arr(k).objects {
        ChartRow(it.str("name") ?: it.str("title") ?: "", sub(it), it.int("plays") ?: 0, it.str("cover_url"),
            if (k == "songs") runCatching { Track.from(it) }.getOrNull() else null)
    }
    return Stats(since, t?.int("plays") ?: 0, t?.int("minutes") ?: 0, t?.int("tracks") ?: 0,
        chart("songs") { it.strings("artists").joinToString(", ") },
        chart("artists") { null },
        chart("albums") { it.str("artist") })
}

/** A file from the phone into the library: what the downloader cannot fetch. */
suspend fun Api.upload(bytes: ByteArray, filename: String): Track = withContext(Dispatchers.IO) {
    val body = MultipartBody.Builder().setType(MultipartBody.FORM)
        .addFormDataPart("audio", filename, bytes.toRequestBody("application/octet-stream".toMediaType()))
        .build()
    val res = http.newCall(Request.Builder().url(url("/uploads")).post(body).build()).execute()
    res.use {
        val text = it.body.string()
        if (it.code >= 400) throw ApiError(it.code, Api.detail(text, it.code))
        Track.from(Api.JSON.parseToJsonElement(text) as kotlinx.serialization.json.JsonObject)
    }
}

/** Synced (LRC) and plain words for a song; either may be missing. */
suspend fun Api.lyrics(id: Int): Pair<String?, String?> {
    val o = obj("GET", "/tracks/$id/lyrics")
    return o.str("synced")?.takeIf { it.isNotBlank() } to o.str("plain")?.takeIf { it.isNotBlank() }
}

suspend fun Api.searchEverything(q: String, where: String, kind: String, lyrics: Boolean = false): Pair<List<Found>, Map<String, String>> {
    val o = obj("GET", "/search/everything", mapOf("q" to q, "where" to where, "kind" to kind,
        "lyrics" to if (lyrics) "true" else null, "limit" to if (where == "all") "40" else "50"))
    val notes = o.obj("notes")?.let { n -> n.keys.associateWith { k -> n.str(k) ?: "" } } ?: emptyMap()
    return o.arr("items").objects(Found::from) to notes
}

suspend fun Api.foundAlbum(place: String, id: String): FoundAlbum {
    val o = obj("GET", "/search/album", mapOf("place" to place, "id" to id))
    return FoundAlbum(o.str("title") ?: "", o.str("artist"), o.str("year"), o.str("cover_url"), o.arr("tracks").objects(Found::from))
}

/** One row of a search taken into the house, wherever it was found. */
suspend fun Api.addFound(f: Found): Track = Track.from(obj("POST", "/search/add", json = buildJsonObject {
    put("place", f.place); put("id", f.id); put("title", f.title); put("subtitle", f.subtitle)
    f.album?.let { put("album", it) }; f.durationMs?.let { put("duration_ms", it) }; f.url?.let { put("url", it) }
}))

suspend fun Api.tuneStation(id: Int, fresh: Float): Playlist =
    Playlist.from(obj("PATCH", "/stations/$id", json = kotlinx.serialization.json.buildJsonObject { put("fresh", fresh) }))
suspend fun Api.refreshStation(id: Int): Playlist = Playlist.from(obj("POST", "/stations/$id/refresh"))

/** Where each letter starts in a list sorted by name. */
data class Letter(val letter: String, val offset: Int, val count: Int)

suspend fun Api.letters(path: String, query: Map<String, String?> = emptyMap()): List<Letter> =
    obj("GET", path, query).arr("letters").objects { Letter(it.str("letter") ?: "#", it.int("offset") ?: 0, it.int("count") ?: 0) }

/** Songs not in the library that belong beside these. */
suspend fun Api.similar(trackIds: List<Int>): List<RemoteHit> =
    obj("GET", "/search/similar", mapOf("tracks" to trackIds.joinToString(","), "limit" to "20")).arr("similar").objects(RemoteHit::from)
