package dance.duckduck.wetowl.ui

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.rounded.Cast
import androidx.compose.material.icons.rounded.Computer
import androidx.compose.material.icons.rounded.Delete
import androidx.compose.material.icons.rounded.Edit
import androidx.compose.material.icons.rounded.Language
import androidx.compose.material.icons.rounded.Pause
import androidx.compose.material.icons.rounded.PhoneAndroid
import androidx.compose.material.icons.rounded.PhoneIphone
import androidx.compose.material.icons.rounded.PlayArrow
import androidx.compose.material.icons.rounded.SkipNext
import androidx.compose.material.icons.rounded.SkipPrevious
import androidx.compose.material.icons.rounded.Speaker
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.FilledTonalButton
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import dance.duckduck.wetowl.core.Device
import dance.duckduck.wetowl.core.commandDevice
import dance.duckduck.wetowl.core.forgetDevice
import dance.duckduck.wetowl.core.renameDevice
import dance.duckduck.wetowl.ui.theme.tonal

private fun iconFor(d: Device): ImageVector = when {
    d.platform == "android" -> Icons.Rounded.PhoneAndroid
    d.platform == "ios" -> Icons.Rounded.PhoneIphone
    d.platform == "web" -> Icons.Rounded.Language
    d.kind == "speaker" -> Icons.Rounded.Speaker
    else -> Icons.Rounded.Computer
}

/** Where the music is: this phone and every other device of yours, to move it between them or steer one. */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun DevicesSheet(onDismiss: () -> Unit) {
    val store = LocalStore.current
    val list by store.devices.collectAsState()
    val now by store.playback.now.collectAsState()
    LaunchedEffect(Unit) { store.refreshDevices() }
    ModalBottomSheet(onDismissRequest = onDismiss, containerColor = MaterialTheme.colorScheme.surfaceContainerHigh) {
        Column(Modifier.navigationBarsPadding().padding(bottom = 12.dp)) {
            Text("Where it plays", style = MaterialTheme.typography.titleLarge, modifier = Modifier.padding(horizontal = 24.dp))
            Text("Move the music between your devices, or steer one from here.", style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant, modifier = Modifier.padding(horizontal = 24.dp, vertical = 4.dp))
            val sorted = list.sortedWith(compareByDescending<Device> { it.isThis }.thenByDescending { it.playing }.thenByDescending { it.live })
            LazyColumn(Modifier.heightIn(max = 520.dp)) {
                items(sorted, key = { it.id }) { d -> DeviceRow(d, now.track != null && now.queue != null) }
            }
        }
    }
}

