package dance.duckduck.wetowl.ui

import android.net.Uri
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.PickVisualMediaRequest
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.clickable
import androidx.compose.foundation.verticalScroll
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.rounded.PlaylistAdd
import androidx.compose.material.icons.automirrored.rounded.QueueMusic
import androidx.compose.material.icons.rounded.Album
import androidx.compose.material.icons.rounded.Edit
import androidx.compose.material.icons.rounded.AutoAwesome
import androidx.compose.material.icons.rounded.Share
import androidx.compose.material.icons.rounded.DeleteForever
import androidx.compose.material.icons.rounded.Favorite
import androidx.compose.material.icons.rounded.FavoriteBorder
import androidx.compose.material.icons.rounded.Person
import androidx.compose.material.icons.rounded.Radio
import androidx.compose.material.icons.rounded.SkipNext
import androidx.compose.material.icons.rounded.ThumbDown
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import dance.duckduck.wetowl.core.ApiError
import dance.duckduck.wetowl.core.Track
import dance.duckduck.wetowl.core.removeFromLibrary
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

/** One more thing a sheet can do, given by the list the song is on. */
data class SheetAction(val icon: ImageVector, val label: String, val run: () -> Unit)

@Composable
internal fun SheetItem(icon: ImageVector, label: String, onClick: () -> Unit) {
    Row(
        Modifier.fillMaxWidth().clickable(onClick = onClick).padding(horizontal = 24.dp, vertical = 14.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Icon(icon, null, tint = MaterialTheme.colorScheme.onSurfaceVariant)
        Spacer(Modifier.width(18.dp))
        Text(label, style = MaterialTheme.typography.bodyLarge)
    }
}

/** What can be done with one song: the same sheet from every list. */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun SongSheet(t: Track, onDismiss: () -> Unit, extra: List<SheetAction> = emptyList()) {
    val store = LocalStore.current
    val go = LocalGo.current
    val favs by store.favourites.collectAsState()
    val fav = t.id in favs
    var editing by remember { mutableStateOf(false) }
    var adding by remember { mutableStateOf(false) }
    var removing by remember { mutableStateOf(false) }
    val scope = rememberCoroutineScope()
    val context = LocalContext.current

    ModalBottomSheet(onDismissRequest = onDismiss, containerColor = MaterialTheme.colorScheme.surfaceContainerHigh) {
        Column(Modifier.verticalScroll(androidx.compose.foundation.rememberScrollState()).navigationBarsPadding().padding(bottom = 8.dp)) {
            Row(Modifier.padding(horizontal = 24.dp, vertical = 8.dp), verticalAlignment = Alignment.CenterVertically) {
                TrackArt(t, 56.dp, corner = 12.dp)
                Spacer(Modifier.width(14.dp))
                Column(Modifier.weight(1f)) {
                    Text(t.name, style = MaterialTheme.typography.titleMedium, maxLines = 2, overflow = TextOverflow.Ellipsis)
                    Text(t.artistLine, style = MaterialTheme.typography.bodyMedium,
                        color = MaterialTheme.colorScheme.onSurfaceVariant, maxLines = 1, overflow = TextOverflow.Ellipsis)
                }
            }
            HorizontalDivider(Modifier.padding(vertical = 6.dp), color = MaterialTheme.colorScheme.outlineVariant)
            extra.forEach { a -> SheetItem(a.icon, a.label) { a.run(); onDismiss() } }
            SheetItem(Icons.Rounded.SkipNext, "Play next") { store.playback.playNext(t); onDismiss() }
            SheetItem(Icons.AutoMirrored.Rounded.QueueMusic, "Add to queue") { store.playback.addToEnd(t); onDismiss() }
            SheetItem(Icons.AutoMirrored.Rounded.PlaylistAdd, "Add to playlist…") { adding = true }
            SheetItem(if (fav) Icons.Rounded.Favorite else Icons.Rounded.FavoriteBorder,
                if (fav) "Remove from favourites" else "Add to favourites") {
                store.launch { store.setFavourite(t, !fav) }
                onDismiss()
            }
            SheetItem(Icons.Rounded.Radio, "Start a station") {
                store.launch {
                    val p = store.api.startStation(trackId = t.id)
                    val list = p.tracks ?: store.api.playlist(p.id).tracks.orEmpty()
                    store.play(list, 0, p.name)
                }
                onDismiss()
            }
            SheetItem(Icons.Rounded.AutoAwesome, "More like this") {
                onDismiss(); go.open("similar/${t.id}?title=${android.net.Uri.encode(t.name)}")
            }
            t.artists.firstOrNull()?.let { a ->
                SheetItem(Icons.Rounded.Person, "Go to $a") { onDismiss(); go.artist(a) }
            }
            t.album?.takeIf { it.isNotBlank() }?.let { al ->
                SheetItem(Icons.Rounded.Album, "Go to $al") { onDismiss(); go.album(al, t.artists.firstOrNull()) }
            }
            SheetItem(Icons.Rounded.Edit, "Edit details…") { editing = true }
            SheetItem(Icons.Rounded.Share, "Share") {
                val text = "${t.name} — ${t.artistLine}" + (t.album?.takeIf { it.isNotBlank() }?.let { " ($it)" } ?: "")
                context.startActivity(android.content.Intent.createChooser(android.content.Intent(android.content.Intent.ACTION_SEND)
                    .setType("text/plain").putExtra(android.content.Intent.EXTRA_TEXT, text), "Share"))
                onDismiss()
            }
            val disliked = t.id in store.dislikes.collectAsState().value
            SheetItem(Icons.Rounded.ThumbDown, if (disliked) "Take back \"not for me\"" else "Not for me") {
                store.launch { store.setDislike(t, !disliked) }
                onDismiss()
            }
            SheetItem(Icons.Rounded.DeleteForever, "Remove from library…") { removing = true }
        }
    }
    if (editing) EditDialog(t, onDone = { editing = false; onDismiss() })
    if (adding) AddToPlaylistDialog(listOf(t), onDone = { adding = false; onDismiss() })
    if (removing) Confirm("Remove from the library?",
        "\"${t.name}\" goes from your library, your lists and your queues.", "Remove",
        onDone = { yes ->
            removing = false
            if (yes) store.launch {
                store.api.removeFromLibrary(listOf(t.id))
                store.playback.notes.tryEmit("Removed ${t.name}")
                store.refreshPlaylists(); store.refreshQueues()
            }
            onDismiss()
        })
}

/**
 * The name, the credits, the record and the cover — a picture from the phone, or
 * another song's. What is saved shows everywhere at once.
 */
@Composable
fun EditDialog(t: Track, onDone: () -> Unit) {
    val store = LocalStore.current
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    var title by remember { mutableStateOf(t.title) }
    var artists by remember { mutableStateOf(t.artists.joinToString(", ")) }
    var album by remember { mutableStateOf(t.album ?: "") }
    var current by remember { mutableStateOf(t) }
    var working by remember { mutableStateOf(false) }
    var error by remember { mutableStateOf<String?>(null) }
    var donor by remember { mutableStateOf(false) }

    fun cover(op: suspend () -> Track) {
        scope.launch {
            working = true
            try {
                current = op()
                store.trackEdited(current)
            } catch (e: ApiError) { error = e.message } finally { working = false }
        }
    }

    val pick = rememberLauncherForActivityResult(ActivityResultContracts.PickVisualMedia()) { uri: Uri? ->
        if (uri != null) cover {
            val bytes = withContext(Dispatchers.IO) {
                context.contentResolver.openInputStream(uri)?.use { it.readBytes() }
            } ?: throw ApiError(-1, "Could not read that picture")
            store.api.setCover(t.id, bytes)
        }
    }

    AlertDialog(
        onDismissRequest = onDone,
        title = { Text("Edit details") },
        text = {
            Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
                Row(verticalAlignment = Alignment.CenterVertically) {
                    TrackArt(current, 72.dp, corner = 14.dp, small = false)
                    Spacer(Modifier.width(12.dp))
                    Column {
                        TextButton(enabled = !working, onClick = {
                            pick.launch(PickVisualMediaRequest(ActivityResultContracts.PickVisualMedia.ImageOnly))
                        }) { Text("Upload a cover") }
                        TextButton(enabled = !working, onClick = { donor = true }) { Text("Copy from another song") }
                    }
                }
                OutlinedTextField(title, { title = it }, label = { Text("Title") }, singleLine = true)
                OutlinedTextField(artists, { artists = it }, label = { Text("Artists") },
                    supportingText = { Text("Separated by commas") }, singleLine = true)
                OutlinedTextField(album, { album = it }, label = { Text("Album") }, singleLine = true)
                error?.let { Text(it, color = MaterialTheme.colorScheme.error, style = MaterialTheme.typography.bodySmall) }
            }
        },
        confirmButton = {
            TextButton(enabled = !working, onClick = {
                val list = artists.split(',').map { it.trim() }.filter { it.isNotEmpty() }
                val al = album.trim().ifEmpty { null }
                if (title.trim() == current.title && list == current.artists && al == current.album) {
                    onDone(); return@TextButton
                }
                scope.launch {
                    working = true
                    try {
                        store.trackEdited(store.api.editTrack(t.id, title.trim(), list, al))
                        onDone()
                    } catch (e: ApiError) { error = e.message } finally { working = false }
                }
            }) { Text("Save") }
        },
        dismissButton = { TextButton(onClick = onDone) { Text("Cancel") } },
    )
    if (donor) CoverDonorDialog(current, onPick = { from ->
        donor = false
        cover { store.api.copyCover(t.id, from.id) }
    }, onDismiss = { donor = false })
}

