package dance.duckduck.wetowl.ui

import androidx.compose.foundation.combinedClickable
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import dance.duckduck.wetowl.core.stats
import dance.duckduck.wetowl.core.people
import dance.duckduck.wetowl.core.discover
import dance.duckduck.wetowl.core.dismissPick
import dance.duckduck.wetowl.ui.theme.*
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.lazy.items
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.rounded.Pause
import androidx.compose.material.icons.rounded.PlayArrow
import androidx.compose.material.icons.rounded.Settings
import androidx.compose.material.icons.rounded.Devices
import androidx.compose.material.icons.rounded.Group
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.material3.pulltorefresh.PullToRefreshBox
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import dance.duckduck.wetowl.core.Pick
import dance.duckduck.wetowl.core.QueueState
import dance.duckduck.wetowl.ui.theme.Kicker
import kotlinx.coroutines.launch
import java.time.LocalTime

@OptIn(androidx.compose.material3.ExperimentalMaterial3Api::class)
@Composable
fun HomeScreen(bottom: PaddingValues) {
    val store = LocalStore.current
    val go = LocalGo.current
    val user by store.user.collectAsState()
    val now by store.playback.now.collectAsState()
    val queues by store.queues.collectAsState()
    val sections by store.home.collectAsState()
    val history by store.history.collectAsState()
    val scope = rememberCoroutineScope()
    var refreshing by remember { mutableStateOf(false) }

    PullToRefreshBox(isRefreshing = refreshing, onRefresh = {
        scope.launch {
            refreshing = true
            store.refreshHome(); store.refreshQueues()
            refreshing = false
        }
    }) {
        var devicesOpen by remember { mutableStateOf(false) }
        var week by remember { mutableStateOf<dance.duckduck.wetowl.core.Stats?>(null) }
        var listening by remember { mutableStateOf<List<dance.duckduck.wetowl.core.Person>>(emptyList()) }
        var fresh by remember { mutableStateOf<List<dance.duckduck.wetowl.core.Track>>(emptyList()) }
        var feed by remember { mutableStateOf<List<dance.duckduck.wetowl.core.FeedItem>>(emptyList()) }
        val homeTick by store.libraryTick.collectAsState()
        androidx.compose.runtime.LaunchedEffect(homeTick) {
            // Each piece on its own: one that cannot be had leaves a gap, not an error.
            runCatching { week = store.api.stats("week") }
            runCatching { listening = store.api.people().filter { it.playingNow && it.playing != null } }
            runCatching { fresh = store.api.songs(0).items.take(12) }
            runCatching { feed = store.api.discover().feed.filter { it.unseen }.take(8) }
        }
        if (devicesOpen) DevicesSheet { devicesOpen = false }
        LazyColumn(contentPadding = bottom) {
            item {
                Row(Modifier.statusBarsPadding().padding(start = 20.dp, end = 8.dp, top = 16.dp),
                    verticalAlignment = Alignment.CenterVertically) {
                    Column(Modifier.weight(1f)) {
                        Text(greeting().uppercase(), style = Kicker, color = MaterialTheme.colorScheme.primary)
                        Text(user ?: "", style = MaterialTheme.typography.headlineLarge)
                    }
                    IconButton(onClick = { go.open("people") }) { Icon(Icons.Rounded.Group, "People") }
                    IconButton(onClick = { devicesOpen = true }) { Icon(Icons.Rounded.Devices, "Where it plays") }
                    IconButton(onClick = go::settings) { Icon(Icons.Rounded.Settings, "Settings") }
                }
            }
            item { ElsewhereBanner { devicesOpen = true } }
            item { JamBanner { go.queue() } }
            now.track?.let { t ->
                item {
                    TonalCard(Modifier.fillMaxWidth().padding(horizontal = 18.dp, vertical = 14.dp),
                        corner = 28.dp, onClick = go::queue) {
                        Row(Modifier.padding(16.dp), verticalAlignment = Alignment.CenterVertically) {
                            TrackArt(t, 76.dp, corner = 16.dp, small = false)
                            Spacer(Modifier.width(14.dp))
                            Column(Modifier.weight(1f)) {
                                Text((if (now.playing) "Playing from " else "Carry on with ").uppercase() +
                                        (now.queue?.name ?: "").uppercase(),
                                    style = Kicker, color = MaterialTheme.colorScheme.primary, maxLines = 1,
                                    overflow = TextOverflow.Ellipsis)
                                Spacer(Modifier.height(4.dp))
                                Text(t.name, style = MaterialTheme.typography.titleMedium, maxLines = 1,
                                    overflow = TextOverflow.Ellipsis)
                                Text(t.artistLine, style = MaterialTheme.typography.bodyMedium, maxLines = 1,
                                    overflow = TextOverflow.Ellipsis, color = MaterialTheme.colorScheme.onSurfaceVariant)
                            }
                            Spacer(Modifier.width(10.dp))
                            RoundButton(if (now.playing) Icons.Rounded.Pause else Icons.Rounded.PlayArrow,
                                if (now.playing) "Pause" else "Play", store.playback::toggle, size = 54.dp, accent = true)
                        }
                    }
                }
            }
            val mine = queues.filter { it.sharedFrom == null }
            if (mine.isNotEmpty()) {
                item { SectionLabel("Your queues") }
                item {
                    LazyRow(contentPadding = PaddingValues(horizontal = 18.dp), horizontalArrangement = Arrangement.spacedBy(14.dp)) {
                        items(mine, key = { it.id }) { q -> QueueTile(q, playing = q.id == now.queue?.id) { go.queue() } }
                    }
                }
            }
            homeExtras(week, listening, fresh, feed, go, store)
            for (s in sections) {
                item(key = "s-${s.id}") { SectionLabel(s.name) }
                item(key = "r-${s.id}") {
                    LazyRow(contentPadding = PaddingValues(horizontal = 18.dp), horizontalArrangement = Arrangement.spacedBy(14.dp)) {
                        items(s.items, key = { it.key }) { p -> PickTile(p, s.items, s.name) }
                    }
                }
            }
            if (history.isNotEmpty()) {
                item { SectionLabel("Played lately") }
                items(history.take(20), key = { "h${it.id}" }) { t ->
                    SongRow(t, onClick = { store.play(history, history.indexOf(t), "Played lately") },
                        lit = t.id == now.track?.id, modifier = Modifier.padding(horizontal = 8.dp))
                }
            }
            item { Spacer(Modifier.height(24.dp)) }
        }
    }
}

