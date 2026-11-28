package dance.duckduck.wetowl.core

import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.buildJsonArray
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put

// The house's own download queue: what it is fetching, what waits, what failed.

data class Job(val jobId: Int, val track: Track?, val trackId: Int?, val batchLabel: String?, val error: String?,
               val percent: Float?, val stage: String?) {
    companion object {
        fun from(o: JsonObject) = Job(o.int("job_id") ?: 0, o.obj("track")?.let { runCatching { Track.from(it) }.getOrNull() },
            o.int("track_id"), o.str("batch_label"), o.str("error"),
            o.obj("progress")?.dbl("percent")?.toFloat(), o.obj("progress")?.str("stage"))
    }
}

data class Batch(val id: String, val label: String, val total: Int, val done: Int, val failed: Int, val remaining: Int)

data class HouseDownloads(
    val paused: Boolean,
    val workerOnline: Boolean,
    val workerName: String?,
    val waiting: Int, val downloading: Int, val done: Int, val failed: Int,
    val active: List<Job>, val queue: List<Job>, val failures: List<Job>, val batches: List<Batch>,
)

suspend fun Api.houseDownloads(): HouseDownloads {
    val o = obj("GET", "/downloads")
    val c = o.obj("counts"); val w = o.obj("worker")
    return HouseDownloads(o.bool("paused") ?: false, w?.bool("online") ?: false, w?.str("name"),
        c?.int("waiting") ?: 0, c?.int("downloading") ?: 0, c?.int("done") ?: 0, c?.int("failed") ?: 0,
        o.arr("active").objects(Job::from), o.arr("waiting").objects(Job::from), o.arr("failed").objects(Job::from),
        o.arr("batches").objects { Batch(it.str("batch_id") ?: return@objects null, it.str("label") ?: "", it.int("total") ?: 0,
            it.int("done") ?: 0, it.int("failed") ?: 0, it.int("remaining") ?: 0) })
}

suspend fun Api.pauseDownloads(paused: Boolean) { raw("POST", "/downloads/pause", json = buildJsonObject { put("paused", paused) }) }
suspend fun Api.retryFailed(batchId: String? = null): Int =
    obj("POST", "/downloads/retry-failed", json = buildJsonObject { batchId?.let { put("batch_id", it) } }).int("retrying") ?: 0
suspend fun Api.cancelDownloads(batchId: String? = null, trackId: Int? = null, all: Boolean = false): Int =
    obj("POST", "/downloads/cancel", json = buildJsonObject {
        batchId?.let { put("batch_id", it) }; trackId?.let { put("track_id", it) }; if (all) put("all", true)
    }).int("cancelled") ?: 0
suspend fun Api.promote(trackIds: List<Int>) {
    raw("POST", "/downloads/promote", json = buildJsonObject {
        put("track_ids", buildJsonArray { trackIds.forEach { add(kotlinx.serialization.json.JsonPrimitive(it)) } })
    })
}
suspend fun Api.refind(trackIds: List<Int>? = null): Int =
    obj("POST", "/downloads/refind", json = buildJsonObject {
        trackIds?.let { l -> put("track_ids", buildJsonArray { l.forEach { add(kotlinx.serialization.json.JsonPrimitive(it)) } }) }
    }).int("found") ?: 0
