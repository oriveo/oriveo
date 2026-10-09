package ai.oriveo.community.core.error

import android.content.Context
import ai.oriveo.community.R
import ai.oriveo.community.core.data.repository.ProviderRepository
import ai.oriveo.community.core.data.repository.streaming.failedMessageDetail
import ai.oriveo.community.core.data.repository.streaming.isAttachmentTextOverLimitDetail
import ai.oriveo.community.core.model.GrokSubscriptionFailureReason
import ai.oriveo.community.core.model.OpenAISubscriptionFailureReason
import ai.oriveo.community.core.model.ProviderServiceError
import ai.oriveo.community.core.model.RelayAuthMode
import ai.oriveo.community.core.model.RelayKind
import ai.oriveo.community.core.model.RelayTransport
import ai.oriveo.community.core.provider.RelayErrorContext
import ai.oriveo.community.core.provider.RelayErrorMapper
import org.junit.Test
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import io.mockk.every
import io.mockk.mockk

class ErrorMapperTest {

    private val context: Context = mockk()

    @Test
    fun `localizeProviderErrorMessage maps invalidKey message`() {
        every { context.getString(R.string.error_invalid_api_key_message) } returns "localized message"
        val result = ErrorMapper.localizeProviderErrorMessage(
            "The API key could not be validated. Check the value or generate a new key.",
            context,
        )
        assertEquals("localized message", result)
    }

    @Test
    fun `localizeProviderErrorMessage maps rateLimited message`() {
        every { context.getString(R.string.error_rate_limited_message) } returns "rate limited"
        val result = ErrorMapper.localizeProviderErrorMessage(
            "The provider is temporarily rate limiting this request. Please wait a moment and try again.",
            context,
        )
        assertEquals("rate limited", result)
    }

    @Test
    fun `localizeProviderErrorMessage maps network message`() {
        every { context.getString(R.string.error_network_message) } returns "network error"
        val result = ErrorMapper.localizeProviderErrorMessage(
            "The request did not complete successfully. Please check your network and try again.",
            context,
        )
        assertEquals("network error", result)
    }

    @Test
    fun `localizeProviderErrorMessage maps upstream message`() {
        every { context.getString(R.string.error_upstream_message) } returns "provider error"
        val result = ErrorMapper.localizeProviderErrorMessage(
            "The provider returned an error for this request. Please retry or switch models.",
            context,
        )
        assertEquals("provider error", result)
    }

    @Test
    fun `localizeProviderErrorMessage maps emptyModelCatalog message`() {
        every { context.getString(R.string.error_no_models_message) } returns "no models found"
        val result = ErrorMapper.localizeProviderErrorMessage(
            "The provider returned an empty model catalog, so we could not finish setup.",
            context,
        )
        assertEquals("no models found", result)
    }

    @Test
    fun `localizeProviderErrorMessage maps emptyResponse message`() {
        every { context.getString(R.string.error_empty_response_message) } returns "empty response"
        val result = ErrorMapper.localizeProviderErrorMessage(
            "The provider returned no assistant content for this message.",
            context,
        )
        assertEquals("empty response", result)
    }

    @Test
    fun `localizeProviderErrorMessage maps config message`() {
        every { context.getString(R.string.error_config_message) } returns "configuration error"
        val result = ErrorMapper.localizeProviderErrorMessage(
            "The selected provider configuration is incomplete, so the request could not be sent.",
            context,
        )
        assertEquals("configuration error", result)
    }

    @Test
    fun `localizeProviderErrorMessage returns raw message for unknown strings`() {
        val raw = "Some unknown error"
        val result = ErrorMapper.localizeProviderErrorMessage(raw, context)
        assertEquals(raw, result)
    }

    @Test
    fun `localizeProviderErrorMessage maps unverified connection message key`() {
        every { context.getString(R.string.provider_connection_unverified) } returns "could not verify connection"
        val result = ErrorMapper.localizeProviderErrorMessage(
            ProviderRepository.PROVIDER_UNVERIFIED_MESSAGE,
            context,
        )
        assertEquals("could not verify connection", result)
    }

    @Test
    fun `localizeProviderErrorMessage covers every non-relay ProviderServiceError userMessage`() {
        every { context.getString(any()) } returns "LOCALIZED"
        nonRelayErrors().forEach { error ->
            assertEquals(
                "userMessage must be in MESSAGE_TO_RES for ${error::class.simpleName}",
                "LOCALIZED",
                ErrorMapper.localizeProviderErrorMessage(error.userMessage, context),
            )
        }
    }

