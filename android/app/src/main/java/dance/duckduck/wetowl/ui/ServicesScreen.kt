package dance.duckduck.wetowl.ui

import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.text.selection.SelectionContainer
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.rounded.CheckCircle
import androidx.compose.material.icons.rounded.Sync
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Button
import androidx.compose.material3.FilledTonalButton
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import dance.duckduck.wetowl.core.ApiError
import dance.duckduck.wetowl.core.DeviceCode
import dance.duckduck.wetowl.core.RemoteHit
import dance.duckduck.wetowl.core.RemoteList
import dance.duckduck.wetowl.core.Scrobbling
import dance.duckduck.wetowl.core.Service
import dance.duckduck.wetowl.core.SpotifyState
import dance.duckduck.wetowl.core.Unmatched
import dance.duckduck.wetowl.core.connectListenBrainz
import dance.duckduck.wetowl.core.disconnectListenBrainz
import dance.duckduck.wetowl.core.linkService
import dance.duckduck.wetowl.core.resolveUnmatched
import dance.duckduck.wetowl.core.scrobbling
import dance.duckduck.wetowl.core.servicePlaylists
import dance.duckduck.wetowl.core.services
import dance.duckduck.wetowl.core.spotify
import dance.duckduck.wetowl.core.spotifyAuthorizeUrl
import dance.duckduck.wetowl.core.spotifyPlaylists
import dance.duckduck.wetowl.core.spotifySync
import dance.duckduck.wetowl.core.spotifyUnlink
import dance.duckduck.wetowl.core.syncService
import dance.duckduck.wetowl.core.unlinkService
import dance.duckduck.wetowl.core.unmatched
import dance.duckduck.wetowl.core.unmatchedSuggestions
import dance.duckduck.wetowl.core.youtubeFinish
import dance.duckduck.wetowl.core.youtubeStart
import dance.duckduck.wetowl.ui.theme.tonal
import kotlinx.coroutines.delay

/** Spotify, YouTube Music, SoundCloud, Bandcamp, Deezer, ListenBrainz: linked or not, and what they bring. */
@Composable
fun ServicesScreen(bottom: PaddingValues) {
    val store = LocalStore.current
    val go = LocalGo.current
    var spotify by remember { mutableStateOf<SpotifyState?>(null) }
    var list by remember { mutableStateOf<List<Service>>(emptyList()) }
    var lb by remember { mutableStateOf<Scrobbling?>(null) }
    var tick by remember { mutableIntStateOf(0) }
    var linking by remember { mutableStateOf<Service?>(null) }
    var code by remember { mutableStateOf<DeviceCode?>(null) }
    var lbToken by remember { mutableStateOf<String?>(null) }
    LaunchedEffect(tick) {
        runCatching { spotify = store.api.spotify() }
        runCatching { list = store.api.services() }
        runCatching { lb = store.api.scrobbling() }
    }
    // Back from the browser after a Spotify sign-in: looked at again.
    LaunchedEffect(Unit) { while (true) { delay(6000); runCatching { spotify = store.api.spotify() } } }
    LaunchedEffect(code) {
        val c = code ?: return@LaunchedEffect
        while (true) {
            delay(c.interval * 1000L)
            val done = runCatching { store.api.youtubeFinish(c.deviceCode) }.getOrElse { code = null; false }
            if (done) { code = null; tick++; store.playback.notes.tryEmit("YouTube Music is linked"); break }
        }
    }
    Column(Modifier.fillMaxSize()) {
        PageBar("Services", "Bring playlists and follows in; send plays out")
        LazyColumn(contentPadding = bottom) {
            spotify?.let { s ->
                item {
                    ServiceCard("Spotify", s.account?.let { "Linked as $it" } ?: if (!s.configured) (s.reason ?: "Not set up on this house") else "Not linked",
                        linked = s.account != null) {
                        if (s.account != null) {
                            FilledTonalButton(onClick = { go.open("service/spotify") }) { Text("Playlists") }
                            TextButton(onClick = { store.launch { store.api.spotifyUnlink(); tick++ } }) { Text("Unlink") }
                        } else if (s.configured) Button(onClick = {
                            store.launch { go.web(store.api.spotifyAuthorizeUrl()) }
                        }) { Text("Sign in with Spotify") }
                    }
                }
            }
            items(list, key = { it.provider }) { s ->
                ServiceCard(s.label, s.linkedAs?.let { "Linked as $it" } ?: s.hint, linked = s.linkedAs != null) {
                    if (s.linkedAs != null) {
                        FilledTonalButton(onClick = { go.open("service/${s.provider}") }) { Text("Playlists") }
                        TextButton(onClick = { store.launch { store.api.unlinkService(s.provider); tick++ } }) { Text("Unlink") }
                    } else if (s.signIn == "code") Button(onClick = { store.launch { code = store.api.youtubeStart() } }) { Text("Sign in with a code") }
                    else if (s.signIn == "name") Button(onClick = { linking = s }) { Text("Link") }
                    else Text("Link it from the desktop app", style = MaterialTheme.typography.bodySmall,
                        color = MaterialTheme.colorScheme.onSurfaceVariant)
                }
            }
            lb?.let { l ->
                item {
                    ServiceCard("ListenBrainz", if (l.connected) "Sending plays as ${l.name} · ${l.sent} sent" +
                        (if (l.owed > 0) " · ${l.owed} waiting" else "") + (l.error?.let { " · $it" } ?: "")
                        else "Send what you play to listenbrainz.org", linked = l.connected) {
                        if (l.connected) TextButton(onClick = { store.launch { store.api.disconnectListenBrainz(); tick++ } }) { Text("Stop") }
                        else Button(onClick = { lbToken = "" }) { Text("Connect") }
                    }
                }
            }
        }
    }
    linking?.let { s ->
        NameDialog("Link ${s.label}", "") { handle ->
            linking = null
            if (!handle.isNullOrBlank()) store.launch { store.api.linkService(s.provider, handle.trim()); tick++ }
        }
    }
    code?.let { c ->
        AlertDialog(onDismissRequest = { code = null }, title = { Text("Sign in to YouTube") },
            text = {
                Column {
                    Text("Open ${c.url} on any device and enter:")
                    SelectionContainer {
                        Text(c.userCode, style = MaterialTheme.typography.displaySmall.copy(fontFamily = FontFamily.Monospace),
                            color = MaterialTheme.colorScheme.primary, modifier = Modifier.padding(vertical = 12.dp))
                    }
                    Text("This page waits and links itself when you are done.", style = MaterialTheme.typography.bodySmall)
                }
            },
            confirmButton = { TextButton(onClick = { go.web(c.url) }) { Text("Open the page") } },
            dismissButton = { TextButton(onClick = { code = null }) { Text("Cancel") } })
    }
    lbToken?.let { t ->
        var v by remember { mutableStateOf(t) }
        AlertDialog(onDismissRequest = { lbToken = null }, title = { Text("ListenBrainz") },
            text = {
                Column {
                    Text("Paste your user token from listenbrainz.org/settings.", style = MaterialTheme.typography.bodySmall)
                    OutlinedTextField(v, { v = it }, singleLine = true, label = { Text("Token") }, modifier = Modifier.padding(top = 8.dp))
                }
            },
            confirmButton = { TextButton(enabled = v.isNotBlank(), onClick = {
                lbToken = null; store.launch { store.api.connectListenBrainz(v.trim()); tick++ }
            }) { Text("Connect") } },
            dismissButton = { TextButton(onClick = { lbToken = null }) { Text("Cancel") } })
    }
}

