package dance.duckduck.wetowl.ui

import android.net.Uri
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.FlowRow
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
import androidx.compose.foundation.lazy.itemsIndexed
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.rounded.Add
import androidx.compose.material.icons.rounded.BookmarkAdd
import androidx.compose.material.icons.rounded.Check
import androidx.compose.material.icons.rounded.Close
import androidx.compose.material.icons.rounded.Group
import androidx.compose.material.icons.rounded.PlayArrow
import androidx.compose.material.icons.rounded.Radio
import androidx.compose.material.icons.rounded.Refresh
import androidx.compose.material.icons.rounded.Search
import androidx.compose.material.icons.rounded.ViewDay
import androidx.compose.material3.AssistChip
import androidx.compose.material3.AssistChipDefaults
import androidx.compose.material3.FilterChip
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
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
import dance.duckduck.wetowl.core.DiscoverPage
import dance.duckduck.wetowl.core.FeedItem
import dance.duckduck.wetowl.core.Follow
import dance.duckduck.wetowl.core.MadeList
import dance.duckduck.wetowl.core.discover
import dance.duckduck.wetowl.core.feedRefresh
import dance.duckduck.wetowl.core.feedSeen
import dance.duckduck.wetowl.core.followGenre
import dance.duckduck.wetowl.core.followSources
import dance.duckduck.wetowl.core.follows
import dance.duckduck.wetowl.core.genres
import dance.duckduck.wetowl.core.importFollows
import dance.duckduck.wetowl.core.keepMadeList
import dance.duckduck.wetowl.core.madeList
import dance.duckduck.wetowl.core.rebuildMadeLists
import dance.duckduck.wetowl.core.startStationOf
import dance.duckduck.wetowl.core.trackCover
import dance.duckduck.wetowl.core.unfollowGenre
import dance.duckduck.wetowl.ui.theme.Kicker
import dance.duckduck.wetowl.ui.theme.RoundButton
import dance.duckduck.wetowl.ui.theme.tonal
import kotlinx.coroutines.delay

/** Play a station made from something, once the house has made it. */
internal fun playStation(store: dance.duckduck.wetowl.Store, make: suspend () -> dance.duckduck.wetowl.core.Playlist) {
    store.launch {
        val p = make()
        val list = p.tracks ?: store.api.playlist(p.id).tracks.orEmpty()
        store.play(list, 0, p.name)
    }
}

/**
 * What is new for you: lists the house made, records out from who you follow, stations
 * to go back to or start, genres, and acts to try.
 */
