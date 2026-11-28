package dance.duckduck.wetowl.ui

import android.net.Uri
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
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.rounded.QueueMusic
import androidx.compose.material.icons.rounded.Add
import androidx.compose.material.icons.rounded.Album
import androidx.compose.material.icons.rounded.Close
import androidx.compose.material.icons.rounded.Folder
import androidx.compose.material.icons.rounded.History
import androidx.compose.material.icons.rounded.LibraryMusic
import androidx.compose.material.icons.rounded.Lyrics
import androidx.compose.material.icons.rounded.Person
import androidx.compose.material.icons.rounded.Search
import androidx.compose.material.icons.rounded.Storefront
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.FilterChip
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.platform.LocalFocusManager
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import dance.duckduck.wetowl.core.ApiError
import dance.duckduck.wetowl.core.Found
import dance.duckduck.wetowl.core.FoundAlbum
import dance.duckduck.wetowl.core.Track
import dance.duckduck.wetowl.core.addFound
import dance.duckduck.wetowl.core.foundAlbum
import dance.duckduck.wetowl.core.searchEverything
import dance.duckduck.wetowl.ui.theme.RoundButton
import dance.duckduck.wetowl.ui.theme.well
import kotlinx.coroutines.delay

private val PLACES = listOf(
    "all" to "Everywhere", "library" to "Library", "ytmusic" to "YouTube Music", "youtube" to "YouTube",
    "spotify" to "Spotify", "soundcloud" to "SoundCloud", "bandcamp" to "Bandcamp",
)
private val KINDS = listOf(
    "all" to "All", "song" to "Songs", "video" to "Videos", "album" to "Records", "artist" to "Artists",
    "label" to "Labels", "playlist" to "Playlists",
)
val PLACE_NAMES = PLACES.toMap() + mapOf("library" to "your library")

/**
 * One field, one ranked list from everywhere: the library, YouTube Music, Spotify,
 * SoundCloud, Bandcamp. Narrowed by where and by what; words too, when asked.
 */
