package ai.oriveo.community.core.data.remote

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File

/**
 * Source boundary lock for the legacy decode types and capability input keys.
 *
 * In a single module `internal` cannot stop production code from referencing a type, so this scans the
 * main sources to lock down who references it; comments are stripped before matching, so a type name
 * mentioned in a comment does not count as a reference.
 */
class MetadataClientDecodeBoundaryTest {

    private val mainRoot = "android/app/src/main"

    @Test
    fun relayTransportEnvelopeOnlyReferencedByMetadataClientAndResolver() {
        assertEquals(
            emptyList<String>(),
            offenders(Regex("""\bRelayTransportEnvelope\b"""), setOf("MetadataClient.kt", "RelayOfficialCatalogResolver.kt")),
        )
    }

    @Test
    fun relayRuntimeConfigOnlyReferencedByWhitelistedFiles() {
        assertEquals(
            emptyList<String>(),
            offenders(
                Regex("""\bRelayRuntimeConfig\b"""),
                setOf(
                    "MetadataClient.kt",
                    "RelayOfficialCatalogResolver.kt",
                    "RelayRuntimeSupport.kt",
                    "ProviderToolLegRunner.kt",
                    "ChatModelCapabilityResolver.kt",
                    "RelayCatalogBoardModel.kt",
                ),
            ),
        )
    }

    @Test
    fun providerAttachmentSupportOnlyReferencedByMetadataClientAndProviderKind() {
        assertEquals(
            emptyList<String>(),
            offenders(
                Regex("""\bProviderAttachmentSupport\b|\bproviderAttachmentSupport\("""),
                setOf("MetadataClient.kt", "ProviderKind.kt"),
            ),
        )
    }

    @Test
    fun providerAttachmentSupportDeclarationsAreInternal() {
        val source = stripComments(mainFile("java/ai/oriveo/community/core/data/remote/MetadataClient.kt").readText())
        assertTrue(Regex("""internal\s+data\s+class\s+ProviderAttachmentSupport\(""").containsMatchIn(source))
        val functions = Regex("""(\w+\s+)?fun\s+providerAttachmentSupport\(""").findAll(source).toList()
        assertEquals(2, functions.size)
        functions.forEach { assertEquals("internal ", it.groupValues[1]) }
        assertTrue(
            Regex("""internal\s+val\s+attachmentSupport:\s*ProviderAttachmentSupport\?""").containsMatchIn(source),
        )
    }

    @Test
    fun relayEnvelopeAndRuntimeConfigDeclarationsAreInternal() {
        val source = stripComments(mainFile("java/ai/oriveo/community/core/data/remote/MetadataClient.kt").readText())
        assertTrue(Regex("""internal\s+data\s+class\s+RelayTransportEnvelope\(""").containsMatchIn(source))
        assertTrue(Regex("""internal\s+data\s+class\s+RelayRuntimeConfig\(""").containsMatchIn(source))
        val accessors = Regex("""(\w+\s+)?fun\s+relayRuntimeConfig\(\)""").findAll(source).toList()
        assertEquals(2, accessors.size)
        accessors.forEach { assertEquals("internal ", it.groupValues[1]) }
        assertTrue(
            Regex("""internal\s+val\s+FALLBACK_RELAY_RUNTIME_CONFIG:\s*RelayRuntimeConfig""").containsMatchIn(source),
        )
    }

    @Test
    fun facadeDeclaresThreeInputKeyConstants() {
        val source = stripComments(mainFile("java/ai/oriveo/community/core/provider/CapabilityEvidenceFacade.kt").readText())
        listOf(
            "VISION_INPUT" to "vision_input",
            "FILE_INPUT" to "file_input",
            "VIDEO_INPUT" to "video_input",
        ).forEach { (name, value) ->
            assertTrue(name, source.contains("const val $name = \"$value\""))
        }
    }

    @Test
    fun inputCapabilityProjectionIsOnlyProjectedByFacade() {
        assertEquals(
            emptyList<String>(),
            offenders(
                Regex("""\bInputCapabilityProjection\.project\("""),
                setOf("CapabilityEvidenceFacade.kt"),
            ),
        )
    }

    private fun offenders(pattern: Regex, allowedFileNames: Set<String>): List<String> {
        val root = workspaceFile(mainRoot)
        val files = root.walkTopDown().filter { it.isFile && it.extension == "kt" }.toList()
        assertTrue("no .kt files found under main", files.size > 100)
        return files
            .filter { it.name !in allowedFileNames }
            .filter { pattern.containsMatchIn(stripComments(it.readText())) }
            .map { it.relativeTo(root).path }
            .sorted()
    }

    private fun stripComments(source: String): String =
        source
            .replace(Regex("""/\*[\s\S]*?\*/"""), "")
            .replace(Regex("""//[^\n]*"""), "")

    private fun mainFile(relative: String): File = workspaceFile("$mainRoot/$relative")

    /** Walks up from the working directory to find a path relative to the repository root (same shape as MetadataTestFixtures). */
    private fun workspaceFile(relative: String): File {
        var dir: File? = File("").absoluteFile
        while (dir != null) {
            val candidate = File(dir, relative)
            if (candidate.exists()) return candidate
            dir = dir.parentFile
        }
        throw IllegalStateException("$relative not found")
    }
}
