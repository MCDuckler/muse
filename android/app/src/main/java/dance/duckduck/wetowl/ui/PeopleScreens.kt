package dance.duckduck.wetowl.ui

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.rounded.Close
import androidx.compose.material.icons.rounded.Groups
import androidx.compose.material.icons.rounded.PersonAdd
import androidx.compose.material.icons.rounded.Share
import androidx.compose.material3.Button
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.FilledTonalButton
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.OutlinedButton
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
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import dance.duckduck.wetowl.core.ApiError
import dance.duckduck.wetowl.core.Person
import dance.duckduck.wetowl.core.PersonPage
import dance.duckduck.wetowl.core.Playlist
import dance.duckduck.wetowl.core.REACTIONS
import dance.duckduck.wetowl.core.RunningJam
import dance.duckduck.wetowl.core.inviteToJam
import dance.duckduck.wetowl.core.jamPeople
import dance.duckduck.wetowl.core.people
import dance.duckduck.wetowl.core.person
import dance.duckduck.wetowl.core.react
import dance.duckduck.wetowl.core.removeFromJam
import dance.duckduck.wetowl.core.runningJams
import dance.duckduck.wetowl.core.theirLibrary
import dance.duckduck.wetowl.core.theirPlaylists
import dance.duckduck.wetowl.ui.theme.tonal

@Composable
fun Avatar(name: String, url: String?, size: androidx.compose.ui.unit.Dp, online: Boolean = false) {
    val store = LocalStore.current
    Box {
        if (url != null) Artwork(store.api.absolute(url), size, corner = size / 2)
        else Box(Modifier.size(size).clip(CircleShape).background(MaterialTheme.colorScheme.secondaryContainer),
            contentAlignment = Alignment.Center) {
            Text(name.take(1).uppercase(), style = MaterialTheme.typography.titleMedium,
                color = MaterialTheme.colorScheme.onSecondaryContainer)
        }
        if (online) Box(Modifier.align(Alignment.BottomEnd).size(size / 4).clip(CircleShape)
            .background(MaterialTheme.colorScheme.primary))
    }
}

/** Everyone on the house: who is around, what they have on, their jams. */
@Composable
fun PeopleScreen(bottom: PaddingValues) {
    val store = LocalStore.current
    val go = LocalGo.current
    var list by remember { mutableStateOf<List<Person>?>(null) }
    var error by remember { mutableStateOf<String?>(null) }
    var attempt by remember { mutableIntStateOf(0) }
    LaunchedEffect(attempt) {
        try { list = store.api.people(); error = null } catch (e: ApiError) { error = e.message }
    }
    Column(Modifier.fillMaxSize()) {
        PageBar("People", "Everyone on this house")
        val l = list
        when {
            l == null -> if (error != null) ErrorRetry(error!!, { attempt++ }) else Loading()
            else -> LazyColumn(contentPadding = bottom) {
                items(l, key = { it.id }) { p ->
                    Row(Modifier.fillMaxWidth().clickable { go.open("person/${p.id}") }.padding(horizontal = 18.dp, vertical = 8.dp),
                        verticalAlignment = Alignment.CenterVertically) {
                        Avatar(p.name, p.avatar, 48.dp, online = p.playingNow)
                        Spacer(Modifier.width(12.dp))
                        Column(Modifier.weight(1f)) {
                            Text(p.name, style = MaterialTheme.typography.titleSmall)
                            Text(p.playing?.let { t -> (if (p.playingNow) "Playing " else "Last played ") + "${t.name} · ${t.artistLine}" }
                                ?: "${p.songs} songs · ${p.playlists} playlists",
                                style = MaterialTheme.typography.bodySmall, maxLines = 1, overflow = TextOverflow.Ellipsis,
                                color = if (p.playingNow) MaterialTheme.colorScheme.primary else MaterialTheme.colorScheme.onSurfaceVariant)
                        }
                        if (p.jamCode != null) FilledTonalButton(onClick = {
                            store.launch { store.jams.join(p.jamCode); go.queue() }
                        }) { Text("Join jam") }
                    }
                }
            }
        }
    }
}

