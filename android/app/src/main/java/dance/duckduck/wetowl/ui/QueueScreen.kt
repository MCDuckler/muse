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
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.itemsIndexed
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.rounded.ArrowBack
import androidx.compose.material.icons.rounded.Add
import androidx.compose.material.icons.rounded.Delete
import androidx.compose.material.icons.rounded.DragIndicator
import androidx.compose.material.icons.rounded.GraphicEq
import androidx.compose.material.icons.rounded.Groups
import androidx.compose.material.icons.rounded.MoreVert
import androidx.compose.material.icons.rounded.PlayArrow
import androidx.compose.material.icons.rounded.Visibility
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import dance.duckduck.wetowl.core.tuneStation
import androidx.compose.material3.FilledTonalButton
import androidx.compose.material3.FilterChip
import androidx.compose.material3.FilterChipDefaults
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.SwipeToDismissBox
import androidx.compose.material3.SwipeToDismissBoxValue
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.rememberSwipeToDismissBoxState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import dance.duckduck.wetowl.core.ApiError
import dance.duckduck.wetowl.core.QueueState
import dance.duckduck.wetowl.core.Track
import kotlinx.coroutines.launch
import sh.calvin.reorderable.ReorderableItem
import sh.calvin.reorderable.rememberReorderableLazyListState

/**
 * The queues. The one playing, to reorder and prune while it plays; any other, looked
 * at — and edited — without being put on, until its Play button (or a song in it) is
 * pressed. [overlay] is what floats over the bottom of the screen (the mini player): the
 * list's edge, where a held row starts scrolling it, sits above that, not under it.
 */
@Composable
fun QueueScreen(overlay: Dp) {
    val store = LocalStore.current
    val go = LocalGo.current
    val now by store.playback.now.collectAsState()
    val queues by store.queues.collectAsState()
    var looking by remember { mutableStateOf<Int?>(null) }
    var naming by remember { mutableStateOf<QueueState?>(null) }
    var making by remember { mutableStateOf(false) }
    var jamOpen by remember { mutableStateOf(false) }
    if (jamOpen) JamSheet { jamOpen = false }
    LaunchedEffect(Unit) { store.refreshQueues() }
    val playingId = now.queue?.id

    Column(Modifier.fillMaxSize().statusBarsPadding()) {
        Row(Modifier.padding(start = 4.dp, end = 8.dp, top = 4.dp), verticalAlignment = Alignment.CenterVertically) {
            IconButton(onClick = go::back) { Icon(Icons.AutoMirrored.Rounded.ArrowBack, "Back") }
            Text("Up next", style = MaterialTheme.typography.titleLarge, modifier = Modifier.weight(1f))
            IconButton(onClick = { jamOpen = true }) { Icon(Icons.Rounded.Groups, "Listen together") }
        }
        JamBanner { jamOpen = true }
        LazyRow(contentPadding = PaddingValues(horizontal = 16.dp, vertical = 6.dp),
            horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            items(queues, key = { it.id }) { q ->
                val selected = q.id == (looking ?: playingId)
                FilterChip(
                    selected = selected,
                    onClick = { looking = if (q.id == playingId) null else q.id },
                    label = { Text(q.sharedFrom?.let { "$it's jam" } ?: "${q.name} · ${q.total}") },
                    leadingIcon = if (q.id == playingId && now.playing) {
                        { Icon(Icons.Rounded.GraphicEq, null, Modifier.size(16.dp)) }
                    } else null,
                    shape = RoundedCornerShape(14.dp),
                    colors = FilterChipDefaults.filterChipColors(
                        selectedContainerColor = MaterialTheme.colorScheme.primaryContainer,
                        selectedLabelColor = MaterialTheme.colorScheme.onPrimaryContainer,
                        selectedLeadingIconColor = MaterialTheme.colorScheme.primary),
                )
            }
            item {
                FilterChip(selected = false, onClick = { making = true }, label = { Text("New queue") },
                    leadingIcon = { Icon(Icons.Rounded.Add, null, Modifier.size(16.dp)) }, shape = RoundedCornerShape(14.dp))
            }
        }
        val id = looking
        if (id != null && id != playingId) {
            QueuePreview(id, overlay, onPlayed = { looking = null }, onRename = { naming = it })
        } else {
            PlayingQueue(overlay, onRename = { naming = it })
        }
    }

    naming?.let { q ->
        NameDialog("Rename queue", q.name, onDone = { name ->
            naming = null
            if (name != null && name != q.name) store.launch {
                val updated = store.api.renameQueue(q.id, name)
                store.playback.adopt(updated)
                store.refreshQueues()
            }
        })
    }
    if (making) NameDialog("New queue", "", onDone = { name ->
        making = false
        if (name != null) store.launch {
            val q = store.api.createQueue(name)
            store.refreshQueues()
            // A new queue is empty: put on, it would stop the music. Looked at instead.
            if (playingId == null) store.playback.open(q.id, autoplay = false) else looking = q.id
        }
    })
}

