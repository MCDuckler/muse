package dance.duckduck.wetowl.ui

import androidx.compose.animation.animateColorAsState
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.itemsIndexed
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import dance.duckduck.wetowl.core.Track
import dance.duckduck.wetowl.core.lyrics

/** A line of synced lyrics: when it starts, and what is sung. */
data class LyricLine(val atMs: Long, val text: String)

private val LRC = Regex("""\[(\d+):(\d+)(?:[.:](\d+))?]""")

fun parseLrc(text: String): List<LyricLine> = text.lines().flatMap { line ->
    val stamps = LRC.findAll(line).toList()
    if (stamps.isEmpty()) return@flatMap emptyList()
    val words = line.substring(stamps.last().range.last + 1).trim()
    stamps.map { m ->
        val (mm, ss, frac) = m.destructured
        val f = frac.ifEmpty { "0" }
        val ms = when (f.length) { 1 -> f.toLong() * 100; 2 -> f.toLong() * 10; else -> f.take(3).toLong() }
        LyricLine(mm.toLong() * 60_000 + ss.toLong() * 1000 + ms, words)
    }
}.sortedBy { it.atMs }

/**
 * The words, in place of the cover. Synced ones follow the song — the line sung lit,
 * kept in the middle — and a tap on any line goes there.
 */
@Composable
fun LyricsPane(t: Track, positionMs: Long, modifier: Modifier = Modifier) {
    val store = LocalStore.current
    var lines by remember(t.id) { mutableStateOf<List<LyricLine>?>(null) }
    var plain by remember(t.id) { mutableStateOf<String?>(null) }
    var state by remember(t.id) { mutableStateOf("loading") }
    LaunchedEffect(t.id) {
        try {
            val (synced, p) = store.api.lyrics(t.id)
            lines = synced?.let(::parseLrc)?.takeIf { it.isNotEmpty() }
            plain = p
            state = if (lines == null && p.isNullOrBlank()) "none" else "ok"
        } catch (e: Exception) { state = "none" }
    }
    val scheme = MaterialTheme.colorScheme
    Box(modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
        when {
            state == "loading" -> Loading()
            state == "none" -> Text("No words found for this one.", color = scheme.onSurfaceVariant)
            lines != null -> {
                val l = lines!!
                val at = l.indexOfLast { it.atMs <= positionMs + 300 }.coerceAtLeast(0)
                val list = rememberLazyListState()
                LaunchedEffect(at) { list.animateScrollToItem((at - 3).coerceAtLeast(0)) }
                LazyColumn(state = list, contentPadding = PaddingValues(vertical = 120.dp), modifier = Modifier.fillMaxSize()) {
                    itemsIndexed(l) { i, line ->
                        val colour by animateColorAsState(when {
                            i == at -> scheme.onSurface
                            i < at -> scheme.onSurfaceVariant.copy(alpha = 0.55f)
                            else -> scheme.onSurfaceVariant
                        }, label = "line")
                        Text(line.text.ifBlank { "♪" }, color = colour,
                            style = MaterialTheme.typography.headlineSmall.copy(
                                fontWeight = if (i == at) FontWeight.ExtraBold else FontWeight.Bold),
                            modifier = Modifier.fillMaxWidth().clickable { store.playback.seek(line.atMs) }.padding(vertical = 7.dp))
                    }
                }
            }
            else -> Text(plain ?: "", style = MaterialTheme.typography.titleMedium, color = scheme.onSurface,
                modifier = Modifier.fillMaxSize().verticalScroll(rememberScrollState()).padding(vertical = 24.dp))
        }
    }
}

private val SLEEP = listOf(5, 15, 30, 45, 60, 90)

/** Stop the music later: after some minutes, or when this song ends. */
@Composable
fun SleepDialog(onDone: () -> Unit) {
    val store = LocalStore.current
    val sleep = store.playback.sleep.value
    AlertDialog(
        onDismissRequest = onDone,
        title = { Text("Sleep timer") },
        text = {
            androidx.compose.foundation.layout.Column {
                SLEEP.forEach { m ->
                    Text("$m minutes", style = MaterialTheme.typography.bodyLarge,
                        modifier = Modifier.fillMaxWidth().clickable { store.playback.sleepIn(m * 60_000L); onDone() }
                            .padding(vertical = 12.dp))
                }
                Text("When this song ends", style = MaterialTheme.typography.bodyLarge,
                    modifier = Modifier.fillMaxWidth().clickable { store.playback.sleepAtEndOfSong(); onDone() }
                        .padding(vertical = 12.dp))
            }
        },
        confirmButton = {
            if (sleep != null) TextButton(onClick = { store.playback.sleepIn(null); onDone() }) { Text("Turn off") }
        },
        dismissButton = { TextButton(onClick = onDone) { Text("Cancel") } },
    )
}
