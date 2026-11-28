package dance.duckduck.wetowl.core

import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put

// People on the house, and listening together.

data class JamMember(val userId: Int, val name: String, val host: Boolean, val online: Boolean)

data class JamPlayback(val trackId: Int?, val itemId: Int?, val positionMs: Long, val playing: Boolean, val ageMs: Long, val seq: Long?) {
    companion object {
        fun from(o: JsonObject): JamPlayback? {
            if (o["playing"] == null && o["track_id"] == null) return null
            return JamPlayback(o.int("track_id"), o.int("item_id"), (o.int("position_ms") ?: 0).toLong(),
                o.bool("playing") ?: false, (o.int("age_ms") ?: 0).toLong(), o.str("seq")?.toLongOrNull())
        }
    }
}

data class Jam(val id: Int, val code: String, val queueId: Int, val host: String?, val isHost: Boolean,
               val members: List<JamMember>, val listening: Int, val playback: JamPlayback?) {
    val title get() = if (isHost) "Your jam" else "${host ?: "Someone"}'s jam"
    companion object {
        fun from(o: JsonObject): Jam {
            val members = o.arr("members").objects {
                JamMember(it.int("user_id") ?: return@objects null, it.str("name") ?: "Someone",
                    it.bool("host") ?: false, it.bool("online") ?: false)
            }
            return Jam(o.int("id")!!, o.str("code") ?: "", o.int("queue_id") ?: 0, o.str("host"), o.bool("is_host") ?: false,
                members, o.int("listening") ?: members.count { it.online }, o.obj("playback")?.let(JamPlayback::from))
        }
    }
}

data class RunningJam(val id: Int, val code: String, val host: String, val queue: String?, val listening: Int,
                      val playing: String?, val by: String?, val joined: Boolean)

data class Person(val id: Int, val name: String, val avatar: String?, val songs: Int, val playlists: Int,
                  val online: Boolean, val playing: Track?, val playingNow: Boolean, val queue: String?, val jamCode: String?)

data class PersonPage(val id: Int, val name: String, val avatar: String?, val songs: Int, val playlists: Int, val played: Int,
                      val jamCode: String?, val recent: List<Track>)

suspend fun Api.currentJam(): Jam? = obj("GET", "/jams/current").obj("jam")?.let(Jam::from)
suspend fun Api.startJam(queueId: Int): Jam = Jam.from(obj("POST", "/jams", json = buildJsonObject { put("queue_id", queueId) }))
suspend fun Api.joinJam(code: String): Jam = Jam.from(obj("POST", "/jams/join", json = buildJsonObject { put("code", code) }))
suspend fun Api.runningJams(): List<RunningJam> = obj("GET", "/jams").arr("items").objects {
    RunningJam(it.int("id")!!, it.str("code") ?: "", it.str("host") ?: "Someone", it.str("queue"), it.int("listening") ?: 0,
        it.str("playing"), it.str("by"), it.bool("joined") ?: false)
}
suspend fun Api.jamPeople(): List<Pair<Int, String>> = obj("GET", "/jams/people").arr("items").objects {
    (it.int("id") ?: return@objects null) to (it.str("name") ?: "Someone")
}
suspend fun Api.inviteToJam(id: Int, userId: Int): Jam = Jam.from(obj("POST", "/jams/$id/invite", json = buildJsonObject { put("user_id", userId) }))
suspend fun Api.leaveJam(id: Int) { raw("POST", "/jams/$id/leave") }
suspend fun Api.removeFromJam(id: Int, userId: Int) { raw("POST", "/jams/$id/remove", json = buildJsonObject { put("user_id", userId) }) }
suspend fun Api.pushJamPlayback(id: Int, trackId: Int?, itemId: Int?, positionMs: Long, playing: Boolean, seq: Long) {
    raw("POST", "/jams/$id/playback", json = buildJsonObject {
        trackId?.let { put("track_id", it) }; itemId?.let { put("item_id", it) }
        put("position_ms", positionMs); put("playing", playing); put("seq", seq)
    })
}
suspend fun Api.moveJam(id: Int, queueId: Int): Jam = Jam.from(obj("POST", "/jams/$id/queue", json = buildJsonObject { put("queue_id", queueId) }))
suspend fun Api.jamControl(id: Int, action: String, positionMs: Long? = null, trackId: Int? = null) {
    raw("POST", "/jams/$id/control", json = buildJsonObject {
        put("action", action); positionMs?.let { put("position_ms", it) }; trackId?.let { put("track_id", it) }
    })
}

suspend fun Api.people(): List<Person> = obj("GET", "/social/people").arr("people").objects {
    val p = it.obj("playing")
    Person(it.int("id")!!, it.str("name") ?: "Someone", it.str("avatar_url"), it.int("songs") ?: 0, it.int("playlists") ?: 0,
        it.str("last_seen") != null, p?.obj("track")?.let(Track::from), p?.bool("now") ?: false, p?.str("queue"),
        it.obj("jam")?.str("code"))
}
suspend fun Api.person(id: Int): PersonPage {
    val o = obj("GET", "/social/people/$id")
    return PersonPage(o.int("id") ?: id, o.str("name") ?: "", o.str("avatar_url"), o.int("songs") ?: 0, o.int("playlists") ?: 0,
        o.int("played") ?: 0, o.obj("jam")?.str("code"), o.arr("recent").objects(Track::from))
}
suspend fun Api.theirPlaylists(id: Int): List<Playlist> = element("/social/people/$id/playlists").listOf().objects(Playlist::from)
suspend fun Api.theirLibrary(id: Int, offset: Int): Page<Track> {
    val o = obj("GET", "/social/people/$id/library", mapOf("offset" to "$offset", "limit" to "60"))
    val items = o.arr("items").objects(Track::from)
    return Page(items, o.int("total") ?: items.size)
}
suspend fun Api.react(personId: Int, emoji: String, trackId: Int?) {
    raw("POST", "/social/people/$personId/react", json = buildJsonObject { put("emoji", emoji); trackId?.let { put("track_id", it) } })
}

val REACTIONS = listOf("❤️", "🔥", "🕺", "😮", "😂", "🤘")