@Composable
private fun PlayingQueue(overlay: Dp, onRename: (QueueState) -> Unit) {
    val store = LocalStore.current
    val go = LocalGo.current
    val now by store.playback.now.collectAsState()
    val q = now.queue
    if (q == null || q.items.isEmpty()) {
        Empty("Nothing queued. Play a list, a record or a song, and it shows up here.")
        return
    }
    QueueHeader(
        text = buildString {
            append("${q.total} songs")
            if (q.isWindowed) append(" · showing ${q.items.size} around where you are")
        },
        playing = true,
        onPlay = null,
        menu = { close ->
            DropdownMenuItem({ Text("Rename…") }, onClick = { close(); onRename(q) })
            DropdownMenuItem({ Text("Save as playlist") }, onClick = {
                close(); store.launch {
                    store.api.saveQueueAsPlaylist(q.id, q.name); store.refreshPlaylists()
                    store.playback.notes.tryEmit("Saved “${q.name}”")
                }
            })
            val key = "queue:${q.id}"
            val kept = store.offline.kept.collectAsState().value.any { it.key == key }
            DropdownMenuItem({ Text(if (kept) "Stop keeping these on the phone" else "Keep this queue on the phone") }, onClick = {
                close()
                if (kept) store.offline.forget(key) else store.offline.keep(key, q.name, q.items)
            })
            now.track?.let { t ->
                DropdownMenuItem({ Text("Make a station from this song, without playing it") }, onClick = {
                    close(); store.launch { val p = store.api.startStation(trackId = t.id); store.refreshPlaylists(); go.playlist(p.id) }
                })
            }
            q.stationId?.let { sid ->
                listOf(0f to "Station: only songs I have", 0.5f to "Station: mine and new", 1f to "Station: mostly new to me").forEach { (v, label) ->
                    DropdownMenuItem({ Text(label) }, onClick = {
                        close(); store.launch { store.api.tuneStation(sid, v); store.playback.notes.tryEmit("From the next top-up on") }
                    })
                }
            }
            if (q.items.any { it.origin == "radio" }) DropdownMenuItem({ Text("Clear radio tracks") }, onClick = {
                close(); store.playback.clear(origin = "radio")
            })
            DropdownMenuItem({ Text("Clear queue") }, onClick = { close(); store.playback.clear() })
        },
    )
    QueueList(
        rows = q.items,
        litRow = now.row,
        overlay = overlay,
        onTap = { store.playback.jumpTo(it) },
        onMove = { from, to -> store.playback.move(from, to) },
        onRemove = { store.playback.remove(it) },
    )
}

