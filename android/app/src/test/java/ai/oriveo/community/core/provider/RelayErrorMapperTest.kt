package ai.oriveo.community.core.provider

import ai.oriveo.community.core.model.ProviderServiceError
import ai.oriveo.community.core.model.RelayAuthMode
import ai.oriveo.community.core.model.RelayKind
import ai.oriveo.community.core.model.RelayTransport
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class RelayErrorMapperTest {

    @Test
    fun `rule 1 maps chat completions input parameter mismatch to codex style guidance`() {
        val error = classify(
            status = 400,
            body = """{"error":{"message":"Unknown parameter: 'input[0]'."}}""",
            context = context(transport = RelayTransport.OpenAIChatCompletions),
        )

        assertGuidance(error, "Responses")
        assertGuidance(error, "Codex (Responses)")
    }

    @Test
    fun `rule 2 maps image schema mismatch on anthropic transport to protocol guidance`() {
        val error = classify(
            status = 400,
            body = """{"error":{"message":"image_url is invalid for this schema"}}""",
            context = context(
                transport = RelayTransport.AnthropicMessages,
                modelID = "gpt-5.4",
            ),
        )

        assertGuidance(error, "Protocol type")
    }

    @Test
    fun `rule 3 maps anthropic auth mismatch to x api key guidance`() {
        val error = classify(
            status = 403,
            body = """{"error":{"message":"authentication_error: x-api-key required"}}""",
            context = context(authMode = RelayAuthMode.Bearer, modelID = "claude-sonnet-4-5"),
        )

        assertGuidance(error, "x-api-key")
    }

    @Test
    fun `rule 4 distinguishes missing codex identity from rejected codex identity`() {
        val missingIdentity = classify(
            status = 403,
            body = """{"error":{"message":"Only Codex official clients are allowed"}}""",
            context = context(transport = RelayTransport.OpenAIChatCompletions),
        )
        val disabledIdentity = classify(
            status = 403,
            body = """{"error":{"message":"Only Codex official clients are allowed"}}""",
            context = context(
                relayKind = RelayKind.CodexStyle,
                transport = RelayTransport.OpenAIResponses,
                codexCompatIdentity = false,
            ),
        )
        val rejectedIdentity = classify(
            status = 403,
            body = """{"error":{"message":"Only Codex official clients are allowed"}}""",
            context = context(
                relayKind = RelayKind.CodexStyle,
                transport = RelayTransport.OpenAIResponses,
                codexCompatIdentity = true,
            ),
        )

        assertGuidance(missingIdentity, "Codex (Responses)")
        assertGuidance(disabledIdentity, "Codex compatible identity")
        assertGuidance(rejectedIdentity, "custom User-Agent")
    }

    @Test
    fun `rule 5 maps codex host chat completions 404 to responses guidance`() {
        val error = classify(
            status = 404,
            body = """{"error":{"message":"Not found"}}""",
            upstreamUrl = "https://codex-relay.example.com/v1/chat/completions",
            context = context(transport = RelayTransport.OpenAIChatCompletions),
        )

        assertGuidance(error, "/chat/completions")
        assertGuidance(error, "Codex (Responses)")
    }

    @Test
    fun `rules 6 through 10 map common upstream failures`() {
        assertGuidance(
            classify(
                status = 400,
                body = """{"error":{"message":"max_tokens is required"}}""",
                context = context(transport = RelayTransport.AnthropicMessages),
            ),
            // The guidance points at Advanced Settings rather than at model behaviour, and
            // the fallback copy has to match the relay_guidance string resources word for word.
            "Open Advanced Settings",
        )
        assertGuidance(
            classify(status = 400, body = """{"error":{"message":"service_tier invalid"}}"""),
            "service tier",
        )
        assertGuidance(
            classify(status = 400, body = """{"error":{"message":"Unknown parameter: 'store'"}}"""),
            "Don't keep responses in the cloud",
        )
        assertGuidance(
            classify(status = 429, body = """{"error":{"message":"rate limit"}}"""),
            "rate limit",
        )
        assertGuidance(
            classify(status = 502, body = """{"error":{"message":"upstream_error: Upstream authentication failed"}}"""),
            "upstream provider",
        )
    }

    @Test
    fun `unmatched errors return null`() {
        assertNull(classify(status = 418, body = """{"error":{"message":"teapot"}}"""))
    }

    @Test
    fun `default mapping preserves relay upstream error detail`() {
        val error = RelayErrorMapper.mapOrDefault(
            status = 500,
            body = """{"error":"internal server error: upstream refused"}""",
            upstreamUrl = "https://relay.example.com/v1/chat/completions",
        )

        assertTrue(error is ProviderServiceError.Upstream)
        assertEquals("Upstream HTTP 500: internal server error: upstream refused", error.technicalDetail)
    }

    @Test
    fun `default mapping uses the live snippet path instead of exposing an unlisted response field`() {
        val unlistedPrompt = "private prompt text"
        val error = RelayErrorMapper.mapOrDefault(
            status = 500,
            body = """{"error":{"message":"Rejected request","prompt":"$unlistedPrompt"}}""",
            upstreamUrl = "https://relay.example.com/v1/chat/completions",
        )

        assertTrue(error is ProviderServiceError.Upstream)
        assertFalse(error.technicalDetail.contains(unlistedPrompt))
        assertEquals("Upstream HTTP 500: Rejected request", error.technicalDetail)
    }

    @Test
    fun `production mapper redacts the actual request credential echoed by upstream`() {
        val credential = "secret-123"
        val error = RelayErrorMapper.mapOrDefault(
            status = 500,
            body = """{"error":{"message":"Invalid API key: $credential"}}""",
            upstreamUrl = "https://relay.example.com/v1/chat/completions",
            credentials = listOf(credential),
        )

        assertFalse(error.technicalDetail.contains(credential))
        assertEquals("Upstream HTTP 500: Invalid API key: ***hidden", error.technicalDetail)
    }

    private fun classify(
        status: Int,
        body: String,
        upstreamUrl: String? = null,
        context: RelayErrorContext = RelayErrorContext(),
    ): ProviderServiceError? = RelayErrorMapper.classify(status, body, upstreamUrl, context)

    private fun context(
        relayKind: RelayKind? = null,
        transport: RelayTransport? = null,
        authMode: RelayAuthMode? = null,
        modelID: String? = null,
        codexCompatIdentity: Boolean? = null,
    ) = RelayErrorContext(
        relayKind = relayKind,
        transport = transport,
        authMode = authMode,
        modelID = modelID,
        codexCompatIdentity = codexCompatIdentity,
    )

    private fun assertGuidance(error: ProviderServiceError?, expected: String) {
        assertTrue(error is ProviderServiceError.RelayUpstream)
        val relayError = error as ProviderServiceError.RelayUpstream
        assertTrue(
            "Expected guidance to contain <$expected>, actual: ${relayError.guidance}",
            relayError.guidance.contains(expected, ignoreCase = true),
        )
        assertEquals(relayError.guidance, relayError.userMessage)
    }

    // Recognition of the errors that trigger the retry-without-tool fallback.

    @Test
    fun `image-tool retry — param tools-bracket plus image_generation message hits`() {
        val payload = RelayErrorMapper.parseUpstreamErrorPayload(
            """{"error":{"code":"unknown_parameter","message":"Unknown parameter: image_generation","param":"tools[0].type"}}"""
        )
        assertTrue(RelayErrorMapper.isImageGenerationToolUnsupportedError(payload, 400))
    }

    @Test
    fun `image-tool retry — param tools plus unknown_parameter code hits`() {
        val payload = RelayErrorMapper.parseUpstreamErrorPayload(
            """{"error":{"code":"unknown_parameter","message":"Tools rejected","param":"tools"}}"""
        )
        assertTrue(RelayErrorMapper.isImageGenerationToolUnsupportedError(payload, 400))
    }

    @Test
    fun `image-tool retry — standalone tool_not_supported code hits`() {
        val payload = RelayErrorMapper.parseUpstreamErrorPayload(
            """{"error":{"code":"tool_not_supported","message":"no tools"}}"""
        )
        assertTrue(RelayErrorMapper.isImageGenerationToolUnsupportedError(payload, 400))
    }

    @Test
    fun `image-tool retry — fallback message containing image_generation phrase hits`() {
        val payload = RelayErrorMapper.parseUpstreamErrorPayload(
            """{"error":{"message":"image_generation is not enabled in this relay"}}"""
        )
        assertTrue(RelayErrorMapper.isImageGenerationToolUnsupportedError(payload, 400))
    }

    @Test
    fun `image-tool retry — an image endpoint model mismatch hits`() {
        val payload = RelayErrorMapper.parseUpstreamErrorPayload(
            """{"error":{"message":"unsupported model: gpt-5.5 (only gpt-image-2 is supported on this endpoint)"}}"""
        )
        assertTrue(RelayErrorMapper.isImageGenerationToolUnsupportedError(payload, 400))
    }

    @Test
    fun `image-tool retry — image_url vision schema does NOT match - prevent misfire`() {
        val payload = RelayErrorMapper.parseUpstreamErrorPayload(
            """{"error":{"message":"Invalid image_url schema for this protocol"}}"""
        )
        assertFalse(RelayErrorMapper.isImageGenerationToolUnsupportedError(payload, 400))
    }

    @Test
    fun `image-tool retry — 5xx not eligible`() {
        val payload = RelayErrorMapper.parseUpstreamErrorPayload(
            """{"error":{"message":"image_generation broken"}}"""
        )
        assertFalse(RelayErrorMapper.isImageGenerationToolUnsupportedError(payload, 502))
    }

    @Test
    fun `image-tool retry — nil payload returns false`() {
        assertFalse(RelayErrorMapper.isImageGenerationToolUnsupportedError(null, 400))
    }

    @Test
    fun `image-tool retry — param tools but unrelated code-message does NOT match`() {
        val payload = RelayErrorMapper.parseUpstreamErrorPayload(
            """{"error":{"code":"rate_limited","message":"too many requests","param":"tools"}}"""
        )
        assertFalse(RelayErrorMapper.isImageGenerationToolUnsupportedError(payload, 400))
    }

    @Test
    fun `xhigh retry — message contains xhigh hits`() {
        val payload = RelayErrorMapper.parseUpstreamErrorPayload(
            """{"error":{"message":"Invalid value: xhigh"}}"""
        )
        assertTrue(RelayErrorMapper.isReasoningEffortXHighError(payload, 400))
    }

    @Test
    fun `xhigh retry — message contains reasoning plus effort hits`() {
        val payload = RelayErrorMapper.parseUpstreamErrorPayload(
            """{"error":{"message":"reasoning effort is not supported"}}"""
        )
        assertTrue(RelayErrorMapper.isReasoningEffortXHighError(payload, 400))
    }

    @Test
    fun `parse — standard openai error structure`() {
        val payload = RelayErrorMapper.parseUpstreamErrorPayload(
            """{"error":{"code":"x","message":"y","param":"z"}}"""
        )
        assertNotNull(payload)
        assertEquals("x", payload?.code)
        assertEquals("y", payload?.message)
        assertEquals("z", payload?.param)
    }

    @Test
    fun `parse — error as plain string degrades to message field`() {
        val payload = RelayErrorMapper.parseUpstreamErrorPayload("""{"error":"plain text"}""")
        assertEquals("plain text", payload?.message)
        assertNull(payload?.code)
    }

    @Test
    fun `parse — invalid or empty body returns null`() {
        assertNull(RelayErrorMapper.parseUpstreamErrorPayload(null))
        assertNull(RelayErrorMapper.parseUpstreamErrorPayload(""))
        assertNull(RelayErrorMapper.parseUpstreamErrorPayload("not json"))
    }
}
