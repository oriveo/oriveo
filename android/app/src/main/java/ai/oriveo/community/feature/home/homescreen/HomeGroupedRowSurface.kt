package ai.oriveo.community.feature.home.homescreen

import androidx.compose.foundation.background
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.drawBehind
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.Shape
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp


internal enum class HomeGroupRowPosition { Single, First, Middle, Last }

internal fun homeGroupRowPosition(index: Int, count: Int): HomeGroupRowPosition = when {
    count <= 1 -> HomeGroupRowPosition.Single
    index == 0 -> HomeGroupRowPosition.First
    index == count - 1 -> HomeGroupRowPosition.Last
    else -> HomeGroupRowPosition.Middle
}

internal fun Modifier.homeGroupedRowSurface(
    surface: Color,
    border: Color,
    divider: Color,
    position: HomeGroupRowPosition,
    radius: Dp = 12.dp,
    borderWidth: Dp = 1.dp,
): Modifier {
    val isTop = position == HomeGroupRowPosition.First || position == HomeGroupRowPosition.Single
    val isBottom = position == HomeGroupRowPosition.Last || position == HomeGroupRowPosition.Single
    val shape: Shape = RoundedCornerShape(
        topStart = if (isTop) radius else 0.dp,
        topEnd = if (isTop) radius else 0.dp,
        bottomStart = if (isBottom) radius else 0.dp,
        bottomEnd = if (isBottom) radius else 0.dp,
    )
    return this
        .clip(shape)
        .background(surface)
        .drawBehind {
            val w = borderWidth.toPx()
            val r = radius.toPx()
            val topInset = if (isTop) r else 0f
            val bottomInset = if (isBottom) r else 0f
            
            drawRect(border, Offset(0f, topInset), Size(w, size.height - topInset - bottomInset))
            drawRect(border, Offset(size.width - w, topInset), Size(w, size.height - topInset - bottomInset))
            
            if (isTop) drawRect(border, Offset(r, 0f), Size(size.width - 2 * r, w))
            if (isBottom) drawRect(border, Offset(r, size.height - w), Size(size.width - 2 * r, w))
            
            if (!isBottom) {
                val pad = 16.dp.toPx()
                drawRect(divider, Offset(pad, size.height - w), Size(size.width - pad * 2, w))
            }
        }
}
