package dance.duckduck.wetowl.ui

import androidx.activity.compose.BackHandler
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.rounded.PlaylistAdd
import androidx.compose.material.icons.automirrored.rounded.QueueMusic
import androidx.compose.material.icons.rounded.Close
import androidx.compose.material.icons.rounded.DeleteForever
import androidx.compose.material.icons.rounded.Favorite
import androidx.compose.material.icons.rounded.PlayArrow
import androidx.compose.material.icons.rounded.SkipNext
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import dance.duckduck.wetowl.core.removeFromLibrary
import dance.duckduck.wetowl.ui.theme.tonal

/**
 * What can be done to the songs picked out: one bar over the bottom while a selection
 * runs, which is also how you see that it is running — and how you end it.
 */
@Composable
fun SelectionBar(modifier: Modifier = Modifier) {
    val store = LocalStore.current
    val picked by store.selection.collectAsState()
    if (picked.isEmpty()) return
    var adding by remember { mutableStateOf(false) }
    var removing by remember { mutableStateOf(false) }
    BackHandler { store.selection.value = emptyList() }
    fun done() { store.selection.value = emptyList() }
    Column(modifier.fillMaxWidth().padding(horizontal = 12.dp).padding(bottom = 10.dp)
        .tonal(corner = 22.dp, color = MaterialTheme.colorScheme.secondaryContainer).padding(vertical = 4.dp)) {
        Row(verticalAlignment = Alignment.CenterVertically, modifier = Modifier.padding(start = 4.dp, end = 4.dp)) {
            IconButton(onClick = ::done) { Icon(Icons.Rounded.Close, "Stop picking") }
            Text("${picked.size} picked", style = MaterialTheme.typography.titleSmall,
                color = MaterialTheme.colorScheme.onSecondaryContainer, modifier = Modifier.weight(1f))
            Row(Modifier.horizontalScroll(rememberScrollState())) {
                IconButton(onClick = { store.play(picked, 0, "Picked"); done() }) { Icon(Icons.Rounded.PlayArrow, "Play these") }
                IconButton(onClick = { store.playback.add(picked, next = true); done() }) { Icon(Icons.Rounded.SkipNext, "Play these next") }
                IconButton(onClick = { store.playback.add(picked, next = false); done() }) {
                    Icon(Icons.AutoMirrored.Rounded.QueueMusic, "Add these to the queue")
                }
                IconButton(onClick = { adding = true }) { Icon(Icons.AutoMirrored.Rounded.PlaylistAdd, "Add these to a playlist") }
                IconButton(onClick = {
                    val list = picked
                    store.launch { list.forEach { if (!store.isFavourite(it.id)) store.setFavourite(it, true) } }
                    store.playback.notes.tryEmit("${list.size} added to favourites"); done()
                }) { Icon(Icons.Rounded.Favorite, "Favourite these") }
                IconButton(onClick = { removing = true }) { Icon(Icons.Rounded.DeleteForever, "Remove these from the library") }
            }
        }
    }
    if (adding) AddToPlaylistDialog(picked, onDone = { adding = false; done() })
    if (removing) Confirm("Remove ${picked.size} songs from the library?",
        "They go from your library, your lists and your queues.", "Remove") { yes ->
        removing = false
        if (yes) {
            val ids = picked.map { it.id }
            store.launch { store.api.removeFromLibrary(ids); store.refreshPlaylists(); store.refreshQueues() }
            done()
        }
    }
}
