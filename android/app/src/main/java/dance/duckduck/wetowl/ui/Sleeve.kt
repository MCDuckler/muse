package dance.duckduck.wetowl.ui

import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.gestures.detectDragGestures
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.rounded.Undo
import androidx.compose.material.icons.rounded.DeleteSweep
import androidx.compose.material.icons.rounded.LineWeight
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import dance.duckduck.wetowl.core.Api
import dance.duckduck.wetowl.core.arr
import dance.duckduck.wetowl.core.bool
import dance.duckduck.wetowl.core.dbl
import dance.duckduck.wetowl.core.int
import dance.duckduck.wetowl.core.objects
import dance.duckduck.wetowl.core.str
import kotlinx.coroutines.delay
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonArray
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.doubleOrNull
import kotlinx.serialization.json.put

/** The felt pens a sleeve is written on with: few, and none bright — it is card. */
private val INKS = listOf(Color(0xFF23201C), Color(0xFFB23A2E), Color(0xFF1F5FA6), Color(0xFF2E7D4F), Color(0xFFF2EDE3))
private const val GRID = 72

data class Stroke(val id: String, val ink: Int, val width: Float, val points: List<Float>, val author: Int?)

suspend fun Api.marks(trackId: Int): List<Stroke> = obj("GET", "/tracks/$trackId/marks").arr("strokes").objects {
    Stroke(it.str("stroke_id") ?: return@objects null, it.int("ink") ?: 0, it.dbl("width")?.toFloat() ?: 1f,
        (it["points"] as? kotlinx.serialization.json.JsonArray)?.mapNotNull { p -> (p as? JsonPrimitive)?.doubleOrNull?.toFloat() } ?: emptyList(),
        it.int("author_id"))
}

suspend fun Api.draw(trackId: Int, s: Stroke, done: Boolean) {
    raw("POST", "/tracks/$trackId/marks", json = buildJsonObject {
        put("stroke_id", s.id); put("ink", s.ink); put("width", s.width); put("done", done)
        put("points", buildJsonArray { s.points.forEach { add(JsonPrimitive(it)) } })
    })
}
suspend fun Api.erase(trackId: Int, strokeId: String) { raw("DELETE", "/tracks/$trackId/marks/" + android.net.Uri.encode(strokeId)) }
suspend fun Api.wipe(trackId: Int) { raw("DELETE", "/tracks/$trackId/marks") }

/**
 * The back of the sleeve: bare kraft board to draw on with a thumb, in pixels of a
 * fixed grid. What is drawn stays with the record — and in a jam it is the host's
 * board, so the whole room draws on the same one and sees each line as it is made.
 */
