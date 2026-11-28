package dance.duckduck.wetowl.ui

import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.rounded.Delete
import androidx.compose.material.icons.rounded.PlayArrow
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import dance.duckduck.wetowl.core.Track

fun humanBytes(b: Long): String = when {
    b >= 1L shl 30 -> "%.1f GB".format(b / (1L shl 30).toDouble())
    b >= 1L shl 20 -> "%.0f MB".format(b / (1L shl 20).toDouble())
    else -> "${b / 1024} KB"
}

/** What is kept on this phone, to play with no connection. */
@Composable
fun OfflineScreen(bottom: PaddingValues) {
    val store = LocalStore.current
    val go = LocalGo.current
    val kept by store.offline.kept.collectAsState()
    val here by store.offline.onPhone.collectAsState()
    val going by store.offline.keeping.collectAsState()
    val bytes by store.offline.bytes.collectAsState()
    var clearing by remember { mutableStateOf(false) }
    Column(Modifier.fillMaxSize()) {
        PageBar("On this phone", "${here.size} songs · ${humanBytes(bytes)}") {
            if (kept.isNotEmpty()) TextButton(onClick = { clearing = true }) { Text("Clear") }
        }
        LazyColumn(contentPadding = bottom) {
            if (kept.isEmpty()) item {
                Empty("Nothing kept yet. Open a playlist's menu and choose “Keep on this phone” — its songs then play with no connection.")
            }
            if (going.isNotEmpty()) item {
                Column(Modifier.padding(horizontal = 20.dp, vertical = 8.dp)) {
                    Text("Keeping ${going.size} songs…", style = MaterialTheme.typography.labelLarge, color = MaterialTheme.colorScheme.primary)
                    LinearProgressIndicator(progress = { going.values.average().toFloat() / 100f },
                        modifier = Modifier.fillMaxWidth().padding(top = 6.dp).height(4.dp), drawStopIndicator = {})
                }
            }
            items(kept, key = { it.key }) { l ->
                val have = l.tracks.count { it.id in here }
                Row(Modifier.fillMaxWidth().clickable {
                    l.key.removePrefix("playlist:").toIntOrNull()?.let(go::playlist)
                }.padding(horizontal = 18.dp, vertical = 8.dp), verticalAlignment = Alignment.CenterVertically) {
                    l.tracks.firstOrNull()?.let { TrackArt(it, 56.dp, corner = 14.dp) }
                    Spacer(Modifier.width(14.dp))
                    Column(Modifier.weight(1f)) {
                        Text(l.name, style = MaterialTheme.typography.titleSmall, maxLines = 1, overflow = TextOverflow.Ellipsis)
                        Text(if (have == l.tracks.size) "${l.tracks.size} songs, all here" else "$have of ${l.tracks.size} here",
                            style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
                    }
                    IconButton(onClick = { playKept(store, l.tracks, 0, l.name) }) {
                        Icon(Icons.Rounded.PlayArrow, "Play ${l.name}", tint = MaterialTheme.colorScheme.primary)
                    }
                    IconButton(onClick = { store.offline.forget(l.key) }) {
                        Icon(Icons.Rounded.Delete, "Take ${l.name} off the phone", tint = MaterialTheme.colorScheme.onSurfaceVariant)
                    }
                }
            }
        }
    }
    if (clearing) Confirm("Clear the phone?", "Every kept song is deleted from this phone. The house keeps them all.", "Clear") { yes ->
        clearing = false
        if (yes) store.offline.forgetAll()
    }
}

/** A kept list played: through the house when it answers, from the phone when it does not. */
fun playKept(store: dance.duckduck.wetowl.Store, tracks: List<Track>, start: Int, name: String) = store.play(tracks, start, name)