/** One person: what they played lately, their playlists and their library; a nod. */
@Composable
fun PersonScreen(id: Int, bottom: PaddingValues) {
    val store = LocalStore.current
    val go = LocalGo.current
    val now by store.playback.now.collectAsState()
    var p by remember { mutableStateOf<PersonPage?>(null) }
    var lists by remember { mutableStateOf<List<Playlist>>(emptyList()) }
    var error by remember { mutableStateOf<String?>(null) }
    var attempt by remember { mutableIntStateOf(0) }
    var tab by remember { mutableIntStateOf(0) }
    LaunchedEffect(id, attempt) {
        try { p = store.api.person(id); error = null } catch (e: ApiError) { error = e.message }
        runCatching { lists = store.api.theirPlaylists(id) }
    }
    val them = p
    Column(Modifier.fillMaxSize()) {
        PageBar(them?.name ?: "", them?.let { "${it.songs} songs · ${it.playlists} playlists · ${it.played} plays" })
        if (them == null) { if (error != null) ErrorRetry(error!!, { attempt++ }) else Loading(); return }
        LazyColumn(contentPadding = bottom) {
            item {
                Row(Modifier.fillMaxWidth().padding(horizontal = 18.dp, vertical = 8.dp), verticalAlignment = Alignment.CenterVertically) {
                    Avatar(them.name, them.avatar, 72.dp)
                    Spacer(Modifier.width(16.dp))
                    Column(Modifier.weight(1f)) {
                        Text("Send a nod", style = MaterialTheme.typography.labelLarge, color = MaterialTheme.colorScheme.onSurfaceVariant)
                        Row {
                            REACTIONS.forEach { e ->
                                Text(e, fontSize = 26.sp, modifier = Modifier.clip(CircleShape).clickable {
                                    store.launch {
                                        store.api.react(them.id, e, them.recent.firstOrNull()?.id)
                                        store.playback.notes.tryEmit("Sent $e to ${them.name}")
                                    }
                                }.padding(4.dp))
                            }
                        }
                    }
                }
            }
            them.jamCode?.let { code ->
                item {
                    Button(onClick = { store.launch { store.jams.join(code); go.queue() } },
                        modifier = Modifier.fillMaxWidth().padding(horizontal = 18.dp, vertical = 6.dp)) {
                        Icon(Icons.Rounded.Groups, null); Spacer(Modifier.width(8.dp)); Text("Join ${them.name}'s jam")
                    }
                }
            }
            item {
                Segments(listOf("Lately", "Playlists", "Library"), tab, { tab = it },
                    Modifier.padding(horizontal = 18.dp, vertical = 10.dp))
            }
            when (tab) {
                0 -> {
                    if (them.recent.isEmpty()) item { Empty("Nothing played lately.") }
                    items(them.recent, key = { "r${it.id}" }) { t ->
                        SongRow(t, onClick = { store.play(them.recent, them.recent.indexOf(t), "${them.name} lately") },
                            lit = t.id == now.track?.id, modifier = Modifier.padding(horizontal = 8.dp))
                    }
                }
                1 -> {
                    if (lists.isEmpty()) item { Empty("No playlists to see.") }
                    items(lists, key = { "p${it.id}" }) { pl -> PlaylistRow(pl) }
                }
                else -> item { TheirLibrary(them) }
            }
        }
    }
}

@Composable
private fun TheirLibrary(them: PersonPage) {
    val store = LocalStore.current
    var items by remember { mutableStateOf<List<dance.duckduck.wetowl.core.Track>?>(null) }
    LaunchedEffect(them.id) { runCatching { items = store.api.theirLibrary(them.id, 0).items } }
    val l = items
    Column {
        when {
            l == null -> Loading()
            l.isEmpty() -> Empty("Nothing in their library yet.")
            else -> l.forEachIndexed { i, t ->
                SongRow(t, onClick = { store.play(l, i, "${them.name}'s library") }, modifier = Modifier.padding(horizontal = 8.dp))
            }
        }
    }
}