@Composable
fun DiscoverScreen(bottom: PaddingValues) {
    val store = LocalStore.current
    val go = LocalGo.current
    var page by remember { mutableStateOf<DiscoverPage?>(null) }
    var error by remember { mutableStateOf<String?>(null) }
    var attempt by remember { mutableIntStateOf(0) }
    var rebuilding by remember { mutableStateOf(false) }
    val tick by store.libraryTick.collectAsState()
    LaunchedEffect(attempt, tick) {
        try { page = store.api.discover(); error = null } catch (e: ApiError) { error = e.message }
    }
    // Lists still being made: asked again until they are.
    LaunchedEffect(page?.building) {
        if (page?.building == true) { delay(8000); attempt++ }
    }
    // What was in view counts as seen — said once the page has been open a moment.
    LaunchedEffect(page?.feed) {
        val unseen = page?.feed?.filter { it.unseen }.orEmpty()
        if (unseen.isNotEmpty()) { delay(4000); runCatching { store.api.feedSeen(unseen) } }
    }
    val p = page
    LazyColumn(contentPadding = bottom) {
        item {
            Row(Modifier.statusBarsPadding().padding(start = 20.dp, end = 8.dp, top = 16.dp), verticalAlignment = Alignment.CenterVertically) {
                Text("Discover", style = MaterialTheme.typography.headlineLarge, modifier = Modifier.weight(1f))
                IconButton(onClick = { go.open("cards") }) { Icon(Icons.Rounded.ViewDay, "One song at a time") }
                IconButton(onClick = { go.open("follows") }) { Icon(Icons.Rounded.Group, "Who you follow") }
                IconButton(onClick = { go.open("genres") }) { Icon(Icons.Rounded.Search, "Genres") }
            }
        }
        if (p == null) {
            item { if (error != null) ErrorRetry(error!!, { attempt++ }) else Loading() }
            return@LazyColumn
        }
        item {
            SectionLabel("Made for you") {
                TextButton(enabled = !rebuilding, onClick = {
                    rebuilding = true
                    store.launch { try { store.api.rebuildMadeLists(); attempt++ } finally { rebuilding = false } }
                }) { Text(if (rebuilding) "Making…" else "Make again") }
            }
        }
        if (p.lists.isEmpty()) item {
            Empty(if (p.building) "Your lists are being made — a minute or so." else "Nothing made yet. Play some music first.")
        } else item {
            LazyRow(contentPadding = PaddingValues(horizontal = 18.dp), horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                items(p.lists, key = { it.slug }) { l -> MadeCard(l) }
            }
        }
        if (p.feed.isNotEmpty()) {
            item {
                SectionLabel("New from who you follow") {
                    IconButton(onClick = { store.launch { store.api.feedRefresh(); delay(1500); attempt++ } }) {
                        Icon(Icons.Rounded.Refresh, "Look for new records")
                    }
                }
            }
            items(p.feed.take(30), key = { "f${it.provider}${it.albumId}${it.releaseMbid}${it.title}" }) { f -> FeedRow(f) }
        }
        if (p.yourStations.isNotEmpty() || p.starterArtists.isNotEmpty()) {
            item { SectionLabel("Stations") }
            item {
                LazyRow(contentPadding = PaddingValues(horizontal = 18.dp), horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                    items(p.yourStations, key = { "s${it.id}" }) { s ->
                        Tile(store.api.trackCover(s.coverTrack), s.name, "${s.count} songs · yours") { go.playlist(s.playlistId) }
                    }
                    items(p.starterArtists, key = { "a${it.name}" }) { a ->
                        Tile(store.api.trackCover(a.coverTrack), a.name, "Start a station", round = true) {
                            playStation(store) { store.api.startStationOf("artist", artist = a.name) }
                        }
                    }
                }
            }
        }
        if (p.genres.isNotEmpty()) {
            item { SectionLabel("Genre stations") }
            item {
                FlowRow(Modifier.padding(horizontal = 18.dp), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    p.genres.forEach { g ->
                        AssistChip(onClick = { playStation(store) { store.api.startStationOf("genre", genre = g.genre) } },
                            label = { Text(g.genre) },
                            leadingIcon = { Icon(Icons.Rounded.Radio, null, Modifier.size(AssistChipDefaults.IconSize)) })
                    }
                }
            }
        }
        if (p.acts.isNotEmpty()) {
            item { SectionLabel("Acts to try") }
            items(p.acts.take(10), key = { "act${it.name}" }) { a ->
                Row(Modifier.fillMaxWidth().clickable { go.artist(a.name) }.padding(horizontal = 18.dp, vertical = 8.dp),
                    verticalAlignment = Alignment.CenterVertically) {
                    Box(Modifier.size(44.dp).clip(CircleShape).background(MaterialTheme.colorScheme.secondaryContainer),
                        contentAlignment = Alignment.Center) {
                        Text(a.name.take(1).uppercase(), color = MaterialTheme.colorScheme.onSecondaryContainer)
                    }
                    Spacer(Modifier.width(12.dp))
                    Column(Modifier.weight(1f)) {
                        Text(a.name, style = MaterialTheme.typography.titleSmall)
                        a.because.firstOrNull()?.let {
                            Text(it, style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant,
                                maxLines = 1, overflow = TextOverflow.Ellipsis)
                        }
                    }
                }
            }
        }
    }
}

@Composable
private fun Tile(art: String?, title: String, sub: String, round: Boolean = false, onClick: () -> Unit) {
    Column(Modifier.width(140.dp).clickable(onClick = onClick)) {
        Artwork(art, 140.dp, corner = if (round) 70.dp else 18.dp)
        Spacer(Modifier.height(6.dp))
        Text(title, style = MaterialTheme.typography.titleSmall, maxLines = 1, overflow = TextOverflow.Ellipsis)
        Text(sub, style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant, maxLines = 1)
    }
}

@Composable
private fun MadeCard(l: MadeList) {
    val store = LocalStore.current
    val go = LocalGo.current
    Column(Modifier.width(168.dp).tonal(corner = 22.dp).clickable { go.open("made/${Uri.encode(l.slug)}") }.padding(12.dp)) {
        // Four covers of what is on it, as a square.
        Box(Modifier.size(144.dp).clip(androidx.compose.foundation.shape.RoundedCornerShape(14.dp))) {
            val covers = l.tracks.take(4)
            if (covers.size < 4) Artwork(covers.firstOrNull()?.let { store.api.coverUrl(it) }, 144.dp, corner = 14.dp)
            else Column {
                Row { TrackArt(covers[0], 72.dp, corner = 0.dp); TrackArt(covers[1], 72.dp, corner = 0.dp) }
                Row { TrackArt(covers[2], 72.dp, corner = 0.dp); TrackArt(covers[3], 72.dp, corner = 0.dp) }
            }
            Box(Modifier.align(Alignment.BottomEnd).padding(6.dp)) {
                RoundButton(Icons.Rounded.PlayArrow, "Play ${l.name}", { store.play(l.tracks, 0, l.name) }, size = 38.dp, accent = true)
            }
        }
        Spacer(Modifier.height(8.dp))
        Text(l.name, style = MaterialTheme.typography.titleSmall, maxLines = 1, overflow = TextOverflow.Ellipsis)
        Text(l.blurb.ifBlank { "${l.count} songs" }, style = MaterialTheme.typography.bodySmall,
            color = MaterialTheme.colorScheme.onSurfaceVariant, maxLines = 2, overflow = TextOverflow.Ellipsis)
    }
}