@Composable
fun SearchScreen(bottom: PaddingValues, initial: String = "") {
    val store = LocalStore.current
    val go = LocalGo.current
    var q by rememberSaveable { mutableStateOf(initial) }
    var where by rememberSaveable { mutableStateOf("all") }
    var kind by rememberSaveable { mutableStateOf("all") }
    var words by rememberSaveable { mutableStateOf(false) }
    var results by remember { mutableStateOf<List<Found>?>(null) }
    var notes by remember { mutableStateOf<Map<String, String>>(emptyMap()) }
    var looking by remember { mutableStateOf(false) }
    var error by remember { mutableStateOf<String?>(null) }
    var attempt by remember { mutableIntStateOf(0) }
    var recent by remember { mutableStateOf(store.prefs.recentSearches) }
    val focus = LocalFocusManager.current
    val field = remember { FocusRequester() }

    fun remember(text: String) {
        val t = text.trim(); if (t.length < 2) return
        recent = (listOf(t) + recent.filter { !it.equals(t, true) }).take(12)
        store.prefs.recentSearches = recent
    }

    LaunchedEffect(q, where, kind, words, attempt) {
        val asked = q.trim()
        if (asked.length < 2) { results = null; error = null; return@LaunchedEffect }
        delay(350)
        looking = true
        try {
            val (items, n) = store.api.searchEverything(asked, where, if (words) "song" else kind, words)
            results = items; notes = n; error = null
        } catch (e: ApiError) { error = e.message } finally { looking = false }
    }

    LazyColumn(contentPadding = bottom) {
        item {
            Row(
                Modifier.statusBarsPadding().padding(horizontal = 18.dp, vertical = 14.dp).fillMaxWidth().height(56.dp)
                    .well(corner = 28.dp).padding(horizontal = 16.dp),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Icon(Icons.Rounded.Search, null, tint = MaterialTheme.colorScheme.onSurfaceVariant)
                Spacer(Modifier.width(10.dp))
                Box(Modifier.weight(1f)) {
                    if (q.isEmpty()) Text(if (words) "Words from a song" else "Songs, records, artists, anywhere",
                        color = MaterialTheme.colorScheme.onSurfaceVariant)
                    BasicTextField(q, { q = it }, singleLine = true,
                        textStyle = MaterialTheme.typography.bodyLarge.copy(color = MaterialTheme.colorScheme.onSurface),
                        cursorBrush = SolidColor(MaterialTheme.colorScheme.primary),
                        keyboardOptions = KeyboardOptions(imeAction = ImeAction.Search),
                        keyboardActions = KeyboardActions(onSearch = { remember(q); focus.clearFocus() }),
                        modifier = Modifier.fillMaxWidth().focusRequester(field))
                }
                if (looking) CircularProgressIndicator(Modifier.size(18.dp), strokeWidth = 2.dp)
                else if (q.isNotEmpty()) IconButton(onClick = { q = "" }) { Icon(Icons.Rounded.Close, "Clear") }
            }
        }
        item {
            LazyRow(contentPadding = PaddingValues(horizontal = 16.dp), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                item {
                    FilterChip(selected = words, onClick = { words = !words }, label = { Text("Words") },
                        leadingIcon = { Icon(Icons.Rounded.Lyrics, null, Modifier.size(16.dp)) })
                }
                items(PLACES, key = { "p" + it.first }) { (k, label) ->
                    FilterChip(selected = where == k, onClick = { where = k }, label = { Text(label) })
                }
            }
        }
        if (!words) item {
            LazyRow(contentPadding = PaddingValues(horizontal = 16.dp), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                items(KINDS, key = { "k" + it.first }) { (k, label) ->
                    FilterChip(selected = kind == k, onClick = { kind = k }, label = { Text(label) })
                }
            }
        }
        error?.let { item { ErrorRetry(it, onRetry = { attempt++ }) } }
        val r = results
        if (r != null) {
            if (r.isEmpty() && !looking) item { Empty("Nothing for “$q”.") }
            items(r, key = { "${it.kind}:${it.place}:${it.id}" }) { f -> FoundRow(f) { remember(q) } }
            notes.forEach { (place, note) ->
                item(key = "note$place") {
                    Text("${PLACE_NAMES[place] ?: place}: $note", style = MaterialTheme.typography.bodySmall,
                        color = MaterialTheme.colorScheme.onSurfaceVariant, modifier = Modifier.padding(horizontal = 20.dp, vertical = 6.dp))
                }
            }
        } else if (q.isBlank()) {
            if (recent.isNotEmpty()) {
                item { SectionLabel("Lately") { androidx.compose.material3.TextButton(onClick = {
                    recent = emptyList(); store.prefs.recentSearches = emptyList()
                }) { Text("Clear") } } }
                items(recent, key = { "r$it" }) { text ->
                    Row(Modifier.fillMaxWidth().clickable { q = text }.padding(horizontal = 20.dp, vertical = 12.dp),
                        verticalAlignment = Alignment.CenterVertically) {
                        Icon(Icons.Rounded.History, null, tint = MaterialTheme.colorScheme.onSurfaceVariant, modifier = Modifier.size(20.dp))
                        Spacer(Modifier.width(14.dp))
                        Text(text, style = MaterialTheme.typography.bodyLarge)
                    }
                }
            } else item { Empty("Search the library and everywhere else at once. Something from out there is fetched as it plays.") }
        }
    }
}

/** Play a found song now: from the library at once, from elsewhere fetched as it comes. */
private fun playFound(store: dance.duckduck.wetowl.Store, f: Found) {
    store.launch {
        val t = f.track ?: store.api.addFound(f)
        store.play(listOf(t), 0, "Search")
        if (!t.isReady) store.playback.notes.tryEmit("Fetching “${f.title}” — it plays as soon as it is here")
    }
}

