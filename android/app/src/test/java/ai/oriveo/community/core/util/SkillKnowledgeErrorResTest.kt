package ai.oriveo.community.core.util

import ai.oriveo.community.R
import ai.oriveo.community.core.data.api.SkillApiService
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Test

class SkillKnowledgeErrorResTest {

    @Test
    fun write_error_keeps_knowledge_code() {
        val expected = mapOf(
            "openai_not_configured" to R.string.skills_knowledgeErrorOpenAI,
            "openai_endpoint_not_official" to R.string.skills_knowledgeErrorEndpoint,
            "retrieval_model_not_enabled" to R.string.skills_knowledgeErrorModelDisabled,
            "knowledge_service_unavailable" to R.string.skills_knowledgeErrorServiceUnavailable,
            "unsupported_file_type" to R.string.skills_knowledgeErrorUnsupportedType,
            "reference_file_too_large" to R.string.skills_fileTooLarge,
            "knowledge_file_too_large" to R.string.skills_knowledgeErrorFileTooLarge,
            "knowledge_total_size_exceeded" to R.string.skills_knowledgeErrorQuotaExceeded,
            "knowledge_extract_failed" to R.string.skills_knowledgeErrorExtractFailed,
            "knowledge_upload_failed" to R.string.skills_knowledgeErrorUploadFailed,
            "knowledge_index_failed" to R.string.skills_knowledgeErrorIndexFailed,
            "knowledge_retrieve_failed" to R.string.skills_knowledgeErrorRetrieveFailed,
            "knowledge_cleanup_failed" to R.string.skills_knowledgeErrorCleanupFailed,
        )
        assertEquals("the knowledge base error set has 13 codes", 13, expected.size)
        expected.forEach { (code, res) ->
            assertEquals(code, res, SkillL10n.knowledgeErrorRes(code))
        }
        assertEquals(R.string.skills_knowledgeErrorCleanupFailed, SkillL10n.knowledgeErrorRes(" knowledge_cleanup_failed\n"))

        assertNull(SkillL10n.knowledgeErrorRes("skill_not_found"))
        assertNull(SkillL10n.knowledgeErrorRes("Request failed: 500"))
        assertNull(SkillL10n.knowledgeErrorRes(""))
    }

    @Test
    fun envelope_502_knowledge_code_reaches_copy() {
        // Production chain: server envelope -> SkillApiService.errorFor -> exception message -> copy resource.
        val cleanup = SkillApiService.errorFor(502, """{"code":502,"message":"cleanup failed","data":{"error":"knowledge_cleanup_failed"}}""")
        assertEquals(502, cleanup.status)
        val detail = cleanup.message.orEmpty()
        assertEquals("knowledge_cleanup_failed", detail)
        assertNotNull(SkillL10n.knowledgeErrorRes(detail))
        assertEquals(R.string.skills_knowledgeErrorCleanupFailed, SkillL10n.knowledgeErrorRes(detail))

        // A non-knowledge envelope code falls back to the generic failure copy.
        val other = SkillApiService.errorFor(502, """{"code":502,"data":{"error":"upstream_failed"}}""")
        assertNull(SkillL10n.knowledgeErrorRes(other.message.orEmpty()))
    }
}