@Composable
private fun FeedRow(f: FeedItem) {
    val store = LocalStore.current
    val go = LocalGo.current
    Row(Modifier.fillMaxWidth().clickable {
        openFeedItem(go, f)
    }.padding(horizontal = 18.dp, vertical = 7.dp), verticalAlignment = Alignment.CenterVertically) {
        Box {
            Artwork(store.api.absolute(f.cover), 56.dp, corner = 12.dp)
            if (f.unseen) Box(Modifier.align(Alignment.TopEnd).padding(3.dp).size(10.dp).clip(CircleShape)
                .background(MaterialTheme.colorScheme.primary))
        }
        Spacer(Modifier.width(12.dp))
        Column(Modifier.weight(1f)) {
            Text(f.title, style = MaterialTheme.typography.titleSmall, maxLines = 1, overflow = TextOverflow.Ellipsis)
            Text(listOfNotNull(f.artist, f.via?.let { "via $it" }, f.genre).joinToString(" · "),
                style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant,
                maxLines = 1, overflow = TextOverflow.Ellipsis)
            Text(listOfNotNull(f.recordType?.uppercase(), if (f.upcoming) "OUT ${f.releaseDate}" else f.releaseDate,
                if (f.inLibrary) "IN YOUR LIBRARY" else null).joinToString(" · "),
                style = Kicker, color = if (f.upcoming) MaterialTheme.colorScheme.primary else MaterialTheme.colorScheme.outline)
        }
    }
}

/** One list the house made: play it, keep it as a playlist of your own. */
@Composable
fun MadeListScreen(slug: String, bottom: PaddingValues) {
    val store = LocalStore.current
    val go = LocalGo.current
    val now by store.playback.now.collectAsState()
    var l by remember { mutableStateOf<MadeList?>(null) }
    var error by remember { mutableStateOf<String?>(null) }
    var attempt by remember { mutableIntStateOf(0) }
    LaunchedEffect(slug, attempt) {
        try { l = store.api.madeList(slug); error = null } catch (e: ApiError) { error = e.message }
    }
    val list = l
    Box(Modifier.fillMaxSize()) {
        if (list == null) Box(Modifier.statusBarsPadding().padding(top = 56.dp)) {
            if (error != null) ErrorRetry(error!!, { attempt++ }) else Loading()
        } else LazyColumn(contentPadding = bottom) {
            item {
                CollectionHead(list.tracks.firstOrNull()?.let { store.api.coverUrl(it, small = false) }, list.name,
                    listOfNotNull(list.blurb.ifBlank { null }, "${list.tracks.size} songs", list.minutes?.let { "$it min" })
                        .joinToString(" · "),
                    kicker = "Made for you",
                    onPlay = { store.play(list.tracks, 0, list.name) },
                    onShuffle = { store.play(list.tracks.shuffled(), 0, list.name) },
                    playEnabled = list.tracks.isNotEmpty(),
                    extra = {
                        RoundButton(Icons.Rounded.BookmarkAdd, "Keep as a playlist", {
                            store.launch {
                                val id = store.api.keepMadeList(slug)
                                store.refreshPlaylists()
                                store.playback.notes.tryEmit("Kept as a playlist")
                                id?.let(go::playlist)
                            }
                        }, size = 52.dp)
                    })
            }
            itemsIndexed(list.tracks, key = { i, t -> "$i-${t.id}" }) { i, t ->
                SongRow(t, onClick = { store.play(list.tracks, i, list.name) }, lit = t.id == now.track?.id,
                    modifier = Modifier.padding(horizontal = 8.dp))
            }
        }
        FloatingTop()
    }
}