@Composable
private fun ServiceCard(name: String, line: String, linked: Boolean, actions: @Composable () -> Unit) {
    Column(Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 6.dp).tonal(corner = 22.dp).padding(16.dp)) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Text(name, style = MaterialTheme.typography.titleMedium, modifier = Modifier.weight(1f))
            if (linked) Icon(Icons.Rounded.CheckCircle, "Linked", tint = MaterialTheme.colorScheme.primary)
        }
        Text(line, style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant,
            modifier = Modifier.padding(top = 2.dp, bottom = 10.dp))
        Row(horizontalArrangement = Arrangement.spacedBy(8.dp), verticalAlignment = Alignment.CenterVertically) { actions() }
    }
}

/** One service's playlists: mirror any of them into the house, and keep them in step. */
@Composable
fun ServicePlaylistsScreen(provider: String, bottom: PaddingValues) {
    val store = LocalStore.current
    val go = LocalGo.current
    var items by remember { mutableStateOf<List<RemoteList>?>(null) }
    var error by remember { mutableStateOf<String?>(null) }
    var tick by remember { mutableIntStateOf(0) }
    var asked by remember { mutableStateOf<Set<String>>(emptySet()) }
    LaunchedEffect(tick) {
        try {
            items = if (provider == "spotify") store.api.spotifyPlaylists() else store.api.servicePlaylists(provider)
            error = null
        } catch (e: ApiError) { error = e.message }
    }
    fun sync(ids: List<String>) {
        asked = asked + ids
        store.launch {
            if (provider == "spotify") store.api.spotifySync(ids) else store.api.syncService(provider, ids)
            store.playback.notes.tryEmit("Mirroring ${ids.size} — songs arrive as they are found")
            delay(2500); tick++; store.refreshPlaylists()
        }
    }
    Column(Modifier.fillMaxSize()) {
        val label = PLACE_NAMES[provider] ?: provider.replaceFirstChar { it.uppercase() }
        PageBar("$label playlists", items?.let { l -> "${l.count { it.mirrorId != null }} of ${l.size} mirrored here" }) {
            items?.filter { it.mirrorId != null }?.takeIf { it.isNotEmpty() }?.let { m ->
                TextButton(onClick = { sync(m.map { it.remoteId }) }) { Text("Sync all") }
            }
        }
        val l = items
        when {
            l == null -> if (error != null) ErrorRetry(error!!, { tick++ }) else Loading()
            l.isEmpty() -> Empty("No playlists there.")
            else -> LazyColumn(contentPadding = bottom) {
                items(l, key = { it.remoteId }) { r ->
                    Row(Modifier.fillMaxWidth().clickable(enabled = r.mirrorId != null) { r.mirrorId?.let(go::playlist) }
                        .padding(horizontal = 18.dp, vertical = 8.dp), verticalAlignment = Alignment.CenterVertically) {
                        Artwork(store.api.absolute(r.image), 52.dp, corner = 12.dp)
                        Spacer(Modifier.width(12.dp))
                        Column(Modifier.weight(1f)) {
                            Text(r.name, style = MaterialTheme.typography.titleSmall, maxLines = 1, overflow = TextOverflow.Ellipsis)
                            Text(listOfNotNull(r.count?.let { "$it songs" }, r.owner?.let { "by $it" },
                                if (r.mirrorId != null) "mirrored" else null,
                                r.unmatched.takeIf { it > 0 }?.let { "$it not found" }).joinToString(" · "),
                                style = MaterialTheme.typography.bodySmall,
                                color = if (r.mirrorId != null) MaterialTheme.colorScheme.primary else MaterialTheme.colorScheme.onSurfaceVariant)
                        }
                        if (r.unmatched > 0 && provider == "spotify") TextButton(onClick = { go.open("unmatched/${r.mirrorId}") }) { Text("Fix") }
                        if (r.remoteId in asked) Icon(Icons.Rounded.Sync, "Mirroring", tint = MaterialTheme.colorScheme.primary)
                        else FilledTonalButton(onClick = { sync(listOf(r.remoteId)) }) { Text(if (r.mirrorId != null) "Sync" else "Mirror") }
                    }
                }
            }
        }
    }
}

