package dance.duckduck.wetowl.ui

import androidx.compose.foundation.gestures.detectTapGestures
import androidx.compose.foundation.gestures.detectVerticalDragGestures
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.runtime.derivedStateOf
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.layout.onSizeChanged
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.withLock
import dance.duckduck.wetowl.core.Letter
import dance.duckduck.wetowl.core.letters
import dance.duckduck.wetowl.ui.theme.*
import androidx.compose.animation.animateColorAsState
import androidx.compose.foundation.clickable
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
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.grid.GridCells
import androidx.compose.foundation.lazy.grid.LazyVerticalGrid
import androidx.compose.foundation.lazy.grid.items
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.rounded.Favorite
import androidx.compose.material.icons.rounded.PlayArrow
import androidx.compose.material.icons.rounded.PushPin
import androidx.compose.material.icons.rounded.Shuffle
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import dance.duckduck.wetowl.core.AlbumSummary
import dance.duckduck.wetowl.core.ApiError
import dance.duckduck.wetowl.core.ArtistSummary
import dance.duckduck.wetowl.core.Playlist
import dance.duckduck.wetowl.core.Track

private val TABS = listOf("Playlists", "Artists", "Albums", "Songs")

/** A row of choices moulded as one well, the chosen one raised out of it. */
@Composable
fun Segments(options: List<String>, selected: Int, onSelect: (Int) -> Unit, modifier: Modifier = Modifier) {
    Row(modifier.fillMaxWidth().height(48.dp).well(corner = 18.dp).padding(5.dp)) {
        options.forEachIndexed { i, label ->
            val on = i == selected
            val colour by animateColorAsState(
                if (on) MaterialTheme.colorScheme.primary else MaterialTheme.colorScheme.onSurfaceVariant, label = "seg")
            Box(
                Modifier.weight(1f).fillMaxSize()
                    .then(if (on) Modifier.picked(corner = 14.dp) else Modifier)
                    .clip(RoundedCornerShape(14.dp))
                    .clickable { onSelect(i) },
                contentAlignment = Alignment.Center,
            ) { Text(label, style = MaterialTheme.typography.labelLarge, color = colour, maxLines = 1) }
        }
    }
}

@Composable
fun LibraryScreen(bottom: PaddingValues) {
    val store = LocalStore.current
    var tab by rememberSaveable { mutableIntStateOf(0) }
    Column(Modifier.fillMaxSize()) {
        Text("Library", style = MaterialTheme.typography.headlineLarge,
            modifier = Modifier.statusBarsPadding().padding(start = 20.dp, top = 16.dp))
        Segments(TABS, tab, { tab = it }, Modifier.padding(horizontal = 18.dp, vertical = 14.dp))
        when (tab) {
            0 -> PlaylistsTab(bottom)
            1 -> PagedList(bottom, "artists", { off -> store.api.artists(off).let { p -> p.items to p.total } },
                index = { store.api.letters("/library/artists/index") }) { a: ArtistSummary -> ArtistRow(a) }
            2 -> AlbumsTab(bottom)
            else -> SongsTab(bottom)
        }
    }
}

/** A list the house hands over a page at a time: what is here, how many there are, more on asking. */
class Pager<T>(private val fetch: suspend (Int) -> Pair<List<T>, Int>) {
    var items by mutableStateOf<List<T>>(emptyList())
    var total by mutableIntStateOf(-1)
    var error by mutableStateOf<String?>(null)
    private val lock = kotlinx.coroutines.sync.Mutex()

    val done get() = total >= 0 && items.size >= total

    suspend fun more() = lock.withLock {
        if (done) return@withLock
        try {
            val (got, t) = fetch(items.size)
            items = items + got
            total = if (got.isEmpty()) items.size else t
            error = null
        } catch (e: ApiError) { error = e.message }
    }

    /** At least [n] rows read (for a letter far down the list). */
    suspend fun upTo(n: Int) { while (!done && items.size <= n && error == null) more() }
}

@Composable
fun <T> rememberPager(key: Any, fetch: suspend (Int) -> Pair<List<T>, Int>): Pager<T> = remember(key) { Pager(fetch) }

