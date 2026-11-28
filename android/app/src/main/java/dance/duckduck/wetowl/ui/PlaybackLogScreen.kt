package dance.duckduck.wetowl.ui

import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.text.selection.SelectionContainer
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import dance.duckduck.wetowl.BuildConfig
import dance.duckduck.wetowl.core.sendPlaybackLog

/** What the player did, in order — for the minute the screen was off when it stopped. */
@Composable
fun PlaybackLogScreen(bottom: PaddingValues) {
    val store = LocalStore.current
    val lines by store.playback.log.collectAsState()
    Column(Modifier.fillMaxSize()) {
        PageBar("Playback log", "${lines.size} lines since the app started") {
            TextButton(enabled = lines.isNotEmpty(), onClick = {
                store.launch {
                    store.api.sendPlaybackLog(store.device, "${BuildConfig.VERSION_NAME} ${BuildConfig.BUILD_STAMP}", lines)
                    store.playback.notes.tryEmit("Sent to the house")
                }
            }) { Text("Send") }
        }
        SelectionContainer {
            LazyColumn(contentPadding = PaddingValues(start = 16.dp, end = 16.dp, bottom = bottom.calculateBottomPadding())) {
                items(lines.reversed()) { l ->
                    Text(l, fontFamily = FontFamily.Monospace, fontSize = 11.sp, modifier = Modifier.padding(vertical = 2.dp),
                        color = if ("ERROR" in l) MaterialTheme.colorScheme.error else MaterialTheme.colorScheme.onSurfaceVariant)
                }
            }
        }
    }
}
