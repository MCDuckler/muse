package dance.duckduck.wetowl.core

import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.launch
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put

/** One of this account's devices, and what it last said it was doing. */
data class Device(
    val id: Int,
    val name: String,
    val platform: String?,
    val kind: String?,
    val isThis: Boolean,
    val live: Boolean,
    val playing: Boolean,
    val positionMs: Long,
    val ageMs: Long,
    val queue: String?,
    val queueId: Int?,
    val itemId: Int?,
    val track: Track?,
    val lastSeen: String?,
) {
    /** Where it is now, carried forward from when it said so. */
    fun positionNow(): Long = positionMs + if (playing) ageMs else 0

    companion object {
        fun from(o: JsonObject) = Device(
            o.int("id")!!, o.str("name") ?: "A device", o.str("platform"), o.str("kind"), o.bool("this") ?: false,
            o.bool("live") ?: false, o.bool("playing") ?: false, (o.int("position_ms") ?: 0).toLong(),
            (o.int("age_ms") ?: 0).toLong(), o.str("queue"), o.int("queue_id"), o.int("item_id"),
            o.obj("track")?.let { runCatching { Track.from(it) }.getOrNull() }, o.str("last_seen"),
        )
    }
}

suspend fun Api.devices(): Pair<Int?, List<Device>> {
    val o = obj("GET", "/devices")
    return o.int("this") to o.arr("devices").objects(Device::from)
}

suspend fun Api.reportState(playing: Boolean, positionMs: Long, trackId: Int?, queueId: Int?, itemId: Int?) {
    raw("POST", "/devices/state", json = buildJsonObject {
        put("playing", playing); put("position_ms", positionMs); put("kind", "phone")
        trackId?.let { put("track_id", it) }; queueId?.let { put("queue_id", it) }; itemId?.let { put("item_id", it) }
    })
}

suspend fun Api.commandDevice(id: Int, action: String, queueId: Int? = null, trackId: Int? = null, positionMs: Long = 0) {
    raw("POST", "/devices/$id/command", json = buildJsonObject {
        put("action", action); queueId?.let { put("queue_id", it) }; trackId?.let { put("track_id", it) }
        put("position_ms", positionMs)
    })
}

suspend fun Api.renameDevice(id: Int, name: String) { raw("PATCH", "/devices/$id", json = buildJsonObject { put("name", name) }) }
suspend fun Api.forgetDevice(id: Int) { raw("DELETE", "/devices/$id") }
