package dance.duckduck.wetowl.ui

import dance.duckduck.wetowl.ui.theme.*
import androidx.compose.foundation.background
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
import androidx.compose.material.icons.rounded.Favorite
import androidx.compose.material.icons.rounded.FavoriteBorder
import androidx.compose.material.icons.rounded.Person
import androidx.compose.material3.AssistChip
import androidx.compose.material3.AssistChipDefaults
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
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
import androidx.compose.material.icons.rounded.Radio
import androidx.compose.material.icons.rounded.CloudDownload
import androidx.compose.foundation.layout.Spacer
import dance.duckduck.wetowl.core.artistAbout
import dance.duckduck.wetowl.core.fillAlbum
import dance.duckduck.wetowl.core.startStationOf
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import dance.duckduck.wetowl.core.AlbumDetail
import dance.duckduck.wetowl.core.ApiError
import dance.duckduck.wetowl.core.ArtistDetail
import dance.duckduck.wetowl.core.Release

@Composable
fun ArtistScreen(name: String, act: String?, bottom: PaddingValues) {
    val store = LocalStore.current
    val go = LocalGo.current
    val now by store.playback.now.collectAsState()
    var d by remember { mutableStateOf<ArtistDetail?>(null) }
    var error by remember { mutableStateOf<String?>(null) }
    var attempt by remember { mutableIntStateOf(0) }
    var following by remember { mutableStateOf<Boolean?>(null) }
    LaunchedEffect(name, act, attempt) {
        try { d = store.api.artist(name, act); error = null } catch (e: ApiError) { error = e.message }
    }
    val a = d
    if (a == null) {
        Box(Modifier.statusBarsPadding()) { if (error != null) ErrorRetry(error!!, { attempt++ }) else Loading() }
        return
    }
    var about by remember(name) { mutableStateOf<String?>(null) }
    var aboutOpen by remember(name) { mutableStateOf(false) }
    LaunchedEffect(a.name) { runCatching { about = store.api.artistAbout(a.name, a.bandcampUrl) } }
    val isFollowing = following ?: a.following
    // Their page on the metadata service, or — for an act only Bandcamp has — theirs there.
    val followId = a.remoteId ?: a.bandcampUrl
    LazyColumn(contentPadding = bottom) {
        item {
            CollectionHead(
                art = a.image ?: a.albums.firstOrNull()?.cover,
                title = a.name,
                subtitle = listOfNotNull(
                    "${a.tracks.size} songs here",
                    a.fans?.takeIf { it > 0 }?.let { "${compact(it)} fans" },
                ).joinToString(" · "),
                kicker = "Artist",
                round = true,
                onPlay = { store.play(a.tracks, 0, a.name) },
                onShuffle = { store.play(a.tracks.shuffled(), 0, a.name) },
                playEnabled = a.tracks.isNotEmpty(),
                extra = followId?.let { id -> {
                    RoundButton(if (isFollowing) Icons.Rounded.Favorite else Icons.Rounded.FavoriteBorder,
                        if (isFollowing) "Unfollow" else "Follow", onClick = {
                            val provider = if (a.remoteId != null) "deezer" else "bandcamp"
                            following = !isFollowing
                            store.launch {
                                if (isFollowing) store.api.unfollow(id, provider) else store.api.follow(id, a.name, provider)
                            }
                        }, size = 52.dp, active = isFollowing)
                } },
            )
        }
        item {
            Row(Modifier.padding(horizontal = 18.dp), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                AssistChip(onClick = {
                    store.launch {
                        val p = store.api.startStation(artist = a.name)
                        val list = p.tracks ?: store.api.playlist(p.id).tracks.orEmpty()
                        store.play(list, 0, p.name)
                    }
                }, label = { Text("${a.name} station") },
                    leadingIcon = { Icon(Icons.Rounded.Radio, null, Modifier.size(AssistChipDefaults.IconSize)) })
            }
        }
        about?.takeIf { it.isNotBlank() }?.let { text ->
            item { SectionLabel("About") }
            item {
                Text(text, style = MaterialTheme.typography.bodyMedium, color = MaterialTheme.colorScheme.onSurfaceVariant,
                    maxLines = if (aboutOpen) Int.MAX_VALUE else 4, overflow = TextOverflow.Ellipsis,
                    modifier = Modifier.fillMaxWidth().clickable { aboutOpen = !aboutOpen }.padding(horizontal = 20.dp))
            }
        }
        if (a.namesakes.isNotEmpty()) {
            item { SectionLabel("Also called ${a.name}") }
            item {
                LazyRow(contentPadding = PaddingValues(horizontal = 18.dp), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    items(a.namesakes, key = { it.key }) { n ->
                        AssistChip(onClick = { go.artist(name, n.key) },
                            label = { Text("${n.label} · ${n.songs}", maxLines = 1) },
                            leadingIcon = { Icon(Icons.Rounded.Person, null, Modifier.size(AssistChipDefaults.IconSize)) })
                    }
                }
            }
        }
        val playableTop = a.top.mapNotNull { it.track }
        if (playableTop.isNotEmpty()) {
            item { SectionLabel("Best known") }
            items(playableTop.take(6), key = { "top${it.id}" }) { t ->
                SongRow(t, onClick = { store.play(playableTop, playableTop.indexOf(t), a.name) },
                    lit = t.id == now.track?.id, modifier = Modifier.padding(horizontal = 8.dp))
            }
        }
        if (a.albums.isNotEmpty()) {
            item { SectionLabel("Discography") }
            item {
                LazyRow(contentPadding = PaddingValues(horizontal = 18.dp), horizontalArrangement = Arrangement.spacedBy(14.dp)) {
                    items(a.albums, key = { it.remoteId }) { r -> ReleaseTile(r, a.name) }
                }
            }
        }
        a.unavailable?.takeIf { a.albums.isEmpty() }?.let { item { Empty("Only your library: $it") } }
        if (a.tracks.isNotEmpty()) {
            item { SectionLabel("In your library · ${a.tracks.size}") }
            items(a.tracks, key = { "mine${it.id}" }) { t ->
                SongRow(t, onClick = { store.play(a.tracks, a.tracks.indexOf(t), a.name) },
                    lit = t.id == now.track?.id, modifier = Modifier.padding(horizontal = 8.dp))
            }
        }
    }
}

