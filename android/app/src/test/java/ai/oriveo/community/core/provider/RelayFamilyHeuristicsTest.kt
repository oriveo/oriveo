package ai.oriveo.community.core.provider

import ai.oriveo.community.core.model.RelayKind
import org.junit.Assert.assertEquals
import org.junit.Test

class RelayFamilyHeuristicsTest {

    @Test
    fun `fixtures match shared contract`() {
        FIXTURES.forEach { fixture ->
            assertEquals(
                "modelId=${fixture.modelId.ifEmpty { "<empty>" }}",
                fixture.expected,
                RelayFamilyHeuristics.infer(fixture.modelId),
            )
        }
    }

    @Test
    fun `case and whitespace are ignored`() {
        assertEquals(RelayModelFamily.OpenAI, RelayFamilyHeuristics.infer("  GPT-4o  "))
        assertEquals(RelayModelFamily.Anthropic, RelayFamilyHeuristics.infer("CLAUDE-OPUS-4"))
    }

    @Test
    fun `null and unknown values fall back to null`() {
        assertEquals(null, RelayFamilyHeuristics.infer(null))
        assertEquals(null, RelayFamilyHeuristics.infer("o5-mini"))
        assertEquals(null, RelayFamilyHeuristics.infer("my-custom-model"))
    }

    @Test
    fun `compatible relay kinds match shared contract`() {
        assertEquals(
            listOf(RelayKind.OpenAICompatible, RelayKind.CodexStyle),
            RelayFamilyHeuristics.compatibleRelayKinds(RelayModelFamily.OpenAI),
        )
        assertEquals(
            listOf(RelayKind.AnthropicCompatible),
            RelayFamilyHeuristics.compatibleRelayKinds(RelayModelFamily.Anthropic),
        )
        assertEquals(
            listOf(RelayKind.GeminiCompatible),
            RelayFamilyHeuristics.compatibleRelayKinds(RelayModelFamily.Google),
        )
        assertEquals(emptyList<RelayKind>(), RelayFamilyHeuristics.compatibleRelayKinds(RelayModelFamily.DeepSeek))
        assertEquals(emptyList<RelayKind>(), RelayFamilyHeuristics.compatibleRelayKinds(null))
    }

    @Test
    fun `suggested relay kind is only returned for deterministic provider families`() {
        assertEquals(RelayKind.OpenAICompatible, RelayFamilyHeuristics.suggestedRelayKind(RelayModelFamily.OpenAI))
        assertEquals(RelayKind.AnthropicCompatible, RelayFamilyHeuristics.suggestedRelayKind(RelayModelFamily.Anthropic))
        assertEquals(RelayKind.GeminiCompatible, RelayFamilyHeuristics.suggestedRelayKind(RelayModelFamily.Google))
        assertEquals(null, RelayFamilyHeuristics.suggestedRelayKind(RelayModelFamily.Qwen))
        assertEquals(null, RelayFamilyHeuristics.suggestedRelayKind(null))
    }

    private data class Fixture(
        val modelId: String,
        val expected: RelayModelFamily?,
    )

    companion object {
        private val FIXTURES = listOf(
            Fixture("gpt-5.4", RelayModelFamily.OpenAI),
            Fixture("gpt-image-2", RelayModelFamily.OpenAI),
            Fixture("gpt-4o-mini", RelayModelFamily.OpenAI),
            Fixture("o3-mini", RelayModelFamily.OpenAI),
            Fixture("o4", RelayModelFamily.OpenAI),
            Fixture("chatgpt-4o-latest", RelayModelFamily.OpenAI),
            Fixture("dall-e-3", RelayModelFamily.OpenAI),
            Fixture("whisper-1", RelayModelFamily.OpenAI),
            Fixture("tts-1-hd", RelayModelFamily.OpenAI),
            Fixture("text-embedding-3-large", RelayModelFamily.OpenAI),
            Fixture("claude-opus-4", RelayModelFamily.Anthropic),
            Fixture("claude-sonnet-4-5", RelayModelFamily.Anthropic),
            Fixture("claude-haiku-4-5", RelayModelFamily.Anthropic),
            Fixture("gemini-2.5-pro", RelayModelFamily.Google),
            Fixture("gemini-2.0-flash", RelayModelFamily.Google),
            Fixture("imagen-3", RelayModelFamily.Google),
            Fixture("deepseek-v3", RelayModelFamily.DeepSeek),
            Fixture("deepseek-r1", RelayModelFamily.DeepSeek),
            Fixture("ds-coder-v2", RelayModelFamily.DeepSeek),
            Fixture("qwen2.5-72b", RelayModelFamily.Qwen),
            Fixture("qwen3-32b", RelayModelFamily.Qwen),
            Fixture("qwq-32b", RelayModelFamily.Qwen),
            Fixture("grok-3", RelayModelFamily.XAI),
            Fixture("grok-vision-beta", RelayModelFamily.XAI),
            Fixture("llama-3.3-70b", RelayModelFamily.Meta),
            Fixture("codellama-34b", RelayModelFamily.Meta),
            Fixture("mistral-large", RelayModelFamily.Mistral),
            Fixture("mixtral-8x22b", RelayModelFamily.Mistral),
            Fixture("codestral-22b", RelayModelFamily.Mistral),
            Fixture("my-custom-model", null),
            Fixture("unknown-xyz-2026", null),
            Fixture("", null),
        )
    }
}
