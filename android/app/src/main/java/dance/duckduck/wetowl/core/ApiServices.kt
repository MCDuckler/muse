package dance.duckduck.wetowl.core

import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonArray
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put

// Services linked to this account: whose playlists come in, who is followed, where plays go.

data class Service(val provider: String, val label: String, val hint: String, val plays: Boolean, val signIn: String,
                   val linkedAs: String?)

data class RemoteList(val remoteId: String, val name: String, val count: Int?, val owner: String?, val image: String?,
                      val mirrorId: Int?, val unmatched: Int)

data class SpotifyState(val configured: Boolean, val reason: String?, val account: String?)

data class Scrobbling(val connected: Boolean, val name: String?, val sent: Int, val owed: Int, val error: String?)

data class DeviceCode(val deviceCode: String, val userCode: String, val url: String, val interval: Int)

data class Unmatched(val pos: Int, val title: String, val artists: List<String>, val reason: String?)

suspend fun Api.services(): List<Service> = obj("GET", "/linked").arr("accounts").objects {
    val l = it.obj("linked")
    Service(it.str("provider") ?: return@objects null, it.str("label") ?: "", it.str("hint") ?: "", it.bool("plays") ?: true,
        it.str("sign_in") ?: "name", l?.let { a -> a.str("display_name") ?: a.str("handle") ?: "linked" })
}
suspend fun Api.linkService(provider: String, handle: String) {
    raw("POST", "/linked/$provider", json = buildJsonObject { put("handle", handle) })
}
suspend fun Api.unlinkService(provider: String) { raw("DELETE", "/linked/$provider") }

private fun remoteList(o: JsonObject): RemoteList? {
    val m = o.obj("mirror")
    return RemoteList(o.str("remote_id") ?: return null, o.str("name") ?: "", o.int("count") ?: o.int("tracks"),
        o.str("owner"), o.str("image"), m?.int("playlist_id"), m?.int("unmatched") ?: 0)
}
suspend fun Api.servicePlaylists(provider: String): List<RemoteList> =
    obj("GET", "/linked/$provider/playlists").arr("items").objects(::remoteList)
suspend fun Api.syncService(provider: String, remoteIds: List<String>) {
    raw("POST", "/linked/$provider/sync", json = buildJsonObject {
        put("remote_ids", buildJsonArray { remoteIds.forEach { add(JsonPrimitive(it)) } })
    })
}

suspend fun Api.youtubeStart(): DeviceCode {
    val o = obj("POST", "/linked/youtube/oauth")
    return DeviceCode(o.str("device_code") ?: "", o.str("user_code") ?: "", o.str("url") ?: "https://google.com/device",
        o.int("interval") ?: 5)
}
/** True once signed in; false while Google is still waiting for the person (409). */
suspend fun Api.youtubeFinish(deviceCode: String): Boolean = try {
    raw("POST", "/linked/youtube/oauth/finish", json = buildJsonObject { put("device_code", deviceCode) }); true
} catch (e: ApiError) { if (e.status == 409) false else throw e }

suspend fun Api.spotify(): SpotifyState {
    val o = obj("GET", "/spotify/account")
    return SpotifyState(o.bool("configured") ?: false, o.str("reason"), o.obj("account")?.str("display_name"))
}
suspend fun Api.spotifyAuthorizeUrl(): String = obj("GET", "/spotify/authorize").str("url") ?: ""
suspend fun Api.spotifyUnlink() { raw("DELETE", "/spotify/account") }
suspend fun Api.spotifyPlaylists(): List<RemoteList> = obj("GET", "/spotify/playlists").arr("items").objects(::remoteList)
suspend fun Api.spotifySync(remoteIds: List<String>) {
    raw("POST", "/spotify/sync", json = buildJsonObject {
        put("remote_ids", buildJsonArray { remoteIds.forEach { add(JsonPrimitive(it)) } })
    })
}
suspend fun Api.unmatched(playlistId: Int): List<Unmatched> = obj("GET", "/spotify/playlists/$playlistId/unmatched").arr("items").objects {
    Unmatched(it.int("pos") ?: return@objects null, it.str("title") ?: "", it.strings("artists"), it.str("reason"))
}
suspend fun Api.unmatchedSuggestions(playlistId: Int, pos: Int): List<RemoteHit> =
    obj("GET", "/spotify/playlists/$playlistId/suggestions", mapOf("pos" to "$pos")).arr("items").objects(RemoteHit::from)
suspend fun Api.resolveUnmatched(playlistId: Int, pos: Int, videoId: String) {
    raw("POST", "/spotify/playlists/$playlistId/unmatched/$pos/resolve", json = buildJsonObject { put("video_id", videoId) })
}
suspend fun Api.clonePlaylist(id: Int, name: String? = null): Int? =
    obj("POST", "/spotify/playlists/$id/clone", json = buildJsonObject { name?.let { put("name", it) } }).int("id")

suspend fun Api.scrobbling(): Scrobbling {
    val o = obj("GET", "/scrobbling").obj("listenbrainz")
    return Scrobbling(o?.bool("connected") ?: false, o?.str("name"), o?.int("sent") ?: 0, o?.int("owed") ?: 0, o?.str("error"))
}
suspend fun Api.connectListenBrainz(token: String) { raw("PUT", "/scrobbling/listenbrainz", json = buildJsonObject { put("token", token) }) }
suspend fun Api.disconnectListenBrainz() { raw("DELETE", "/scrobbling/listenbrainz") }

/** A mirrored list read again from where it came from. */
suspend fun Api.pullPlaylist(id: Int) { raw("POST", "/sync/playlists/$id/pull") }
