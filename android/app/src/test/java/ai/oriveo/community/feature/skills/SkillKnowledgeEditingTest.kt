package ai.oriveo.community.feature.skills

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class SkillKnowledgeEditingTest {

    @Test
    fun `sanitizeKnowledgeFileName removes controls and keeps extension`() {
        val sanitized = sanitizeKnowledgeFileName(
            "line1\n\t" + "a".repeat(140) + ".txt",
        )

        assertTrue(!sanitized.contains('\n'))
        assertTrue(!sanitized.contains('\t'))
        assertTrue(sanitized.endsWith(".txt"))
    }

    @Test
    fun `file size check prefers metadata instead of stream available`() {
        val metadataSize = 6L * 1024 * 1024
        val resolved = resolveImportedFileSize(
            metadataSizeBytes = metadataSize,
            fallbackSizeBytes = 1_024L,
        )

        assertEquals(metadataSize, resolved)
    }

    @Test
    fun `a reference file over the size cap is rejected`() {
        assertEquals(null, validateReferenceFileSize(MAX_REFERENCE_FILE_SIZE_BYTES))
        assertEquals(
            ai.oriveo.community.core.model.SkillKnowledgeErrorCode.REFERENCE_FILE_TOO_LARGE,
            validateReferenceFileSize(MAX_REFERENCE_FILE_SIZE_BYTES + 1),
        )
    }
}
