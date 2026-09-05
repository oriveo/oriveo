package ai.oriveo.community.core.data.remote

import ai.oriveo.community.core.model.ProviderKind
import java.io.File
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class ModelFactsMetadataClientTest {
    @Test
    fun `production model facts survive sanitized cache and revision replacement`() {
        val client = MetadataClient()
        val fixture = productionFixture()

        client.loadNetworkPayloadForTesting(fixture, "etag-production-slice")

        val fact = client.modelFacts(ProviderKind.Grok, "  GROK-4.6-20260822  ")
        assertEquals(listOf("low", "medium", "high", "xhigh"), fact?.reasoningEfforts)
        assertEquals(true, fact?.toolCall)
        assertEquals(
            "sha256:7d381935dc3b7c397d6241cc965c848522241f48d618d0d822e39d9875e4b71a",
            client.modelFactsRevision(),
        )

        val persisted = client.encodedCachePayloadForTesting().orEmpty()
        assertTrue(persisted.contains("grok/grok-4.6"))
        assertTrue(persisted.contains("reasoningEfforts"))
        assertTrue(persisted.contains("modelFactsRevision"))
        assertFalse(persisted.contains("artifactHash"))

        client.loadNetworkPayloadForTesting(
            """{"version":84,"modelFactsRevision":"revision-84","modelFacts":{"grok/grok-4.6":{"toolCall":false}}}""",
            "etag-84",
        )
        assertEquals(false, client.modelFacts(ProviderKind.Grok, "grok-4.6")?.toolCall)
        assertEquals("revision-84", client.modelFactsRevision())
        assertNull(client.modelFacts(ProviderKind.Grok, "grok-never-shipped"))
    }

    @Test
    fun `model facts id normalization matches server join order`() {
        assertEquals("gpt-5.6-sol", MetadataClient.normalizeModelFactsID("GPT-5.6-Sol-20260401"))
        assertEquals("claude-sonnet-5", MetadataClient.normalizeModelFactsID("claude-sonnet-5-2026-04-01"))
        assertEquals("deepseek-v4-flash-0731", MetadataClient.normalizeModelFactsID("deepseek-v4-flash-0731"))
        assertEquals("llama-v3.1-8b", MetadataClient.normalizeModelFactsID("accounts/fireworks/models/llama-v3p1-8b"))
        assertEquals("zai-org/glm-5.1", MetadataClient.normalizeModelFactsID("Pro/zai-org/GLM-5.1"))
    }

    private fun productionFixture(): String {
        val moduleDir = File(System.getProperty("user.dir") ?: ".").absoluteFile
        val repoRoot = moduleDir.parentFile!!.parentFile!!
        return File(repoRoot, "shared/test-fixtures/model-facts/production-slice.v1.json")
            .also { require(it.exists()) { "fixture not found at: ${it.absolutePath}" } }
            .readText(Charsets.UTF_8)
    }
}