@Composable
private fun FoundRow(f: Found, onUsed: () -> Unit) {
    val store = LocalStore.current
    val go = LocalGo.current
    val now by store.playback.now.collectAsState()
    if (f.track != null && f.plays) {
        SongRow(f.track, onClick = { onUsed(); store.play(listOf(f.track), 0, "Search") }, lit = f.track.id == now.track?.id,
            subtitle = f.lyric?.let { "“$it”" }, modifier = Modifier.padding(horizontal = 8.dp))
        return
    }
    val round = f.kind == "artist" || f.kind == "label"
    Row(Modifier.fillMaxWidth().clickable {
        onUsed()
        when (f.kind) {
            "artist" -> go.artist(f.title)
            "label" -> go.open("bandcamp?url=${Uri.encode(f.id)}&name=${Uri.encode(f.title)}")
            "playlist" -> f.id.toIntOrNull()?.let(go::playlist)
            "folder" -> f.id.toIntOrNull()?.let { go.open("folder/$it") }
            "album" -> if (f.place == "library") go.album(f.title, f.subtitle)
                else go.open("found-album?place=${f.place}&id=${Uri.encode(f.id)}")
            else -> playFound(store, f)
        }
    }.padding(horizontal = 18.dp, vertical = 7.dp), verticalAlignment = Alignment.CenterVertically) {
        if (f.coverUrl != null) Artwork(store.api.absolute(f.coverUrl), 48.dp, corner = if (round) 24.dp else 10.dp)
        else Box(Modifier.size(48.dp).clip(CircleShape).well(circle = true), contentAlignment = Alignment.Center) {
            Icon(when (f.kind) {
                "artist" -> Icons.Rounded.Person; "album" -> Icons.Rounded.Album; "label" -> Icons.Rounded.Storefront
                "playlist" -> Icons.AutoMirrored.Rounded.QueueMusic; "folder" -> Icons.Rounded.Folder
                else -> Icons.Rounded.LibraryMusic
            }, null, tint = MaterialTheme.colorScheme.primary)
        }
        Spacer(Modifier.width(12.dp))
        Column(Modifier.weight(1f)) {
            Text(f.title, maxLines = 1, overflow = TextOverflow.Ellipsis, style = MaterialTheme.typography.titleSmall)
            val kindWord = when (f.kind) { "album" -> "Record"; "artist" -> "Artist"; "label" -> "Label"
                "playlist" -> "Playlist"; "folder" -> "Folder"; "video" -> "Video"; else -> null }
            Text(f.lyric?.let { "“$it”" } ?: listOfNotNull(kindWord, f.subtitle.ifBlank { null }, f.year,
                PLACE_NAMES[f.place]?.takeIf { f.place != "library" }).joinToString(" · "),
                maxLines = 1, overflow = TextOverflow.Ellipsis,
                style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
        }
        if (f.plays) {
            Text(formatTime(f.durationMs), style = MaterialTheme.typography.labelSmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant)
            IconButton(onClick = {
                onUsed()
                store.launch {
                    store.playback.playNext(f.track ?: store.api.addFound(f))
                    store.playback.notes.tryEmit("Playing ${f.title} next")
                }
            }) { Icon(Icons.Rounded.Add, "Play next", tint = MaterialTheme.colorScheme.primary) }
        }
    }
}

/** A record found somewhere else, opened: what is on it, to play or take in whole. */
@Composable
fun FoundAlbumScreen(place: String, id: String, bottom: PaddingValues) {
    val store = LocalStore.current
    var a by remember { mutableStateOf<FoundAlbum?>(null) }
    var error by remember { mutableStateOf<String?>(null) }
    var attempt by remember { mutableIntStateOf(0) }
    var taking by remember { mutableStateOf(false) }
    LaunchedEffect(place, id, attempt) {
        try { a = store.api.foundAlbum(place, id); error = null } catch (e: ApiError) { error = e.message }
    }
    val al = a
    Box(Modifier.fillMaxSize()) {
        if (al == null) Box(Modifier.statusBarsPadding().padding(top = 56.dp)) {
            if (error != null) ErrorRetry(error!!, { attempt++ }) else Loading()
        } else {
            suspend fun takeAll(): List<Track> = al.tracks.filter { it.plays }.map { it.track ?: store.api.addFound(it) }
            LazyColumn(contentPadding = bottom) {
                item {
                    CollectionHead(store.api.absolute(al.coverUrl), al.title,
                        listOfNotNull(al.artist, al.year, "${al.tracks.size} songs", PLACE_NAMES[place]).joinToString(" · "),
                        kicker = "Record",
                        onPlay = { taking = true; store.launch { try { store.play(takeAll(), 0, al.title) } finally { taking = false } } },
                        onShuffle = { taking = true; store.launch { try { store.play(takeAll().shuffled(), 0, al.title) } finally { taking = false } } },
                        playEnabled = !taking && al.tracks.isNotEmpty(),
                        extra = {
                            RoundButton(Icons.Rounded.Add, "Add the whole record to the library", {
                                taking = true
                                store.launch {
                                    try {
                                        val got = takeAll()
                                        store.playback.notes.tryEmit("Taking in ${got.size} songs from ${al.title}")
                                    } finally { taking = false }
                                }
                            }, size = 52.dp, enabled = !taking)
                        })
                }
                items(al.tracks, key = { "t" + it.id }) { f -> FoundRow(f) {} }
            }
        }
        FloatingTop()
    }
}
