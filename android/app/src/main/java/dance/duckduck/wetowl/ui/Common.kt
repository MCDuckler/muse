package dance.duckduck.wetowl.ui

import androidx.compose.foundation.background
import androidx.compose.foundation.combinedClickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.rounded.CloudDownload
import androidx.compose.material.icons.rounded.ErrorOutline
import androidx.compose.material.icons.rounded.GraphicEq
import androidx.compose.material.icons.rounded.MoreVert
import androidx.compose.material.icons.rounded.MusicNote
import androidx.compose.material.icons.rounded.Check
import androidx.compose.material.icons.rounded.OfflinePin
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.FilledTonalButton
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.compositionLocalOf
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.lerp
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import coil3.compose.AsyncImage
import dance.duckduck.wetowl.Store
import dance.duckduck.wetowl.core.Track
import dance.duckduck.wetowl.ui.theme.Kicker

val LocalStore = compositionLocalOf<Store> { error("no store") }

/** Where a screen can go: the app's navigation, handed down. */
interface Go {
    fun artist(name: String, act: String? = null)
    fun album(name: String?, artist: String?, remoteId: String? = null)
    fun playlist(id: Int)
    fun queue()
    fun settings()
    fun back()
    fun web(url: String)
    /** Any other page, by its route: "history", "folder/3", "smart/never"… */
    fun open(route: String)
}

val LocalGo = compositionLocalOf<Go> { error("no navigation") }

fun parseHex(hex: String?): Color? = runCatching {
    val h = hex?.removePrefix("#") ?: return null
    if (h.length != 6) return null
    Color(0xFF000000 or h.toLong(16))
}.getOrNull()

/**
 * A cover. Until it arrives (and when there is none) a wash of the cover's own colour,
 * or the accent's, with a note on it — never a grey square.
 */
@Composable
fun Artwork(
    url: String?,
    size: Dp,
    modifier: Modifier = Modifier,
    corner: Dp = 10.dp,
    colour: String? = null,
) {
    val scheme = MaterialTheme.colorScheme
    val wash = parseHex(colour) ?: scheme.primary
    Box(
        modifier
            .size(size)
            .clip(RoundedCornerShape(corner))
            .background(Brush.linearGradient(listOf(lerp(scheme.surface, wash, 0.45f), lerp(scheme.surface, wash, 0.15f)))),
        contentAlignment = Alignment.Center,
    ) {
        if (url == null) {
            Icon(Icons.Rounded.MusicNote, null, tint = lerp(wash, Color.White, 0.4f).copy(alpha = 0.7f),
                modifier = Modifier.size(size * 0.38f))
        } else {
            AsyncImage(model = url, contentDescription = null, contentScale = ContentScale.Crop,
                modifier = Modifier.fillMaxSize())
        }
    }
}

@Composable
fun TrackArt(t: Track, size: Dp, modifier: Modifier = Modifier, corner: Dp = 10.dp, small: Boolean = true) {
    val store = LocalStore.current
    Artwork(store.api.coverUrl(t, small), size, modifier, corner, t.coverColor)
}

fun formatTime(ms: Long?): String {
    if (ms == null || ms <= 0) return ""
    val s = ms / 1000
    return if (s >= 3600) "%d:%02d:%02d".format(s / 3600, s / 60 % 60, s % 60) else "%d:%02d".format(s / 60, s % 60)
}

/**
 * A song, the same in every list: cover, name, who, and what it is doing. The song
 * playing is lit with the accent; one still on its way says so.
 */
