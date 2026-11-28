package dance.duckduck.wetowl.ui

import android.net.Uri
import android.provider.OpenableColumns
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.PickVisualMediaRequest
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.verticalScroll
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.RowScope
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.itemsIndexed
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.rounded.ArrowBack
import androidx.compose.material.icons.automirrored.rounded.Sort
import androidx.compose.material.icons.rounded.Add
import androidx.compose.material.icons.rounded.AutoAwesome
import androidx.compose.material.icons.rounded.BarChart
import androidx.compose.material.icons.rounded.Bookmark
import androidx.compose.material.icons.rounded.BookmarkBorder
import androidx.compose.material.icons.rounded.CloudDownload
import androidx.compose.material.icons.rounded.CreateNewFolder
import androidx.compose.material.icons.rounded.Delete
import androidx.compose.material.icons.rounded.DriveFileMove
import androidx.compose.material.icons.rounded.Edit
import androidx.compose.material.icons.rounded.Favorite
import androidx.compose.material.icons.rounded.Folder
import androidx.compose.material.icons.rounded.HideImage
import androidx.compose.material.icons.rounded.History
import androidx.compose.material.icons.rounded.Image
import androidx.compose.material.icons.rounded.MoreVert
import androidx.compose.material.icons.rounded.PlaylistRemove
import androidx.compose.material.icons.rounded.PlayArrow
import androidx.compose.material.icons.rounded.Sync
import androidx.compose.material.icons.rounded.ContentCopy
import androidx.compose.material.icons.rounded.OfflinePin
import androidx.compose.material.icons.rounded.PhonelinkErase
import androidx.compose.material.icons.rounded.PushPin
import androidx.compose.material.icons.rounded.Radio
import androidx.compose.material.icons.rounded.ThumbDown
import androidx.compose.material.icons.rounded.UploadFile
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.FilterChip
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.RadioButton
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import dance.duckduck.wetowl.core.ApiError
import dance.duckduck.wetowl.core.Folder
import dance.duckduck.wetowl.core.Playlist
import dance.duckduck.wetowl.core.SmartList
import dance.duckduck.wetowl.core.Stats
import dance.duckduck.wetowl.core.Track
import dance.duckduck.wetowl.core.clearHistory
import dance.duckduck.wetowl.core.clearPlaylistCover
import dance.duckduck.wetowl.core.createFolder
import dance.duckduck.wetowl.core.deleteFolder
import dance.duckduck.wetowl.core.deletePlaylist
import dance.duckduck.wetowl.core.fetchPlaylist
import dance.duckduck.wetowl.core.folderTracks
import dance.duckduck.wetowl.core.fullHistory
import dance.duckduck.wetowl.core.movePlaylistItem
import dance.duckduck.wetowl.core.pinPlaylist
import dance.duckduck.wetowl.core.placePlaylist
import dance.duckduck.wetowl.core.removeFromPlaylist
import dance.duckduck.wetowl.core.renameFolder
import dance.duckduck.wetowl.core.renamePlaylist
import dance.duckduck.wetowl.core.savePlaylist
import dance.duckduck.wetowl.core.setPlaylistCover
import dance.duckduck.wetowl.core.smartList
import dance.duckduck.wetowl.core.smartLists
import dance.duckduck.wetowl.core.sortPlaylist
import dance.duckduck.wetowl.core.stats
import dance.duckduck.wetowl.core.suggestedFor
import dance.duckduck.wetowl.core.unsavePlaylist
import dance.duckduck.wetowl.core.upload
import dance.duckduck.wetowl.core.similar
import dance.duckduck.wetowl.core.clonePlaylist
import dance.duckduck.wetowl.core.pullPlaylist
import dance.duckduck.wetowl.core.tuneStation
import dance.duckduck.wetowl.core.refreshStation
import dance.duckduck.wetowl.ui.theme.Kicker
import dance.duckduck.wetowl.ui.theme.RoundButton
import dance.duckduck.wetowl.ui.theme.tonal
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

// ----------------------------------------------------------------------- page chrome

/** Back, and whatever the page can do, floating over its top. */
@Composable
fun FloatingTop(modifier: Modifier = Modifier, actions: @Composable RowScope.() -> Unit = {}) {
    val go = LocalGo.current
    Row(modifier.fillMaxWidth().statusBarsPadding().padding(horizontal = 10.dp, vertical = 6.dp),
        verticalAlignment = Alignment.CenterVertically) {
        RoundButton(Icons.AutoMirrored.Rounded.ArrowBack, "Back", go::back, size = 42.dp)
        Spacer(Modifier.weight(1f))
        actions()
    }
}