/** Another queue, looked at: its rows edited straight on the house, nothing played. */
@Composable
private fun QueuePreview(id: Int, overlay: Dp, onPlayed: () -> Unit, onRename: (QueueState) -> Unit) {
    val store = LocalStore.current
    val scope = rememberCoroutineScope()
    var q by remember(id) { mutableStateOf<QueueState?>(null) }
    var error by remember(id) { mutableStateOf<String?>(null) }
    var confirmDelete by remember { mutableStateOf(false) }
    LaunchedEffect(id) {
        try { q = store.api.queue(id) } catch (e: ApiError) { error = e.message }
    }
    fun take(op: suspend () -> QueueState) = scope.launch {
        try { q = op(); store.refreshQueues() } catch (e: ApiError) {
            store.playback.notes.tryEmit(e.message)
            runCatching { q = store.api.queue(id) }
        }
    }
    val queue = q ?: run {
        if (error != null) ErrorRetry(error!!, { scope.launch { runCatching { q = store.api.queue(id) } } }) else Loading()
        return
    }
    QueueHeader(
        text = "Not playing · ${queue.total} songs",
        playing = false,
        onPlay = if (queue.items.isEmpty()) null else ({
            scope.launch { runCatching { store.playback.open(id) }; onPlayed() }
        }),
        menu = { close ->
            DropdownMenuItem({ Text("Rename…") }, onClick = { close(); onRename(queue) })
            DropdownMenuItem({ Text("Clear queue") }, onClick = { close(); take { store.api.clearQueue(id) } })
            DropdownMenuItem({ Text("Delete this queue") }, onClick = { close(); confirmDelete = true })
        },
    )
    if (queue.items.isEmpty()) { Empty("Nothing in this queue yet."); return }
    QueueList(
        rows = queue.items,
        litRow = -1,
        overlay = overlay,
        onTap = { row -> scope.launch { runCatching { store.playback.open(id, row = queue.windowFrom + row) }; onPlayed() } },
        onMove = { from, to ->
            q = queue.copy(items = queue.items.toMutableList().apply { add(to, removeAt(from)) })
            take { store.api.moveInQueue(id, queue.windowFrom + from, queue.windowFrom + to) }
        },
        onRemove = { row ->
            q = queue.copy(items = queue.items.filterIndexed { i, _ -> i != row }, total = queue.total - 1)
            take { store.api.removeFromQueue(id, queue.windowFrom + row) }
        },
    )
    if (confirmDelete) AlertDialog(
        onDismissRequest = { confirmDelete = false },
        title = { Text("Delete “${queue.name}”?") },
        text = { Text("The songs stay in your library; only the queue goes.") },
        confirmButton = { TextButton(onClick = {
            confirmDelete = false
            store.launch { store.api.deleteQueue(id); store.refreshQueues(); onPlayed() }
        }) { Text("Delete") } },
        dismissButton = { TextButton(onClick = { confirmDelete = false }) { Text("Cancel") } },
    )
}

@Composable
private fun QueueHeader(
    text: String,
    playing: Boolean,
    onPlay: (() -> Unit)?,
    menu: @Composable (close: () -> Unit) -> Unit,
) {
    var open by remember { mutableStateOf(false) }
    Row(Modifier.fillMaxWidth().padding(start = 20.dp, end = 4.dp, top = 6.dp, bottom = 4.dp),
        verticalAlignment = Alignment.CenterVertically) {
        if (!playing) Icon(Icons.Rounded.Visibility, null, tint = MaterialTheme.colorScheme.onSurfaceVariant,
            modifier = Modifier.size(18.dp).padding(end = 2.dp))
        Text(text, style = MaterialTheme.typography.bodyMedium, color = MaterialTheme.colorScheme.onSurfaceVariant,
            modifier = Modifier.weight(1f).padding(start = if (playing) 0.dp else 6.dp))
        if (onPlay != null) FilledTonalButton(onClick = onPlay) {
            Icon(Icons.Rounded.PlayArrow, null, Modifier.size(18.dp)); Spacer(Modifier.width(4.dp)); Text("Play")
        }
        Box {
            IconButton(onClick = { open = true }) { Icon(Icons.Rounded.MoreVert, "Queue actions") }
            DropdownMenu(open, onDismissRequest = { open = false }) { menu { open = false } }
        }
    }
}

/**
 * Rows to hold by the grip and drag, and to swipe away. While a row is held the order
 * changes on screen as it moves; the house is told once, when it is let go.
 */
