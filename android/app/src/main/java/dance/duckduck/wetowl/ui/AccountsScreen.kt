package dance.duckduck.wetowl.ui

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
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.rounded.Delete
import androidx.compose.material.icons.rounded.Key
import androidx.compose.material.icons.rounded.PersonAdd
import androidx.compose.material.icons.rounded.Share
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
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
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.unit.dp
import dance.duckduck.wetowl.core.Account
import dance.duckduck.wetowl.core.Invite
import dance.duckduck.wetowl.core.accounts
import dance.duckduck.wetowl.core.createAccount
import dance.duckduck.wetowl.core.createInvite
import dance.duckduck.wetowl.core.deleteAccount
import dance.duckduck.wetowl.core.invites
import dance.duckduck.wetowl.core.resetPassword
import dance.duckduck.wetowl.core.revokeInvite

private fun shareInvite(context: android.content.Context, store: dance.duckduck.wetowl.Store, code: String) {
    val text = "Join my WetOwl: open the app, choose “Have an invite?” and use $code (house ${store.prefs.server})"
    context.startActivity(android.content.Intent.createChooser(android.content.Intent(android.content.Intent.ACTION_SEND)
        .setType("text/plain").putExtra(android.content.Intent.EXTRA_TEXT, text), "Send the invite"))
}

/** For an admin: everyone with an account, and invites that make new ones. */
@Composable
fun AccountsScreen(bottom: PaddingValues) {
    val store = LocalStore.current
    val context = LocalContext.current
    var list by remember { mutableStateOf<List<Account>>(emptyList()) }
    var codes by remember { mutableStateOf<List<Invite>>(emptyList()) }
    var tick by remember { mutableIntStateOf(0) }
    var dialog by remember { mutableStateOf<String?>(null) }
    var target by remember { mutableStateOf<Account?>(null) }
    LaunchedEffect(tick) {
        runCatching { list = store.api.accounts().second }
        runCatching { codes = store.api.invites() }
    }
    Column(Modifier.fillMaxSize()) {
        PageBar("Accounts", "${list.size} people on this house") {
            IconButton(onClick = { dialog = "invite" }) { Icon(Icons.Rounded.Share, "Make an invite") }
            IconButton(onClick = { dialog = "create" }) { Icon(Icons.Rounded.PersonAdd, "Make an account") }
        }
        LazyColumn(contentPadding = bottom) {
            items(list, key = { it.id }) { a ->
                Row(Modifier.fillMaxWidth().padding(horizontal = 18.dp, vertical = 6.dp), verticalAlignment = Alignment.CenterVertically) {
                    Avatar(a.name, null, 40.dp)
                    Spacer(Modifier.width(12.dp))
                    Column(Modifier.weight(1f)) {
                        Text(a.name, style = MaterialTheme.typography.titleSmall)
                        Text(listOfNotNull("${a.devices} devices", "${a.score} heard through",
                            a.lastSeen?.take(10)?.let { "seen $it" }, if (a.needsPassword) "no password yet" else null).joinToString(" · "),
                            style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
                    }
                    IconButton(onClick = { target = a; dialog = "password" }) { Icon(Icons.Rounded.Key, "Set ${a.name}'s password") }
                    IconButton(onClick = { target = a; dialog = "delete" }) { Icon(Icons.Rounded.Delete, "Delete ${a.name}") }
                }
            }
            if (codes.isNotEmpty()) {
                item { SectionLabel("Open invites") }
                items(codes, key = { it.code }) { inv ->
                    Row(Modifier.fillMaxWidth().padding(horizontal = 18.dp, vertical = 4.dp), verticalAlignment = Alignment.CenterVertically) {
                        Column(Modifier.weight(1f)) {
                            Text(inv.code, style = MaterialTheme.typography.titleMedium.copy(fontFamily = FontFamily.Monospace),
                                color = MaterialTheme.colorScheme.primary)
                            Text(listOfNotNull(inv.note, inv.expiresAt?.take(16)?.replace('T', ' ')?.let { "until $it" }).joinToString(" · "),
                                style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
                        }
                        IconButton(onClick = { shareInvite(context, store, inv.code) }) { Icon(Icons.Rounded.Share, "Send ${inv.code}") }
                        IconButton(onClick = { store.launch { store.api.revokeInvite(inv.code); tick++ } }) {
                            Icon(Icons.Rounded.Delete, "Revoke ${inv.code}")
                        }
                    }
                }
            }
        }
    }
    when (dialog) {
        "invite" -> NameDialog("Who is it for? (a note)", "") { note ->
            dialog = null
            if (note != null) store.launch {
                val inv = store.api.createInvite(note.trim().ifBlank { null }); tick++
                shareInvite(context, store, inv.code)
            }
        }
        "create" -> {
            var name by remember { mutableStateOf("") }
            var pw by remember { mutableStateOf("") }
            AlertDialog(onDismissRequest = { dialog = null }, title = { Text("New account") },
                text = {
                    Column {
                        OutlinedTextField(name, { name = it }, label = { Text("Name") }, singleLine = true)
                        OutlinedTextField(pw, { pw = it }, label = { Text("Password") }, singleLine = true,
                            visualTransformation = androidx.compose.ui.text.input.PasswordVisualTransformation())
                    }
                },
                confirmButton = { TextButton(enabled = name.isNotBlank() && pw.length >= 8, onClick = {
                    dialog = null; store.launch { store.api.createAccount(name.trim(), pw); tick++ }
                }) { Text("Make it") } },
                dismissButton = { TextButton(onClick = { dialog = null }) { Text("Cancel") } })
        }
        "password" -> PasswordDialog("Password for ${target?.name}") { pw ->
            dialog = null
            val t = target
            if (pw != null && t != null) store.launch {
                store.api.resetPassword(t.id, pw); store.playback.notes.tryEmit("${t.name}'s password set; their devices are signed out")
            }
        }
        "delete" -> Confirm("Delete ${target?.name}?", "Their account, lists and queues go. Songs stay on the house.", "Delete") { yes ->
            dialog = null
            val t = target
            if (yes && t != null) store.launch { store.api.deleteAccount(t.id); tick++ }
        }
    }
}
