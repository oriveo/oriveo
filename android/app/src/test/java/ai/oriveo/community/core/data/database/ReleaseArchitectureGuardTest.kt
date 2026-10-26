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

    /**
     * The Room version, the registered migrations and the exported schema have to agree.
     *
     * Every assertion is derived from the live code and **no version number is hard-coded**. A
     * guard that pins a literal version has to be edited by hand every time a migration is added,
     * which means it expires by itself — and a guard that expires is no guard at all.
     */
    @Test
    fun `room migrations are registered and the current schema is exported`() {
        val databaseSource = File(
            "src/main/java/ai/oriveo/community/core/data/database/OriveoDatabase.kt",
        ).readText()
        val moduleSource = File("src/main/java/ai/oriveo/community/di/DatabaseModule.kt").readText()

        val version = Regex("""version = (\d+)""").find(databaseSource)
            ?.groupValues?.get(1)?.toInt()
            ?: error("could not parse the Room version out of OriveoDatabase.kt")
        assertTrue(databaseSource.contains("exportSchema = true"))

        val declared = Regex("""val (MIGRATION_(\d+)_(\d+))""").findAll(databaseSource)
            .map { Triple(it.groupValues[1], it.groupValues[2].toInt(), it.groupValues[3].toInt()) }
            .toList()
        assertTrue("No migration was parsed — the regex has drifted from the code, not the other way round.", declared.isNotEmpty())

        // Declared but not registered means Room throws IllegalStateException on upgrade. Production registers only the allMigrations set.
        assertTrue(
            "DatabaseModule must register the OriveoDatabase.allMigrations set",
            moduleSource.contains("*OriveoDatabase.allMigrations"),
        )
        val registered = OriveoDatabase.allMigrations().map { it.startVersion to it.endVersion }.toSet()
        declared.forEach { (name, from, to) ->
            assertTrue(
                "$name is declared but missing from OriveoDatabase.allMigrations — existing installs would crash on upgrade.",
                (from to to) in registered,
            )
        }

        // The upgrade chain has to reach the current version without a gap.
        val earliest = declared.minOf { it.second }
        for (step in (earliest + 1)..version) {
            assertTrue(
                "Nothing migrates to v$step, so an existing install would crash on the way there.",
                declared.any { (_, from, to) -> to == step && from < step },
            )
        }

        val schemaFile = File(
            "schemas/ai.oriveo.community.core.data.database.OriveoDatabase/$version.json",
        )
        assertTrue(
            "The Room schema JSON for v$version must be exported and committed: hand-written migration SQL that is " +
                "one character off is a crash on open in production, and the exported schema is the only thing that pins it down.",
            schemaFile.exists(),
        )
        val schema = schemaFile.readText()
        assertTrue(schema.contains("\"version\": $version"))

        // Below: columns, tables and constraints that must not get lost in a later migration. They
        // follow the current version rather than pinning an old one.
        assertTrue(schema.contains("`capabilityExecutionResultsJson` TEXT"))
        assertTrue(schema.contains("`customRetryWithoutFieldsAvailable` INTEGER NOT NULL"))
        // NOCASE on id and reference columns is what keeps a single UUID from becoming two rows,
        // which would hand the list two identical keys and break rendering. New tables follow suit.
        assertTrue(schema.contains("`id` TEXT NOT NULL COLLATE NOCASE"))
        assertTrue(schema.contains("`conversationId` TEXT NOT NULL COLLATE NOCASE"))
        assertTrue(schema.contains("`folderID` TEXT COLLATE NOCASE"))
        assertTrue(schema.contains("`noteFolderID` TEXT COLLATE NOCASE"))
        assertTrue(schema.contains("PRIMARY KEY(`id`, `accountId`)"))
        assertTrue(schema.contains("FOREIGN KEY(`conversationId`, `accountId`)"))
        // Conversation search: both the count table and the FTS index are trigger-maintained, so a
        // missing table means nothing is findable and every count reads zero.
        assertTrue(schema.contains("conversation_message_counts"))
        assertTrue(schema.contains("conversation_search_index"))
    }

    /** The migration set tests open databases with must be the production set: a hand-written subset goes stale (and red) with every new version. */
    @Test
    fun `tests open databases with the production migration set`() {
        val offenders = File("src/test").walkTopDown()
            .filter { it.isFile && it.extension == "kt" }
            .flatMap { file ->
                Regex("""\.addMigrations\(([^)]*)""").findAll(file.readText())
                    .filterNot { it.groupValues[1].trim().startsWith("*OriveoDatabase.allMigrations(") }
                    .map { "${file.name}: ${it.value}" }
            }
            .toList()
        assertTrue("addMigrations in tests must use *OriveoDatabase.allMigrations(...): $offenders", offenders.isEmpty())
    }
}
