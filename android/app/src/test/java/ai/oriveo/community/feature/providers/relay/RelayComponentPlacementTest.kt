package ai.oriveo.community.feature.providers.relay

import java.io.File
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class RelayComponentPlacementTest {

    @Test
    fun `relay detail composables live in relay package`() {
        val projectRoot = generateSequence(File(".").canonicalFile) { it.parentFile }
            .first { File(it, "settings.gradle.kts").exists() }
        val detailScreen = File(
            projectRoot,
            "app/src/main/java/ai/oriveo/community/feature/providers/detail/ProviderDetailScreen.kt",
        ).readText()
        val relayDir = File(projectRoot, "app/src/main/java/ai/oriveo/community/feature/providers/relay")

        val movedComposables = listOf(
            "RelayAdvancedSettingsSheet",
            "RelayPresetModeInfoCard",
            "RelayWebSearchToolNameCard",
            "RelayAdvancedHttpDisclosure",
            "RelayKvSection",
        )

        movedComposables.forEach { name ->
            assertFalse(
                "$name should not be declared in ProviderDetailScreen.kt",
                detailScreen.contains("fun $name("),
            )
            assertTrue(
                "$name should be declared under feature/providers/relay",
                relayDir.walkTopDown()
                    .filter { it.isFile && it.extension == "kt" }
                    .any { it.readText().contains("fun $name(") },
            )
        }
    }
}