private fun greeting(): String = when (LocalTime.now().hour) {
    in 5..11 -> "Good morning"
    in 12..17 -> "Good afternoon"
    in 18..22 -> "Good evening"
    else -> "Up late"
}

/** A queue as a small moulded tile: the first cover, its name and count. */
@Composable
private fun QueueTile(q: QueueState, playing: Boolean, onClick: () -> Unit) {
    TonalCard(Modifier.width(150.dp), corner = 22.dp, onClick = onClick) {
        Column(Modifier.padding(12.dp)) {
            Box(Modifier.fillMaxWidth().height(70.dp), contentAlignment = Alignment.CenterStart) {
                Text(q.name.take(1).uppercase(), style = MaterialTheme.typography.displaySmall,
                    color = if (playing) MaterialTheme.colorScheme.primary else MaterialTheme.colorScheme.onSurfaceVariant)
            }
            Text(q.name, style = MaterialTheme.typography.titleSmall, maxLines = 1, overflow = TextOverflow.Ellipsis)
            Text(if (playing) "Playing · ${q.total}" else "${q.total} songs", style = MaterialTheme.typography.bodySmall,
                color = if (playing) MaterialTheme.colorScheme.primary else MaterialTheme.colorScheme.onSurfaceVariant)
        }
    }
}

@Composable
private fun PickTile(p: Pick, all: List<Pick>, section: String) {
    val store = LocalStore.current
    val url = p.track?.let { store.api.coverUrl(it, small = false) } ?: store.api.absolute(p.hit?.coverUrl)
    Column(Modifier.width(140.dp).clickable {
        store.launch {
            // Only the one tapped is brought in from outside; the rest of the shelf that
            // is here already plays after it.
            val tapped = p.track ?: store.api.resolve(p.hit!!)
            val here = all.mapNotNull { it.track }
            val tracks = if (p.track == null) listOf(tapped) + here else here
            store.play(tracks, tracks.indexOfFirst { it.id == tapped.id }.coerceAtLeast(0), section)
        }
    }) {
        Artwork(url, 140.dp, corner = 20.dp, colour = p.track?.coverColor)
        Spacer(Modifier.height(8.dp))
        Text(p.title, style = MaterialTheme.typography.titleSmall, maxLines = 1, overflow = TextOverflow.Ellipsis)
        Text(p.artistLine, style = MaterialTheme.typography.bodySmall, maxLines = 1, overflow = TextOverflow.Ellipsis,
            color = MaterialTheme.colorScheme.onSurfaceVariant)
    }
}

