package ai.oriveo.community.core.provider

import ai.oriveo.community.core.model.ProviderServiceError
import ai.oriveo.community.core.model.RelayAuthMode
import ai.oriveo.community.core.model.RelayGuidanceCode
import ai.oriveo.community.core.model.RelayKind
import ai.oriveo.community.core.model.RelayTransport
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import io.ktor.client.engine.mock.respond
import java.io.File
import javax.xml.parsers.DocumentBuilderFactory
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.int
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import org.w3c.dom.Element

class RelayErrorMapperTest {

    @Test
    fun `rule 1 maps chat completions input parameter mismatch to codex style guidance`() {
        val error = classify(
            status = 400,
            body = """{"error":{"message":"Unknown parameter: 'input[0]'."}}""",
            context = context(transport = RelayTransport.OpenAIChatCompletions),
        )

        assertGuidance(error, "Responses")
        assertGuidance(error, "set Protocol to OpenAI Responses")
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

        assertGuidance(error, "set Protocol to one that fits")
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
    fun `rule 4 splits codex identity 403 by whether the request was codex style`() {
        val body = """{"error":{"message":"Only Codex official clients are allowed"}}"""
        val missingIdentity = classify(
            status = 403,
            body = body,
            context = context(transport = RelayTransport.OpenAIChatCompletions),
        )
        val codexStyleByKind = classify(
            status = 403,
            body = body,
            context = context(relayKind = RelayKind.CodexStyle, transport = RelayTransport.OpenAIResponses),
        )
        val codexStyleByTransport = classify(
            status = 403,
            body = body,
            context = context(transport = RelayTransport.OpenAIResponses),
        )

        assertGuidance(missingIdentity, "set Protocol to OpenAI Responses")
        // The mobile apps have no "Codex compatible identity" switch, so a codex-style context always
        // points at Advanced HTTP, which exists.
        for (rejected in listOf(codexStyleByKind, codexStyleByTransport)) {
            assertGuidance(rejected, "custom User-Agent")
            val relayError = rejected as ProviderServiceError.RelayUpstream
            assertFalse(relayError.guidance.contains("Codex compatible identity", ignoreCase = true))
            assertEquals(RelayGuidanceCode.CodexIdentityStillRejected, relayError.guidanceCode)
        }
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
        assertGuidance(error, "set Protocol to OpenAI Responses")
    }

    @Test
    fun `rules 6 through 10 map common upstream failures`() {
        assertGuidance(
            classify(
                status = 400,
                body = """{"error":{"message":"max_tokens is required"}}""",
                context = context(transport = RelayTransport.AnthropicMessages),
            ),
            // The guidance points at "Providers -> this connection -> Parameters" (the final iOS wording), and
            // the fallback copy has to match the relay_guidance string resources word for word.
            "this connection → Parameters",
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
    ) = RelayErrorContext(
        relayKind = relayKind,
        transport = transport,
        authMode = authMode,
        modelID = modelID,
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

    // MARK: - Relay guidance alignment with iOS: the error object comes out of the production mapOrDefault, and the
    // semantic code, the fallback English and the values resource must all equal the iOS final English sentence.

    private val englishStrings: Map<String, String> by lazy {
        val doc = DocumentBuilderFactory.newInstance().newDocumentBuilder()
            .parse(File("src/main/res/values/strings.xml"))
        val nodes = doc.getElementsByTagName("string")
        (0 until nodes.length).associate { i ->
            val element = nodes.item(i) as Element
            element.getAttribute("name") to element.textContent.replace("\\'", "'").replace("\\\"", "\"")
        }
    }

    private fun mapped(
        status: Int,
        body: String,
        upstreamUrl: String = "https://relay.example.com/v1/chat/completions",
        context: RelayErrorContext = RelayErrorContext(),
    ): ProviderServiceError = RelayErrorMapper.mapOrDefault(status, body, upstreamUrl, context)

    private fun assertIOSGuide(caseName: String, error: ProviderServiceError, stableKey: String, iosEnglish: String) {
        assertTrue("$caseName: ${error::class.simpleName}", error is ProviderServiceError.RelayUpstream)
        val relayError = error as ProviderServiceError.RelayUpstream
        assertEquals(caseName, stableKey, relayError.guidanceCode?.stableKey)
        assertEquals("$caseName fallback English", iosEnglish, relayError.guidance)
        assertEquals("$caseName values resource", iosEnglish, englishStrings["relay_guidance_$stableKey"])
    }

    private val codexBody = """{"error":{"message":"Only Codex official clients are allowed"}}"""

    @Test
    fun `guide 01 Codex identity 403 on a non-Responses protocol`() = assertIOSGuide(
        "guide 01",
        mapped(403, codexBody, context = context(transport = RelayTransport.OpenAIChatCompletions)),
        "codex_identity_switch_type",
        IOS_CODEX_SWITCH,
    )

    @Test
    fun `guide 02 Codex identity 403 on the Responses protocol`() = assertIOSGuide(
        "guide 02",
        mapped(403, codexBody, "https://relay.example.com/v1/responses", context(transport = RelayTransport.OpenAIResponses)),
        "codex_identity_still_rejected",
        IOS_CODEX_STILL_REJECTED,
    )

    @Test
    fun `guide 03 standalone image endpoint 404`() = assertIOSGuide(
        "guide 03",
        mapped(404, """{"error":{"message":"Not Found"}}""", "https://relay.example.com/v1/images/generations"),
        "images_endpoint_unavailable",
        IOS_IMAGES_ENDPOINT,
    )

    @Test
    fun `guide 03 standalone image endpoint 404 with a model_not_found body still means no standalone image API`() = assertIOSGuide(
        "guide 03 model_not_found",
        mapped(
            404,
            """{"error":{"message":"The model `gpt-image-1` does not exist","code":"model_not_found"}}""",
            "https://relay.example.com/v1/images/generations",
        ),
        "images_endpoint_unavailable",
        IOS_IMAGES_ENDPOINT,
    )

    @Test
    fun `guide 04 Codex-style host chat completions 404`() = assertIOSGuide(
        "guide 04",
        mapped(
            404,
            """{"error":{"message":"Not found"}}""",
            "https://code.ylsagi.com/codex/v1/chat/completions",
            context(transport = RelayTransport.OpenAIChatCompletions),
        ),
        "responses_only_endpoint",
        IOS_RESPONSES_ONLY,
    )

    @Test
    fun `guide 05 image endpoint 400 response_format`() = assertIOSGuide(
        "guide 05",
        mapped(
            400,
            """{"error":{"message":"Unknown parameter: 'response_format'.","type":"invalid_request_error","param":"response_format"}}""",
            "https://relay.example.com/v1/images/generations",
        ),
        "image_response_format_rejected",
        IOS_IMAGE_RESPONSE_FORMAT,
    )

    @Test
    fun `guide 06 502 upstream error`() = assertIOSGuide(
        "guide 06",
        mapped(502, """{"error":{"message":"upstream_error: Upstream authentication failed"}}"""),
        "upstream_unreachable",
        IOS_UPSTREAM_UNREACHABLE,
    )

    @Test
    fun `guide 07 model not found 404 and 400`() {
        for (status in listOf(404, 400)) {
            assertIOSGuide(
                "guide 07 $status",
                mapped(status, """{"error":{"message":"The model `gpt-x` does not exist","code":"model_not_found"}}"""),
                "model_not_offered",
                IOS_MODEL_NOT_OFFERED,
            )
        }
    }

    @Test
    fun `guide 08 unknown input parameter`() = assertIOSGuide(
        "guide 08",
        mapped(
            400,
            """{"error":{"message":"Unknown parameter: 'input[4].content[1].url'."}}""",
            context = context(transport = RelayTransport.OpenAIChatCompletions),
        ),
        "responses_protocol_required",
        IOS_RESPONSES_REQUIRED,
    )

    @Test
    fun `guide 09 unknown store parameter`() = assertIOSGuide(
        "guide 09",
        mapped(400, """{"error":{"message":"Unknown parameter: 'store'."}}"""),
        "store_param_rejected",
        IOS_STORE_REJECTED,
    )

    @Test
    fun `guide 10 invalid service_tier`() = assertIOSGuide(
        "guide 10",
        mapped(400, """{"error":{"message":"Invalid value for service_tier: 'flex'."}}"""),
        "service_tier_invalid",
        IOS_SERVICE_TIER,
    )

    @Test
    fun `guide 11 Messages missing max_tokens`() = assertIOSGuide(
        "guide 11",
        mapped(
            400,
            """{"type":"error","error":{"type":"invalid_request_error","message":"max_tokens: Field required"}}""",
            "https://relay.example.com/v1/messages",
            context(transport = RelayTransport.AnthropicMessages),
        ),
        "max_tokens_required",
        IOS_MAX_TOKENS,
    )

    @Test
    fun `guide 12 Messages 401 authentication_error invalid x-api-key`() = assertIOSGuide(
        "guide 12",
        mapped(
            401,
            """{"type":"error","error":{"type":"authentication_error","message":"invalid x-api-key"}}""",
            "https://relay.example.com/v1/messages",
            context(transport = RelayTransport.AnthropicMessages, authMode = RelayAuthMode.Bearer),
        ),
        "anthropic_auth_header",
        IOS_ANTHROPIC_AUTH,
    )

    @Test
    fun `guide 13 image_url expected an object`() = assertIOSGuide(
        "guide 13",
        mapped(
            400,
            """{"type":"error","error":{"type":"invalid_request_error","message":"Invalid image_url: expected an object."}}""",
            "https://relay.example.com/v1/messages",
            context(transport = RelayTransport.AnthropicMessages),
        ),
        "image_schema_mismatch",
        IOS_IMAGE_SCHEMA,
    )

    @Test
    fun `guide 14 official CLI gate 403 covers every client_gated fixture case`() {
        val cases = clientGateCases()
        assertTrue(cases.any { it.third })
        cases.forEach { (caseId, status, gated) ->
            val body = clientGateBody(caseId)
            val error = mapped(status, body, "https://relay.example.com/v1/messages", context(transport = RelayTransport.AnthropicMessages))
            if (gated) {
                assertIOSGuide("guide 14 $caseId", error, "client_gated", IOS_CLIENT_GATED)
                // Not a key problem: the key access verdict is none, and it does not switch protocol as a route-level rejection would.
                assertEquals(caseId, "none", error.relayKeyAccess?.outcome?.value ?: "none")
                assertFalse(caseId, ai.oriveo.community.core.provider.relay.RelayProtocolFallback.isRouteRejection(error))
            } else {
                assertFalse(caseId, (error as? ProviderServiceError.RelayUpstream)?.guidanceCode?.stableKey == "client_gated")
            }
        }
    }

    @Test
    fun `guide 15 429 falls to the generic rate-limited error with no relay guidance`() {
        val error = mapped(429, """{"error":{"message":"rate limit exceeded"}}""")
        assertTrue(error::class.simpleName, error is ProviderServiceError.RateLimited)
        assertFalse(englishStrings.containsKey("relay_guidance_rate_limited"))
    }

    @Test
    fun `guide 16 an official provider receiving the same bodies gets no relay guidance`() {
        val bodies = listOf(
            403 to codexBody,
            404 to """{"error":{"message":"Not Found"}}""",
            400 to """{"error":{"message":"Unknown parameter: 'response_format'."}}""",
            502 to """{"error":{"message":"upstream_error: Upstream authentication failed"}}""",
            404 to """{"error":{"message":"The model `gpt-x` does not exist","code":"model_not_found"}}""",
            400 to """{"error":{"message":"Unknown parameter: 'input[4].content[1].url'."}}""",
            400 to """{"error":{"message":"Unknown parameter: 'store'."}}""",
            400 to """{"error":{"message":"Invalid value for service_tier: 'flex'."}}""",
            400 to """{"type":"error","error":{"type":"invalid_request_error","message":"max_tokens: Field required"}}""",
            401 to """{"type":"error","error":{"type":"authentication_error","message":"invalid x-api-key"}}""",
            400 to """{"type":"error","error":{"type":"invalid_request_error","message":"Invalid image_url: expected an object."}}""",
        ) + clientGateCases().filter { it.third }.map { it.second to clientGateBody(it.first) }
        bodies.forEach { (status, body) ->
            val official = SseParser.mapHttpError(status, body)
            assertFalse("$status $body", official is ProviderServiceError.RelayUpstream)
        }
    }

    // MARK: - A call site with an unknown protocol gets the "still rejected" branch; a relay 429 splits by body into quota / unavailable / rate limit

    private fun codexRejectingService(): RelayService {
        val json = Json { ignoreUnknownKeys = true }
        val engine = io.ktor.client.engine.mock.MockEngine {
            respond(
                codexBody,
                io.ktor.http.HttpStatusCode.Forbidden,
                io.ktor.http.headersOf(io.ktor.http.HttpHeaders.ContentType, "application/json"),
            )
        }
        return RelayService(
            client = io.ktor.client.HttpClient(engine),
            json = json,
            transportRegistry = ai.oriveo.community.core.provider.transport.TransportRegistry(json),
        )
    }

    private suspend fun thrownBy(block: suspend () -> Unit): ProviderServiceError {
        try {
            block()
        } catch (error: ProviderServiceError) {
            return error
        }
        throw AssertionError("expected ProviderServiceError")
    }

    @Test
    fun `guide 19 catalog sync models 403 Codex identity with unknown protocol gives the still-rejected branch`() = kotlinx.coroutines.runBlocking {
        val error = thrownBy {
            codexRejectingService().syncProvider(
                apiKey = "sk-relay",
                preferredModelID = null,
                baseUrl = "https://relay.example.com/v1",
                relayRequested = ai.oriveo.community.core.model.RelayRequestedConfig(transport = RelayTransport.OpenAIChatCompletions),
            )
        }
        assertIOSGuide("guide 19", error, "codex_identity_still_rejected", IOS_CODEX_STILL_REJECTED)
    }

    @Test
    fun `guide 20 images generations 403 Codex identity with unknown protocol gives the still-rejected branch`() = kotlinx.coroutines.runBlocking {
        val error = thrownBy {
            codexRejectingService().generateImageViaImagesEndpoint(
                apiKey = "sk-relay",
                modelID = "gpt-image-1",
                messages = listOf(
                    ai.oriveo.community.core.model.ChatMessage(
                        id = "u1",
                        role = ai.oriveo.community.core.model.ChatRole.User,
                        text = "a cat",
                        providerKind = ai.oriveo.community.core.model.ProviderKind.Relay,
                        providerName = "Relay",
                        modelID = "gpt-image-1",
                        modelName = "gpt-image-1",
                        state = ai.oriveo.community.core.model.ChatMessageState.Delivered,
                    ),
                ),
                baseUrl = "https://relay.example.com/v1",
                requestOptions = ai.oriveo.community.core.model.ChatRequestOptions(
                    relayRequested = ai.oriveo.community.core.model.RelayRequestedConfig(transport = RelayTransport.OpenAIChatCompletions),
                ),
            )
        }
        assertIOSGuide("guide 20", error, "codex_identity_still_rejected", IOS_CODEX_STILL_REJECTED)
    }

    @Test
    fun `guide 21 relay 429 body with insufficient quota maps to quota exceeded`() {
        val body = """{"error":{"message":"insufficient quota for this key"}}"""
        val error = mapped(429, body)
        assertTrue(error::class.simpleName, error is ProviderServiceError.QuotaExceeded)
        // The key access attachment is still carried out with the error object (same exit as the other branches).
        assertEquals(
            ai.oriveo.community.core.provider.relay.RelayKeyAccess.signal(429, body),
            error.relayKeyAccess,
        )
        val unavailable = mapped(429, """{"error":{"message":"model is temporarily unavailable"}}""")
        assertTrue(unavailable::class.simpleName, unavailable is ProviderServiceError.ModelUnavailable)
    }

    private val negativeCacheFixture by lazy {
        Json.parseToJsonElement(
            generateSequence(File(System.getProperty("user.dir") ?: ".").absoluteFile) { it.parentFile }
                .map { File(it, "shared/test-fixtures/relay/negative-cache.v1.json") }
                .first { it.isFile }
                .readText(Charsets.UTF_8),
        ).jsonObject
    }

    /** (caseId, status, client_gated?) */
    private fun clientGateCases(): List<Triple<String, Int, Boolean>> =
        negativeCacheFixture.getValue("clientGateCases").jsonArray.map { it.jsonObject }.map {
            Triple(
                it.getValue("caseId").jsonPrimitive.content,
                it.getValue("status").jsonPrimitive.int,
                it.getValue("expect").jsonPrimitive.content == "client_gated",
            )
        }

    private fun clientGateBody(caseId: String): String =
        negativeCacheFixture.getValue("clientGateCases").jsonArray.map { it.jsonObject }
            .single { it.getValue("caseId").jsonPrimitive.content == caseId }
            .getValue("body").jsonPrimitive.content

    private companion object {
        // The final iOS English (source of truth for the guidance copy), word for word.
        const val IOS_CODEX_SWITCH = "This connection requires a Codex client identity. Open Providers → this connection → Model Library → this model → Advanced and set Protocol to OpenAI Responses, then retry."
        const val IOS_CODEX_STILL_REJECTED = "This connection still rejects Oriveo's Codex client identity. Open Providers → this connection → Edit connection → Headers & query params and set a custom User-Agent or header, or switch to another connection."
        const val IOS_IMAGES_ENDPOINT = "This connection doesn't offer a separate image generation API. Open Providers → this connection → Model Library → this model → Advanced and set Protocol to OpenAI Responses. Oriveo will then generate images inside the chat instead."
        const val IOS_RESPONSES_ONLY = "This connection only exposes /v1/responses and rejects /chat/completions. Open Providers → this connection → Model Library → this model → Advanced and set Protocol to OpenAI Responses, then retry."
        const val IOS_IMAGE_RESPONSE_FORMAT = "This image model doesn't accept the response_format parameter. Try a different image model ID."
        const val IOS_UPSTREAM_UNREACHABLE = "This connection could not reach its upstream provider. This is not your configuration — its administrator's upstream account may be invalid, out of credits, or rate-limited. Switch to another connection or contact its administrator."
        const val IOS_MODEL_NOT_OFFERED = "This connection's upstream does not offer this model. Open Providers → this connection → Model Library and enable a model it actually offers. You can ask its administrator for the exact list of available model IDs."
        const val IOS_RESPONSES_REQUIRED = "This connection requires the OpenAI Responses protocol for this model. Open Providers → this connection → Model Library → this model → Advanced and set Protocol to OpenAI Responses, then retry."
        const val IOS_STORE_REJECTED = "This connection rejects the “store/disable_response_storage” field. Open Providers → this connection → Edit connection → Compatibility and turn off “Don't keep responses in the cloud”, then retry."
        const val IOS_SERVICE_TIER = "This connection does not accept the current service tier value. Open Providers → this connection → Edit connection → Compatibility and clear “Service Tier”, then retry."
        const val IOS_MAX_TOKENS = "This connection requires the “max_tokens” parameter. Open Providers → this connection → Parameters and set “Max Tokens” (e.g. 4096), then retry."
        const val IOS_ANTHROPIC_AUTH = "This connection expects an Anthropic-style x-api-key header. Open Providers → this connection → Edit connection → Authentication and choose “x-api-key”, then retry."
        const val IOS_IMAGE_SCHEMA = "Image attachments use a schema that doesn't match this model's protocol. Open Providers → this connection → Model Library → this model → Advanced and set Protocol to one that fits this model, then retry."
        const val IOS_CLIENT_GATED = "This key's group only accepts the official Claude CLI. In the account console of the site that issued this key, move the key to a group that allows API access, or create a new key and add it in Providers → this connection → API Keys. Then retry."
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
