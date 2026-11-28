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
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.itemsIndexed
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.rounded.Favorite
import androidx.compose.material.icons.rounded.FavoriteBorder
import androidx.compose.material.icons.rounded.LibraryAdd
import androidx.compose.material.icons.rounded.OpenInBrowser
import androidx.compose.material3.AssistChip
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
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import dance.duckduck.wetowl.core.ApiError
import dance.duckduck.wetowl.core.BandPage
import dance.duckduck.wetowl.core.RecordPreview
import dance.duckduck.wetowl.core.SourceHit
import dance.duckduck.wetowl.core.bandcampBand
import dance.duckduck.wetowl.core.importRecord
import dance.duckduck.wetowl.core.previewRecord
import dance.duckduck.wetowl.core.resolveSource
import dance.duckduck.wetowl.ui.theme.RoundButton

/** A Bandcamp act or label: its records (and acts, for a label), to follow. */
@Composable
fun BandcampBandScreen(url: String, name: String, bottom: PaddingValues) {
    val store = LocalStore.current
    val go = LocalGo.current
    var b by remember { mutableStateOf<BandPage?>(null) }
    var error by remember { mutableStateOf<String?>(null) }
    var attempt by remember { mutableIntStateOf(0) }
    var following by remember { mutableStateOf<Boolean?>(null) }
    var aboutOpen by remember { mutableStateOf(false) }
    LaunchedEffect(url, attempt) {
        try { b = store.api.bandcampBand(url); error = null } catch (e: ApiError) { error = e.message }
    }
    val band = b
    Box(Modifier.fillMaxSize()) {
        if (band == null) Box(Modifier.statusBarsPadding().padding(top = 56.dp)) {
            if (error != null) ErrorRetry(error!!, { attempt++ }) else Loading()
        } else LazyColumn(contentPadding = bottom) {
            val on = following ?: band.following
            item {
                CollectionHead(store.api.absolute(band.image), band.name.ifBlank { name },
                    "${band.records.size} records on Bandcamp", kicker = if (band.isLabel) "Label" else "Bandcamp",
                    round = true, onPlay = { go.web(band.url) }, onShuffle = {}, playEnabled = false,
                    extra = {
                        RoundButton(if (on) Icons.Rounded.Favorite else Icons.Rounded.FavoriteBorder,
                            if (on) "Unfollow" else "Follow", {
                                following = !on
                                store.launch {
                                    if (on) store.api.unfollow(band.url, "bandcamp")
                                    else store.api.follow(band.url, band.name, "bandcamp")
                                }
                            }, size = 52.dp, active = on)
                    })
            }
            band.about?.takeIf { it.isNotBlank() }?.let { text ->
                item {
                    Text(text, style = MaterialTheme.typography.bodyMedium, color = MaterialTheme.colorScheme.onSurfaceVariant,
                        maxLines = if (aboutOpen) Int.MAX_VALUE else 4, overflow = TextOverflow.Ellipsis,
                        modifier = Modifier.fillMaxWidth().clickable { aboutOpen = !aboutOpen }.padding(horizontal = 20.dp))
                }
            }
            if (band.roster.isNotEmpty()) {
                item { SectionLabel("On the label") }
                item {
                    LazyRow(contentPadding = PaddingValues(horizontal = 18.dp), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                        items(band.roster, key = { it.first }) { (who, page) ->
                            AssistChip(onClick = {
                                if (page.isNotBlank()) go.open("bandcamp?url=${Uri.encode(page)}&name=${Uri.encode(who)}")
                                else go.artist(who)
                            }, label = { Text(who) })
                        }
                    }
                }
            }
            item { SectionLabel("Records") }
            items(band.records, key = { it.remoteId }) { r ->
                Row(Modifier.fillMaxWidth().clickable {
                    go.open("bandcamp-record?url=${Uri.encode(r.url ?: r.remoteId)}")
                }.padding(horizontal = 18.dp, vertical = 7.dp), verticalAlignment = Alignment.CenterVertically) {
                    Artwork(store.api.absolute(r.cover), 56.dp, corner = 12.dp)
                    Spacer(Modifier.width(12.dp))
                    Column(Modifier.weight(1f)) {
                        Text(r.title, style = MaterialTheme.typography.titleSmall, maxLines = 1, overflow = TextOverflow.Ellipsis)
                        Text(listOfNotNull(r.year, r.recordType).joinToString(" · "),
                            style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
                    }
                }
            }
        }
        FloatingTop()
    }
}

/** A Bandcamp record: what is on it, to play one at a time or take in whole. */
@Composable
fun BandcampRecordScreen(url: String, bottom: PaddingValues) {
    val store = LocalStore.current
    val go = LocalGo.current
    val now by store.playback.now.collectAsState()
    var p by remember { mutableStateOf<RecordPreview?>(null) }
    var error by remember { mutableStateOf<String?>(null) }
    var attempt by remember { mutableIntStateOf(0) }
    var taking by remember { mutableStateOf(false) }
    LaunchedEffect(url, attempt) {
        try { p = store.api.previewRecord(url); error = null } catch (e: ApiError) { error = e.message }
    }
    suspend fun play(hits: List<SourceHit>, start: Int, name: String) {
        val tracks = hits.filter { it.streamable }.map { it.track ?: store.api.resolveSource(it) }
        store.play(tracks, start.coerceAtMost(tracks.size - 1).coerceAtLeast(0), name)
    }
    val rec = p
    Box(Modifier.fillMaxSize()) {
        if (rec == null) Box(Modifier.statusBarsPadding().padding(top = 56.dp)) {
            if (error != null) ErrorRetry(error!!, { attempt++ }) else Loading()
        } else LazyColumn(contentPadding = bottom) {
            val title = rec.album ?: "Record"
            item {
                CollectionHead(rec.tracks.firstOrNull { it.track != null }?.track?.let { store.api.coverUrl(it, small = false) },
                    title, listOfNotNull(rec.artist, "${rec.tracks.size} songs",
                        rec.unavailable.takeIf { it > 0 }?.let { "$it only when bought" }).joinToString(" · "),
                    kicker = "Bandcamp",
                    onPlay = { store.launch { play(rec.tracks, 0, title) } },
                    onShuffle = { store.launch { play(rec.tracks.shuffled(), 0, title) } },
                    playEnabled = rec.tracks.any { it.streamable },
                    extra = {
                        RoundButton(Icons.Rounded.LibraryAdd, "Take the whole record in, as a playlist", {
                            taking = true
                            store.launch {
                                try {
                                    val id = store.api.importRecord(url)
                                    store.refreshPlaylists()
                                    id?.let(go::playlist)
                                } finally { taking = false }
                            }
                        }, size = 52.dp, enabled = !taking)
                    })
            }
            itemsIndexed(rec.tracks, key = { i, h -> "$i${h.providerId}" }) { i, h ->
                val t = h.track
                if (t != null) SongRow(t, onClick = { store.launch { play(rec.tracks, i, title) } }, lit = t.id == now.track?.id,
                    modifier = Modifier.padding(horizontal = 8.dp))
                else Row(Modifier.fillMaxWidth().clickable(enabled = h.streamable) { store.launch { play(rec.tracks, i, title) } }
                    .padding(horizontal = 18.dp, vertical = 12.dp), verticalAlignment = Alignment.CenterVertically) {
                    Text("${i + 1}", style = MaterialTheme.typography.labelMedium, color = MaterialTheme.colorScheme.onSurfaceVariant,
                        modifier = Modifier.width(26.dp))
                    Column(Modifier.weight(1f)) {
                        Text(h.title, style = MaterialTheme.typography.titleSmall, maxLines = 1, overflow = TextOverflow.Ellipsis,
                            color = if (h.streamable) MaterialTheme.colorScheme.onSurface else MaterialTheme.colorScheme.outline)
                        Text(if (h.streamable) h.artists.joinToString(", ") else "Only when bought",
                            style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
                    }
                    Text(formatTime(h.durationMs), style = MaterialTheme.typography.labelSmall, color = MaterialTheme.colorScheme.outline)
                }
            }
            item {
                AssistChip(onClick = { go.web(url) }, label = { Text("Open on Bandcamp") },
                    leadingIcon = { androidx.compose.material3.Icon(Icons.Rounded.OpenInBrowser, null) },
                    modifier = Modifier.padding(horizontal = 18.dp, vertical = 12.dp))
            }
        }
        FloatingTop()
    }
}
