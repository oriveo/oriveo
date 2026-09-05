package ai.oriveo.community.core.model

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Test

class FolderColorTest {

    @Test
    fun `all 10 colors exist`() {
        assertEquals(10, FolderColor.entries.size)
    }

    @Test
    fun `fromTag returns correct color`() {
        assertEquals(FolderColor.BLUE, FolderColor.fromTag("blue"))
        assertEquals(FolderColor.PINK, FolderColor.fromTag("pink"))
        assertEquals(FolderColor.GRAY, FolderColor.fromTag("gray"))
    }

    @Test
    fun `fromTag returns BLUE for null`() {
        assertEquals(FolderColor.BLUE, FolderColor.fromTag(null))
    }

    @Test
    fun `fromTag returns BLUE for unknown tag`() {
        assertEquals(FolderColor.BLUE, FolderColor.fromTag("neon"))
    }

    @Test
    fun `nextColor returns blue for empty list`() {
        assertEquals(FolderColor.BLUE, FolderColor.nextColor(emptyList()))
    }

    @Test
    fun `nextColor returns purple after blue`() {
        val folders = listOf(
            Folder(id = "1", name = "A", sortOrder = 1000, colorTag = "blue"),
        )
        assertEquals(FolderColor.PURPLE, FolderColor.nextColor(folders))
    }

    @Test
    fun `nextColor wraps around after gray`() {
        val folders = listOf(
            Folder(id = "1", name = "A", sortOrder = 1000, colorTag = "gray"),
        )
        assertEquals(FolderColor.BLUE, FolderColor.nextColor(folders))
    }

    @Test
    fun `nextColor uses last folder by sortOrder`() {
        val folders = listOf(
            Folder(id = "1", name = "A", sortOrder = 2000, colorTag = "red"),
            Folder(id = "2", name = "B", sortOrder = 1000, colorTag = "blue"),
            Folder(id = "3", name = "C", sortOrder = 3000, colorTag = "green"),
        )
        assertEquals(FolderColor.TEAL, FolderColor.nextColor(folders))
    }

    @Test
    fun `sequential 10 folders cycle full palette`() {
        val expected = FolderColor.entries.map { it.tag }
        val folders = mutableListOf<Folder>()
        for (i in 0 until 10) {
            val color = FolderColor.nextColor(folders)
            folders.add(
                Folder(
                    id = "f$i",
                    name = "Folder $i",
                    sortOrder = (i + 1) * 1000,
                    colorTag = color.tag,
                ),
            )
        }
        assertEquals(expected, folders.map { it.colorTag })
    }

    @Test
    fun `toColor returns non-null`() {
        for (fc in FolderColor.entries) {
            assertNotNull(fc.toColor())
        }
    }

    @Test
    fun `gradientBrush returns non-null`() {
        for (fc in FolderColor.entries) {
            assertNotNull(fc.gradientBrush())
        }
    }
}
