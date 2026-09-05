package ai.oriveo.community.feature.skills

import ai.oriveo.community.core.model.SkillKnowledgeBase
import ai.oriveo.community.core.model.SkillKnowledgeFileStatus
import ai.oriveo.community.core.model.SkillKnowledgeIngestionMode
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
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
    fun `draft cleanup keeps persisted remote files and only removes temp uploads`() {
        val original = SkillKnowledgeBase(
            provider = "openai",
            retrievalModel = "gpt-5.4-mini",
            vectorStoreId = "vs_123",
            expiresAfterDays = 90,
            files = listOf(
                buildLocalKnowledgeBaseFile(
                    id = "kb-1",
                    name = "guide.txt",
                    mimeType = "text/plain",
                    sizeBytes = 42,
                    ingestionMode = SkillKnowledgeIngestionMode.NATIVE_FILE,
                    status = SkillKnowledgeFileStatus.READY,
                    openAIFileId = "file-old-1",
                ),
            ),
        )
        val current = original.copy(
            files = listOf(
                buildLocalKnowledgeBaseFile(
                    id = "kb-1",
                    name = "guide.txt",
                    mimeType = "text/plain",
                    sizeBytes = 42,
                    ingestionMode = SkillKnowledgeIngestionMode.NATIVE_FILE,
                    status = SkillKnowledgeFileStatus.READY,
                    openAIFileId = "file-new-1",
                ),
                buildLocalKnowledgeBaseFile(
                    id = "kb-2",
                    name = "appendix.txt",
                    mimeType = "text/plain",
                    sizeBytes = 21,
                    ingestionMode = SkillKnowledgeIngestionMode.NATIVE_FILE,
                    status = SkillKnowledgeFileStatus.READY,
                    openAIFileId = "file-new-2",
                ),
            ),
        )

        val plan = buildDraftKnowledgeCleanupPlan(
            originalKnowledgeBase = original,
            currentKnowledgeBase = current,
        )

        assertEquals("vs_123", plan?.vectorStoreId)
        assertFalse(plan?.deleteVectorStore ?: true)
        assertEquals(listOf("file-new-1", "file-new-2"), plan?.openAIFileIds)
    }

    @Test
    fun `new unsaved skill cleanup removes draft vector store`() {
        val current = SkillKnowledgeBase(
            provider = "openai",
            retrievalModel = "gpt-5.4-mini",
            vectorStoreId = "vs_new",
            expiresAfterDays = 90,
            files = listOf(
                buildLocalKnowledgeBaseFile(
                    id = "kb-1",
                    name = "guide.txt",
                    mimeType = "text/plain",
                    sizeBytes = 42,
                    ingestionMode = SkillKnowledgeIngestionMode.NATIVE_FILE,
                    status = SkillKnowledgeFileStatus.READY,
                    openAIFileId = "file-temp-1",
                ),
            ),
        )

        val plan = buildDraftKnowledgeCleanupPlan(
            originalKnowledgeBase = null,
            currentKnowledgeBase = current,
        )

        assertEquals("vs_new", plan?.vectorStoreId)
        assertTrue(plan?.deleteVectorStore == true)
        assertEquals(listOf("file-temp-1"), plan?.openAIFileIds)
    }

    @Test
    fun `draft cleanup is empty when no remote temp resource exists`() {
        val original = SkillKnowledgeBase(
            provider = "openai",
            retrievalModel = "gpt-5.4-mini",
            vectorStoreId = "vs_123",
            expiresAfterDays = 90,
            files = listOf(
                buildLocalKnowledgeBaseFile(
                    id = "kb-1",
                    name = "guide.txt",
                    mimeType = "text/plain",
                    sizeBytes = 42,
                    ingestionMode = SkillKnowledgeIngestionMode.NATIVE_FILE,
                    status = SkillKnowledgeFileStatus.READY,
                    openAIFileId = "file-old-1",
                ),
            ),
        )

        assertNull(
            buildDraftKnowledgeCleanupPlan(
                originalKnowledgeBase = original,
                currentKnowledgeBase = original,
            ),
        )
    }
}
