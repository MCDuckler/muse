package dance.duckduck.wetowl.ui

import dance.duckduck.wetowl.ui.theme.*
import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.gestures.detectHorizontalDragGestures
import androidx.compose.foundation.gestures.detectTapGestures
import androidx.compose.foundation.gestures.detectVerticalDragGestures
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.rounded.QueueMusic
import androidx.compose.material.icons.rounded.Favorite
import androidx.compose.material.icons.rounded.FavoriteBorder
import androidx.compose.material.icons.rounded.KeyboardArrowDown
import androidx.compose.material.icons.rounded.MoreVert
import androidx.compose.material.icons.rounded.Pause
import androidx.compose.material.icons.rounded.PlayArrow
import androidx.compose.material.icons.rounded.Repeat
import androidx.compose.material.icons.rounded.RepeatOne
import androidx.compose.material.icons.rounded.Shuffle
import androidx.compose.material.icons.rounded.Lyrics
import androidx.compose.material.icons.rounded.Devices
import androidx.compose.material.icons.rounded.Draw
import androidx.compose.material3.LocalContentColor
import androidx.compose.material.icons.rounded.Bedtime
import androidx.compose.material.icons.rounded.Equalizer
import androidx.compose.material.icons.rounded.SkipNext
import androidx.compose.material.icons.rounded.SkipPrevious
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableFloatStateOf
import androidx.compose.runtime.mutableLongStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.lerp
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import dance.duckduck.wetowl.core.RepeatMode
import dance.duckduck.wetowl.ui.theme.Kicker
import kotlinx.coroutines.delay

/** Where the song is, read off the player a few times a second while it is on screen. */
@Composable
fun rememberPosition(): Pair<Long, Long> {
    val playback = LocalStore.current.playback
    var pos by remember { mutableLongStateOf(playback.positionMs) }
    var dur by remember { mutableLongStateOf(playback.durationMs) }
    LaunchedEffect(Unit) {
        while (true) {
            pos = playback.positionMs
            dur = playback.durationMs
            delay(250)
        }
    }
    return pos to dur
}

/**
 * Where the song is: a groove pressed into the ground, the part played filled with the
 * accent, and a small moulded knob riding it. Drag or tap anywhere along it.
 */
@Composable
fun SeekBar(value: Float, onSeek: (Float) -> Unit, onDone: () -> Unit, modifier: Modifier = Modifier) {
    val accent = MaterialTheme.colorScheme.primary
    BoxWithConstraints(
        modifier.fillMaxWidth().height(30.dp)
            .pointerInput(Unit) {
                detectTapGestures { onSeek((it.x / size.width).coerceIn(0f, 1f)); onDone() }
            }
            .pointerInput(Unit) {
                detectHorizontalDragGestures(onDragEnd = onDone, onDragCancel = onDone) { change, _ ->
                    onSeek((change.position.x / size.width).coerceIn(0f, 1f))
                }
            },
        contentAlignment = Alignment.CenterStart,
    ) {
        val w = maxWidth
        Box(Modifier.fillMaxWidth().height(6.dp).well(corner = 3.dp))
        Box(Modifier.width(w * value).height(6.dp).clip(RoundedCornerShape(3.dp)).background(accent))
        Box(Modifier.padding(start = ((w - 18.dp) * value).coerceAtLeast(0.dp)).size(18.dp)
            .clip(androidx.compose.foundation.shape.CircleShape).background(accent))
    }
}

/** The bar over the tabs: what is playing, its progress, play/pause. Tap to open. */
@Composable
fun MiniPlayer(onOpen: () -> Unit, modifier: Modifier = Modifier) {
    val store = LocalStore.current
    val now by store.playback.now.collectAsState()
    val t = now.track ?: return
    val (pos, dur) = rememberPosition()
    Box(
        modifier.fillMaxWidth().padding(horizontal = 12.dp).height(68.dp)
            .tonal(corner = 22.dp)
            .clip(RoundedCornerShape(22.dp))
            .clickable(onClick = onOpen)
            .pointerInput(Unit) { detectVerticalDragGestures { _, dy -> if (dy < -12) onOpen() } },
    ) {
        Row(Modifier.fillMaxSize().padding(start = 10.dp, end = 8.dp), verticalAlignment = Alignment.CenterVertically) {
            TrackArt(t, 48.dp, corner = 12.dp)
            Spacer(Modifier.width(12.dp))
            Column(Modifier.weight(1f)) {
                Text(store.edited(t).name, style = MaterialTheme.typography.titleSmall, maxLines = 1, overflow = TextOverflow.Ellipsis)
                Text(t.artistLine, style = MaterialTheme.typography.bodySmall, maxLines = 1, overflow = TextOverflow.Ellipsis,
                    color = MaterialTheme.colorScheme.onSurfaceVariant)
            }
            IconButton(onClick = store.playback::toggle) {
                Icon(if (now.playing) Icons.Rounded.Pause else Icons.Rounded.PlayArrow,
                    if (now.playing) "Pause" else "Play", tint = MaterialTheme.colorScheme.primary,
                    modifier = Modifier.size(30.dp))
            }
            IconButton(onClick = store.playback::next) { Icon(Icons.Rounded.SkipNext, "Next") }
        }
        LinearProgressIndicator(
            progress = { if (dur > 0) (pos.toFloat() / dur).coerceIn(0f, 1f) else 0f },
            modifier = Modifier.align(Alignment.BottomCenter).fillMaxWidth().padding(horizontal = 22.dp).height(2.dp),
            color = MaterialTheme.colorScheme.primary, trackColor = Color.Transparent, drawStopIndicator = {},
        )
    }
}