@Composable
private fun ReleaseTile(r: Release, artist: String) {
    val go = LocalGo.current
    Column(Modifier.width(138.dp).clickable {
        // One discography: a record only their Bandcamp page has opens there.
        if (r.onBandcamp) go.open("bandcamp-record?url=${android.net.Uri.encode(r.url!!)}") else go.album(r.title, artist, r.remoteId)
    }) {
        Box {
            Artwork(r.cover, 138.dp, corner = 18.dp)
            if (r.have > 0) Text("${r.have} HERE", style = dance.duckduck.wetowl.ui.theme.Kicker,
                color = MaterialTheme.colorScheme.onPrimary,
                modifier = Modifier.align(Alignment.TopEnd).padding(6.dp)
                    .background(MaterialTheme.colorScheme.primary, androidx.compose.foundation.shape.RoundedCornerShape(8.dp))
                    .padding(horizontal = 6.dp, vertical = 2.dp))
        }
        Spacer(Modifier.height(8.dp))
        Text(r.title, style = MaterialTheme.typography.titleSmall, maxLines = 2, overflow = TextOverflow.Ellipsis)
        Text(listOfNotNull(r.year, r.recordType, if (r.onBandcamp) "Bandcamp" else null).joinToString(" · "),
            style = MaterialTheme.typography.bodySmall, color = if (r.onBandcamp) MaterialTheme.colorScheme.primary
            else MaterialTheme.colorScheme.onSurfaceVariant, maxLines = 1)
    }
}

private fun compact(n: Int) = when {
    n >= 1_000_000 -> "%.1fM".format(n / 1_000_000.0)
    n >= 1_000 -> "${n / 1000}K"
    else -> "$n"
}

