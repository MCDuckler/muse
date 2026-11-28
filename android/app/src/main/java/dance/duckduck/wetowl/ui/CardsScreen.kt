package dance.duckduck.wetowl.ui

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
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
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.pager.VerticalPager
import androidx.compose.foundation.pager.rememberPagerState
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.rounded.PlaylistAdd
import androidx.compose.material.icons.rounded.Add
import androidx.compose.material.icons.rounded.Favorite
import androidx.compose.material.icons.rounded.FavoriteBorder
import androidx.compose.material.icons.rounded.Pause
import androidx.compose.material.icons.rounded.PlayArrow
import androidx.compose.material.icons.rounded.Share
import androidx.compose.material3.AssistChip
import androidx.compose.material3.FilterChip
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
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import dance.duckduck.wetowl.core.Card
import dance.duckduck.wetowl.core.CardDetails
import dance.duckduck.wetowl.core.cardDetails
import dance.duckduck.wetowl.core.cards
import dance.duckduck.wetowl.core.followGenre
import dance.duckduck.wetowl.ui.theme.RoundButton

private val SERVICES = listOf(null to "Everything", "bandcamp" to "Bandcamp", "soundcloud" to "SoundCloud", "youtube" to "YouTube")

/** The feed: one song a page, as big as the screen allows, with why it is here and what people said. */
@Composable
fun CardsScreen(bottom: PaddingValues) {
    val store = LocalStore.current
    var service by remember { mutableStateOf<String?>(null) }
    var cards by remember(service) { mutableStateOf<List<Card>>(emptyList()) }
    var total by remember(service) { mutableIntStateOf(-1) }
    var loading by remember { mutableStateOf(false) }
    val pager = rememberPagerState { cards.size }
    LaunchedEffect(service, pager.currentPage, cards.size) {
        if (loading || (total >= 0 && cards.size >= total) || pager.currentPage < cards.size - 4) return@LaunchedEffect
        loading = true
        runCatching { val (more, t) = store.api.cards(cards.size, service); cards = cards + more; total = if (more.isEmpty()) cards.size else t }
        loading = false
    }
    Box(Modifier.fillMaxSize()) {
        if (cards.isEmpty()) Box(Modifier.fillMaxSize().padding(top = 120.dp)) {
            if (total == 0) Empty("Nothing in the feed yet. Follow some acts and genres, and play some music.") else Loading()
        } else VerticalPager(pager, Modifier.fillMaxSize(), key = { cards[it].track.id }) { i ->
            CardPage(cards[i], cards, i, bottom)
        }
        Column {
            FloatingTop()
            androidx.compose.foundation.lazy.LazyRow(contentPadding = PaddingValues(horizontal = 16.dp),
                horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                items(SERVICES.size) { j ->
                    val (k, label) = SERVICES[j]
                    FilterChip(selected = service == k, onClick = { service = k }, label = { Text(label) })
                }
            }
        }
    }
}

@Composable
private fun CardPage(c: Card, all: List<Card>, index: Int, bottom: PaddingValues) {
    val store = LocalStore.current
    val context = LocalContext.current
    val now by store.playback.now.collectAsState()
    val favs by store.favourites.collectAsState()
    var details by remember(c.track.id) { mutableStateOf<CardDetails?>(null) }
    var adding by remember { mutableStateOf(false) }
    LaunchedEffect(c.track.id) { runCatching { details = store.api.cardDetails(c.track.id) } }
    val t = c.track
    val playingThis = now.track?.id == t.id && now.playing
    Column(Modifier.fillMaxSize().verticalScroll(rememberScrollState())
        .padding(top = 120.dp, start = 22.dp, end = 22.dp, bottom = bottom.calculateBottomPadding())) {
        BoxWithConstraints(Modifier.fillMaxWidth()) {
            TrackArt(t, maxWidth, corner = 28.dp, small = false)
        }
        Spacer(Modifier.height(16.dp))
        Text(c.why.ifBlank { c.listName }.uppercase(), style = dance.duckduck.wetowl.ui.theme.Kicker,
            color = MaterialTheme.colorScheme.primary)
        Text(t.name, style = MaterialTheme.typography.headlineSmall, maxLines = 2, overflow = TextOverflow.Ellipsis)
        Text(t.artistLine, style = MaterialTheme.typography.bodyLarge, color = MaterialTheme.colorScheme.onSurfaceVariant)
        Row(Modifier.fillMaxWidth().padding(vertical = 14.dp), horizontalArrangement = Arrangement.spacedBy(14.dp),
            verticalAlignment = Alignment.CenterVertically) {
            RoundButton(if (playingThis) Icons.Rounded.Pause else Icons.Rounded.PlayArrow, if (playingThis) "Pause" else "Play",
                { if (now.track?.id == t.id) store.playback.toggle() else store.play(all.map { it.track }, index, "Discover feed") },
                size = 60.dp, accent = true)
            val fav = t.id in favs
            RoundButton(if (fav) Icons.Rounded.Favorite else Icons.Rounded.FavoriteBorder, if (fav) "Unfavourite" else "Favourite",
                { store.launch { store.setFavourite(t, !fav) } }, size = 48.dp, active = fav)
            RoundButton(Icons.AutoMirrored.Rounded.PlaylistAdd, "Add to a playlist", { adding = true }, size = 48.dp)
            RoundButton(Icons.Rounded.Share, "Pass it on", {
                val text = "${t.name} — ${t.artistLine}" + (details?.url?.let { "\n$it" } ?: "")
                context.startActivity(android.content.Intent.createChooser(android.content.Intent(android.content.Intent.ACTION_SEND)
                    .setType("text/plain").putExtra(android.content.Intent.EXTRA_TEXT, text), "Pass it on"))
            }, size = 48.dp)
        }
        details?.let { d ->
            if (d.genres.isNotEmpty()) FlowRow(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                d.genres.forEach { g ->
                    AssistChip(onClick = { store.launch { store.api.followGenre(g); store.playback.notes.tryEmit("Following $g") } },
                        label = { Text(g) }, leadingIcon = { Icon(Icons.Rounded.Add, null, Modifier.size(16.dp)) })
                }
            }
            d.about?.takeIf { it.isNotBlank() }?.let {
                Text(it, style = MaterialTheme.typography.bodyMedium, color = MaterialTheme.colorScheme.onSurfaceVariant,
                    maxLines = 6, overflow = TextOverflow.Ellipsis, modifier = Modifier.padding(vertical = 8.dp))
            }
            d.comments.forEach { cm ->
                Row(Modifier.padding(vertical = 6.dp)) {
                    Avatar(cm.name, cm.avatar, 32.dp)
                    Spacer(Modifier.width(10.dp))
                    Column {
                        Text(cm.name, style = MaterialTheme.typography.labelLarge)
                        Text(cm.text, style = MaterialTheme.typography.bodyMedium, color = MaterialTheme.colorScheme.onSurfaceVariant)
                    }
                }
            }
        }
        Spacer(Modifier.height(40.dp))
    }
    if (adding) AddToPlaylistDialog(listOf(t), onDone = { adding = false })
}