@Composable
fun SongRow(
    track: Track,
    onClick: () -> Unit,
    modifier: Modifier = Modifier,
    lit: Boolean = false,
    leading: (@Composable () -> Unit)? = null,
    trailing: (@Composable () -> Unit)? = null,
    showMenu: Boolean = true,
    subtitle: String? = null,
    extraActions: List<SheetAction> = emptyList(),
) {
    val store = LocalStore.current
    val edits by store.edited.collectAsState()
    val t = edits[track.id]?.let { store.edited(track) } ?: track
    val fetching = if (!t.isReady && !t.isFailed) store.fetching.collectAsState().value[t.id] else null
    val scheme = MaterialTheme.colorScheme
    var menu by remember { mutableStateOf(false) }
    val picked by store.selection.collectAsState()
    val haptics = androidx.compose.ui.platform.LocalHapticFeedback.current
    val selecting = picked.isNotEmpty()
    val isPicked = selecting && picked.any { it.rowKey == track.rowKey }
    Row(
        modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(16.dp))
            .background(when {
                isPicked -> scheme.secondaryContainer
                lit -> scheme.primary.copy(alpha = 0.10f)
                else -> Color.Transparent
            })
            .combinedClickable(
                onClick = { if (selecting) store.toggleSelected(track) else onClick() },
                onLongClick = {
                    if (showMenu) {
                        haptics.performHapticFeedback(androidx.compose.ui.hapticfeedback.HapticFeedbackType.LongPress)
                        store.toggleSelected(track)
                    }
                })
            .padding(horizontal = 10.dp, vertical = 7.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        leading?.invoke()
        Box(contentAlignment = Alignment.Center) {
            TrackArt(t, 48.dp)
            if (isPicked) {
                Box(Modifier.size(48.dp).clip(RoundedCornerShape(10.dp)).background(scheme.primary.copy(alpha = 0.85f)))
                Icon(Icons.Rounded.Check, "Picked", tint = scheme.onPrimary, modifier = Modifier.size(24.dp))
            } else if (lit) {
                Box(Modifier.size(48.dp).clip(RoundedCornerShape(10.dp)).background(Color.Black.copy(alpha = 0.45f)))
                Icon(Icons.Rounded.GraphicEq, null, tint = scheme.primary, modifier = Modifier.size(22.dp))
            }
        }
        Spacer(Modifier.width(12.dp))
        Column(Modifier.weight(1f)) {
            Text(t.name, maxLines = 1, overflow = TextOverflow.Ellipsis,
                style = MaterialTheme.typography.titleSmall,
                color = when {
                    lit -> scheme.primary
                    t.isFailed -> scheme.onSurfaceVariant
                    else -> scheme.onSurface
                })
            Row(verticalAlignment = Alignment.CenterVertically) {
                if (!t.isReady && !t.isFailed) {
                    Icon(Icons.Rounded.CloudDownload, null, tint = scheme.primary.copy(alpha = 0.8f),
                        modifier = Modifier.size(13.dp).padding(end = 3.dp))
                }
                if (t.id in store.offline.onPhone.collectAsState().value) {
                    Icon(Icons.Rounded.OfflinePin, "On this phone", tint = scheme.primary,
                        modifier = Modifier.size(13.dp).padding(end = 3.dp))
                }
                if (t.isFailed) {
                    Icon(Icons.Rounded.ErrorOutline, null, tint = scheme.error,
                        modifier = Modifier.size(13.dp).padding(end = 3.dp))
                }
                Text(
                    subtitle ?: when {
                        t.isFailed -> t.failReason ?: "Could not be fetched"
                        fetching != null -> fetching.percent?.let { "Fetching · ${it.toInt()}%" }
                            ?: "Fetching · ${fetching.stage.replace('_', ' ')}"
                        else -> listOfNotNull(t.artistLine, t.album?.takeIf { it.isNotBlank() && it != t.name })
                            .joinToString(" · ")
                    },
                    maxLines = 1, overflow = TextOverflow.Ellipsis,
                    style = MaterialTheme.typography.bodySmall, color = scheme.onSurfaceVariant)
            }
        }
        if (trailing != null) trailing() else Text(formatTime(t.durationMs),
            style = MaterialTheme.typography.labelSmall, color = scheme.onSurfaceVariant,
            modifier = Modifier.padding(start = 8.dp))
        if (showMenu) {
            IconButton(onClick = { menu = true }) {
                Icon(Icons.Rounded.MoreVert, "More", tint = scheme.onSurfaceVariant)
            }
        }
    }
    if (menu) SongSheet(t, onDismiss = { menu = false }, extra = extraActions)
}

@Composable
fun SectionLabel(text: String, modifier: Modifier = Modifier, action: (@Composable () -> Unit)? = null) {
    Row(modifier.fillMaxWidth().padding(start = 20.dp, end = 12.dp, top = 22.dp, bottom = 8.dp),
        verticalAlignment = Alignment.CenterVertically) {
        Text(text.uppercase(), style = Kicker, color = MaterialTheme.colorScheme.onSurfaceVariant,
            modifier = Modifier.weight(1f))
        action?.invoke()
    }
}

@Composable
fun Loading(modifier: Modifier = Modifier) {
    Box(modifier.fillMaxWidth().padding(48.dp), contentAlignment = Alignment.Center) {
        CircularProgressIndicator(strokeWidth = 3.dp, modifier = Modifier.size(32.dp))
    }
}

@Composable
fun ErrorRetry(message: String, onRetry: () -> Unit, modifier: Modifier = Modifier) {
    Column(modifier.fillMaxWidth().padding(32.dp), horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.spacedBy(12.dp)) {
        Text(message, style = MaterialTheme.typography.bodyMedium, color = MaterialTheme.colorScheme.onSurfaceVariant)
        FilledTonalButton(onClick = onRetry) { Text("Try again") }
    }
}

@Composable
fun Empty(text: String, modifier: Modifier = Modifier) {
    Text(text, style = MaterialTheme.typography.bodyMedium, color = MaterialTheme.colorScheme.onSurfaceVariant,
        fontWeight = FontWeight.Medium, modifier = modifier.fillMaxWidth().padding(32.dp))
}
