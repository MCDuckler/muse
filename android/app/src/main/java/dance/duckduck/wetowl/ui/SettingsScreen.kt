package dance.duckduck.wetowl.ui

import androidx.compose.material.icons.rounded.Link
import androidx.compose.material.icons.rounded.Group
import androidx.compose.material.icons.rounded.Devices
import androidx.compose.material.icons.rounded.CloudDownload
import androidx.compose.material.icons.rounded.OfflinePin
import androidx.compose.material.icons.rounded.Interests
import androidx.compose.material.icons.rounded.AdminPanelSettings
import androidx.compose.material.icons.rounded.SystemUpdate
import androidx.compose.material.icons.rounded.Equalizer
import androidx.compose.material.icons.rounded.Receipt
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.width
import dance.duckduck.wetowl.core.meFull
import dance.duckduck.wetowl.core.accounts
import dance.duckduck.wetowl.core.checkUpdate
import dance.duckduck.wetowl.core.clearAvatar
import dance.duckduck.wetowl.core.setAvatar
import dance.duckduck.wetowl.core.changePassword
import dance.duckduck.wetowl.ui.theme.*
import android.os.Build
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ExperimentalLayoutApi
import androidx.compose.foundation.layout.FlowRow
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.rounded.ArrowBack
import androidx.compose.material.icons.automirrored.rounded.Logout
import androidx.compose.material.icons.rounded.Check
import androidx.compose.material.icons.rounded.Wallpaper
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.unit.dp
import dance.duckduck.wetowl.BuildConfig
import dance.duckduck.wetowl.core.Accent
import dance.duckduck.wetowl.ui.theme.accentColor

