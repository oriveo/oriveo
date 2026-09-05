package ai.oriveo.community.core.util

import ai.oriveo.community.core.model.ProviderKind
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Golden-vector tests for deterministic provider ids -- locks in the exact UUIDv5 values every
 * platform must produce. Any drift in the algorithm, namespace, or canonicalKind gets caught
 * here (all clients assert against the same set of values). The uppercase output form is pinned
 * separately below, so the vectors themselves are compared case-insensitively.
 */
class DeterministicProviderIdTest {

    // no region (name = "{kind}|")
    @Test
    fun `golden vectors for region-less providers`() {
        assertEquals("cee693bc-01b3-5542-a639-d3263af0d47a", id(ProviderKind.OpenAI, "").lowercase())
        assertEquals("f4d47a73-2034-5ceb-b2b7-366412c44a5b", id(ProviderKind.Anthropic, "").lowercase())
        assertEquals("ef43015b-fe23-5d59-8d1e-460c5d07d447", id(ProviderKind.Gemini, "").lowercase())
        assertEquals("644b24b7-e017-5253-bdda-2e1d24a0608e", id(ProviderKind.OpenRouter, "").lowercase())
        assertEquals("72efde43-1ebd-5251-8bf8-87596caccd04", id(ProviderKind.DeepSeek, "").lowercase())
        assertEquals("2238ee91-0bc2-51cc-aa86-595f0b0bf865", id(ProviderKind.Grok, "").lowercase())
        assertEquals("1c71c539-54cf-5613-b913-e994161df74f", id(ProviderKind.Groq, "").lowercase())
        assertEquals("91dd594c-1437-5c33-a923-ea5debc43d02", id(ProviderKind.Together, "").lowercase())
        assertEquals("3abbd200-caf5-5d8b-a473-4fe3e92ae39d", id(ProviderKind.Fireworks, "").lowercase())
        assertEquals("6993d319-cd3a-5d36-8ddc-17c7d32b00ea", id(ProviderKind.Zhipu, "").lowercase())
        assertEquals("986b6cd0-2eca-570b-bced-00d4d6708c81", id(ProviderKind.Mistral, "").lowercase())
        assertEquals("dee48b1e-584b-51f4-8a1f-f921e52796ea", id(ProviderKind.SiliconFlow, "").lowercase())
    }

    // with region (name = "{kind}|{regionId}")
    @Test
    fun `golden vectors for region-aware providers`() {
        assertEquals("c1f9299a-51d9-51ed-9b4f-853dec6875a6", id(ProviderKind.MiniMax, "global").lowercase())
        assertEquals("53ca3fcb-2e5c-5b51-bda0-61fc22339096", id(ProviderKind.MiniMax, "cn").lowercase())
        assertEquals("b5e00f0c-3e68-5e10-b66c-a6dad2fd7263", id(ProviderKind.Qwen, "sg").lowercase())
        assertEquals("248f0148-c596-5b0a-a5ee-7d9091f789f0", id(ProviderKind.Qwen, "bj").lowercase())
        assertEquals("b64ed15a-f012-574c-808e-1a728151ecf3", id(ProviderKind.Qwen, "hk").lowercase())
        assertEquals("92d43121-6b8a-5e38-a831-6506372a84ab", id(ProviderKind.Qwen, "us").lowercase())
        assertEquals("e8bdd52a-8670-5ff1-8bc4-6d7653977089", id(ProviderKind.Moonshot, "intl").lowercase())
        assertEquals("6331c09b-260b-5105-aa15-63380223d72e", id(ProviderKind.Moonshot, "cn").lowercase())
        assertEquals("dee48b1e-584b-51f4-8a1f-f921e52796ea", id(ProviderKind.SiliconFlow, "cn").lowercase())
        assertEquals("9935660f-5b1a-50ce-b700-42da5090fe1b", id(ProviderKind.SiliconFlow, "intl").lowercase())
    }

    @Test
    fun `result is a valid uppercase v5 uuid`() {
        val v5Regex = Regex("^[0-9A-F]{8}-[0-9A-F]{4}-5[0-9A-F]{3}-[89AB][0-9A-F]{3}-[0-9A-F]{12}$")
        for (kind in ProviderKind.entries) {
            if (kind == ProviderKind.Relay) continue
            val value = id(kind, "")
            assertTrue("$kind -> $value must be a valid uppercase v5 UUID", v5Regex.matches(value))
        }
    }

    @Test
    fun `deterministic across calls`() {
        assertEquals(id(ProviderKind.OpenAI, ""), id(ProviderKind.OpenAI, ""))
        assertEquals(id(ProviderKind.Qwen, "bj"), id(ProviderKind.Qwen, "bj"))
    }

    private fun id(kind: ProviderKind, regionId: String): String =
        DeterministicProviderId.forProvider(kind, regionId)
}