/** Songs on a Spotify list nothing was found for: pick the right one from what YouTube Music has. */
@Composable
fun UnmatchedScreen(playlistId: Int, bottom: PaddingValues) {
    val store = LocalStore.current
    var items by remember { mutableStateOf<List<Unmatched>?>(null) }
    var open by remember { mutableStateOf<Int?>(null) }
    var hits by remember { mutableStateOf<List<RemoteHit>>(emptyList()) }
    var tick by remember { mutableIntStateOf(0) }
    LaunchedEffect(tick) { runCatching { items = store.api.unmatched(playlistId) } }
    LaunchedEffect(open) {
        hits = emptyList()
        open?.let { pos -> runCatching { hits = store.api.unmatchedSuggestions(playlistId, pos) } }
    }
    Column(Modifier.fillMaxSize()) {
        PageBar("Not found", items?.let { "${it.size} songs need a hand" })
        val l = items
        when {
            l == null -> Loading()
            l.isEmpty() -> Empty("Everything on this list was found.")
            else -> LazyColumn(contentPadding = bottom) {
                items(l, key = { it.pos }) { u ->
                    Column(Modifier.fillMaxWidth().clickable { open = if (open == u.pos) null else u.pos }
                        .padding(horizontal = 18.dp, vertical = 10.dp)) {
                        Text(u.title, style = MaterialTheme.typography.titleSmall)
                        Text(listOfNotNull(u.artists.joinToString(", ").ifBlank { null }, u.reason).joinToString(" · "),
                            style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
                        if (open == u.pos) {
                            if (hits.isEmpty()) Loading()
                            hits.forEach { h ->
                                Row(Modifier.fillMaxWidth().clickable {
                                    store.launch {
                                        store.api.resolveUnmatched(playlistId, u.pos, h.videoId)
                                        open = null; tick++
                                    }
                                }.padding(vertical = 8.dp), verticalAlignment = Alignment.CenterVertically) {
                                    Artwork(store.api.absolute(h.coverUrl), 40.dp)
                                    Spacer(Modifier.width(10.dp))
                                    Column(Modifier.weight(1f)) {
                                        Text(h.title, style = MaterialTheme.typography.bodyMedium, maxLines = 1, overflow = TextOverflow.Ellipsis)
                                        Text(listOfNotNull(h.artistLine, h.album).joinToString(" · "), style = MaterialTheme.typography.bodySmall,
                                            color = MaterialTheme.colorScheme.onSurfaceVariant, maxLines = 1)
                                    }
                                    Text(formatTime(h.durationMs), style = MaterialTheme.typography.labelSmall)
                                }
                            }
                        }
                    }
                }
            }
        }
    }
}