@OptIn(ExperimentalLayoutApi::class)
@Composable
fun SettingsScreen(bottom: PaddingValues) {
    val store = LocalStore.current
    val go = LocalGo.current
    val user by store.user.collectAsState()
    val accent by store.prefs.accent.collectAsState()
    val context = androidx.compose.ui.platform.LocalContext.current
    var me by remember { mutableStateOf<dance.duckduck.wetowl.core.Me?>(null) }
    var admin by remember { mutableStateOf(false) }
    var update by remember { mutableStateOf<dance.duckduck.wetowl.core.Update?>(null) }
    var checked by remember { mutableStateOf(false) }
    var passwording by remember { mutableStateOf(false) }
    var devicesOpen by remember { mutableStateOf(false) }
    val here by store.offline.onPhone.collectAsState()
    val bytes by store.offline.bytes.collectAsState()
    LaunchedEffect(Unit) {
        runCatching { me = store.api.meFull() }
        runCatching { admin = store.api.accounts().first }
        update = store.api.checkUpdate(BuildConfig.VERSION_CODE); checked = true
    }
    val pickAvatar = androidx.activity.compose.rememberLauncherForActivityResult(
        androidx.activity.result.contract.ActivityResultContracts.PickVisualMedia()) { uri ->
        if (uri != null) store.launch {
            val b = kotlinx.coroutines.withContext(kotlinx.coroutines.Dispatchers.IO) {
                context.contentResolver.openInputStream(uri)?.use { it.readBytes() }
            } ?: return@launch
            store.api.setAvatar(b); me = store.api.meFull()
        }
    }
    if (devicesOpen) DevicesSheet { devicesOpen = false }
    if (passwording) PasswordDialog("Change password") { pw ->
        passwording = false
        if (pw != null) store.launch { store.api.changePassword(pw); store.playback.notes.tryEmit("Password changed") }
    }
    val choices = Accent.entries.filter { it != Accent.WALLPAPER || Build.VERSION.SDK_INT >= Build.VERSION_CODES.S }

    Column(Modifier.verticalScroll(rememberScrollState()).statusBarsPadding().padding(bottom = bottom.calculateBottomPadding())) {
        Row(Modifier.padding(start = 4.dp, top = 4.dp), verticalAlignment = Alignment.CenterVertically) {
            IconButton(onClick = go::back) { Icon(Icons.AutoMirrored.Rounded.ArrowBack, "Back") }
            Text("Settings", style = MaterialTheme.typography.titleLarge)
        }
        SectionLabel("Accent")
        TonalCard(Modifier.fillMaxWidth().padding(horizontal = 18.dp), corner = 26.dp) {
            Column(Modifier.padding(18.dp)) {
                FlowRow(horizontalArrangement = Arrangement.spacedBy(16.dp), verticalArrangement = Arrangement.spacedBy(16.dp)) {
                    for (a in choices) {
                        val on = a == accent
                        Column(horizontalAlignment = Alignment.CenterHorizontally,
                            modifier = Modifier.clip(MaterialTheme.shapes.medium).clickable { store.prefs.setAccent(a) }.padding(4.dp)) {
                            Box(Modifier.size(54.dp).then(if (on) Modifier.picked(circle = true)
                                else Modifier.tonal(circle = true)), contentAlignment = Alignment.Center) {
                                if (a == Accent.WALLPAPER) {
                                    Icon(Icons.Rounded.Wallpaper, null, tint = if (on) MaterialTheme.colorScheme.primary
                                        else MaterialTheme.colorScheme.onSurfaceVariant)
                                } else Box(Modifier.size(28.dp).clip(CircleShape).background(accentColor(a)),
                                    contentAlignment = Alignment.Center) {
                                    if (on) Icon(Icons.Rounded.Check, null, tint = Color(0xFF111215), modifier = Modifier.size(18.dp))
                                }
                            }
                            Text(a.label, style = MaterialTheme.typography.labelSmall,
                                color = if (on) MaterialTheme.colorScheme.primary else MaterialTheme.colorScheme.onSurfaceVariant,
                                modifier = Modifier.padding(top = 6.dp))
                        }
                    }
                }
                Text("Wallpaper takes the colour from your phone (Material You). Dark, always.",
                    style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant,
                    modifier = Modifier.padding(top = 14.dp))
            }
        }
        SectionLabel("Account")
        TonalCard(Modifier.fillMaxWidth().padding(horizontal = 18.dp), corner = 26.dp) {
            Column(Modifier.padding(18.dp)) {
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Box(Modifier.clip(CircleShape).clickable {
                        pickAvatar.launch(androidx.activity.result.PickVisualMediaRequest(
                            androidx.activity.result.contract.ActivityResultContracts.PickVisualMedia.ImageOnly))
                    }) {
                        Avatar(user ?: "", me?.avatarVersion?.let { v -> "/users/${me?.userId}/avatar?v=$v" }, 56.dp)
                    }
                    Spacer(Modifier.width(14.dp))
                    Column(Modifier.weight(1f)) {
                        Text(user ?: "", style = MaterialTheme.typography.titleMedium)
                        Text(listOfNotNull(me?.score?.let { "$it records heard through" }, me?.device).joinToString(" · "),
                            style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
                        Text(store.prefs.server, style = MaterialTheme.typography.bodySmall,
                            color = MaterialTheme.colorScheme.outline)
                    }
                }
                Row(Modifier.padding(top = 8.dp)) {
                    TextButton(onClick = { passwording = true }) { Text("Change password") }
                    if (me?.avatarVersion != null) TextButton(onClick = {
                        store.launch { store.api.clearAvatar(); me = store.api.meFull() }
                    }) { Text("Remove picture") }
                }
                TextButton(onClick = { store.signOut() }) {
                    Icon(Icons.AutoMirrored.Rounded.Logout, null, Modifier.size(18.dp))
                    Text("  Sign out")
                }
            }
        }
        SectionLabel("Your house")
        TonalCard(Modifier.fillMaxWidth().padding(horizontal = 18.dp), corner = 26.dp) {
            Column(Modifier.padding(vertical = 6.dp)) {
                PlaceRow(Icons.Rounded.Link, "Services", "Spotify, YouTube Music, SoundCloud, Bandcamp, ListenBrainz") { go.open("services") }
                PlaceRow(Icons.Rounded.Group, "People", "Who else listens here, and their jams") { go.open("people") }
                PlaceRow(Icons.Rounded.Devices, "Devices", "Where the music plays") { devicesOpen = true }
                PlaceRow(Icons.Rounded.CloudDownload, "Downloads", "What the house is fetching") { go.open("downloads") }
                PlaceRow(Icons.Rounded.OfflinePin, "On this phone", "${here.size} songs kept · ${humanBytes(bytes)}") { go.open("offline") }
                PlaceRow(Icons.Rounded.Interests, "Genres and follows", "What comes into Discover") { go.open("follows") }
                if (admin) PlaceRow(Icons.Rounded.AdminPanelSettings, "Accounts and invites", "Run the house") { go.open("accounts") }
            }
        }
        SectionLabel("This app")
        TonalCard(Modifier.fillMaxWidth().padding(horizontal = 18.dp), corner = 26.dp) {
            Column(Modifier.padding(vertical = 6.dp)) {
                val u = update
                if (u != null) PlaceRow(Icons.Rounded.SystemUpdate, "Update to ${u.versionName}",
                    u.notes ?: "Downloads the new version; open it to install") { go.web(u.url) }
                else PlaceRow(Icons.Rounded.SystemUpdate, "Up to date", if (checked) "No newer build" else "Looking…") {
                    checked = false; store.launch { update = store.api.checkUpdate(BuildConfig.VERSION_CODE); checked = true }
                }
                PlaceRow(Icons.Rounded.Equalizer, "Equalizer", "Bands, curves and bass, for this player") { go.open("equalizer") }
                PlaceRow(Icons.Rounded.Receipt, "Playback log", "What the player did, to send when it misbehaves") { go.open("playback-log") }
            }
        }
        Text("WetOwl for Android ${BuildConfig.VERSION_NAME} · ${BuildConfig.BUILD_STAMP}",
            style = MaterialTheme.typography.labelSmall, color = MaterialTheme.colorScheme.outline,
            modifier = Modifier.fillMaxWidth().padding(24.dp))
    }
}

