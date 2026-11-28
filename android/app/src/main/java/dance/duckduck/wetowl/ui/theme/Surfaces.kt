package dance.duckduck.wetowl.ui.theme

import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.core.spring
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.interaction.collectIsPressedAsState
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.scale
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.Shape
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp

// Flat Material You: surfaces are told apart by tone, never by shadow. The accent's
// tonal containers mark what is selected; the accent itself only what is live.

private fun shapeOf(corner: Dp, circle: Boolean): Shape = if (circle) CircleShape else RoundedCornerShape(corner)

/** A tonal plate one step up from the ground. */
@Composable
fun Modifier.tonal(corner: Dp = 20.dp, circle: Boolean = false, color: Color? = null): Modifier {
    val c = color ?: MaterialTheme.colorScheme.surfaceContainerHigh
    return this.clip(shapeOf(corner, circle)).background(c)
}

/** A sunken track or field: a step down from the ground. */
@Composable
fun Modifier.well(corner: Dp = 18.dp, circle: Boolean = false): Modifier =
    this.clip(shapeOf(corner, circle)).background(MaterialTheme.colorScheme.surfaceContainerHighest)

/** What is selected among siblings: the accent's own container. */
@Composable
fun Modifier.picked(corner: Dp = 18.dp, circle: Boolean = false): Modifier =
    this.clip(shapeOf(corner, circle)).background(MaterialTheme.colorScheme.secondaryContainer)

/**
 * A round control. [accent] fills it with the accent (play); [active] gives it the
 * accent's tonal container; otherwise it sits on a quiet tonal disc.
 */
@Composable
fun RoundButton(
    icon: ImageVector,
    contentDescription: String?,
    onClick: () -> Unit,
    modifier: Modifier = Modifier,
    size: Dp = 52.dp,
    accent: Boolean = false,
    active: Boolean = false,
    enabled: Boolean = true,
    plain: Boolean = false,
) {
    val source = remember { MutableInteractionSource() }
    val pressed by source.collectIsPressedAsState()
    val press by animateFloatAsState(if (pressed) 1f else 0f, spring(stiffness = 900f), label = "press")
    val scheme = MaterialTheme.colorScheme
    val (bg, tint) = when {
        accent -> scheme.primary to scheme.onPrimary
        active -> scheme.secondaryContainer to scheme.onSecondaryContainer
        plain -> Color.Transparent to scheme.onSurface
        else -> scheme.surfaceContainerHigh to scheme.onSurface
    }
    Box(
        modifier
            .size(size)
            .scale(1f - press * 0.06f)
            .clip(if (accent) RoundedCornerShape(size * 0.32f) else CircleShape)
            .background(if (enabled) bg else bg.copy(alpha = bg.alpha * 0.5f))
            .clickable(source, indication = androidx.compose.material3.ripple(), enabled = enabled,
                role = Role.Button, onClick = onClick),
        contentAlignment = Alignment.Center,
    ) {
        Icon(icon, contentDescription, tint = if (enabled) tint else tint.copy(alpha = 0.4f),
            modifier = Modifier.size(size * 0.46f))
    }
}

/** A tonal card to put a group of things on. */
@Composable
fun TonalCard(
    modifier: Modifier = Modifier,
    corner: Dp = 24.dp,
    onClick: (() -> Unit)? = null,
    content: @Composable () -> Unit,
) {
    Box(
        modifier
            .tonal(corner = corner, color = MaterialTheme.colorScheme.surfaceContainer)
            .then(if (onClick != null) Modifier.clickable(onClick = onClick) else Modifier),
    ) { content() }
}
