package dance.duckduck.wetowl.ui

import dance.duckduck.wetowl.ui.theme.*
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.imePadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.Button
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.input.PasswordVisualTransformation
import androidx.compose.ui.unit.dp
import dance.duckduck.wetowl.core.ApiError
import kotlinx.coroutines.launch

@Composable
fun LoginScreen() {
    val store = LocalStore.current
    val scope = rememberCoroutineScope()
    var server by remember { mutableStateOf(store.prefs.server) }
    var user by remember { mutableStateOf(store.prefs.user ?: "") }
    var password by remember { mutableStateOf("") }
    var showServer by remember { mutableStateOf(false) }
    var invite by remember { mutableStateOf<String?>(null) }
    var working by remember { mutableStateOf(false) }
    var error by remember { mutableStateOf<String?>(null) }

    fun go() {
        if (working || user.isBlank() || password.isEmpty()) return
        scope.launch {
            working = true
            error = null
            try {
                val code = invite
                if (code != null) store.redeem(server, code, user, password) else store.signIn(server, user, password)
            } catch (e: ApiError) {
                error = if (e.status == 401) "That name and password do not match." else e.message
            } finally { working = false }
        }
    }

    Box(Modifier.fillMaxSize().statusBarsPadding().imePadding().verticalScroll(rememberScrollState()),
        contentAlignment = Alignment.Center) {
        Column(Modifier.widthIn(max = 420.dp).padding(24.dp), horizontalAlignment = Alignment.CenterHorizontally) {
            OwlMark(Modifier.size(88.dp))
            Spacer(Modifier.height(18.dp))
            Text("WetOwl", style = MaterialTheme.typography.displaySmall)
            Text("Your house's music, on this phone.", style = MaterialTheme.typography.bodyMedium,
                color = MaterialTheme.colorScheme.onSurfaceVariant)
            Spacer(Modifier.height(32.dp))
            TonalCard(Modifier.fillMaxWidth(), corner = 28.dp) {
                Column(Modifier.padding(20.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
                    invite?.let { code ->
                        OutlinedTextField(code, { invite = it.trim() }, label = { Text("Invite code") }, singleLine = true,
                            shape = RoundedCornerShape(16.dp), modifier = Modifier.fillMaxWidth())
                    }
                    OutlinedTextField(user, { user = it }, label = { Text(if (invite != null) "Pick a name" else "Name") }, singleLine = true,
                        shape = RoundedCornerShape(16.dp), modifier = Modifier.fillMaxWidth(),
                        keyboardOptions = KeyboardOptions(imeAction = ImeAction.Next))
                    OutlinedTextField(password, { password = it }, label = { Text("Password") }, singleLine = true,
                        shape = RoundedCornerShape(16.dp), modifier = Modifier.fillMaxWidth(),
                        visualTransformation = PasswordVisualTransformation(),
                        keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Password, imeAction = ImeAction.Go),
                        keyboardActions = androidx.compose.foundation.text.KeyboardActions(onGo = { go() }))
                    if (showServer) {
                        OutlinedTextField(server, { server = it }, label = { Text("House address") }, singleLine = true,
                            shape = RoundedCornerShape(16.dp), modifier = Modifier.fillMaxWidth(),
                            keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Uri))
                    }
                    error?.let { Text(it, color = MaterialTheme.colorScheme.error, style = MaterialTheme.typography.bodySmall) }
                    Button(onClick = ::go, enabled = !working && user.isNotBlank() && password.isNotEmpty(),
                        shape = RoundedCornerShape(18.dp), modifier = Modifier.fillMaxWidth().height(52.dp)) {
                        if (working) CircularProgressIndicator(Modifier.size(20.dp), strokeWidth = 2.dp,
                            color = MaterialTheme.colorScheme.onPrimary)
                        else Text(if (invite != null) "Make my account" else "Sign in")
                    }
                }
            }
            TextButton(onClick = { invite = if (invite == null) "" else null; error = null }, modifier = Modifier.padding(top = 8.dp)) {
                Text(if (invite == null) "Have an invite?" else "I already have an account")
            }
            TextButton(onClick = { showServer = !showServer }) {
                Text(if (showServer) "Hide the house address" else "Another house?")
            }
        }
    }
}
