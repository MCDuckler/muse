package dance.duckduck.wetowl.ui

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.rounded.Close
import androidx.compose.material.icons.rounded.Pause
import androidx.compose.material.icons.rounded.PlayArrow
import androidx.compose.material.icons.rounded.Refresh
import androidx.compose.material.icons.rounded.VerticalAlignTop
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import dance.duckduck.wetowl.core.ApiError
import dance.duckduck.wetowl.core.HouseDownloads
import dance.duckduck.wetowl.core.Job
import dance.duckduck.wetowl.core.cancelDownloads
import dance.duckduck.wetowl.core.houseDownloads
import dance.duckduck.wetowl.core.pauseDownloads
import dance.duckduck.wetowl.core.promote
import dance.duckduck.wetowl.core.refind
import dance.duckduck.wetowl.core.retryFailed
import dance.duckduck.wetowl.ui.theme.tonal
import kotlinx.coroutines.delay

/** What the house is fetching for everybody: running, waiting, failed — and the knobs. */
@Composable
fun HouseDownloadsScreen(bottom: PaddingValues) {
    val store = LocalStore.current
    var d by remember { mutableStateOf<HouseDownloads?>(null) }
    var error by remember { mutableStateOf<String?>(null) }
    var tick by remember { mutableIntStateOf(0) }
    val live by store.fetching.collectAsState()
    LaunchedEffect(tick) {
        try { d = store.api.houseDownloads(); error = null } catch (e: ApiError) { error = e.message }
        delay(5000); tick++
    }
    fun act(block: suspend () -> Unit) = store.launch { block(); tick++ }
    Column(Modifier.fillMaxSize()) {
        val h = d
        PageBar("Downloads", h?.let { "${it.downloading} fetching · ${it.waiting} waiting · ${it.failed} failed" }) {
            if (h != null) IconButton(onClick = { act { store.api.pauseDownloads(!h.paused) } }) {
                Icon(if (h.paused) Icons.Rounded.PlayArrow else Icons.Rounded.Pause, if (h.paused) "Carry on" else "Pause the house")
            }
        }
        if (h == null) { if (error != null) ErrorRetry(error!!, { tick++ }) else Loading(); return }
        LazyColumn(contentPadding = bottom) {
            item {
                Row(Modifier.fillMaxWidth().padding(horizontal = 18.dp, vertical = 6.dp).tonal(corner = 18.dp).padding(14.dp),
                    verticalAlignment = Alignment.CenterVertically) {
                    Box(Modifier.size(10.dp).clip(CircleShape).background(
                        if (h.workerOnline && !h.paused) MaterialTheme.colorScheme.primary else MaterialTheme.colorScheme.error))
                    Spacer(Modifier.width(12.dp))
                    Text(when {
                        h.paused -> "Paused — nothing new starts until you carry on"
                        h.workerOnline -> "Fetching on ${h.workerName ?: "the house"}"
                        else -> "The downloader is not answering"
                    }, style = MaterialTheme.typography.bodyMedium)
                }
            }
            if (h.batches.isNotEmpty()) {
                item { SectionLabel("Batches") }
                items(h.batches, key = { "b" + it.id }) { b ->
                    Column(Modifier.fillMaxWidth().padding(horizontal = 20.dp, vertical = 8.dp)) {
                        Row(verticalAlignment = Alignment.CenterVertically) {
                            Column(Modifier.weight(1f)) {
                                Text(b.label.ifBlank { b.id }, style = MaterialTheme.typography.titleSmall, maxLines = 1,
                                    overflow = TextOverflow.Ellipsis)
                                Text("${b.done} of ${b.total}" + (if (b.failed > 0) " · ${b.failed} failed" else ""),
                                    style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
                            }
                            if (b.failed > 0) TextButton(onClick = { act { store.api.retryFailed(b.id) } }) { Text("Retry") }
                            if (b.remaining > 0) IconButton(onClick = { act { store.api.cancelDownloads(batchId = b.id) } }) {
                                Icon(Icons.Rounded.Close, "Cancel the rest of ${b.label}")
                            }
                        }
                        LinearProgressIndicator(progress = { if (b.total > 0) b.done / b.total.toFloat() else 0f },
                            modifier = Modifier.fillMaxWidth().padding(top = 6.dp).height(4.dp), drawStopIndicator = {})
                    }
                }
            }
            if (h.active.isNotEmpty()) {
                item { SectionLabel("Fetching now") }
                items(h.active, key = { "a${it.jobId}" }) { j -> JobRow(j, live[j.trackId]?.percent ?: j.percent) }
            }
            if (h.queue.isNotEmpty()) {
                item { SectionLabel("Waiting · ${h.waiting}") }
                items(h.queue, key = { "w${it.jobId}" }) { j ->
                    JobRow(j, null) {
                        IconButton(onClick = { act { j.trackId?.let { store.api.promote(listOf(it)) } } }) {
                            Icon(Icons.Rounded.VerticalAlignTop, "Fetch this first")
                        }
                        IconButton(onClick = { act { store.api.cancelDownloads(trackId = j.trackId) } }) {
                            Icon(Icons.Rounded.Close, "Don't fetch")
                        }
                    }
                }
            }
            if (h.failures.isNotEmpty()) {
                item {
                    SectionLabel("Failed · ${h.failed}") {
                        TextButton(onClick = { act { store.api.refind(h.failures.mapNotNull { it.trackId }) } }) { Text("Look again") }
                        TextButton(onClick = { act { store.api.retryFailed() } }) { Text("Retry all") }
                    }
                }
                items(h.failures, key = { "f${it.jobId}" }) { j -> JobRow(j, null) }
            }
            if (h.active.isEmpty() && h.queue.isEmpty() && h.failures.isEmpty()) item { Empty("Nothing waiting. Everything asked for is here.") }
        }
    }
}

@Composable
private fun JobRow(j: Job, percent: Float?, actions: @Composable () -> Unit = {}) {
    val t = j.track
    Row(Modifier.fillMaxWidth().padding(horizontal = 18.dp, vertical = 6.dp), verticalAlignment = Alignment.CenterVertically) {
        if (t != null) TrackArt(t, 44.dp) else Spacer(Modifier.size(44.dp))
        Spacer(Modifier.width(12.dp))
        Column(Modifier.weight(1f)) {
            Text(t?.name ?: "Song ${j.trackId}", style = MaterialTheme.typography.titleSmall, maxLines = 1, overflow = TextOverflow.Ellipsis)
            Text(j.error ?: listOfNotNull(t?.artistLine, j.batchLabel).joinToString(" · "),
                style = MaterialTheme.typography.bodySmall, maxLines = 2, overflow = TextOverflow.Ellipsis,
                color = if (j.error != null) MaterialTheme.colorScheme.error else MaterialTheme.colorScheme.onSurfaceVariant)
            if (percent != null) LinearProgressIndicator(progress = { percent / 100f },
                modifier = Modifier.fillMaxWidth().padding(top = 4.dp).height(3.dp), drawStopIndicator = {})
        }
        Row(horizontalArrangement = Arrangement.spacedBy(0.dp)) { actions() }
    }
}