/** A plain page: back, a title, actions, then the content. */
@Composable
fun PageBar(title: String, subtitle: String? = null, actions: @Composable RowScope.() -> Unit = {}) {
    val go = LocalGo.current
    Row(Modifier.fillMaxWidth().statusBarsPadding().padding(start = 4.dp, end = 8.dp, top = 6.dp, bottom = 4.dp),
        verticalAlignment = Alignment.CenterVertically) {
        IconButton(onClick = go::back) { Icon(Icons.AutoMirrored.Rounded.ArrowBack, "Back") }
        Column(Modifier.weight(1f).padding(start = 4.dp)) {
            Text(title, style = MaterialTheme.typography.titleLarge, maxLines = 1, overflow = TextOverflow.Ellipsis)
            subtitle?.let {
                Text(it, style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
            }
        }
        actions()
    }
}

private fun notes(store: dance.duckduck.wetowl.Store, s: String) { store.playback.notes.tryEmit(s) }

// ----------------------------------------------------------------------- playlists tab

/** Shortcuts at the top of the library: where your listening is kept. */
@Composable
private fun LibraryShortcuts() {
    val go = LocalGo.current
    Row(Modifier.fillMaxWidth().horizontalScroll(rememberScrollState()).padding(horizontal = 18.dp),
        horizontalArrangement = Arrangement.spacedBy(10.dp)) {
        Shortcut(Icons.Rounded.History, "History") { go.open("history") }
        Shortcut(Icons.Rounded.BarChart, "Your charts") { go.open("stats") }
        Shortcut(Icons.Rounded.OfflinePin, "On this phone") { go.open("offline") }
        Shortcut(Icons.Rounded.CloudDownload, "Downloads") { go.open("downloads") }
        Shortcut(Icons.Rounded.ThumbDown, "Not for me") { go.open("notforme") }
    }
}

@Composable
private fun Shortcut(icon: ImageVector, label: String, onClick: () -> Unit) {
    Row(Modifier.tonal(corner = 16.dp).clickable(onClick = onClick).padding(horizontal = 14.dp, vertical = 10.dp),
        verticalAlignment = Alignment.CenterVertically) {
        Icon(icon, null, tint = MaterialTheme.colorScheme.primary, modifier = Modifier.size(18.dp))
        Spacer(Modifier.width(8.dp))
        Text(label, style = MaterialTheme.typography.labelLarge)
    }
}

/** Folders, pins, smart lists and every playlist; making new ones; a file from the phone. */
@Composable
fun PlaylistsTab(bottom: PaddingValues) {
    val store = LocalStore.current
    val go = LocalGo.current
    val context = LocalContext.current
    val lists by store.playlists.collectAsState()
    val folders by store.folders.collectAsState()
    var smart by remember { mutableStateOf<List<SmartList>>(emptyList()) }
    var naming by remember { mutableStateOf<String?>(null) }
    var uploading by remember { mutableStateOf(false) }
    LaunchedEffect(Unit) {
        store.refreshPlaylists()
        runCatching { smart = store.api.smartLists() }
    }
    val upload = rememberLauncherForActivityResult(ActivityResultContracts.OpenMultipleDocuments()) { uris: List<Uri> ->
        if (uris.isEmpty()) return@rememberLauncherForActivityResult
        uploading = true
        store.launch {
            try {
                for (uri in uris) {
                    val name = context.contentResolver.query(uri, arrayOf(OpenableColumns.DISPLAY_NAME), null, null, null)
                        ?.use { c -> if (c.moveToFirst()) c.getString(0) else null } ?: "upload"
                    val bytes = withContext(Dispatchers.IO) {
                        context.contentResolver.openInputStream(uri)?.use { it.readBytes() }
                    } ?: continue
                    val t = store.api.upload(bytes, name)
                    notes(store, "Added ${t.name}")
                }
            } finally { uploading = false }
        }
    }

    val sorted = lists.sortedWith(compareByDescending<Playlist> { it.isFavourites }.thenByDescending { it.pinned })
    val loose = sorted.filter { it.folderId == null || folders.none { f -> f.id == it.folderId } }
    LazyColumn(contentPadding = bottom) {
        item { LibraryShortcuts() }
        if (smart.isNotEmpty()) {
            item { SectionLabel("Made from your library") }
            item {
                LazyRow(contentPadding = PaddingValues(horizontal = 18.dp), horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                    items(smart, key = { it.id }) { s ->
                        Column(Modifier.width(140.dp).tonal(corner = 18.dp).clickable { go.open("smart/${Uri.encode(s.id)}") }
                            .padding(14.dp)) {
                            Icon(Icons.Rounded.AutoAwesome, null, tint = MaterialTheme.colorScheme.primary, modifier = Modifier.size(20.dp))
                            Spacer(Modifier.height(10.dp))
                            Text(s.name, style = MaterialTheme.typography.titleSmall, maxLines = 1, overflow = TextOverflow.Ellipsis)
                            Text("${s.count} songs", style = MaterialTheme.typography.bodySmall,
                                color = MaterialTheme.colorScheme.onSurfaceVariant)
                        }
                    }
                }
            }
        }
        item {
            SectionLabel("Playlists") {
                IconButton(onClick = { upload.launch(arrayOf("audio/*")) }, enabled = !uploading) {
                    Icon(Icons.Rounded.UploadFile, "Add a file from the phone")
                }
                IconButton(onClick = { naming = "folder" }) { Icon(Icons.Rounded.CreateNewFolder, "New folder") }
                IconButton(onClick = { naming = "playlist" }) { Icon(Icons.Rounded.Add, "New playlist") }
            }
        }
        if (uploading) item { Text("Sending to the house…", style = MaterialTheme.typography.bodySmall,
            color = MaterialTheme.colorScheme.primary, modifier = Modifier.padding(horizontal = 20.dp)) }
        if (lists.isEmpty()) item { Loading() }
        items(folders, key = { "f${it.id}" }) { f ->
            ListRow(
                art = { Box(Modifier.size(56.dp).tonal(corner = 14.dp), contentAlignment = Alignment.Center) {
                    Icon(Icons.Rounded.Folder, null, tint = MaterialTheme.colorScheme.primary)
                } },
                title = f.name,
                sub = "${lists.count { it.folderId == f.id }} playlists",
                onClick = { go.open("folder/${f.id}") },
            )
        }
        items(loose, key = { it.id }) { p -> PlaylistRow(p) }
    }
    when (naming) {
        "folder" -> NameDialog("New folder", "") { n ->
            naming = null
            if (!n.isNullOrBlank()) store.launch { store.api.createFolder(n.trim()); store.refreshPlaylists() }
        }
        "playlist" -> NameDialog("New playlist", "") { n ->
            naming = null
            if (!n.isNullOrBlank()) store.launch {
                val id = store.api.createPlaylist(n.trim()); store.refreshPlaylists(); go.playlist(id)
            }
        }
    }
}

@Composable
private fun ListRow(art: @Composable () -> Unit, title: String, sub: String, onClick: () -> Unit,
                    trailing: (@Composable () -> Unit)? = null) {
    Row(Modifier.fillMaxWidth().clickable(onClick = onClick).padding(horizontal = 18.dp, vertical = 8.dp),
        verticalAlignment = Alignment.CenterVertically) {
        art()
        Spacer(Modifier.width(14.dp))
        Column(Modifier.weight(1f)) {
            Text(title, style = MaterialTheme.typography.titleSmall, maxLines = 1, overflow = TextOverflow.Ellipsis)
            Text(sub, style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant,
                maxLines = 1, overflow = TextOverflow.Ellipsis)
        }
        trailing?.invoke()
    }
}

@Composable
fun PlaylistRow(p: Playlist) {
    val store = LocalStore.current
    val go = LocalGo.current
    var menu by remember { mutableStateOf(false) }
    ListRow(
        art = {
            if (p.isFavourites) {
                Box(Modifier.size(56.dp).tonal(corner = 14.dp, color = MaterialTheme.colorScheme.primaryContainer),
                    contentAlignment = Alignment.Center) {
                    Icon(Icons.Rounded.Favorite, null, tint = MaterialTheme.colorScheme.primary)
                }
            } else Artwork(store.api.coverUrl(p), 56.dp, corner = 14.dp)
        },
        title = p.shownName,
        sub = listOfNotNull("${p.count} songs", p.ownerName?.let { "by $it" },
            if (p.stationId != null) "station" else null).joinToString(" · "),
        onClick = { go.playlist(p.id) },
        trailing = {
            if (p.pinned) Icon(Icons.Rounded.PushPin, "Pinned", tint = MaterialTheme.colorScheme.onSurfaceVariant,
                modifier = Modifier.size(16.dp))
            if (!p.isFavourites) IconButton(onClick = { menu = true }) {
                Icon(Icons.Rounded.MoreVert, "More", tint = MaterialTheme.colorScheme.onSurfaceVariant)
            }
        },
    )
    if (menu) PlaylistSheet(p, onDismiss = { menu = false }, onChanged = {}, onDeleted = {})
}

// ----------------------------------------------------------------------- one playlist

private val SORTS = listOf(
    "added_desc" to "Recently added",
    "added_asc" to "First added",
    "manual" to "Your order (drag to move)",
    "title" to "Title",
    "artist" to "Artist",
    "album" to "Record",
    "year" to "Newest records",
    "duration" to "Shortest first",
)

/** What can be done to a whole list. */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun PlaylistSheet(p: Playlist, onDismiss: () -> Unit, onChanged: (Playlist?) -> Unit, onDeleted: () -> Unit) {
    val store = LocalStore.current
    val context = LocalContext.current
    val folders by store.folders.collectAsState()
    var dialog by remember { mutableStateOf<String?>(null) }
    val mine = p.ownerName == null
    val pickCover = rememberLauncherForActivityResult(ActivityResultContracts.PickVisualMedia()) { uri: Uri? ->
        if (uri != null) store.launch {
            val bytes = withContext(Dispatchers.IO) { context.contentResolver.openInputStream(uri)?.use { it.readBytes() } }
                ?: throw ApiError(-1, "Could not read that picture")
            store.api.setPlaylistCover(p.id, bytes)
            store.refreshPlaylists(); onChanged(null)
        }
        onDismiss()
    }
    ModalBottomSheet(onDismissRequest = onDismiss, containerColor = MaterialTheme.colorScheme.surfaceContainerHigh) {
        Column(Modifier.verticalScroll(androidx.compose.foundation.rememberScrollState()).navigationBarsPadding().padding(bottom = 8.dp)) {
            Text(p.shownName, style = MaterialTheme.typography.titleMedium, maxLines = 1, overflow = TextOverflow.Ellipsis,
                modifier = Modifier.padding(horizontal = 24.dp, vertical = 8.dp))
            HorizontalDivider(Modifier.padding(vertical = 6.dp), color = MaterialTheme.colorScheme.outlineVariant)
            if (p.canEdit && !p.isFavourites) SheetItem(Icons.Rounded.Edit, "Rename…") { dialog = "rename" }
            if (p.canEdit) SheetItem(Icons.AutoMirrored.Rounded.Sort, "Sort…") { dialog = "sort" }
            SheetItem(Icons.Rounded.PushPin, if (p.pinned) "Unpin" else "Pin to the top") {
                store.launch { store.api.pinPlaylist(p.id, !p.pinned); store.refreshPlaylists() }; onDismiss()
            }
            if (!p.isFavourites) SheetItem(Icons.Rounded.DriveFileMove, "Move to folder…") { dialog = "folder" }
            if (p.canEdit && !p.isFavourites) {
                SheetItem(Icons.Rounded.Image, "Choose a cover…") {
                    pickCover.launch(PickVisualMediaRequest(ActivityResultContracts.PickVisualMedia.ImageOnly))
                }
                if (p.coverUrl != null) SheetItem(Icons.Rounded.HideImage, "Use the songs' covers") {
                    store.launch { store.api.clearPlaylistCover(p.id); store.refreshPlaylists(); onChanged(null) }; onDismiss()
                }
            }
            val keyOf = "playlist:${p.id}"
            val keptHere = store.offline.kept.collectAsState().value.any { it.key == keyOf }
            SheetItem(if (keptHere) Icons.Rounded.PhonelinkErase else Icons.Rounded.OfflinePin,
                if (keptHere) "Take off this phone" else "Keep on this phone") {
                if (keptHere) store.offline.forget(keyOf)
                else store.launch {
                    val full = p.tracks ?: store.api.playlist(p.id).tracks.orEmpty()
                    store.offline.keep(keyOf, p.shownName, full)
                    notes(store, "Keeping ${full.size} songs on this phone")
                }
                onDismiss()
            }
            SheetItem(Icons.Rounded.CloudDownload, "Fetch the audio of every song") {
                store.launch { val n = store.api.fetchPlaylist(p.id); notes(store, if (n == 0) "All here already" else "Fetching $n songs") }
                onDismiss()
            }
            if (!mine) SheetItem(if (p.saved) Icons.Rounded.Bookmark else Icons.Rounded.BookmarkBorder,
                if (p.saved) "Remove from your library" else "Save to your library") {
                store.launch {
                    if (p.saved) store.api.unsavePlaylist(p.id) else store.api.savePlaylist(p.id)
                    store.refreshPlaylists(); onChanged(null)
                }
                onDismiss()
            }
            if (p.kind != "local" && p.kind != "favourites" && p.kind != "station" && mine) {
                SheetItem(Icons.Rounded.Sync, "Sync with ${PLACE_NAMES[p.kind] ?: p.kind.replaceFirstChar { it.uppercase() }} now") {
                    store.launch { store.api.pullPlaylist(p.id); notes(store, "Syncing ${p.shownName}"); onChanged(null) }
                    onDismiss()
                }
                SheetItem(Icons.Rounded.ContentCopy, "Make my own copy") {
                    store.launch {
                        val id = store.api.clonePlaylist(p.id)
                        store.refreshPlaylists(); notes(store, "Copied — the copy is yours to change")
                        id?.let { onChanged(null) }
                    }
                    onDismiss()
                }
            }
            if (mine && !p.isFavourites) SheetItem(Icons.Rounded.Delete, "Delete playlist…") { dialog = "delete" }
        }
    }
    when (dialog) {
        "rename" -> NameDialog("Rename", p.name) { n ->
            dialog = null
            if (!n.isNullOrBlank()) store.launch { onChanged(store.api.renamePlaylist(p.id, n.trim())); store.refreshPlaylists() }
            onDismiss()
        }
        "sort" -> ChoiceDialog("Sort", SORTS, p.sort ?: "added_desc") { s ->
            dialog = null
            if (s != null) store.launch { onChanged(store.api.sortPlaylist(p.id, s)) }
            onDismiss()
        }
        "folder" -> ChoiceDialog("Move to folder",
            listOf("" to "No folder") + folders.map { "${it.id}" to it.name }, p.folderId?.toString() ?: "") { s ->
            dialog = null
            if (s != null) store.launch { store.api.placePlaylist(p.id, s.toIntOrNull()); store.refreshPlaylists() }
            onDismiss()
        }
        "delete" -> Confirm("Delete \"${p.name}\"?", "The list goes; the songs stay in your library.", "Delete") { yes ->
            dialog = null
            if (yes) store.launch { store.api.deletePlaylist(p.id); store.refreshPlaylists(); onDeleted() }
            onDismiss()
        }
    }
}

@Composable
fun ChoiceDialog(title: String, options: List<Pair<String, String>>, current: String, onDone: (String?) -> Unit) {
    AlertDialog(
        onDismissRequest = { onDone(null) },
        title = { Text(title) },
        text = {
            LazyColumn(Modifier.heightIn(max = 440.dp)) {
                items(options, key = { it.first }) { (k, label) ->
                    Row(Modifier.fillMaxWidth().clip(RoundedCornerShape(12.dp)).clickable { onDone(k) }.padding(vertical = 2.dp),
                        verticalAlignment = Alignment.CenterVertically) {
                        RadioButton(selected = k == current, onClick = { onDone(k) })
                        Text(label)
                    }
                }
            }
        },
        confirmButton = { TextButton(onClick = { onDone(null) }) { Text("Cancel") } },
    )
}

/** One playlist: play, shuffle, its songs to drag about and take off, and what might fit. */
@Composable
fun PlaylistScreen(id: Int, bottom: PaddingValues) {
    val store = LocalStore.current
    val go = LocalGo.current
    val now by store.playback.now.collectAsState()
    var p by remember { mutableStateOf<Playlist?>(null) }
    var error by remember { mutableStateOf<String?>(null) }
    var attempt by remember { mutableIntStateOf(0) }
    var menu by remember { mutableStateOf(false) }
    var suggested by remember { mutableStateOf<List<Track>>(emptyList()) }
    LaunchedEffect(id, attempt) {
        try { p = store.api.playlist(id); error = null } catch (e: ApiError) { error = e.message }
    }
    LaunchedEffect(id, p?.canEdit) {
        if (p?.canEdit == true && p?.isFavourites == false) runCatching { suggested = store.api.suggestedFor(id) }
    }
    val list = p
    Box(Modifier.fillMaxSize()) {
        if (list == null) {
            Box(Modifier.statusBarsPadding().padding(top = 56.dp)) {
                if (error != null) ErrorRetry(error!!, { attempt++ }) else Loading()
            }
        } else {
            val tracks = list.tracks.orEmpty()
            val editable = list.canEdit
            val overlay = bottom.calculateBottomPadding()
            QueueList(
                rows = tracks,
                litRow = tracks.indexOfFirst { it.id == now.track?.id },
                overlay = overlay,
                onTap = { i -> store.play(tracks, i, list.shownName) },
                onMove = if (editable && list.sort == "manual") { from, to ->
                    store.launch {
                        store.api.movePlaylistItem(list.id, from, to)
                        p = store.api.playlist(list.id)
                    }
                } else null,
                onRemove = if (editable) { i ->
                    val t = tracks[i]
                    p = list.copy(tracks = tracks.filterIndexed { j, _ -> j != i }, count = list.count - 1)
                    store.launch {
                        p = store.api.removeFromPlaylist(list.id, listOf(t.id))
                        notes(store, "Took ${t.name} off ${list.shownName}")
                        store.refreshPlaylists()
                    }
                } else null,
                extraActions = if (editable) { t -> listOf(SheetAction(Icons.Rounded.PlaylistRemove, "Take off this list") {
                    p = list.copy(tracks = tracks.filter { it.id != t.id })
                    store.launch { p = store.api.removeFromPlaylist(list.id, listOf(t.id)); store.refreshPlaylists() }
                }) } else null,
                header = {
                    item {
                        CollectionHead(store.api.coverUrl(list), list.shownName,
                            listOfNotNull("${tracks.size} songs", list.ownerName?.let { "by $it" },
                                SORTS.firstOrNull { it.first == list.sort }?.second?.takeIf { list.sort != "added_desc" })
                                .joinToString(" · "),
                            onPlay = { store.play(tracks, 0, list.shownName) },
                            onShuffle = { store.play(tracks.shuffled(), 0, list.shownName) },
                            playEnabled = tracks.isNotEmpty(),
                            extra = if (list.stationId != null) {{
                                RoundButton(Icons.Rounded.Radio, "More like this", {
                                    store.launch {
                                        val q = store.playback.now.value.queue
                                        if (q != null) store.api.extendStation(list.stationId, q.id)
                                        p = store.api.playlist(list.id)
                                    }
                                }, size = 52.dp)
                            }} else null)
                    }
                    if (list.stationId != null) item {
                        var fresh by remember(list.stationFresh) { mutableStateOf(list.stationFresh ?: 0.5f) }
                        Column(Modifier.padding(horizontal = 24.dp)) {
                            Row(verticalAlignment = Alignment.CenterVertically) {
                                Text("Familiar", style = MaterialTheme.typography.labelMedium, color = MaterialTheme.colorScheme.onSurfaceVariant)
                                androidx.compose.material3.Slider(value = fresh, onValueChange = { fresh = it },
                                    onValueChangeFinished = { store.launch { p = store.api.tuneStation(list.stationId, fresh) } },
                                    modifier = Modifier.weight(1f).padding(horizontal = 10.dp))
                                Text("New", style = MaterialTheme.typography.labelMedium, color = MaterialTheme.colorScheme.onSurfaceVariant)
                            }
                            androidx.compose.material3.TextButton(onClick = {
                                store.launch { p = store.api.refreshStation(list.stationId); notes(store, "Station written again") }
                            }) { Text("Write it again") }
                        }
                    }
                    if (list.unmatched > 0) item {
                        androidx.compose.material3.TextButton(onClick = { go.open("unmatched/${list.id}") },
                            modifier = Modifier.padding(horizontal = 16.dp)) {
                            Text("${list.unmatched} songs were not found — fix them")
                        }
                    }
                    if (tracks.isEmpty()) item { Empty("No songs on this list yet. Add some from any song's menu.") }
                },
                footer = {
                    if (suggested.isNotEmpty()) {
                        item { SectionLabel("Might fit") }
                        items(suggested.take(12), key = { "s" + it.id }) { t ->
                            SongRow(t, onClick = { store.play(listOf(t), 0, list.shownName) }, showMenu = false,
                                trailing = {
                                    IconButton(onClick = {
                                        suggested = suggested - t
                                        store.launch {
                                            store.api.addToPlaylist(list.id, listOf(t.id))
                                            p = store.api.playlist(list.id); store.refreshPlaylists()
                                        }
                                    }) { Icon(Icons.Rounded.Add, "Add to ${list.shownName}", tint = MaterialTheme.colorScheme.primary) }
                                })
                        }
                    }
                },
            )
        }
        FloatingTop {
            if (list != null && !list.isFavourites || list?.canEdit == true) {
                RoundButton(Icons.Rounded.MoreVert, "Playlist options", { menu = true }, size = 42.dp)
            }
        }
    }
    if (menu && list != null) PlaylistSheet(list, onDismiss = { menu = false },
        onChanged = { changed -> if (changed != null) p = changed else attempt++ },
        onDeleted = { go.back() })
}

// ----------------------------------------------------------------------- folder

@Composable
fun FolderScreen(id: Int, bottom: PaddingValues) {
    val store = LocalStore.current
    val go = LocalGo.current
    val lists by store.playlists.collectAsState()
    val folders by store.folders.collectAsState()
    val folder = folders.firstOrNull { it.id == id }
    var dialog by remember { mutableStateOf<String?>(null) }
    val inside = lists.filter { it.folderId == id }
    Column(Modifier.fillMaxSize()) {
        PageBar(folder?.name ?: "Folder", "${inside.size} playlists") {
            IconButton(onClick = {
                store.launch {
                    val all = store.api.folderTracks(id)
                    if (all.isNotEmpty()) store.play(all, 0, folder?.name ?: "Folder")
                }
            }) { Icon(Icons.Rounded.PlayArrow, "Play everything", tint = MaterialTheme.colorScheme.primary) }
            IconButton(onClick = { dialog = "rename" }) { Icon(Icons.Rounded.Edit, "Rename folder") }
            IconButton(onClick = { dialog = "delete" }) { Icon(Icons.Rounded.Delete, "Delete folder") }
        }
        LazyColumn(contentPadding = bottom) {
            if (inside.isEmpty()) item { Empty("Nothing in here yet. Move a playlist in from its menu.") }
            items(inside, key = { it.id }) { PlaylistRow(it) }
        }
    }
    when (dialog) {
        "rename" -> NameDialog("Rename folder", folder?.name ?: "") { n ->
            dialog = null
            if (!n.isNullOrBlank()) store.launch { store.api.renameFolder(id, n.trim()); store.refreshPlaylists() }
        }
        "delete" -> Confirm("Delete this folder?", "The playlists in it stay, out of any folder.", "Delete") { yes ->
            dialog = null
            if (yes) store.launch { store.api.deleteFolder(id); store.refreshPlaylists(); go.back() }
        }
    }
}

// ----------------------------------------------------------------------- song lists

/** A plain page of songs read once: smart lists, history, what is not for you. */
@Composable
private fun SongsPage(
    title: String,
    bottom: PaddingValues,
    load: suspend () -> Pair<String?, List<Track>>,
    emptyText: String,
    key: Any = title,
    actions: @Composable RowScope.(List<Track>) -> Unit = {},
    rowActions: ((Track) -> List<SheetAction>)? = null,
) {
    val store = LocalStore.current
    val now by store.playback.now.collectAsState()
    var items by remember(key) { mutableStateOf<List<Track>?>(null) }
    var blurb by remember(key) { mutableStateOf<String?>(null) }
    var error by remember { mutableStateOf<String?>(null) }
    var attempt by remember { mutableIntStateOf(0) }
    LaunchedEffect(key, attempt) {
        try { val (b, l) = load(); blurb = b; items = l; error = null } catch (e: ApiError) { error = e.message }
    }
    Column(Modifier.fillMaxSize()) {
        PageBar(title, blurb ?: items?.let { "${it.size} songs" }) {
            items?.let { l ->
                if (l.isNotEmpty()) RoundButton(Icons.Rounded.PlayArrow, "Play",
                    { store.play(l, 0, title) }, size = 40.dp, accent = true)
                actions(l)
            }
        }
        val l = items
        when {
            error != null && l == null -> ErrorRetry(error!!, { attempt++ })
            l == null -> Loading()
            l.isEmpty() -> Empty(emptyText)
            else -> LazyColumn(contentPadding = bottom) {
                itemsIndexed(l, key = { i, t -> "$i-${t.id}" }) { i, t ->
                    SongRow(t, onClick = { store.play(l, i, title) }, lit = t.id == now.track?.id,
                        modifier = Modifier.padding(horizontal = 8.dp), extraActions = rowActions?.invoke(t).orEmpty())
                }
            }
        }
    }
}

@Composable
fun SmartListScreen(id: String, bottom: PaddingValues) {
    val store = LocalStore.current
    var name by remember { mutableStateOf("") }
    SongsPage(name.ifEmpty { "Made for you" }, bottom, {
        val (s, l) = store.api.smartList(id); name = s.name; s.blurb.ifBlank { null } to l
    }, "Nothing on this list right now.", key = id)
}

@Composable
fun HistoryScreen(bottom: PaddingValues) {
    val store = LocalStore.current
    var clearing by remember { mutableStateOf(false) }
    var generation by remember { mutableIntStateOf(0) }
    SongsPage("History", bottom, { null to store.api.fullHistory() }, "Nothing played yet.", key = generation,
        actions = { l -> if (l.isNotEmpty()) IconButton(onClick = { clearing = true }) { Icon(Icons.Rounded.Delete, "Clear history") } })
    if (clearing) Confirm("Clear your history?", "What you played is forgotten. Your charts and picks start again.", "Clear") { yes ->
        clearing = false
        if (yes) store.launch { store.api.clearHistory(); store.refreshHome(); generation++ }
    }
}

@Composable
fun NotForMeScreen(bottom: PaddingValues) {
    val store = LocalStore.current
    val ids by store.dislikes.collectAsState()
    SongsPage("Not for me", bottom, {
        "Never picked for you, never in a station" to ids.toList().takeLast(150).reversed()
            .mapNotNull { runCatching { store.api.track(it) }.getOrNull() }
    }, "Nothing here. Mark a song \"not for me\" from its menu and it is never picked for you again.",
        key = ids.size,
        rowActions = { t -> listOf(SheetAction(Icons.Rounded.ThumbDown, "Take it back") {
            store.launch { store.setDislike(t, false) }
        }) })
}

// ----------------------------------------------------------------------- charts

private val PERIODS = listOf("week" to "Week", "month" to "Month", "year" to "Year", "all" to "All time")

@Composable
fun StatsScreen(bottom: PaddingValues) {
    val store = LocalStore.current
    val go = LocalGo.current
    var since by rememberSaveable { mutableStateOf("week") }
    var stats by remember { mutableStateOf<Stats?>(null) }
    var error by remember { mutableStateOf<String?>(null) }
    var attempt by remember { mutableIntStateOf(0) }
    var tab by rememberSaveable { mutableIntStateOf(0) }
    LaunchedEffect(since, attempt) {
        stats = null
        try { stats = store.api.stats(since); error = null } catch (e: ApiError) { error = e.message }
    }
    Column(Modifier.fillMaxSize()) {
        PageBar("Your charts")
        Row(Modifier.padding(horizontal = 16.dp), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            PERIODS.forEach { (k, label) -> FilterChip(selected = since == k, onClick = { since = k }, label = { Text(label) }) }
        }
        val s = stats
        when {
            error != null && s == null -> ErrorRetry(error!!, { attempt++ })
            s == null -> Loading()
            else -> LazyColumn(contentPadding = bottom) {
                item {
                    Row(Modifier.fillMaxWidth().padding(16.dp), horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                        StatTile("Plays", "${s.plays}", Modifier.weight(1f))
                        StatTile("Hours", if (s.minutes >= 600) "${s.minutes / 60}" else "%.1f".format(s.minutes / 60f), Modifier.weight(1f))
                        StatTile("Songs", "${s.tracks}", Modifier.weight(1f))
                    }
                }
                item {
                    Segments(listOf("Songs", "Artists", "Records"), tab, { tab = it },
                        Modifier.padding(horizontal = 16.dp, vertical = 4.dp))
                }
                val rows = when (tab) { 0 -> s.songs; 1 -> s.artists; else -> s.albums }
                val top = rows.maxOfOrNull { it.plays }?.coerceAtLeast(1) ?: 1
                if (rows.isEmpty()) item { Empty("Nothing played in this time.") }
                itemsIndexed(rows, key = { i, r -> "$tab-$i-${r.name}" }) { i, r ->
                    Row(Modifier.fillMaxWidth().clickable {
                        when (tab) {
                            0 -> r.track?.let { t -> store.play(s.songs.mapNotNull { it.track }, s.songs.mapNotNull { it.track }.indexOf(t), "Your charts") }
                            1 -> go.artist(r.name)
                            else -> go.album(r.name, r.sub)
                        }
                    }.padding(horizontal = 16.dp, vertical = 6.dp), verticalAlignment = Alignment.CenterVertically) {
                        Text("${i + 1}", style = MaterialTheme.typography.titleMedium,
                            color = if (i < 3) MaterialTheme.colorScheme.primary else MaterialTheme.colorScheme.onSurfaceVariant,
                            modifier = Modifier.width(32.dp))
                        if (tab == 1) {
                            Box(Modifier.size(44.dp).clip(CircleShape).background(MaterialTheme.colorScheme.secondaryContainer),
                                contentAlignment = Alignment.Center) {
                                Text(r.name.take(1).uppercase(), color = MaterialTheme.colorScheme.onSecondaryContainer)
                            }
                        } else if (r.track != null) TrackArt(r.track, 44.dp)
                        else Artwork(store.api.absolute(r.cover), 44.dp)
                        Spacer(Modifier.width(12.dp))
                        Column(Modifier.weight(1f)) {
                            Text(r.name, style = MaterialTheme.typography.titleSmall, maxLines = 1, overflow = TextOverflow.Ellipsis)
                            r.sub?.takeIf { it.isNotBlank() }?.let {
                                Text(it, style = MaterialTheme.typography.bodySmall, maxLines = 1,
                                    overflow = TextOverflow.Ellipsis, color = MaterialTheme.colorScheme.onSurfaceVariant)
                            }
                            Box(Modifier.padding(top = 4.dp).fillMaxWidth(r.plays / top.toFloat()).height(4.dp)
                                .clip(RoundedCornerShape(2.dp)).background(MaterialTheme.colorScheme.primary.copy(alpha = 0.7f)))
                        }
                        Text("${r.plays}", style = MaterialTheme.typography.labelMedium,
                            color = MaterialTheme.colorScheme.onSurfaceVariant, modifier = Modifier.padding(start = 10.dp))
                    }
                }
            }
        }
    }
}

@Composable
private fun StatTile(label: String, value: String, modifier: Modifier = Modifier) {
    Column(modifier.tonal(corner = 18.dp).padding(14.dp)) {
        Text(value, style = MaterialTheme.typography.headlineSmall, color = MaterialTheme.colorScheme.primary)
        Text(label.uppercase(), style = Kicker, color = MaterialTheme.colorScheme.onSurfaceVariant)
    }
}

/** Songs from outside the library that belong beside one: to play one, or take it in. */
@Composable
fun SimilarScreen(trackId: Int, title: String, bottom: PaddingValues) {
    val store = LocalStore.current
    var hits by remember { mutableStateOf<List<dance.duckduck.wetowl.core.RemoteHit>?>(null) }
    var error by remember { mutableStateOf<String?>(null) }
    LaunchedEffect(trackId) {
        try { hits = store.api.similar(listOf(trackId)); error = null } catch (e: ApiError) { error = e.message }
    }
    Column(Modifier.fillMaxSize()) {
        PageBar("Like “$title”", "Not in your library yet")
        val l = hits
        when {
            l == null -> if (error != null) Empty(error!!) else Loading()
            l.isEmpty() -> Empty("Nothing found to go beside it.")
            else -> LazyColumn(contentPadding = bottom) {
                items(l, key = { it.videoId }) { h ->
                    Row(Modifier.fillMaxWidth().clickable {
                        store.launch { store.play(listOf(store.api.resolve(h)), 0, "Like $title") }
                    }.padding(horizontal = 18.dp, vertical = 7.dp), verticalAlignment = Alignment.CenterVertically) {
                        Artwork(store.api.absolute(h.coverUrl), 48.dp)
                        Spacer(Modifier.width(12.dp))
                        Column(Modifier.weight(1f)) {
                            Text(h.title, maxLines = 1, overflow = TextOverflow.Ellipsis, style = MaterialTheme.typography.titleSmall)
                            Text(listOfNotNull(h.artistLine, h.album).joinToString(" · "), maxLines = 1, overflow = TextOverflow.Ellipsis,
                                style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
                        }
                        IconButton(onClick = {
                            store.launch { store.playback.playNext(store.api.resolve(h)); notes(store, "Playing ${h.title} next") }
                        }) { Icon(Icons.Rounded.Add, "Play next", tint = MaterialTheme.colorScheme.primary) }
                    }
                }
            }
        }
    }
}