    // Drives all 12 branches of the production classify function, then hands the real error object to ErrorMapper.
    // This pins the stable semantic code -> Android resource mapping, instead of self-verifying by matching the English guidance string.
    @Test
    fun `map localizes every relay guidance produced by RelayErrorMapper classify`() {
        every { context.getString(any()) } answers { "mapped-resource-${firstArg<Int>()}" }
        every { context.getString(any(), *anyVararg()) } returns "custom LLM error"
        val codexBody = """{"error":{"message":"Only Codex official clients are allowed"}}"""
        val codexContext = RelayErrorContext(
            relayKind = RelayKind.CodexStyle,
            transport = RelayTransport.OpenAIResponses,
        )
        val classified = listOf(
            RelayErrorMapper.classify(403, codexBody, null, RelayErrorContext()) to
                R.string.relay_guidance_codex_identity_switch_type,
            RelayErrorMapper.classify(403, codexBody, null, codexContext) to
                R.string.relay_guidance_codex_identity_still_rejected,
            RelayErrorMapper.classify(
                404,
                """{"error":{"message":"Not found"}}""",
                "https://codex-relay.example.com/v1/chat/completions",
                RelayErrorContext(transport = RelayTransport.OpenAIChatCompletions),
            ) to R.string.relay_guidance_responses_only_endpoint,
            RelayErrorMapper.classify(502, """{"error":{"message":"upstream_error: Upstream authentication failed"}}""") to
                R.string.relay_guidance_upstream_unreachable,
            RelayErrorMapper.classify(404, """{"error":{"message":"model_not_found: no such model"}}""") to
                R.string.relay_guidance_model_not_offered,
            RelayErrorMapper.classify(
                400,
                """{"error":{"message":"Unknown parameter: 'input[0]'."}}""",
                null,
                RelayErrorContext(transport = RelayTransport.OpenAIChatCompletions),
            ) to R.string.relay_guidance_responses_protocol_required,
            RelayErrorMapper.classify(400, """{"error":{"message":"Unknown parameter: 'store'"}}""") to
                R.string.relay_guidance_store_param_rejected,
            RelayErrorMapper.classify(400, """{"error":{"message":"service_tier invalid"}}""") to
                R.string.relay_guidance_service_tier_invalid,
            RelayErrorMapper.classify(
                400,
                """{"error":{"message":"max_tokens is required"}}""",
                null,
                RelayErrorContext(transport = RelayTransport.AnthropicMessages),
            ) to R.string.relay_guidance_max_tokens_required,
            RelayErrorMapper.classify(
                403,
                """{"error":{"message":"authentication_error: x-api-key required"}}""",
                null,
                RelayErrorContext(authMode = RelayAuthMode.Bearer, modelID = "claude-sonnet-4-5"),
            ) to R.string.relay_guidance_anthropic_auth_header,
            RelayErrorMapper.classify(
                400,
                """{"error":{"message":"image_url is invalid for this schema"}}""",
                null,
                RelayErrorContext(transport = RelayTransport.AnthropicMessages, modelID = "gpt-5.4"),
            ) to R.string.relay_guidance_image_schema_mismatch,
            RelayErrorMapper.classify(429, """{"error":{"message":"rate limit"}}""") to
                R.string.relay_guidance_rate_limited,
        )

        val guidanceCodes = classified.mapIndexed { index, (error, expectedRes) ->
            assertTrue(
                "case $index must classify to RelayUpstream",
                error is ProviderServiceError.RelayUpstream,
            )
            val relayError = error as ProviderServiceError.RelayUpstream
            assertEquals("mapped-resource-$expectedRes", ErrorMapper.map(relayError, context).message)
            val persistenceKey = requireNotNull(relayError.guidanceCode).persistenceKey
            assertTrue(ErrorMapper.hasLocalizedProviderMessage(persistenceKey))
            assertEquals(
                "mapped-resource-$expectedRes",
                ErrorMapper.localizeProviderErrorMessage(persistenceKey, context),
            )
            relayError.guidanceCode
        }
        // All 12 branches must each be hit (guards against two cases colliding on the same branch and faking coverage).
        assertEquals(12, guidanceCodes.filterNotNull().distinct().size)
    }

