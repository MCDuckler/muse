package dance.duckduck.wetowl.ui

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.FlowRow
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.FilterChip
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Slider
import androidx.compose.material3.Switch
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.unit.dp
import dance.duckduck.wetowl.ui.theme.TonalCard

/** Tone: the phone's equalizer bands and presets, and a bass boost, on this player only. */
@Composable
fun EqualizerScreen(bottom: PaddingValues) {
    val store = LocalStore.current
    val context = androidx.compose.ui.platform.LocalContext.current
    val s by store.eq.state.collectAsState()
    Column(Modifier.fillMaxSize()) {
        PageBar("Equalizer", if (s.available) null else "Starts with the music") {
            Switch(checked = s.on, onCheckedChange = store.eq::setOn, enabled = s.available,
                modifier = Modifier.padding(end = 8.dp))
        }
        Column(Modifier.verticalScroll(rememberScrollState()).padding(bottom = bottom.calculateBottomPadding())) {
            if (!s.available) {
                Empty("The equalizer is ready once something has played. This phone may also have its own:")
                TextButton(onClick = { openEqualizer(context, store.playback.exo.audioSessionId) },
                    modifier = Modifier.padding(horizontal = 24.dp)) { Text("Open the phone's equalizer") }
                return@Column
            }
            TonalCard(Modifier.fillMaxWidth().padding(16.dp)) {
                Row(Modifier.fillMaxWidth().height(260.dp).padding(vertical = 16.dp, horizontal = 8.dp),
                    horizontalArrangement = Arrangement.SpaceEvenly, verticalAlignment = Alignment.CenterVertically) {
                    s.bands.forEachIndexed { i, b ->
                        Column(horizontalAlignment = Alignment.CenterHorizontally, modifier = Modifier.weight(1f)) {
                            Text("%+.0f".format(b.level / 100f), style = MaterialTheme.typography.labelSmall,
                                color = MaterialTheme.colorScheme.onSurfaceVariant)
                            // A fader: the slider turned on its side.
                            Slider(value = b.level.toFloat(), onValueChange = { store.eq.setBand(i, it.toInt()) },
                                valueRange = s.range.first.toFloat()..s.range.last.toFloat(), enabled = s.on,
                                modifier = Modifier.width(180.dp).graphicsLayer { rotationZ = -90f }.height(48.dp))
                            Text(if (b.centreHz >= 1000) "${b.centreHz / 1000}k" else "${b.centreHz}",
                                style = MaterialTheme.typography.labelSmall)
                        }
                    }
                }
            }
            SectionLabel("Bass boost")
            Slider(value = s.bass.toFloat(), onValueChange = { store.eq.setBass(it.toInt()) }, valueRange = 0f..1000f, enabled = s.on,
                modifier = Modifier.padding(horizontal = 24.dp))
            SectionLabel("Curves") { TextButton(onClick = store.eq::flat, enabled = s.on) { Text("Flat") } }
            FlowRow(Modifier.padding(horizontal = 18.dp), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                s.presets.forEachIndexed { i, name ->
                    FilterChip(selected = s.preset == i, onClick = { store.eq.usePreset(i) }, label = { Text(name) }, enabled = s.on)
                }
            }
        }
    }
}