/** The week, the house, what is new: each only when it has something to say. */
private fun androidx.compose.foundation.lazy.LazyListScope.homeExtras(
    week: dance.duckduck.wetowl.core.Stats?,
    listening: List<dance.duckduck.wetowl.core.Person>,
    fresh: List<dance.duckduck.wetowl.core.Track>,
    feed: List<dance.duckduck.wetowl.core.FeedItem>,
    go: Go,
    store: dance.duckduck.wetowl.Store,
) {
    val top = week?.songs?.mapNotNull { r -> r.track?.let { it to r.plays } }.orEmpty()
    if (top.isNotEmpty()) {
        item(key = "week") { SectionLabel("Your week · ${week!!.plays} plays") { androidx.compose.material3.TextButton(onClick = { go.open("stats") }) { Text("Charts") } } }
        item(key = "week-row") {
            LazyRow(contentPadding = PaddingValues(horizontal = 18.dp), horizontalArrangement = Arrangement.spacedBy(14.dp)) {
                items(top.take(10).size) { i ->
                    val (t, plays) = top[i]
                    Column(Modifier.width(140.dp).clickable { store.play(top.map { it.first }, i, "Your week") }) {
                        Box {
                            TrackArt(t, 140.dp, corner = 20.dp, small = false)
                            Text("${i + 1}", style = MaterialTheme.typography.headlineMedium, color = MaterialTheme.colorScheme.primary,
                                modifier = Modifier.padding(8.dp))
                        }
                        Spacer(Modifier.height(8.dp))
                        Text(t.name, style = MaterialTheme.typography.titleSmall, maxLines = 1, overflow = TextOverflow.Ellipsis)
                        Text("$plays plays · ${t.artistLine}", style = MaterialTheme.typography.bodySmall, maxLines = 1,
                            overflow = TextOverflow.Ellipsis, color = MaterialTheme.colorScheme.onSurfaceVariant)
                    }
                }
            }
        }
    }
    if (listening.isNotEmpty()) {
        item(key = "now") { SectionLabel("Listening now") }
        items(listening.size, key = { "p" + listening[it].id }) { i ->
            val p = listening[i]
            val t = p.playing!!
            Row(Modifier.fillMaxWidth().clickable { go.open("person/${p.id}") }.padding(horizontal = 18.dp, vertical = 6.dp),
                verticalAlignment = Alignment.CenterVertically) {
                Avatar(p.name, p.avatar, 40.dp, online = true)
                Spacer(Modifier.width(12.dp))
                Column(Modifier.weight(1f)) {
                    Text(p.name, style = MaterialTheme.typography.titleSmall)
                    Text("${t.name} · ${t.artistLine}", style = MaterialTheme.typography.bodySmall, maxLines = 1,
                        overflow = TextOverflow.Ellipsis, color = MaterialTheme.colorScheme.primary)
                }
                if (p.jamCode != null) androidx.compose.material3.TextButton(onClick = {
                    store.launch { store.jams.join(p.jamCode); go.queue() }
                }) { Text("Join") }
                else TrackArt(t, 40.dp)
            }
        }
    }
    if (feed.isNotEmpty()) {
        item(key = "feed") { SectionLabel("Just out") { androidx.compose.material3.TextButton(onClick = { go.open("discover") }) { Text("Discover") } } }
        item(key = "feed-row") {
            LazyRow(contentPadding = PaddingValues(horizontal = 18.dp), horizontalArrangement = Arrangement.spacedBy(14.dp)) {
                items(feed.size) { i ->
                    val f = feed[i]
                    Column(Modifier.width(140.dp).clickable { openFeedItem(go, f) }) {
                        Artwork(store.api.absolute(f.cover), 140.dp, corner = 20.dp)
                        Spacer(Modifier.height(8.dp))
                        Text(f.title, style = MaterialTheme.typography.titleSmall, maxLines = 1, overflow = TextOverflow.Ellipsis)
                        Text(f.artist, style = MaterialTheme.typography.bodySmall, maxLines = 1, overflow = TextOverflow.Ellipsis,
                            color = MaterialTheme.colorScheme.onSurfaceVariant)
                    }
                }
            }
        }
    }
    if (fresh.isNotEmpty()) {
        item(key = "fresh") { SectionLabel("New in the library") }
        item(key = "fresh-row") {
            LazyRow(contentPadding = PaddingValues(horizontal = 18.dp), horizontalArrangement = Arrangement.spacedBy(14.dp)) {
                items(fresh.size) { i ->
                    val t = fresh[i]
                    Column(Modifier.width(120.dp).clickable { store.play(fresh, i, "New in the library") }) {
                        TrackArt(t, 120.dp, corner = 18.dp, small = false)
                        Spacer(Modifier.height(6.dp))
                        Text(t.name, style = MaterialTheme.typography.titleSmall, maxLines = 1, overflow = TextOverflow.Ellipsis)
                        Text(t.artistLine, style = MaterialTheme.typography.bodySmall, maxLines = 1, overflow = TextOverflow.Ellipsis,
                            color = MaterialTheme.colorScheme.onSurfaceVariant)
                    }
                }
            }
        }
    }
}