    // A key stored by older versions for a switch the mobile apps do not have must render as the
    // current Advanced HTTP guidance, never as the raw key.
    @Test
    fun `legacy enable compat persistence key localizes to still rejected guidance`() {
        every { context.getString(any()) } answers { "mapped-resource-${firstArg<Int>()}" }
        val legacyKey = "relay_guidance:codex_identity_enable_compat"

        assertTrue(ErrorMapper.hasLocalizedProviderMessage(legacyKey))
        assertEquals(
            "mapped-resource-${R.string.relay_guidance_codex_identity_still_rejected}",
            ErrorMapper.localizeProviderErrorMessage(legacyKey, context),
        )
    }

    @Test
    fun `localizeProviderErrorTitle maps every static provider error title`() {
        val expected = mapOf(
            "Invalid API Key" to R.string.error_invalid_api_key,
            "Provider Rate Limited" to R.string.error_rate_limited,
            "No Models Found" to R.string.error_no_models,
            "Empty Provider Response" to R.string.error_empty_response,
            "Provider Configuration Error" to R.string.error_config,
            "Provider Request Failed" to R.string.error_request_failed,
            "Request Failed" to R.string.message_failed,
        )
        expected.forEach { (raw, resId) ->
            every { context.getString(resId) } returns "localized-$resId"
            assertEquals("localized-$resId", ErrorMapper.localizeProviderErrorTitle(raw, context))
        }
    }

    @Test
    fun `localizeProviderErrorTitle covers every non-relay ProviderServiceError title`() {
        every { context.getString(any()) } returns "LOCALIZED"
        nonRelayErrors().forEach { error ->
            assertEquals(
                "title must be in TITLE_TO_RES for ${error::class.simpleName}",
                "LOCALIZED",
                ErrorMapper.localizeProviderErrorTitle(error.title, context),
            )
        }
    }

    @Test
    fun `localizeProviderErrorTitle maps relay upstream title with status code`() {
        every { context.getString(R.string.error_relay_upstream_title, 502) } returns "relay error (502)"
        val error = ProviderServiceError.RelayUpstream(statusCode = 502, guidance = "g", detail = "d")
        assertEquals("relay error (502)", ErrorMapper.localizeProviderErrorTitle(error.title, context))
    }

    @Test
    fun `localizeProviderErrorTitle returns raw title for unknown strings`() {
        assertEquals(
            "Mystery Failure",
            ErrorMapper.localizeProviderErrorTitle("Mystery Failure", context),
        )
    }

    @Test
    fun `map localizes provider error title and message`() {
        every { context.getString(R.string.error_invalid_api_key) } returns "invalid key"
        every { context.getString(R.string.error_invalid_api_key_message) } returns "check your key"
        every { context.getString(R.string.change_api_key) } returns "change key"

        val result = ErrorMapper.map(ProviderServiceError.InvalidAPIKey("raw detail"), context)

        assertEquals("invalid key", result.title)
        assertEquals("check your key", result.message)
        // technicalDetail keeps the raw text for debugging
        assertEquals("raw detail", result.detail)
    }

    @Test
    fun `attachment text over limit is rendered from the persisted safe code with its file names`() {
        every { context.getString(R.string.file_extraction_send_blocked_text_budget, *anyVararg()) } answers {
            "blocked[" + (args[1] as Array<*>).joinToString("|") + "]"
        }
        every { context.getString(R.string.error_attachment_not_accepted_title) } returns "Attachment not accepted"
        every { context.getString(R.string.edit) } returns "Edit"
        // File names are user content: ':' and '@' separate other safe codes and must not break the name apart.
        val error = ProviderServiceError.AttachmentTextOverLimit(listOf("notes: v2@home.md", "b.txt"))
        val stored = failedMessageDetail(error)

        assertTrue(stored, stored.startsWith("attachment_text_over_limit:"))
        assertTrue("The stored code must not contain plain file names: $stored", !stored.contains("notes") && !stored.contains("b.txt"))
        assertTrue(ErrorMapper.hasLocalizedProviderMessage(stored))
        assertEquals("blocked[notes: v2@home.md, b.txt]", ErrorMapper.localizeProviderErrorMessage(stored, context))
        assertTrue(isAttachmentTextOverLimitDetail(stored))

        val mapped = ErrorMapper.map(error, context)
        assertEquals("Attachment not accepted", mapped.title)
        assertEquals("blocked[notes: v2@home.md, b.txt]", mapped.message)
        assertEquals("Edit", mapped.actionTitle)
    }