/** The song, whole: the cover moulded out of the room, the transport under it. */
@Composable
fun NowPlayingScreen(onClose: () -> Unit, onQueue: () -> Unit) {
    val store = LocalStore.current
    val go = LocalGo.current
    val context = androidx.compose.ui.platform.LocalContext.current
    val now by store.playback.now.collectAsState()
    val favs by store.favourites.collectAsState()
    val raw = now.track
    if (raw == null) { onClose(); return }
    val t = store.edited(raw)
    val (pos, dur) = rememberPosition()
    var seeking by remember { mutableStateOf<Float?>(null) }
    var menu by remember { mutableStateOf(false) }
    val scheme = MaterialTheme.colorScheme
    val wash = parseHex(t.coverColor) ?: scheme.primary
    val press by animateFloatAsState(if (now.playing) 1f else 0.94f, label = "breathe")
    var drag by remember { mutableFloatStateOf(0f) }
    var words by remember { mutableStateOf(false) }
    var sleeve by remember { mutableStateOf(false) }
    var sleeping by remember { mutableStateOf(false) }
    var devicesOpen by remember { mutableStateOf(false) }
    val sleep by store.playback.sleep.collectAsState()

    Box(
        Modifier.fillMaxSize()
            .background(Brush.verticalGradient(listOf(lerp(scheme.background, wash, 0.22f), scheme.background, scheme.background)))
            .pointerInput(Unit) {
                detectVerticalDragGestures(onDragEnd = { if (drag > 160) onClose(); drag = 0f }) { _, dy -> drag += dy }
            },
    ) {
        Column(Modifier.fillMaxSize().statusBarsPadding().navigationBarsPadding().padding(horizontal = 26.dp),
            horizontalAlignment = Alignment.CenterHorizontally) {
            Row(Modifier.fillMaxWidth().padding(top = 6.dp), verticalAlignment = Alignment.CenterVertically) {
                IconButton(onClick = onClose) { Icon(Icons.Rounded.KeyboardArrowDown, "Close", Modifier.size(30.dp)) }
                Column(Modifier.weight(1f), horizontalAlignment = Alignment.CenterHorizontally) {
                    Text("PLAYING FROM", style = Kicker, color = scheme.onSurfaceVariant)
                    Text(now.queue?.name ?: "", style = MaterialTheme.typography.titleSmall, maxLines = 1,
                        overflow = TextOverflow.Ellipsis)
                }
                IconButton(onClick = { sleeve = !sleeve; words = false }) {
                    Icon(Icons.Rounded.Draw, if (sleeve) "Turn the sleeve back" else "Draw on the sleeve",
                        tint = if (sleeve) scheme.primary else LocalContentColor.current)
                }
                IconButton(onClick = { devicesOpen = true }) { Icon(Icons.Rounded.Devices, "Where it plays") }
                IconButton(onClick = { menu = true }) { Icon(Icons.Rounded.MoreVert, "More") }
            }
            if (sleeve) BoxWithConstraints(Modifier.weight(1f).fillMaxWidth(), contentAlignment = Alignment.Center) {
                SleeveBack(t.id, minOf(maxWidth, maxHeight - 64.dp))
            }
            else if (words) LyricsPane(t, pos, Modifier.weight(1f))
            else BoxWithConstraints(Modifier.weight(1f).fillMaxWidth(), contentAlignment = Alignment.Center) {
                val side = minOf(maxWidth, maxHeight) * 0.94f * press
                Box(Modifier.size(side).clickable { words = true }) {
                    TrackArt(t, side, corner = 28.dp, small = false)
                }
            }
            Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
                Column(Modifier.weight(1f)) {
                    Text(t.name, style = MaterialTheme.typography.headlineSmall, maxLines = 2, overflow = TextOverflow.Ellipsis,
                        modifier = Modifier.clickable { t.album?.let { go.album(it, t.artists.firstOrNull()); onClose() } })
                    Text(t.artistLine, style = MaterialTheme.typography.bodyLarge, color = scheme.primary, maxLines = 1,
                        overflow = TextOverflow.Ellipsis,
                        modifier = Modifier.clickable { t.artists.firstOrNull()?.let { go.artist(it); onClose() } })
                }
                val fav = t.id in favs
                IconButton(onClick = { store.launch { store.setFavourite(t, !fav) } }) {
                    Icon(if (fav) Icons.Rounded.Favorite else Icons.Rounded.FavoriteBorder,
                        if (fav) "Remove from favourites" else "Add to favourites",
                        tint = if (fav) scheme.primary else scheme.onSurfaceVariant)
                }
            }
            Spacer(Modifier.height(10.dp))
            val shown = seeking ?: if (dur > 0) pos.toFloat() / dur else 0f
            SeekBar(shown.coerceIn(0f, 1f), onSeek = { seeking = it },
                onDone = { seeking?.let { store.playback.seek((it * dur).toLong()) }; seeking = null })
            Spacer(Modifier.height(8.dp))
            Row(Modifier.fillMaxWidth()) {
                Text(formatTime((shown * dur).toLong()).ifEmpty { "0:00" }, style = MaterialTheme.typography.labelSmall,
                    color = scheme.onSurfaceVariant)
                Spacer(Modifier.weight(1f))
                Text(if (now.buffering) "Loading…" else formatTime(dur), style = MaterialTheme.typography.labelSmall,
                    color = scheme.onSurfaceVariant)
            }
            Row(Modifier.fillMaxWidth().padding(vertical = 18.dp), horizontalArrangement = Arrangement.SpaceEvenly,
                verticalAlignment = Alignment.CenterVertically) {
                RoundButton(Icons.Rounded.SkipPrevious, "Previous", store.playback::previous, size = 60.dp)
                RoundButton(if (now.playing) Icons.Rounded.Pause else Icons.Rounded.PlayArrow,
                    if (now.playing) "Pause" else "Play", store.playback::toggle, size = 84.dp, accent = true)
                RoundButton(Icons.Rounded.SkipNext, "Next", store.playback::next, size = 60.dp)
            }
            Row(Modifier.fillMaxWidth().padding(bottom = 18.dp), horizontalArrangement = Arrangement.SpaceBetween,
                verticalAlignment = Alignment.CenterVertically) {
                RoundButton(Icons.Rounded.Shuffle, "Shuffle what is coming", store.playback::shuffle, size = 44.dp)
                val repeat = now.queue?.repeat ?: RepeatMode.OFF
                RoundButton(if (repeat == RepeatMode.ONE) Icons.Rounded.RepeatOne else Icons.Rounded.Repeat,
                    when (repeat) { RepeatMode.OFF -> "Repeat off"; RepeatMode.ALL -> "Repeat queue"; RepeatMode.ONE -> "Repeat song" },
                    store.playback::cycleRepeat, size = 44.dp, active = repeat != RepeatMode.OFF)
                RoundButton(Icons.Rounded.Lyrics, if (words) "Show the cover" else "Words", { words = !words; sleeve = false },
                    size = 44.dp, active = words)
                RoundButton(Icons.Rounded.Bedtime, sleepLabel(sleep), { sleeping = true }, size = 44.dp, active = sleep != null)
                RoundButton(Icons.AutoMirrored.Rounded.QueueMusic, "Up next", onQueue, size = 44.dp)
            }
        }
    }
    if (menu) SongSheet(t, onDismiss = { menu = false }, extra = listOf(
        SheetAction(Icons.Rounded.Equalizer, "Equalizer") { onClose(); go.open("equalizer") }))
    if (sleeping) SleepDialog { sleeping = false }
    if (devicesOpen) DevicesSheet { devicesOpen = false }
}

private fun sleepLabel(at: Long?): String = when {
    at == null -> "Sleep timer"
    at < 0 -> "Stops after this song"
    else -> "Stops in ${((at - System.currentTimeMillis()) / 60_000 + 1)} min"
}

/** The phone's own equalizer, pointed at this player. */
fun openEqualizer(context: android.content.Context, session: Int) {
    val i = android.content.Intent(android.media.audiofx.AudioEffect.ACTION_DISPLAY_AUDIO_EFFECT_CONTROL_PANEL)
        .putExtra(android.media.audiofx.AudioEffect.EXTRA_AUDIO_SESSION, session)
        .putExtra(android.media.audiofx.AudioEffect.EXTRA_PACKAGE_NAME, context.packageName)
        .putExtra(android.media.audiofx.AudioEffect.EXTRA_CONTENT_TYPE, android.media.audiofx.AudioEffect.CONTENT_TYPE_MUSIC)
    runCatching { context.startActivity(i) }.onFailure {
        android.widget.Toast.makeText(context, "This phone has no equalizer to open", android.widget.Toast.LENGTH_SHORT).show()
    }
}
