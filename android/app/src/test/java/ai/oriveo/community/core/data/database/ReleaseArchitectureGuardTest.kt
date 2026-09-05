package ai.oriveo.community.core.data.database

import java.io.File
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class ReleaseArchitectureGuardTest {

    @Test
    fun `database builder must not destructively migrate on upgrade`() {
        val source = File("src/main/java/ai/oriveo/community/di/DatabaseModule.kt").readText()

        assertFalse(
            "Room upgrades must fail loudly when a migration is missing; destructive fallback would delete local chat data.",
            source.contains(".fallbackToDestructiveMigration(true)"),
        )
        assertTrue(
            "Downgrades may still use destructive fallback because Play rollback installs can hit older schemas.",
            source.contains(".fallbackToDestructiveMigrationOnDowngrade(true)"),
        )
    }

    @Test
    fun `the declared room version matches the exported schema`() {
        val databaseSource = File(
            "src/main/java/ai/oriveo/community/core/data/database/OriveoDatabase.kt",
        ).readText()
        val schemaFile = File("schemas/ai.oriveo.community.core.data.database.OriveoDatabase/1.json")

        assertTrue(databaseSource.contains("version = 1"))
        assertTrue(databaseSource.contains("exportSchema = true"))
        assertTrue("The Room schema JSON must be exported and committed.", schemaFile.exists())
        assertTrue(schemaFile.readText().contains("\"version\": 1"))
    }
}