    @Test
    fun `attachment count over limit is rendered with the same sentence as the add-time count gate`() {
        every { context.getString(R.string.file_attachment_count_limit_reached, *anyVararg()) } answers {
            "count[" + (args[1] as Array<*>).joinToString("|") + "]"
        }
        every { context.getString(R.string.error_attachment_not_accepted_title) } returns "Attachment not accepted"
        every { context.getString(R.string.edit) } returns "Edit"
        val error = ProviderServiceError.AttachmentCountOverLimit(maxFiles = 3)
        val stored = failedMessageDetail(error)

        assertEquals("attachment_count_over_limit:3", stored)
        assertTrue(ErrorMapper.hasLocalizedProviderMessage(stored))
        assertEquals("count[3]", ErrorMapper.localizeProviderErrorMessage(stored, context))
        // The card actions match the text overrun: the way out is to edit the message.
        assertTrue(isAttachmentTextOverLimitDetail(stored))
        assertTrue(!ErrorMapper.hasLocalizedProviderMessage("attachment_count_over_limit:x"))

        val mapped = ErrorMapper.map(error, context)
        assertEquals("Attachment not accepted", mapped.title)
        assertEquals("count[3]", mapped.message)
        assertEquals("Edit", mapped.actionTitle)
    }

    @Test
    fun `count and text limits exceeded together render as two lines from the persisted safe code`() {
        every { context.getString(R.string.file_extraction_send_blocked_text_budget, *anyVararg()) } answers {
            "blocked[" + (args[1] as Array<*>).joinToString("|") + "]"
        }
        every { context.getString(R.string.file_attachment_count_limit_reached, *anyVararg()) } answers {
            "count[" + (args[1] as Array<*>).joinToString("|") + "]"
        }
        val error = ProviderServiceError.AttachmentTextOverLimit(listOf("big: v2.txt"), countLimit = 3)
        val stored = failedMessageDetail(error)

        assertTrue(stored, stored.startsWith("attachment_text_over_limit:"))
        assertTrue(stored, !stored.contains("big"))
        assertTrue(isAttachmentTextOverLimitDetail(stored))
        assertEquals("count[3]\nblocked[big: v2.txt]", ErrorMapper.localizeProviderErrorMessage(stored, context))
        assertEquals("count[3]\nblocked[big: v2.txt]", ErrorMapper.localizeProviderErrorMessage(error, context))
    }

    @Test
    fun `the attachment limit failures are titled as an attachment problem not a generic send failure`() {
        every { context.getString(R.string.error_attachment_not_accepted_title) } returns "Attachment not accepted"
        for (error in listOf(
            ProviderServiceError.AttachmentTextOverLimit(listOf("a.txt")),
            ProviderServiceError.AttachmentCountOverLimit(3),
        )) {
            assertEquals("Attachment Not Accepted", error.title)
            assertEquals("Attachment not accepted", ErrorMapper.localizeProviderErrorTitle(error.title, context))
        }
    }

    @Test
    fun `unrelated or damaged details are not mistaken for the attachment limit code`() {
        val isDetail = ::isAttachmentTextOverLimitDetail
        assertTrue(!isDetail(null))
        assertTrue(!isDetail("additional_body_rejected:not_object"))
        assertTrue(!isDetail("attachment_text_over_limit"))
        // Right code, damaged name segment: it is still treated as this kind of failure (card actions), but there is no
        // sentence to restore, so it does not pass as localized.
        assertTrue(isDetail("attachment_text_over_limit:%%%"))
        assertTrue(!ErrorMapper.hasLocalizedProviderMessage("attachment_text_over_limit:%%%"))
    }

    private fun nonRelayErrors(): List<ProviderServiceError> = listOf(
        ProviderServiceError.InvalidAPIKey("d"),
        ProviderServiceError.QuotaExceeded("d"),
        ProviderServiceError.ModelUnavailable("d"),
        ProviderServiceError.RateLimited("d"),
        ProviderServiceError.EmptyModelCatalog,
        ProviderServiceError.EmptyResponse,
        ProviderServiceError.InvalidConfiguration("d"),
        ProviderServiceError.Network("d"),
        ProviderServiceError.Upstream(500, "d"),
        // Both subscription error paths used to be missing from this list, so the "every title has a mapping"
        // assertion never covered them -- that's exactly how a missing mapping could slip through undetected.
        ProviderServiceError.GrokSubscription(GrokSubscriptionFailureReason.Expired, "d"),
        ProviderServiceError.OpenAISubscription(OpenAISubscriptionFailureReason.Expired, "d"),
    )
}