/** Letters down the right edge of a long list: touch or drag to go there. */
@Composable
fun LetterRail(letters: List<Letter>, modifier: Modifier = Modifier, onPick: (Letter) -> Unit) {
    if (letters.size < 4) return
    var height by remember { mutableIntStateOf(1) }
    var last by remember { mutableStateOf<Letter?>(null) }
    fun at(y: Float) {
        val i = ((y / height) * letters.size).toInt().coerceIn(0, letters.size - 1)
        val l = letters[i]
        if (l != last) { last = l; onPick(l) }
    }
    Column(modifier.width(24.dp).fillMaxHeight().padding(vertical = 8.dp)
        .onSizeChanged { height = it.height.coerceAtLeast(1) }
        .pointerInput(letters) {
            detectTapGestures { at(it.y) }
        }
        .pointerInput(letters) {
            detectVerticalDragGestures(onDragEnd = { last = null }) { change, _ -> at(change.position.y) }
        },
        verticalArrangement = Arrangement.SpaceEvenly, horizontalAlignment = Alignment.CenterHorizontally) {
        letters.forEach { l ->
            Text(l.letter, style = MaterialTheme.typography.labelSmall,
                color = if (l == last) MaterialTheme.colorScheme.primary else MaterialTheme.colorScheme.onSurfaceVariant)
        }
    }
}

/** A list read from the house a page at a time, the next page asked for near the end; letters down the side when it has them. */
@Composable
private fun <T> PagedList(
    bottom: PaddingValues,
    key: Any,
    fetch: suspend (Int) -> Pair<List<T>, Int>,
    index: (suspend () -> List<Letter>)? = null,
    row: @Composable (T) -> Unit,
) {
    val pager = rememberPager(key, fetch)
    val list = androidx.compose.foundation.lazy.rememberLazyListState()
    val scope = androidx.compose.runtime.rememberCoroutineScope()
    var letters by remember(key) { mutableStateOf<List<Letter>>(emptyList()) }
    LaunchedEffect(key) { index?.let { runCatching { letters = it() } } }
    LaunchedEffect(pager) { if (pager.items.isEmpty()) pager.more() }
    val nearEnd by remember { derivedStateOf { (list.layoutInfo.visibleItemsInfo.lastOrNull()?.index ?: 0) > pager.items.size - 30 } }
    LaunchedEffect(nearEnd, pager.items.size) { if (nearEnd && !pager.done) pager.more() }
    when {
        pager.error != null && pager.items.isEmpty() -> ErrorRetry(pager.error!!, { scope.launch { pager.more() } })
        pager.items.isEmpty() && pager.total != 0 -> Loading()
        pager.items.isEmpty() -> Empty("Nothing here yet.")
        else -> Box(Modifier.fillMaxSize()) {
            LazyColumn(state = list, contentPadding = bottom, modifier = Modifier.fillMaxSize()) {
                items(pager.items.size) { i -> row(pager.items[i]) }
            }
            LetterRail(letters, Modifier.align(Alignment.CenterEnd).padding(bottom = bottom.calculateBottomPadding())) { l ->
                scope.launch { pager.upTo(l.offset); list.scrollToItem(l.offset.coerceAtMost(pager.items.size - 1)) }
            }
        }
    }
}

@Composable
private fun ArtistRow(a: ArtistSummary) {
    val go = LocalGo.current
    Row(Modifier.fillMaxWidth().clickable { go.artist(a.name) }.padding(start = 18.dp, end = 28.dp, top = 8.dp, bottom = 8.dp),
        verticalAlignment = Alignment.CenterVertically) {
        Box(Modifier.size(48.dp).well(circle = true), contentAlignment = Alignment.Center) {
            Text(a.name.take(1).uppercase(), style = MaterialTheme.typography.titleMedium, color = MaterialTheme.colorScheme.primary)
        }
        Spacer(Modifier.width(14.dp))
        Column(Modifier.weight(1f)) {
            Text(a.name, style = MaterialTheme.typography.titleSmall, maxLines = 1, overflow = TextOverflow.Ellipsis)
            Text("${a.tracks} songs · ${a.albums} records", style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant)
        }
    }
}