@Composable
private fun PlaceRow(icon: androidx.compose.ui.graphics.vector.ImageVector, title: String, sub: String, onClick: () -> Unit) {
    Row(Modifier.fillMaxWidth().clickable(onClick = onClick).padding(horizontal = 18.dp, vertical = 12.dp),
        verticalAlignment = Alignment.CenterVertically) {
        Icon(icon, null, tint = MaterialTheme.colorScheme.primary)
        Spacer(Modifier.width(16.dp))
        Column(Modifier.weight(1f)) {
            Text(title, style = MaterialTheme.typography.titleSmall)
            Text(sub, style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
        }
    }
}

/** A new password, typed twice. */
@Composable
fun PasswordDialog(title: String, onDone: (String?) -> Unit) {
    var a by remember { mutableStateOf("") }
    var b by remember { mutableStateOf("") }
    androidx.compose.material3.AlertDialog(
        onDismissRequest = { onDone(null) },
        title = { Text(title) },
        text = {
            Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                androidx.compose.material3.OutlinedTextField(a, { a = it }, label = { Text("New password") }, singleLine = true,
                    visualTransformation = androidx.compose.ui.text.input.PasswordVisualTransformation())
                androidx.compose.material3.OutlinedTextField(b, { b = it }, label = { Text("Again") }, singleLine = true,
                    visualTransformation = androidx.compose.ui.text.input.PasswordVisualTransformation(),
                    isError = b.isNotEmpty() && a != b)
            }
        },
        confirmButton = { TextButton(enabled = a.length >= 8 && a == b, onClick = { onDone(a) }) { Text("Change") } },
        dismissButton = { TextButton(onClick = { onDone(null) }) { Text("Cancel") } },
    )
}