@Composable
private fun DeviceRow(d: Device, havePlaying: Boolean) {
    val store = LocalStore.current
    val scheme = MaterialTheme.colorScheme
    var menu by remember { mutableStateOf(false) }
    var naming by remember { mutableStateOf(false) }
    Column(Modifier.fillMaxWidth().padding(horizontal = 14.dp, vertical = 5.dp)
        .tonal(corner = 20.dp, color = if (d.playing) scheme.secondaryContainer else scheme.surfaceContainerHighest)
        .padding(12.dp)) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Box(Modifier.size(40.dp).clip(CircleShape).background(scheme.surfaceContainerHigh), contentAlignment = Alignment.Center) {
                Icon(iconFor(d), null, tint = if (d.playing) scheme.primary else scheme.onSurfaceVariant)
            }
            Spacer(Modifier.width(12.dp))
            Column(Modifier.weight(1f)) {
                Text(d.name + if (d.isThis) " · this phone" else "", style = MaterialTheme.typography.titleSmall,
                    maxLines = 1, overflow = TextOverflow.Ellipsis)
                val mine = store.playback.now.collectAsState().value
                val track = if (d.isThis) mine.track else d.track
                val playing = if (d.isThis) mine.playing else d.playing
                val what = track?.let { t -> "${if (playing) "Playing" else "Paused on"} ${t.name} · ${t.artistLine}" }
                Text(when {
                    d.isThis -> what ?: "Nothing on"
                    !d.live -> "Not around" + (d.lastSeen?.take(10)?.let { " · seen $it" } ?: "")
                    else -> what ?: "Around, nothing on"
                }, style = MaterialTheme.typography.bodySmall, maxLines = 1, overflow = TextOverflow.Ellipsis,
                    color = if (d.playing) scheme.primary else scheme.onSurfaceVariant)
            }
            Box {
                IconButton(onClick = { menu = true }) { Icon(Icons.Rounded.Edit, "Rename or forget ${d.name}", tint = scheme.onSurfaceVariant) }
                DropdownMenu(menu, { menu = false }) {
                    DropdownMenuItem(text = { Text("Rename") }, leadingIcon = { Icon(Icons.Rounded.Edit, null) },
                        onClick = { menu = false; naming = true })
                    if (!d.isThis) DropdownMenuItem(text = { Text("Forget") }, leadingIcon = { Icon(Icons.Rounded.Delete, null) },
                        onClick = {
                            menu = false
                            store.launch { store.api.forgetDevice(d.id); store.refreshDevices() }
                        })
                }
            }
        }
        if (!d.isThis && d.live) {
            Row(Modifier.fillMaxWidth().padding(top = 8.dp), horizontalArrangement = Arrangement.spacedBy(6.dp),
                verticalAlignment = Alignment.CenterVertically) {
                if (d.track != null) {
                    IconButton(onClick = { store.launch { store.api.commandDevice(d.id, "previous") } }) {
                        Icon(Icons.Rounded.SkipPrevious, "Previous on ${d.name}")
                    }
                    IconButton(onClick = { store.launch { store.api.commandDevice(d.id, if (d.playing) "pause" else "play") } }) {
                        Icon(if (d.playing) Icons.Rounded.Pause else Icons.Rounded.PlayArrow,
                            if (d.playing) "Pause on ${d.name}" else "Play on ${d.name}")
                    }
                    IconButton(onClick = { store.launch { store.api.commandDevice(d.id, "next") } }) {
                        Icon(Icons.Rounded.SkipNext, "Next on ${d.name}")
                    }
                }
            }
            Row(Modifier.fillMaxWidth().padding(top = 4.dp), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                if (d.track != null) FilledTonalButton(onClick = {
                    // Taken here: this phone is told (through the house) to play what that one is.
                    val me = store.thisDevice ?: return@FilledTonalButton
                    store.launch {
                        store.api.commandDevice(me, "take", d.queueId, d.track.id, d.positionNow())
                    }
                }, modifier = Modifier.weight(1f)) { Text("Play here") }
                if (havePlaying) FilledTonalButton(modifier = Modifier.weight(1f), onClick = {
                    val now = store.playback.now.value
                    store.launch {
                        store.api.commandDevice(d.id, "take", now.queue?.id, now.track?.id, store.playback.positionMs)
                    }
                }) {
                    Icon(Icons.Rounded.Cast, null, Modifier.size(16.dp)); Spacer(Modifier.width(6.dp)); Text("Send there")
                }
            }
        }
    }
    if (naming) NameDialog("Rename device", d.name) { n ->
        naming = false
        if (!n.isNullOrBlank()) store.launch { store.api.renameDevice(d.id, n.trim()); store.refreshDevices() }
    }
}

/** Something playing on another device while this one is quiet: said, with a way to take it. */
@Composable
fun ElsewhereBanner(modifier: Modifier = Modifier, onOpen: () -> Unit) {
    val store = LocalStore.current
    val list by store.devices.collectAsState()
    val now by store.playback.now.collectAsState()
    val other = list.firstOrNull { !it.isThis && it.live && it.playing && it.track != null } ?: return
    if (now.playing) return
    Row(modifier.fillMaxWidth().padding(horizontal = 18.dp, vertical = 6.dp)
        .tonal(corner = 18.dp, color = MaterialTheme.colorScheme.secondaryContainer)
        .clickable(onClick = onOpen).padding(horizontal = 14.dp, vertical = 10.dp),
        verticalAlignment = Alignment.CenterVertically) {
        Icon(iconFor(other), null, tint = MaterialTheme.colorScheme.primary)
        Spacer(Modifier.width(12.dp))
        Column(Modifier.weight(1f)) {
            Text("Playing on ${other.name}", style = MaterialTheme.typography.labelLarge, color = MaterialTheme.colorScheme.primary)
            Text("${other.track!!.name} · ${other.track.artistLine}", style = MaterialTheme.typography.bodySmall,
                maxLines = 1, overflow = TextOverflow.Ellipsis)
        }
        Text("Play here", style = MaterialTheme.typography.labelLarge, color = MaterialTheme.colorScheme.primary,
            modifier = Modifier.clickable {
                val me = store.thisDevice ?: return@clickable
                store.launch { store.api.commandDevice(me, "take", other.queueId, other.track?.id, other.positionNow()) }
            }.padding(6.dp))
    }
}
