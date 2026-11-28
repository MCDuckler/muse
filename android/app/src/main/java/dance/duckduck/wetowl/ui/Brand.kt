package dance.duckduck.wetowl.ui

import dance.duckduck.wetowl.ui.theme.*
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.material3.MaterialTheme
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.Path
import androidx.compose.ui.graphics.lerp

/** The owl: a moulded disc with two eyes lit in the accent. */
@Composable
fun OwlMark(modifier: Modifier = Modifier) {
    val accent = MaterialTheme.colorScheme.primary
    val ground = MaterialTheme.colorScheme.background
    Box(modifier.tonal(circle = true)) {
        Canvas(Modifier.fillMaxSize()) {
            val r = size.minDimension / 2
            val c = Offset(size.width / 2, size.height / 2)
            val eye = r * 0.27f
            for (dx in listOf(-0.36f, 0.36f)) {
                val at = Offset(c.x + dx * r, c.y - 0.06f * r)
                drawCircle(Brush.radialGradient(listOf(lerp(accent, Color.White, 0.25f), accent),
                    center = at - Offset(eye * 0.3f, eye * 0.3f), radius = eye * 1.3f), eye, at)
                drawCircle(ground, eye * 0.48f, at)
                drawCircle(Color.White.copy(alpha = 0.85f), eye * 0.16f, at - Offset(eye * 0.18f, eye * 0.2f))
            }
            val beak = Path().apply {
                moveTo(c.x - r * 0.08f, c.y + r * 0.2f)
                lineTo(c.x + r * 0.08f, c.y + r * 0.2f)
                lineTo(c.x, c.y + r * 0.34f)
                close()
            }
            drawPath(beak, accent.copy(alpha = 0.8f))
        }
    }
}