/** Another song whose cover to take: the rest of the record first, then by name. */
@Composable
private fun CoverDonorDialog(forSong: Track, onPick: (Track) -> Unit, onDismiss: () -> Unit) {
    val store = LocalStore.current
    var q by remember { mutableStateOf("") }
    var found by remember { mutableStateOf<List<Track>>(emptyList()) }
    androidx.compose.runtime.LaunchedEffect(q) {
        val asked = q.trim()
        kotlinx.coroutines.delay(if (asked.isEmpty()) 0 else 300)
        found = runCatching {
            if (asked.length >= 2) store.api.search(asked, remote = false).local
            else forSong.album?.let { store.api.album(it, null).playable } ?: emptyList()
        }.getOrDefault(emptyList()).filter { it.id != forSong.id && it.coverUrl != null }
    }
    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text("Take the cover of…") },
        text = {
            Column {
                OutlinedTextField(q, { q = it }, placeholder = { Text("A song in the library") }, singleLine = true,
                    modifier = Modifier.fillMaxWidth())
                LazyColumn(Modifier.heightIn(max = 360.dp).padding(top = 8.dp)) {
                    items(found, key = { it.id }) { t ->
                        Row(Modifier.fillMaxWidth().clickable { onPick(t) }.padding(vertical = 6.dp),
                            verticalAlignment = Alignment.CenterVertically) {
                            TrackArt(t, 44.dp)
                            Spacer(Modifier.width(10.dp))
                            Column {
                                Text(t.name, maxLines = 1, overflow = TextOverflow.Ellipsis)
                                Text(t.artistLine, maxLines = 1, style = MaterialTheme.typography.bodySmall,
                                    color = MaterialTheme.colorScheme.onSurfaceVariant)
                            }
                        }
                    }
                }
            }
        },
        confirmButton = { TextButton(onClick = onDismiss) { Text("Cancel") } },
    )
}