@Composable
fun SleeveBack(trackId: Int, side: Dp, modifier: Modifier = Modifier) {
    val store = LocalStore.current
    var strokes by remember(trackId) { mutableStateOf<List<Stroke>>(emptyList()) }
    var ink by remember { mutableIntStateOf(0) }
    var width by remember { mutableStateOf(1f) }
    var mine by remember { mutableStateOf<List<String>>(emptyList()) }
    var live by remember { mutableStateOf<Stroke?>(null) }
    var sentAt by remember { mutableStateOf(0L) }
    LaunchedEffect(trackId) { runCatching { strokes = store.api.marks(trackId) } }
    // Somebody else's pen, as it moves.
    LaunchedEffect(trackId) {
        store.others.collect { e ->
            val d = e.data
            if (d.int("track_id") != trackId) return@collect
            when (e.name) {
                "sleeve_mark" -> {
                    val s = Stroke(d.str("stroke_id") ?: return@collect, d.int("ink") ?: 0, d.dbl("width")?.toFloat() ?: 1f,
                        (d["points"] as? kotlinx.serialization.json.JsonArray)?.mapNotNull { (it as? JsonPrimitive)?.doubleOrNull?.toFloat() }
                            ?: emptyList(), d.int("author_id"))
                    if (s.id !in mine) strokes = strokes.filter { it.id != s.id } + s
                }
                "sleeve_erase" -> strokes = strokes.filter { it.id != d.str("stroke_id") }
                "sleeve_wiped" -> strokes = emptyList()
            }
        }
    }
    fun send(s: Stroke, done: Boolean) = store.launch { store.api.draw(trackId, s, done) }

    Column(modifier, horizontalAlignment = Alignment.CenterHorizontally) {
        Canvas(Modifier.size(side).clip(RoundedCornerShape(16.dp))
            .pointerInput(trackId, ink, width) {
                detectDragGestures(
                    onDragStart = { o ->
                        val s = Stroke("a" + System.nanoTime().toString(36), ink, width,
                            listOf(o.x / size.width, o.y / size.height), null)
                        live = s; mine = mine + s.id
                    },
                    onDragEnd = {
                        live?.let { s -> strokes = strokes + s; send(s, true) }
                        live = null
                    },
                ) { change, _ ->
                    val s = live ?: return@detectDragGestures
                    val p = change.position
                    val next = s.copy(points = s.points + listOf((p.x / size.width).coerceIn(0f, 1f), (p.y / size.height).coerceIn(0f, 1f)))
                    live = next
                    val now = System.currentTimeMillis()
                    // The line goes out while it is being drawn, a few times a second.
                    if (now - sentAt > 180 && next.points.size < 2400) { sentAt = now; send(next, false) }
                }
            }) {
            drawRect(Color(0xFFBFB093))
            drawRect(Brush.horizontalGradient(listOf(Color(0x22000000), Color.Transparent), endX = size.width * 0.04f),
                size = Size(size.width * 0.04f, size.height))
            val cell = size.width / GRID
            (strokes + listOfNotNull(live)).forEach { s ->
                val nib = if (s.width <= 1.5f) 1 else if (s.width <= 3f) 2 else 3
                val filled = HashSet<Int>()
                fun stamp(cx: Int, cy: Int) {
                    val half = nib / 2
                    for (dy in 0 until nib) for (dx in 0 until nib) {
                        val x = cx - half + dx; val y = cy - half + dy
                        if (x in 0 until GRID && y in 0 until GRID) filled += y * GRID + x
                    }
                }
                val pts = s.points
                if (pts.size < 2) return@forEach
                var px = (pts[0] * GRID).toInt(); var py = (pts[1] * GRID).toInt()
                stamp(px, py)
                var i = 2
                while (i + 1 < pts.size) {
                    val nx = (pts[i] * GRID).toInt(); val ny = (pts[i + 1] * GRID).toInt()
                    // Bresenham between samples, so a quick stroke is not a dotted line.
                    var x0 = px; var y0 = py
                    val dx = kotlin.math.abs(nx - x0); val sx = if (x0 < nx) 1 else -1
                    val dy = -kotlin.math.abs(ny - y0); val sy = if (y0 < ny) 1 else -1
                    var err = dx + dy
                    while (true) {
                        stamp(x0, y0)
                        if (x0 == nx && y0 == ny) break
                        val e2 = 2 * err
                        if (e2 >= dy) { err += dy; x0 += sx }
                        if (e2 <= dx) { err += dx; y0 += sy }
                    }
                    px = nx; py = ny; i += 2
                }
                val colour = INKS[s.ink.coerceIn(0, INKS.size - 1)]
                filled.forEach { c -> drawRect(colour, Offset((c % GRID) * cell, (c / GRID) * cell), Size(cell + 0.5f, cell + 0.5f)) }
            }
        }
        Row(Modifier.padding(top = 10.dp), horizontalArrangement = Arrangement.spacedBy(10.dp), verticalAlignment = Alignment.CenterVertically) {
            INKS.forEachIndexed { i, c ->
                Box(Modifier.size(28.dp).clip(CircleShape).background(c)
                    .then(if (i == ink) Modifier.border(3.dp, MaterialTheme.colorScheme.primary, CircleShape) else Modifier)
                    .clickable { ink = i })
            }
            Spacer(Modifier.size(4.dp))
            IconButton(onClick = { width = if (width < 1.5f) 2.5f else if (width < 3f) 4f else 1f }) {
                Icon(Icons.Rounded.LineWeight, "Pen width")
            }
            IconButton(onClick = {
                val last = mine.lastOrNull { id -> strokes.any { it.id == id } } ?: return@IconButton
                strokes = strokes.filter { it.id != last }; mine = mine - last
                store.launch { store.api.erase(trackId, last) }
            }) { Icon(Icons.AutoMirrored.Rounded.Undo, "Take back your last line") }
            IconButton(onClick = { strokes = emptyList(); store.launch { store.api.wipe(trackId) } }) {
                Icon(Icons.Rounded.DeleteSweep, "Wipe the sleeve")
            }
        }
    }
}
