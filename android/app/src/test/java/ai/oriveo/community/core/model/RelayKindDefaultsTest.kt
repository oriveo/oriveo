package ai.oriveo.community.core.model

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class RelayKindDefaultsTest {

    @Test
    fun `openai compatible defaults to chat completions bearer`() {
        val requested = RelayKindDefaults.makeRequested(RelayKind.OpenAICompatible)

        assertEquals(RelayTransport.OpenAIChatCompletions, requested.transport)
        assertEquals(RelayAuthMode.Bearer, requested.authMode)
        assertEquals(true, requested.stream)
        assertEquals(RelayReasoningEffort.Automatic, requested.reasoningEffort)
        assertNull(requested.disableResponseStorage)
        assertNull(requested.codexCompatIdentity)
    }

    @Test
    fun `unknown relay kind raw value falls back to custom while null stays absent`() {
        assertEquals(RelayKind.Custom, RelayKind.fromValue("future_profile"))
        assertNull(RelayKind.fromValue(null))
    }

    @Test
    fun `codex style defaults to responses bearer no storage and codex identity`() {
        val requested = RelayKindDefaults.makeRequested(RelayKind.CodexStyle)

        assertEquals(RelayTransport.OpenAIResponses, requested.transport)
        assertEquals(RelayAuthMode.Bearer, requested.authMode)
        assertEquals(true, requested.stream)
        assertEquals(true, requested.disableResponseStorage)
        assertEquals(true, requested.codexCompatIdentity)
        assertEquals(RelayReasoningEffort.Automatic, requested.reasoningEffort)
    }

    @Test
    fun `anthropic and gemini defaults use native auth modes`() {
        val anthropic = RelayKindDefaults.makeRequested(RelayKind.AnthropicCompatible)
        val gemini = RelayKindDefaults.makeRequested(RelayKind.GeminiCompatible)

        assertEquals(RelayTransport.AnthropicMessages, anthropic.transport)
        assertEquals(RelayAuthMode.XApiKey, anthropic.authMode)
        assertNull(anthropic.reasoningEffort)

        assertEquals(RelayTransport.GeminiGenerateContent, gemini.transport)
        assertEquals(RelayAuthMode.XGoogApiKey, gemini.authMode)
        assertNull(gemini.reasoningEffort)
    }

    @Test
    fun `kind reset preserves user level fields`() {
        val preserving = RelayRequestedConfig(
            transport = RelayTransport.OpenAIChatCompletions,
            authMode = RelayAuthMode.Bearer,
            modelID = "gpt-5.4",
            reasoningEffort = RelayReasoningEffort.High,
            serviceTier = "priority",
            headers = listOf(RelayKeyValue("X-Trace", "trace-1")),
            queryParams = listOf(RelayKeyValue("region", "us")),
            customUserAgent = "Custom UA",
            codexCompatIdentity = false,
        )

        val requested = RelayKindDefaults.makeRequested(RelayKind.CodexStyle, preserving)

        assertEquals(RelayTransport.OpenAIResponses, requested.transport)
        assertEquals(RelayAuthMode.Bearer, requested.authMode)
        assertEquals("gpt-5.4", requested.modelID)
        assertEquals(RelayReasoningEffort.High, requested.reasoningEffort)
        assertEquals("priority", requested.serviceTier)
        assertEquals(listOf(RelayKeyValue("X-Trace", "trace-1")), requested.headers)
        assertEquals(listOf(RelayKeyValue("region", "us")), requested.queryParams)
        assertEquals("Custom UA", requested.customUserAgent)
        assertEquals(true, requested.codexCompatIdentity)
    }

    @Test
    fun `custom kind preserves protocol fields`() {
        val preserving = RelayRequestedConfig(
            transport = RelayTransport.GeminiGenerateContent,
            authMode = RelayAuthMode.QueryKey,
            stream = false,
            disableResponseStorage = true,
            codexCompatIdentity = false,
            customUserAgent = "UA",
        )

        val requested = RelayKindDefaults.makeRequested(RelayKind.Custom, preserving)

        assertEquals(RelayTransport.GeminiGenerateContent, requested.transport)
        assertEquals(RelayAuthMode.QueryKey, requested.authMode)
        assertEquals(false, requested.stream)
        assertEquals(true, requested.disableResponseStorage)
        assertEquals(false, requested.codexCompatIdentity)
        assertEquals("UA", requested.customUserAgent)
    }

    @Test
    fun `infer kind from requested transport`() {
        assertEquals(
            RelayKind.OpenAICompatible,
            RelayKindDefaults.inferKind(
                RelayRequestedConfig(transport = RelayTransport.OpenAIChatCompletions),
            ),
        )
        assertEquals(
            RelayKind.CodexStyle,
            RelayKindDefaults.inferKind(
                RelayRequestedConfig(transport = RelayTransport.OpenAIResponses),
            ),
        )
        assertEquals(
            RelayKind.AnthropicCompatible,
            RelayKindDefaults.inferKind(
                RelayRequestedConfig(transport = RelayTransport.AnthropicMessages),
            ),
        )
        assertEquals(
            RelayKind.GeminiCompatible,
            RelayKindDefaults.inferKind(
                RelayRequestedConfig(transport = RelayTransport.GeminiGenerateContent),
            ),
        )
    }
}
