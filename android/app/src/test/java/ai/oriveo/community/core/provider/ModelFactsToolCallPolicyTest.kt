package ai.oriveo.community.core.provider

import ai.oriveo.community.core.model.AIModel
import ai.oriveo.community.core.model.Provider
import ai.oriveo.community.core.model.ProviderAuthMode
import ai.oriveo.community.core.model.ProviderKind
import java.io.File
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test

class ModelFactsToolCallPolicyTest {
    @Before
    fun loadProductionFacts() {
        MetadataTestFixtures.applyRaw(productionFixture())
    }

    @After
    fun clearMetadata() {
        MetadataTestFixtures.clear()
    }

    @Test
    fun `subscription model facts authorize the real adapter`() {
        val provider = Provider(
            id = "grok-subscription",
            kind = ProviderKind.Grok,
            authMode = ProviderAuthMode.Subscription,
        )
        val model = AIModel(id = "grok-4.6", name = "Grok 4.6")

        val projection = CapabilityEvidenceProductionAdapter.toolCallProjection(provider, model)
        val decision = projection.decision("tool_call")!!
        assertEquals("model_facts", decision.resolution.source)
        assertEquals("supported", decision.resolution.support)
        assertTrue(decision.permitsOutbound)
        assertEquals("openai_responses", projection.identity?.effectiveTransport)
    }

    @Test
    fun `first party declaration wins and catalog external false remains blocked`() {
        val grok = Provider(
            id = "grok-subscription",
            kind = ProviderKind.Grok,
            authMode = ProviderAuthMode.Subscription,
        )
        val firstPartyFalse = AIModel(id = "grok-4.6", name = "Grok 4.6", toolCall = false)
        val firstParty = CapabilityEvidenceProductionAdapter.toolCallProjection(grok, firstPartyFalse)
        assertEquals("server_profile", firstParty.decision("tool_call")?.resolution?.source)
        assertFalse(firstParty.permitsOutbound("tool_call"))

        val gemini = Provider(id = "gemini-manual", kind = ProviderKind.Gemini)
        val manual = AIModel(
            id = "gemini-2.5-flash-image",
            name = "Gemini image",
            isManual = true,
        )
        val modelFactsFalse = CapabilityEvidenceProductionAdapter.toolCallProjection(gemini, manual)
        assertEquals("model_facts", modelFactsFalse.decision("tool_call")?.resolution?.source)
        assertEquals("gemini_generate", modelFactsFalse.identity?.effectiveTransport)
        assertFalse(modelFactsFalse.permitsOutbound("tool_call"))
    }

    @Test
    fun `unknown catalog external model fails open only with a concrete local adapter`() {
        val provider = Provider(id = "manual-mistral", kind = ProviderKind.Mistral)
        val model = AIModel(id = "future-model-not-in-facts", name = "Future", isManual = true)
        val projection = CapabilityEvidenceProductionAdapter.toolCallProjection(provider, model)

        assertEquals("unknown", projection.decision("tool_call")?.resolution?.support)
        assertEquals("user_accepted_unverified", projection.decision("tool_call")?.resolution?.reasonCode)
        assertTrue(projection.permitsOutbound("tool_call"))
        assertEquals("openai_chat", projection.identity?.effectiveTransport)
    }

    private fun productionFixture(): String {
        val moduleDir = File(System.getProperty("user.dir") ?: ".").absoluteFile
        val repoRoot = moduleDir.parentFile!!.parentFile!!
        return File(repoRoot, "shared/test-fixtures/model-facts/production-slice.v1.json")
            .also { require(it.exists()) { "fixture not found at: ${it.absolutePath}" } }
            .readText(Charsets.UTF_8)
    }
}