@Composable
internal fun QueueList(
    rows: List<Track>,
    litRow: Int,
    overlay: Dp,
    onTap: (Int) -> Unit,
    onMove: ((Int, Int) -> Unit)?,
    onRemove: ((Int) -> Unit)?,
    header: (androidx.compose.foundation.lazy.LazyListScope.() -> Unit)? = null,
    footer: (androidx.compose.foundation.lazy.LazyListScope.() -> Unit)? = null,
    extraActions: ((Track) -> List<SheetAction>)? = null,
) {
    var shown by remember { mutableStateOf(rows) }
    var heldKey by remember { mutableStateOf<String?>(null) }
    var heldFrom by remember { mutableStateOf(-1) }
    LaunchedEffect(rows) { if (heldKey == null) shown = rows }
    val list = rememberLazyListState()
    val reorder = rememberReorderableLazyListState(
        list,
        // The edge a held row scrolls the list at is above the mini player, where a
        // finger can actually reach — not the bottom of the screen under it.
        scrollThresholdPadding = PaddingValues(bottom = overlay),
    ) { from, to ->
        val f = shown.indexOfFirst { it.rowKey == from.key }
        val t = shown.indexOfFirst { it.rowKey == to.key }
        if (f >= 0 && t >= 0) shown = shown.toMutableList().apply { add(t, removeAt(f)) }
    }
    LaunchedEffect(Unit) { if (litRow > 3 && header == null) list.scrollToItem(litRow - 2) }
    LazyColumn(state = list, contentPadding = PaddingValues(start = 8.dp, end = 8.dp, bottom = overlay + 16.dp),
        modifier = Modifier.fillMaxSize()) {
        header?.invoke(this)
        itemsIndexed(shown, key = { _, t -> t.rowKey }) { i, t ->
            ReorderableItem(reorder, key = t.rowKey, enabled = onMove != null) { dragging ->
                val swipe = rememberSwipeToDismissBoxState()
                LaunchedEffect(swipe.currentValue) {
                    if (swipe.currentValue == SwipeToDismissBoxValue.EndToStart) {
                        val at = rows.indexOfFirst { it.rowKey == t.rowKey }
                        if (at >= 0) onRemove?.invoke(at)
                    }
                }
                SwipeToDismissBox(
                    state = swipe,
                    enableDismissFromStartToEnd = false,
                    enableDismissFromEndToStart = onRemove != null,
                    backgroundContent = {
                        Box(Modifier.fillMaxSize().clip(RoundedCornerShape(16.dp))
                            .background(MaterialTheme.colorScheme.errorContainer.copy(alpha = 0.6f)).padding(end = 22.dp),
                            contentAlignment = Alignment.CenterEnd) {
                            Icon(Icons.Rounded.Delete, "Remove", tint = MaterialTheme.colorScheme.onErrorContainer)
                        }
                    },
                ) {
                    Box(Modifier.background(if (dragging) MaterialTheme.colorScheme.surfaceContainerHighest
                        else MaterialTheme.colorScheme.background, RoundedCornerShape(16.dp))) {
                        SongRow(
                            t,
                            onClick = { onTap(rows.indexOfFirst { it.rowKey == t.rowKey }.coerceAtLeast(0)) },
                            lit = t.rowKey == rows.getOrNull(litRow)?.rowKey,
                            extraActions = extraActions?.invoke(t).orEmpty(),
                            leading = if (onMove == null) null else {{
                                Icon(Icons.Rounded.DragIndicator, "Hold to move",
                                    tint = MaterialTheme.colorScheme.outline,
                                    modifier = Modifier.draggableHandle(
                                        onDragStarted = { heldKey = t.rowKey; heldFrom = rows.indexOfFirst { it.rowKey == t.rowKey } },
                                        onDragStopped = {
                                            val to = shown.indexOfFirst { it.rowKey == heldKey }
                                            if (heldFrom >= 0 && to >= 0 && to != heldFrom) onMove?.invoke(heldFrom, to)
                                            heldKey = null
                                        },
                                    ).padding(end = 6.dp).size(22.dp))
                            }},
                        )
                    }
                }
            }
        }
        footer?.invoke(this)
    }
}

@Composable
fun NameDialog(title: String, initial: String, onDone: (String?) -> Unit) {
    var name by remember { mutableStateOf(initial) }
    AlertDialog(
        onDismissRequest = { onDone(null) },
        title = { Text(title) },
        text = { OutlinedTextField(name, { name = it }, singleLine = true) },
        confirmButton = { TextButton(enabled = name.isNotBlank(), onClick = { onDone(name.trim()) }) { Text("OK") } },
        dismissButton = { TextButton(onClick = { onDone(null) }) { Text("Cancel") } },
    )
}