@Composable
fun AddToPlaylistDialog(tracks: List<Track>, onDone: () -> Unit) {
    val store = LocalStore.current
    val lists by store.playlists.collectAsState()
    var naming by remember { mutableStateOf(false) }
    var name by remember { mutableStateOf("") }
    AlertDialog(
        onDismissRequest = onDone,
        title = { Text(if (naming) "New playlist" else "Add to playlist") },
        text = {
            if (naming) {
                OutlinedTextField(name, { name = it }, label = { Text("Name") }, singleLine = true)
            } else LazyColumn(Modifier.heightIn(max = 420.dp)) {
                item {
                    Text("New playlist…", color = MaterialTheme.colorScheme.primary,
                        modifier = Modifier.fillMaxWidth().clickable { naming = true }.padding(vertical = 12.dp))
                }
                items(lists.filter { it.canEdit }, key = { it.id }) { p ->
                    Row(Modifier.fillMaxWidth().clickable {
                        store.launch {
                            store.api.addToPlaylist(p.id, tracks.map { it.id })
                            store.playback.notes.tryEmit("Added to ${p.shownName}")
                            store.refreshPlaylists()
                        }
                        onDone()
                    }.padding(vertical = 8.dp), verticalAlignment = Alignment.CenterVertically) {
                        Artwork(store.api.coverUrl(p), 40.dp, corner = 8.dp)
                        Spacer(Modifier.width(12.dp))
                        Text(p.shownName, maxLines = 1, overflow = TextOverflow.Ellipsis)
                    }
                }
            }
        },
        confirmButton = {
            if (naming) TextButton(enabled = name.isNotBlank(), onClick = {
                store.launch {
                    val id = store.api.createPlaylist(name.trim())
                    store.api.addToPlaylist(id, tracks.map { it.id })
                    store.playback.notes.tryEmit("Added to ${name.trim()}")
                    store.refreshPlaylists()
                }
                onDone()
            }) { Text("Create") } else TextButton(onClick = onDone) { Text("Cancel") }
        },
    )
}

/** Yes or no, before something that cannot be taken back. */
@Composable
fun Confirm(title: String, text: String, yes: String, onDone: (Boolean) -> Unit) {
    AlertDialog(
        onDismissRequest = { onDone(false) },
        title = { Text(title) },
        text = { Text(text) },
        confirmButton = { TextButton(onClick = { onDone(true) }) { Text(yes, color = MaterialTheme.colorScheme.error) } },
        dismissButton = { TextButton(onClick = { onDone(false) }) { Text("Cancel") } },
    )
}