@Composable
private fun AlbumsTab(bottom: PaddingValues) {
    val store = LocalStore.current
    val go = LocalGo.current
    val pager = rememberPager("albums") { off -> store.api.albums(off).let { it.items to it.total } }
    val grid = androidx.compose.foundation.lazy.grid.rememberLazyGridState()
    val scope = androidx.compose.runtime.rememberCoroutineScope()
    var letters by remember { mutableStateOf<List<Letter>>(emptyList()) }
    LaunchedEffect(Unit) { runCatching { letters = store.api.letters("/library/albums/index") } }
    LaunchedEffect(pager) { if (pager.items.isEmpty()) pager.more() }
    val nearEnd by remember { derivedStateOf { (grid.layoutInfo.visibleItemsInfo.lastOrNull()?.index ?: 0) > pager.items.size - 20 } }
    LaunchedEffect(nearEnd, pager.items.size) { if (nearEnd && !pager.done) pager.more() }
    val list = pager.items
    when {
        pager.error != null && list.isEmpty() -> ErrorRetry(pager.error!!, { scope.launch { pager.more() } })
        list.isEmpty() && pager.total != 0 -> Loading()
        list.isEmpty() -> Empty("No records yet.")
        else -> Box(Modifier.fillMaxSize()) {
            LazyVerticalGrid(GridCells.Adaptive(150.dp), state = grid, contentPadding = PaddingValues(
                start = 18.dp, end = 30.dp, bottom = bottom.calculateBottomPadding()),
                horizontalArrangement = Arrangement.spacedBy(14.dp), verticalArrangement = Arrangement.spacedBy(16.dp)) {
                items(list.size, key = { i -> list[i].artist + "\u0001" + list[i].name + i }) { i ->
                    val a = list[i]
                    Column(Modifier.clickable { go.album(a.name, a.artist) }) {
                        Artwork(store.api.absolute(a.coverUrl), 160.dp, corner = 20.dp, modifier = Modifier.fillMaxWidth())
                        Spacer(Modifier.height(6.dp))
                        Text(a.name, style = MaterialTheme.typography.titleSmall, maxLines = 1, overflow = TextOverflow.Ellipsis)
                        Text(listOfNotNull(a.artist, a.year?.toString()).joinToString(" · "), maxLines = 1,
                            style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
                    }
                }
            }
            LetterRail(letters, Modifier.align(Alignment.CenterEnd).padding(bottom = bottom.calculateBottomPadding())) { l ->
                scope.launch { pager.upTo(l.offset); grid.scrollToItem(l.offset.coerceAtMost(pager.items.size - 1)) }
            }
        }
    }
}

private val SONG_SORTS = listOf("added" to "Recently added", "title" to "Title", "artist" to "Artist")

@Composable
private fun SongsTab(bottom: PaddingValues) {
    val store = LocalStore.current
    val now by store.playback.now.collectAsState()
    var sort by rememberSaveable { mutableStateOf("added") }
    Column {
        androidx.compose.foundation.lazy.LazyRow(contentPadding = PaddingValues(horizontal = 16.dp),
            horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            items(SONG_SORTS) { (k, label) ->
                androidx.compose.material3.FilterChip(selected = sort == k, onClick = { sort = k }, label = { Text(label) })
            }
        }
        var loaded by remember(sort) { mutableStateOf<List<Track>>(emptyList()) }
        PagedList(bottom, "songs:$sort", { offset: Int ->
            store.api.songs(offset, sort).let { p -> loaded = loaded + p.items; p.items to p.total }
        }, index = if (sort == "added") null else ({ store.api.letters("/library/tracks/index", mapOf("sort" to sort)) })) { t: Track ->
            SongRow(t, onClick = { store.play(loaded, loaded.indexOf(t).coerceAtLeast(0), "Library") },
                lit = t.id == now.track?.id, modifier = Modifier.padding(start = 8.dp, end = 22.dp))
        }
    }
}

/** The head of a list, a record or an artist: the art raised, the name, play/shuffle. */
@Composable
fun CollectionHead(
    art: String?,
    title: String,
    subtitle: String,
    onPlay: () -> Unit,
    onShuffle: () -> Unit,
    playEnabled: Boolean = true,
    kicker: String? = null,
    round: Boolean = false,
    extra: (@Composable () -> Unit)? = null,
) {
    Column(Modifier.fillMaxWidth().statusBarsPadding().padding(top = 56.dp), horizontalAlignment = Alignment.CenterHorizontally) {
        Box(Modifier.size(210.dp)) {
            Artwork(art, 190.dp, corner = if (round) 95.dp else 26.dp)
        }
        Spacer(Modifier.height(22.dp))
        kicker?.let { Text(it.uppercase(), style = dance.duckduck.wetowl.ui.theme.Kicker, color = MaterialTheme.colorScheme.primary) }
        Text(title, style = MaterialTheme.typography.headlineMedium, maxLines = 2, overflow = TextOverflow.Ellipsis,
            textAlign = androidx.compose.ui.text.style.TextAlign.Center, modifier = Modifier.padding(horizontal = 24.dp))
        Text(subtitle, style = MaterialTheme.typography.bodyMedium, color = MaterialTheme.colorScheme.onSurfaceVariant,
            modifier = Modifier.padding(top = 4.dp, start = 24.dp, end = 24.dp),
            textAlign = androidx.compose.ui.text.style.TextAlign.Center)
        Row(Modifier.padding(vertical = 18.dp), horizontalArrangement = Arrangement.spacedBy(22.dp),
            verticalAlignment = Alignment.CenterVertically) {
            RoundButton(Icons.Rounded.Shuffle, "Shuffle", onShuffle, size = 52.dp, enabled = playEnabled)
            RoundButton(Icons.Rounded.PlayArrow, "Play", onPlay, size = 68.dp, accent = true, enabled = playEnabled)
            extra?.invoke() ?: Spacer(Modifier.size(52.dp))
        }
    }
}