/** Listening together: start one from this queue, join one, or run the one you are in. */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun JamSheet(onDismiss: () -> Unit) {
    val store = LocalStore.current
    val context = LocalContext.current
    val jam by store.jams.jam.collectAsState()
    val now by store.playback.now.collectAsState()
    var code by remember { mutableStateOf("") }
    var running by remember { mutableStateOf<List<RunningJam>>(emptyList()) }
    var invitable by remember { mutableStateOf<List<Pair<Int, String>>>(emptyList()) }
    var busy by remember { mutableStateOf(false) }
    LaunchedEffect(jam?.id) {
        if (jam == null) runCatching { running = store.api.runningJams() }
        else if (jam?.isHost == true) runCatching { invitable = store.api.jamPeople() }
    }
    fun go(block: suspend () -> Unit) { busy = true; store.launch { try { block() } finally { busy = false } } }
    ModalBottomSheet(onDismissRequest = onDismiss, containerColor = MaterialTheme.colorScheme.surfaceContainerHigh) {
        Column(Modifier.navigationBarsPadding().padding(horizontal = 24.dp).padding(bottom = 16.dp)) {
            val j = jam
            if (j == null) {
                Text("Listen together", style = MaterialTheme.typography.titleLarge)
                Text("Open this queue to people on the house. Everyone hears the same song at the same moment, adds to it, and works the buttons.",
                    style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant,
                    modifier = Modifier.padding(vertical = 6.dp))
                Button(enabled = !busy && now.queue != null && !store.playback.isLocal, onClick = {
                    go { store.jams.start(now.queue!!.id) }
                }, modifier = Modifier.fillMaxWidth()) { Text("Start a jam with ${now.queue?.name ?: "this queue"}") }
                HorizontalDivider(Modifier.padding(vertical = 14.dp), color = MaterialTheme.colorScheme.outlineVariant)
                Row(verticalAlignment = Alignment.CenterVertically) {
                    OutlinedTextField(code, { code = it.uppercase().take(8) }, label = { Text("A code") }, singleLine = true,
                        modifier = Modifier.weight(1f))
                    Spacer(Modifier.width(10.dp))
                    FilledTonalButton(enabled = !busy && code.length >= 3, onClick = { go { store.jams.join(code); onDismiss() } }) { Text("Join") }
                }
                if (running.isNotEmpty()) {
                    Text("RUNNING NOW", style = dance.duckduck.wetowl.ui.theme.Kicker, color = MaterialTheme.colorScheme.onSurfaceVariant,
                        modifier = Modifier.padding(top = 18.dp, bottom = 6.dp))
                    LazyColumn(Modifier.heightIn(max = 260.dp)) {
                        items(running, key = { it.id }) { r ->
                            Row(Modifier.fillMaxWidth().clip(androidx.compose.foundation.shape.RoundedCornerShape(14.dp))
                                .clickable { go { store.jams.join(r.code); onDismiss() } }.padding(vertical = 8.dp),
                                verticalAlignment = Alignment.CenterVertically) {
                                Avatar(r.host, null, 40.dp)
                                Spacer(Modifier.width(12.dp))
                                Column(Modifier.weight(1f)) {
                                    Text("${r.host}'s jam · ${r.listening} listening", style = MaterialTheme.typography.titleSmall)
                                    Text(listOfNotNull(r.playing, r.by).joinToString(" · ").ifBlank { r.queue ?: "" },
                                        style = MaterialTheme.typography.bodySmall, maxLines = 1, overflow = TextOverflow.Ellipsis,
                                        color = MaterialTheme.colorScheme.onSurfaceVariant)
                                }
                                Text(if (r.joined) "Back in" else "Join", color = MaterialTheme.colorScheme.primary,
                                    style = MaterialTheme.typography.labelLarge)
                            }
                        }
                    }
                }
            } else {
                Text(j.title, style = MaterialTheme.typography.titleLarge)
                Text(if (j.listening <= 1) "Just you so far" else "${j.listening} listening",
                    style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
                Row(Modifier.fillMaxWidth().padding(vertical = 14.dp).tonal(corner = 20.dp, color = MaterialTheme.colorScheme.surfaceContainerHighest)
                    .padding(16.dp), verticalAlignment = Alignment.CenterVertically) {
                    Column(Modifier.weight(1f)) {
                        Text("CODE", style = dance.duckduck.wetowl.ui.theme.Kicker, color = MaterialTheme.colorScheme.onSurfaceVariant)
                        Text(j.code, style = MaterialTheme.typography.displaySmall.copy(fontFamily = FontFamily.Monospace),
                            color = MaterialTheme.colorScheme.primary)
                    }
                    IconButton(onClick = {
                        val send = android.content.Intent(android.content.Intent.ACTION_SEND).setType("text/plain")
                            .putExtra(android.content.Intent.EXTRA_TEXT, "Listen with me on WetOwl — jam code ${j.code}")
                        context.startActivity(android.content.Intent.createChooser(send, "Share the code"))
                    }) { Icon(Icons.Rounded.Share, "Share the code") }
                }
                j.members.forEach { m ->
                    Row(Modifier.fillMaxWidth().padding(vertical = 4.dp), verticalAlignment = Alignment.CenterVertically) {
                        Avatar(m.name, null, 36.dp, online = m.online)
                        Spacer(Modifier.width(12.dp))
                        Text(m.name + if (m.host) " · host" else "", style = MaterialTheme.typography.bodyLarge, modifier = Modifier.weight(1f))
                        if (j.isHost && !m.host) IconButton(onClick = { go { store.api.removeFromJam(j.id, m.userId); store.jams.refresh() } }) {
                            Icon(Icons.Rounded.Close, "Remove ${m.name}")
                        }
                    }
                }
                val out = invitable.filter { (id, _) -> j.members.none { it.userId == id } }
                if (j.isHost && out.isNotEmpty()) {
                    Text("INVITE", style = dance.duckduck.wetowl.ui.theme.Kicker, color = MaterialTheme.colorScheme.onSurfaceVariant,
                        modifier = Modifier.padding(top = 12.dp, bottom = 4.dp))
                    LazyRow(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                        items(out, key = { it.first }) { (id, name) ->
                            androidx.compose.material3.AssistChip(onClick = { go { store.api.inviteToJam(j.id, id); store.jams.refresh() } },
                                label = { Text(name) }, leadingIcon = { Icon(Icons.Rounded.PersonAdd, null, Modifier.size(16.dp)) })
                        }
                    }
                }
                OutlinedButton(enabled = !busy, onClick = { go { store.jams.leave(); onDismiss() } },
                    modifier = Modifier.fillMaxWidth().padding(top = 16.dp)) {
                    Text(if (j.isHost) "End the jam" else "Leave", color = MaterialTheme.colorScheme.error)
                }
            }
        }
    }
}

/** In a jam: said along the top of the queue and home, with the code. */
@Composable
fun JamBanner(modifier: Modifier = Modifier, onOpen: () -> Unit) {
    val store = LocalStore.current
    val j = store.jams.jam.collectAsState().value ?: return
    Row(modifier.fillMaxWidth().padding(horizontal = 18.dp, vertical = 6.dp)
        .tonal(corner = 18.dp, color = MaterialTheme.colorScheme.primaryContainer)
        .clickable(onClick = onOpen).padding(horizontal = 14.dp, vertical = 10.dp), verticalAlignment = Alignment.CenterVertically) {
        Icon(Icons.Rounded.Groups, null, tint = MaterialTheme.colorScheme.primary)
        Spacer(Modifier.width(12.dp))
        Column(Modifier.weight(1f)) {
            Text(j.title, style = MaterialTheme.typography.labelLarge, color = MaterialTheme.colorScheme.onPrimaryContainer)
            Text("${j.listening} listening · code ${j.code}", style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onPrimaryContainer.copy(alpha = 0.8f))
        }
    }
}