/** The genres you follow (their records come into the feed), and finding more. */
@Composable
fun GenresScreen(bottom: PaddingValues) {
    val store = LocalStore.current
    var q by remember { mutableStateOf("") }
    var following by remember { mutableStateOf<List<String>>(emptyList()) }
    var offered by remember { mutableStateOf<List<String>>(emptyList()) }
    var attempt by remember { mutableIntStateOf(0) }
    LaunchedEffect(q, attempt) {
        if (q.isNotBlank()) delay(300)
        runCatching {
            val (f, s, found) = store.api.genres(q.trim().ifEmpty { null })
            following = f; offered = (s + found).distinct().filter { it !in f }
        }
    }
    fun toggle(g: String, on: Boolean) {
        following = if (on) following + g else following - g
        store.launch { if (on) store.api.followGenre(g) else store.api.unfollowGenre(g); attempt++ }
    }
    Column(Modifier.fillMaxSize()) {
        PageBar("Genres", "Records in the genres you follow come into your feed")
        LazyColumn(contentPadding = bottom) {
            item {
                OutlinedTextField(q, { q = it }, label = { Text("Find a genre") }, singleLine = true,
                    modifier = Modifier.fillMaxWidth().padding(horizontal = 18.dp))
            }
            if (following.isNotEmpty()) {
                item { SectionLabel("Following") }
                item {
                    FlowRow(Modifier.padding(horizontal = 18.dp), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                        following.forEach { g ->
                            FilterChip(selected = true, onClick = { toggle(g, false) }, label = { Text(g) },
                                leadingIcon = { Icon(Icons.Rounded.Check, null, Modifier.size(16.dp)) })
                        }
                    }
                }
            }
            item { SectionLabel(if (q.isBlank()) "You might like" else "Found") }
            item {
                FlowRow(Modifier.padding(horizontal = 18.dp), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    offered.forEach { g ->
                        FilterChip(selected = false, onClick = { toggle(g, true) }, label = { Text(g) },
                            leadingIcon = { Icon(Icons.Rounded.Add, null, Modifier.size(16.dp)) })
                    }
                }
            }
        }
    }
}

/** Who you follow, and bringing in who you follow elsewhere. */
@Composable
fun FollowsScreen(bottom: PaddingValues) {
    val store = LocalStore.current
    val go = LocalGo.current
    var list by remember { mutableStateOf<List<Follow>?>(null) }
    var sources by remember { mutableStateOf<List<Pair<String, String>>>(emptyList()) }
    var attempt by remember { mutableIntStateOf(0) }
    var importing by remember { mutableStateOf<String?>(null) }
    LaunchedEffect(attempt) {
        runCatching { list = store.api.follows() }
        runCatching { sources = store.api.followSources() }
    }
    Column(Modifier.fillMaxSize()) {
        PageBar("Following", list?.let { "${it.size} artists and labels" })
        LazyColumn(contentPadding = bottom) {
            if (sources.isNotEmpty()) {
                item { SectionLabel("Bring in who you follow on") }
                item {
                    FlowRow(Modifier.padding(horizontal = 18.dp), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                        sources.forEach { (provider, label) ->
                            AssistChip(enabled = importing == null, onClick = {
                                importing = provider
                                store.launch {
                                    try {
                                        val (n, missed) = store.api.importFollows(provider)
                                        store.playback.notes.tryEmit("Followed $n more" +
                                            if (missed.isNotEmpty()) " · ${missed.size} not found" else "")
                                        attempt++
                                    } finally { importing = null }
                                }
                            }, label = { Text(if (importing == provider) "Bringing in…" else label) })
                        }
                    }
                }
            }
            val l = list
            when {
                l == null -> item { Loading() }
                l.isEmpty() -> item { Empty("Nobody yet. Follow an artist from their page and their new records show up in Discover.") }
                else -> items(l, key = { "${it.provider}:${it.remoteId}" }) { f ->
                    Row(Modifier.fillMaxWidth().clickable { go.artist(f.name) }.padding(horizontal = 18.dp, vertical = 6.dp),
                        verticalAlignment = Alignment.CenterVertically) {
                        Artwork(store.api.absolute(f.image), 48.dp, corner = 24.dp)
                        Spacer(Modifier.width(12.dp))
                        Column(Modifier.weight(1f)) {
                            Text(f.name, style = MaterialTheme.typography.titleSmall)
                            Text(listOfNotNull(if (f.isLabel) "Label" else null, PLACE_NAMES[f.provider] ?: f.provider.replaceFirstChar { it.uppercase() })
                                .joinToString(" · "), style = MaterialTheme.typography.bodySmall,
                                color = MaterialTheme.colorScheme.onSurfaceVariant)
                        }
                        IconButton(onClick = {
                            list = l - f
                            store.launch { store.api.unfollow(f.remoteId, f.provider) }
                        }) { Icon(Icons.Rounded.Close, "Unfollow ${f.name}", tint = MaterialTheme.colorScheme.onSurfaceVariant) }
                    }
                }
            }
        }
    }
}

/** A release from the feed: a Bandcamp record on its own page, anything else as a record. */
internal fun openFeedItem(go: Go, f: FeedItem) = when {
    f.provider == "bandcamp" && f.albumId != null -> go.open("bandcamp-record?url=${Uri.encode(f.albumId)}")
    f.albumId != null && f.provider == "deezer" -> go.album(f.title, f.artist, f.albumId)
    else -> go.album(f.title, f.artist)
}
