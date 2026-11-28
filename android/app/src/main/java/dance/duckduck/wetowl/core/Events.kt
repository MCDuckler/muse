package dance.duckduck.wetowl.core

import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.flow.SharedFlow
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.jsonObject
import okhttp3.Request
import java.util.concurrent.TimeUnit

/** One thing the house said: its name and what came with it. */
data class Event(val name: String, val data: JsonObject)

/**
 * The house's event stream (/events, server-sent events), held open while signed in.
 * It dies whenever the phone sleeps or a proxy gives up; it comes back on its own,
 * waiting longer each time it fails in a row, and [connected] says when it is up.
 */
class Events(private val api: Api, private val scope: CoroutineScope) {
    private val _events = MutableSharedFlow<Event>(extraBufferCapacity = 64)
    val events: SharedFlow<Event> = _events

    /** Fired on every (re)connect: whatever was missed while it was down is read again. */
    val connected = MutableSharedFlow<Unit>(extraBufferCapacity = 1)

    /** Whether the house answered the last time it was tried. */
    val reachable = kotlinx.coroutines.flow.MutableStateFlow(true)

    private var job: Job? = null
    private val client by lazy {
        // Nothing is said between keepalives (20 s); a minute of silence is a dead line.
        api.http.newBuilder().readTimeout(60, TimeUnit.SECONDS).build()
    }

    fun start() {
        if (job?.isActive == true) return
        job = scope.launch(Dispatchers.IO) {
            var backoff = 1_000L
            while (isActive) {
                if (api.token == null) { delay(2_000); continue }
                try {
                    val req = Request.Builder().url(api.url("/events")).header("Accept", "text/event-stream").build()
                    client.newCall(req).execute().use { res ->
                        if (!res.isSuccessful) throw java.io.IOException("events ${res.code}")
                        val source = res.body.source()
                        var name = "message"
                        val data = StringBuilder()
                        while (isActive) {
                            val line = source.readUtf8Line() ?: break
                            when {
                                line.isEmpty() -> {
                                    if (name == "hello") { backoff = 1_000L; reachable.value = true; connected.tryEmit(Unit) }
                                    else if (data.isNotEmpty()) runCatching {
                                        _events.tryEmit(Event(name, Api.JSON.parseToJsonElement(data.toString()).jsonObject))
                                    }
                                    name = "message"; data.clear()
                                }
                                line.startsWith(":") -> {}
                                line.startsWith("event:") -> name = line.substring(6).trim()
                                line.startsWith("data:") -> {
                                    if (data.isNotEmpty()) data.append('\n')
                                    data.append(line.substring(5).trimStart())
                                }
                            }
                        }
                    }
                } catch (e: Exception) {
                    if (!isActive) break
                    if (e is java.io.IOException && e.message?.startsWith("events ") != true) reachable.value = false
                }
                delay(backoff)
                backoff = (backoff * 2).coerceAtMost(60_000L)
            }
        }
    }

    fun stop() { job?.cancel(); job = null }
}

/** How far along the house is with fetching a song. */
data class Fetching(val stage: String, val percent: Float?)
