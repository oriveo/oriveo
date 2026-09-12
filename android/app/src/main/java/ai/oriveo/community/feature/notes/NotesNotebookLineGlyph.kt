package ai.oriveo.community.feature.notes

import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.graphics.StrokeJoin
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.graphics.vector.addPathNodes
import androidx.compose.ui.unit.dp

/**
 * The notebook-pen line glyph on the right of the home Notes entry (shared with the iOS `NotesNotebookLine`
 * asset, stroke 1.6).
 *
 * Differences from `ic_notes_notebook` (the solid-stroke version used as the notes screen brand icon):
 * - no binding ticks on the left: an objectBoundingBox gradient never paints a zero-height path, so they were
 *   invisible in the design anyway;
 * - the gradient is baked into the vector: #C4B5FD → #EC8FEA → #8DB4FF between the notebook body's bounding
 *   box (4,2)→(20,22) rather than the whole 24 grid. VectorPainter brush coordinates are viewport coordinates,
 *   so the points are written directly on the grid.
 *
 * Callers keep the colors with `Icon(tint = Color.Unspecified)` / `Image`.
 */
internal val NotesNotebookLineGlyph: ImageVector by lazy {
    val brush = Brush.linearGradient(
        colorStops = arrayOf(
            0f to Color(0xFFC4B5FD),
            0.5f to Color(0xFFEC8FEA),
            1f to Color(0xFF8DB4FF),
        ),
        start = Offset(4f, 2f),
        end = Offset(20f, 22f),
    )
    ImageVector.Builder(
        name = "NotesNotebookLine",
        defaultWidth = 24.dp,
        defaultHeight = 24.dp,
        viewportWidth = 24f,
        viewportHeight = 24f,
    ).apply {
        listOf(
            // Notebook body
            "M13.4 2 H6 a2 2 0 0 0 -2 2 v16 a2 2 0 0 0 2 2 h12 a2 2 0 0 0 2 -2 v-7.4",
            // Pen
            "M21.378 5.626 a1 1 0 1 0 -3.004 -3.004 l-5.01 5.012 a2 2 0 0 0 -0.506 0.854 " +
                "l-0.837 2.87 a0.5 0.5 0 0 0 0.62 0.62 l2.87 -0.837 a2 2 0 0 0 0.854 -0.506 z",
        ).forEach { path ->
            addPath(
                pathData = addPathNodes(path),
                fill = null,
                stroke = brush,
                strokeLineWidth = 1.6f,
                strokeLineCap = StrokeCap.Round,
                strokeLineJoin = StrokeJoin.Round,
            )
        }
    }.build()
}
