package ai.oriveo.community.core.model

import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json
import org.junit.Assert.assertEquals
import org.junit.Test

class FolderTest {

    @Test
    fun `Folder serialization preserves all fields`() {
        val folder = Folder(
            id = "f1",
            name = "Work",
            sortOrder = 1000,
            createdAt = 100L,
            updatedAt = 200L,
        )

        val json = Json.encodeToString(folder)
        val decoded = Json.decodeFromString<Folder>(json)

        assertEquals(folder.id, decoded.id)
        assertEquals(folder.name, decoded.name)
        assertEquals(folder.sortOrder, decoded.sortOrder)
        assertEquals(folder.createdAt, decoded.createdAt)
        assertEquals(folder.updatedAt, decoded.updatedAt)
    }

}
