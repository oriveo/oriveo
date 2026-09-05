package ai.oriveo.community.ui.component.markdown

import androidx.compose.ui.unit.dp
import org.junit.Assert.assertEquals
import org.junit.Test

class MarkdownTableLayoutTest {

    @Test
    fun `table keeps viewport width when columns fit`() {
        val layout = resolveMarkdownTableLayout(
            viewportWidth = 320.dp,
            columnCount = 2,
        )

        assertEquals(320.dp, layout.tableWidth)
        assertEquals(160.dp, layout.columnWidth)
    }

    @Test
    fun `table grows to minimum column width when columns would collapse`() {
        val layout = resolveMarkdownTableLayout(
            viewportWidth = 320.dp,
            columnCount = 4,
        )

        assertEquals(480.dp, layout.tableWidth)
        assertEquals(120.dp, layout.columnWidth)
    }
}