@Composable
fun AlbumScreen(name: String?, artist: String?, remoteId: String?, bottom: PaddingValues) {
    val store = LocalStore.current
    val now by store.playback.now.collectAsState()
    var d by remember { mutableStateOf<AlbumDetail?>(null) }
    var error by remember { mutableStateOf<String?>(null) }
    var attempt by remember { mutableIntStateOf(0) }
    LaunchedEffect(name, artist, remoteId, attempt) {
        try { d = store.api.album(name, artist, remoteId); error = null } catch (e: ApiError) { error = e.message }
    }
    val al = d
    if (al == null) {
        Box(Modifier.statusBarsPadding()) { if (error != null) ErrorRetry(error!!, { attempt++ }) else Loading() }
        return
    }
    val playable = al.playable
    val title = al.name ?: name ?: "Record"
    LazyColumn(contentPadding = bottom) {
        item {
            CollectionHead(
                art = al.cover ?: playable.firstOrNull()?.let { store.api.coverUrl(it, small = false) },
                title = title,
                subtitle = listOfNotNull(al.artist ?: artist, al.year, "${playable.size} of ${al.rows.size.coerceAtLeast(playable.size)} here")
                    .joinToString(" · "),
                kicker = al.recordType ?: "Record",
                onPlay = { store.play(playable, 0, title) },
                onShuffle = { store.play(playable.shuffled(), 0, title) },
                playEnabled = playable.isNotEmpty(),
            )
        }
        item {
            androidx.compose.material3.AssistChip(onClick = {
                playStation(store) { store.api.startStationOf("album", album = al.name ?: name, artist = al.artist ?: artist) }
            }, label = { Text("Station from this record") },
                leadingIcon = { Icon(Icons.Rounded.Radio, null, Modifier.size(AssistChipDefaults.IconSize)) },
                modifier = Modifier.padding(horizontal = 18.dp))
        }
        val missing = al.rows.count { it.track == null }
        if (missing > 0) item {
            var asked by remember { mutableStateOf(false) }
            androidx.compose.material3.FilledTonalButton(enabled = !asked, onClick = {
                asked = true
                store.launch {
                    val n = store.api.fillAlbum(al.name ?: name, al.artist ?: artist, remoteId)
                    store.playback.notes.tryEmit(if (n == 0) "Nothing more to fetch" else "Fetching $n songs into the house")
                }
            }, modifier = Modifier.padding(horizontal = 18.dp, vertical = 4.dp)) {
                Icon(Icons.Rounded.CloudDownload, null, Modifier.size(18.dp))
                Spacer(Modifier.width(8.dp))
                Text(if (asked) "Fetching…" else "Get the other $missing")
            }
        }
        items(al.rows, key = { "row${it.pos}" }) { r ->
            val t = r.track
            if (t != null) SongRow(t, onClick = { store.play(playable, playable.indexOf(t), title) },
                lit = t.id == now.track?.id, modifier = Modifier.padding(horizontal = 8.dp),
                leading = { Text("${r.pos}", style = MaterialTheme.typography.labelMedium,
                    color = MaterialTheme.colorScheme.onSurfaceVariant, modifier = Modifier.width(26.dp)) })
            else Row(Modifier.fillMaxWidth().clickable {
                // Not here yet: asked of the house by name, fetched as it plays.
                store.launch {
                    val got = store.api.resolveByName(r.title, r.artists.ifEmpty { listOfNotNull(al.artist ?: artist) },
                        title, r.durationMs)
                    store.playback.playNext(got)
                }
            }.padding(horizontal = 18.dp, vertical = 12.dp), verticalAlignment = Alignment.CenterVertically) {
                Text("${r.pos}", style = MaterialTheme.typography.labelMedium, color = MaterialTheme.colorScheme.onSurfaceVariant,
                    modifier = Modifier.width(26.dp))
                Column(Modifier.weight(1f)) {
                    Text(r.title, style = MaterialTheme.typography.titleSmall, color = MaterialTheme.colorScheme.onSurfaceVariant,
                        maxLines = 1, overflow = TextOverflow.Ellipsis)
                    Text("Not in the house yet", style = MaterialTheme.typography.bodySmall,
                        color = MaterialTheme.colorScheme.outline)
                }
                Text(formatTime(r.durationMs), style = MaterialTheme.typography.labelSmall,
                    color = MaterialTheme.colorScheme.outline)
            }
        }
        if (al.extra.isNotEmpty()) {
            item { SectionLabel("Also here") }
            items(al.extra, key = { "x${it.id}" }) { t ->
                SongRow(t, onClick = { store.play(playable, playable.indexOf(t), title) },
                    lit = t.id == now.track?.id, modifier = Modifier.padding(horizontal = 8.dp))
            }
        }
    }
}
