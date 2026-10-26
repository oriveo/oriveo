package ai.oriveo.community.core.provider

import ai.oriveo.community.R
import ai.oriveo.community.core.capability.InputNegativeCache
import ai.oriveo.community.core.capability.InputRejectionFlow
import ai.oriveo.community.core.capability.RejectionSignatureTable
import ai.oriveo.community.core.capability.RejectionSignatures
import ai.oriveo.community.core.data.remote.MetadataClient
import ai.oriveo.community.core.model.AIModel
import ai.oriveo.community.core.model.CapabilityEvidenceIdentity
import ai.oriveo.community.core.model.CapabilityExecutionCollector
import ai.oriveo.community.core.model.ChatMessage
import ai.oriveo.community.core.model.ChatMessageState
import ai.oriveo.community.core.model.ChatRequestOptions
import ai.oriveo.community.core.model.ChatRole
import ai.oriveo.community.core.model.Provider
import ai.oriveo.community.core.model.ProviderKind
import ai.oriveo.community.core.model.ProviderServiceError
import ai.oriveo.community.core.model.ReasoningMode
import ai.oriveo.community.feature.chat.omitParameterOnceName
import ai.oriveo.community.feature.chat.parameterResendMarker
import ai.oriveo.community.feature.chat.recovery.MessageRecoveryActionKind
import ai.oriveo.community.feature.chat.recovery.performRecoveryAction
import ai.oriveo.community.feature.chat.recovery.resolveMessageRecoveryCardActionLayout
import ai.oriveo.community.feature.chat.recovery.titleRes
import io.ktor.client.HttpClient
import io.ktor.client.engine.mock.MockEngine
import io.ktor.client.engine.mock.respond
import io.ktor.http.HttpHeaders
import io.ktor.http.HttpStatusCode
import io.ktor.http.content.TextContent
import io.ktor.http.headersOf
import kotlinx.coroutines.flow.toList
import kotlinx.coroutines.test.runTest
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.jsonObject
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment

/**
 * Parameter gate of official connections (param_rejected): when the upstream rejects a parameter with a narrow signature, `param:<name>` is recorded,
 * and the next outbound request through the production resolver omits that parameter; a parameter that was not rejected is sent as before; Relay does not use this gate.
 */
@RunWith(RobolectricTestRunner::class)
class ParameterRejectionGateTest {
    private val openAI = Provider(id = "official-openai", kind = ProviderKind.OpenAI)
    private val anthropic = Provider(id = "official-anthropic", kind = ProviderKind.Anthropic)
    private val relay = Provider(id = "relay-1", kind = ProviderKind.Relay)
    private val gpt = AIModel(id = "gpt-test", name = "gpt-test")
    private val claude = AIModel(id = "claude-test", name = "claude-test")

    /** The shared signature table has no temperature entry, so build an openai_chat param_rejected through the same parse entry. */
    private val temperatureTable: RejectionSignatureTable = RejectionSignatures.parse(
        """
        {"byWireFamily":{},"byProtocol":{"openai_chat":[
          {"signatureId":"test.temperature_unsupported","httpStatus":400,"messagePattern":"Unsupported parameter: 'temperature'",
           "kind":"param_rejected","parameter":"temperature"},
          {"signatureId":"test.tools_unsupported","httpStatus":400,"messagePattern":"tools are not supported",
           "kind":"param_rejected","parameter":"tools"}
        ]}}
        """.trimIndent(),
    )
    private val assetTable: RejectionSignatureTable by lazy {
        requireNotNull(RejectionSignatures.load(RuntimeEnvironment.getApplication())) { "the signature table asset should be packaged with the APK" }
    }

    @Before
    fun setUp() {
        InputNegativeCache.configure(RuntimeEnvironment.getApplication())
        clear()
    }

    @After
    fun tearDown() {
        clear()
        MetadataTestFixtures.clear()
    }

    private fun clear() = listOf(openAI, anthropic, relay).forEach { InputNegativeCache.shared.clearConnection(it.id) }

    @Test
    fun `param_rejected signature hit records param temperature and the next OpenAI body drops temperature`() {
        val recorded = InputRejectionFlow.recordOfficialParameter(
            provider = openAI,
            model = gpt,
            error = temperatureRejection(),
            outputStarted = false,
            dispatchTransport = "openai_chat",
            table = temperatureTable,
        )
        assertEquals("temperature", recorded)
        // The failure card offers "resend without this parameter": the code comes from the parameter result the failed message recorded itself; tapping it takes the plain resend path, and the outbound request omits it per the negative cache.
        val code = InputRejectionFlow.recoveryCode(input = null, rejectedParameter = recorded)
        assertEquals("input_parameter_rejected:temperature", code)
        val layout = resolveMessageRecoveryCardActionLayout(
            state = ChatMessageState.Failed,
            shouldOfferModelSwitch = false,
            customRetryWithoutFieldsCode = code,
        )
        assertEquals(MessageRecoveryActionKind.ResendWithoutParameter, layout.primary)
        assertEquals(R.string.retry_without_this_setting, layout.primary.titleRes())
        val key = InputNegativeCache.shared.entries().map { it.first }.single { it.connectionId == openAI.id }
        assertEquals(InputNegativeCache.Key(openAI.id, gpt.id, "openai_chat", "param:temperature"), key)

        val body = GenerationParameterResolver.apply(openAIBody(), options(openAI, "openai_chat"), resolved = null)
        val sent = Json.parseToJsonElement(body).jsonObject
        assertFalse("rejected temperature must not go out again", "temperature" in sent)
        assertTrue("the rest of the request stays", "messages" in sent && "model" in sent)
    }

    @Test
    fun `without a rejection record temperature is sent as is`() {
        val body = GenerationParameterResolver.apply(openAIBody(), options(openAI, "openai_chat"), resolved = null)
        assertTrue("temperature" in Json.parseToJsonElement(body).jsonObject)
    }

    @Test
    fun `non gated parameter signature, output started and stream frame errors write nothing`() {
        val toolsError = ProviderServiceError.Upstream(400, "bad").apply {
            rawBody = """{"error":{"message":"tools are not supported"}}"""
        }
        assertNull(InputRejectionFlow.recordOfficialParameter(openAI, gpt, toolsError, false, "openai_chat", temperatureTable))
        assertNull(InputRejectionFlow.recordOfficialParameter(openAI, gpt, temperatureRejection(), true, "openai_chat", temperatureTable))
        assertNull(InputRejectionFlow.recordOfficialParameter(openAI, gpt, temperatureRejection(), false, null, temperatureTable))
        assertTrue(InputNegativeCache.shared.entries().none { it.first.connectionId == openAI.id })
    }

    @Test
    fun `thinking rejection drops the whole thinking field even when typed off`() {
        val error = ProviderServiceError.Upstream(400, "invalid_request_error").apply {
            rawBody = """{"type":"error","error":{"type":"invalid_request_error","message":"\"thinking.type.enabled\" is not supported for this model."}}"""
        }
        val recorded = InputRejectionFlow.recordOfficialParameter(anthropic, claude, error, false, "anthropic_messages", assetTable)
        assertEquals("thinking", recorded)

        val body = """{"model":"claude-test","max_tokens":1024,"messages":[],"thinking":{"type":"disabled"},"temperature":0.5}"""
        val sent = Json.parseToJsonElement(
            GenerationParameterResolver.apply(body, options(anthropic, "anthropic_messages"), null, outboundTemplate = "anthropic_messages"),
        ).jsonObject
        assertFalse("thinking" in sent)
        assertTrue("only the rejected field goes away", "temperature" in sent)
    }

    @Test
    fun `relay does not go through the parameter gate`() {
        assertNull(InputRejectionFlow.recordOfficialParameter(relay, gpt, temperatureRejection(), false, "openai_chat", temperatureTable))
        assertTrue(InputNegativeCache.shared.entries().none { it.first.connectionId == relay.id })

        // Even with a record under the same key, outbound for a Relay identity never reads it.
        InputNegativeCache.shared.record(relay.id, gpt.id, "openai_chat", "param:temperature", "test.temperature_unsupported", null)
        val body = GenerationParameterResolver.apply(openAIBody(), options(relay, "openai_chat"), resolved = null)
        assertTrue("temperature" in Json.parseToJsonElement(body).jsonObject)
    }

    @Test
    fun `param negative cache misses once parameterSupport for that parameter changes`() {
        val silent = openAIClient("""{"temperature":{"state":"unknown","reasonCode":"catalog_silent"}}""")
        val recorded = InputRejectionFlow.recordOfficialParameter(
            provider = openAI,
            model = gpt,
            error = temperatureRejection(),
            outputStarted = false,
            dispatchTransport = "openai_chat",
            table = temperatureTable,
            metadataClient = silent,
        )
        assertEquals("temperature", recorded)
        val options = options(openAI, "openai_chat")
        assertEquals(setOf("temperature"), InputRejectionFlow.rejectedParameters(options, gpt.id, metadataClient = silent))

        val republished = openAIClient("""{"temperature":{"state":"auto_available","sourceRefs":["openai.docs"]}}""")
        assertEquals(emptySet<String>(), InputRejectionFlow.rejectedParameters(options, gpt.id, metadataClient = republished))
        // A different revision only reads as a miss without deleting the entry: returning to the original verdict still hits.
        assertEquals(setOf("temperature"), InputRejectionFlow.rejectedParameters(options, gpt.id, metadataClient = silent))
    }

    @Test
    fun `resend without parameter omits it explicitly even after the negative cache is cleared`() {
        val recorded = InputRejectionFlow.recordOfficialParameter(
            provider = openAI,
            model = gpt,
            error = temperatureRejection(),
            outputStarted = false,
            dispatchTransport = "openai_chat",
            table = temperatureTable,
        )
        val code = InputRejectionFlow.recoveryCode(input = null, rejectedParameter = recorded)
        // The one-tap action goes through a resend carrying a one-shot omit marker, not a plain retry.
        var explicitResend = 0
        var ordinaryRetry = 0
        performRecoveryAction(
            action = MessageRecoveryActionKind.ResendWithoutParameter,
            onRetry = { ordinaryRetry++ },
            onEdit = {},
            onRegenerate = {},
            onSwitchModel = {},
            onContinue = {},
            onRetryWithoutLocalCustomFields = { explicitResend++ },
        )
        assertEquals(1 to 0, explicitResend to ordinaryRetry)

        // Negative cache expired / cleared: the one-shot omit list still keeps this request from carrying the parameter.
        clear()
        val marker = parameterResendMarker(code)
        val once = options(openAI, "openai_chat").copy(
            omitParametersOnce = setOfNotNull(omitParameterOnceName(marker)),
        )
        assertEquals(setOf("temperature"), once.omitParametersOnce)
        val resent = Json.parseToJsonElement(GenerationParameterResolver.apply(openAIBody(), once, resolved = null)).jsonObject
        assertFalse("explicit resend must not carry the rejected parameter", "temperature" in resent)
        assertTrue("messages" in resent && "model" in resent)

        // A later plain retry carries no one-shot marker and follows only the negative cache: with an empty cache it sends as before, and after recording again it omits.
        val ordinary = options(openAI, "openai_chat")
        assertTrue("temperature" in Json.parseToJsonElement(GenerationParameterResolver.apply(openAIBody(), ordinary, null)).jsonObject)
        InputRejectionFlow.recordOfficialParameter(openAI, gpt, temperatureRejection(), false, "openai_chat", temperatureTable)
        assertFalse("temperature" in Json.parseToJsonElement(GenerationParameterResolver.apply(openAIBody(), ordinary, null)).jsonObject)
    }

    /** The MiniMax web route assembles its own Anthropic body and also reads only the rejectedParameters entry: the one-shot omit works there too. */
    @Test
    fun `MiniMax web body drops temperature on an omit once resend with the negative cache cleared`() = runTest {
        MetadataTestFixtures.applyRaw(MINIMAX_WEB_WITH_TEMPERATURE)
        clear()
        val bodies = mutableListOf<JsonObject>()
        val client = HttpClient(MockEngine { request ->
            bodies += Json.parseToJsonElement((request.body as TextContent).text).jsonObject
            respond(
                content = "event: message_stop\ndata: {\"type\":\"message_stop\"}\n\n",
                status = HttpStatusCode.OK,
                headers = headersOf(HttpHeaders.ContentType, "text/event-stream"),
            )
        })
        val service = MiniMaxService(client, Json { ignoreUnknownKeys = true })
        val message = ChatMessage(id = "u1", role = ChatRole.User, text = "news", providerKind = ProviderKind.MiniMax, providerName = "MiniMax", modelName = "MiniMax-M3", state = ai.oriveo.community.core.model.ChatMessageState.Delivered)
        suspend fun send(options: ChatRequestOptions) = service.sendMessageStream(
            "key", "MiniMax-M3", listOf(message), "https://api.minimax.io/v1",
            false, ReasoningMode.Automatic, true, options,
        ).toList()

        val base = ChatRequestOptions(temperature = 0.7f)
        send(base)
        assertTrue("control: the web route sends temperature when nothing omits it", "temperature" in bodies.last())

        val marker = parameterResendMarker("input_parameter_rejected:temperature")
        send(base.copy(omitParametersOnce = setOfNotNull(omitParameterOnceName(marker))))
        assertTrue("still the web route", "web_search_20250305" in bodies.last()["tools"].toString())
        assertFalse("omit once must reach the MiniMax web body", "temperature" in bodies.last())
    }

    @Test
    fun `omit once marker only accepts gated parameter names`() {
        assertNull(parameterResendMarker("input_parameter_rejected:tools"))
        assertNull(parameterResendMarker("local_fields_retry_offer:web"))
        assertNull(omitParameterOnceName("omit_parameter_once:tools"))
        assertNull(omitParameterOnceName("omit_local_fields_once:web"))
        assertEquals("thinking", omitParameterOnceName(parameterResendMarker("input_parameter_rejected:thinking")))
    }

    private fun openAIClient(parameterSupport: String) = MetadataClient().apply {
        loadNetworkPayloadForTesting(
            """
            {"version":1,"contractVersion":1,"providers":{"${ProviderKind.OpenAI.rawValue}":{"resolveMap":{"gpt-test":"gpt-test"},"models":{
              "gpt-test":{"canonicalModelId":"gpt-test","transport":"openai_chat","parameterSupport":$parameterSupport}
            }}}}
            """.trimIndent(),
            "\"param-gate-${parameterSupport.hashCode()}\"",
        )
    }

    private fun openAIBody() = """{"model":"gpt-test","messages":[{"role":"user","content":"hi"}],"temperature":0.7}"""

    private fun temperatureRejection() = ProviderServiceError.Upstream(400, "invalid_request_error").apply {
        rawBody = """{"error":{"type":"invalid_request_error","message":"Unsupported parameter: 'temperature' is not supported with this model."}}"""
    }

    private companion object {
        val MINIMAX_WEB_WITH_TEMPERATURE = """
            {
              "version":1,
              "providers":{"miniMax":{"resolveMap":{"MiniMax-M3":"MiniMax-M3"},"models":{
                "MiniMax-M3":{"canonicalModelId":"MiniMax-M3","transport":"openai_chat","capabilities":["text","web"],
                  "capabilityControls":{"web":{"state":"auto_available","recipeRef":"minimax.messages.web.v1"},"generation":{"state":"auto_available","recipeRef":"minimax.chat.generation.v1"}}}
              }}},
              "capabilityRuntime":{"schemaVersion":2,"revision":"minimax-web-param-gate","generatedAt":"2026-08-23T00:00:00Z","controlDefinitions":{},
                "sourceIndex":{"minimax.server_tools":{"kind":"official_doc","url":"https://platform.minimax.io/docs/guides/server-tools","reviewedAt":"2026-08-23"}},
                "recipes":{"minimax.messages.web.v1":{"id":"minimax.messages.web.v1","providerKind":"miniMax","transport":{"protocol":"openai_chat"},"capability":"web","executionKind":"endpoint_route","requestOps":[{"op":"append","pointer":"/tools/-","value":{"type":"web_search_20250305","name":"web_search"}}],"route":{"sourceProtocol":"openai_chat","protocol":"anthropic_messages","endpointClass":"messages","path":"/anthropic/v1/messages","method":"POST","authMode":"x_api_key","authHeader":"x-api-key","headers":{"Content-Type":"application/json","anthropic-version":"2023-06-01"},"requestMapper":"minimax_anthropic_messages_v1"},"responseParserKind":"minimax_anthropic_web_v1","continuationKind":"replay_blocks","fallbackPolicy":"remove_auto_patch_once_pre_token","sourceRefs":["minimax.server_tools"]},
                  "minimax.chat.generation.v1":{"id":"minimax.chat.generation.v1","providerKind":"miniMax","capability":"generation","executionKind":"request_overlay","continuationKind":"none","controlRefs":[],"fallbackPolicy":"user_confirmed_resend_without_located_setting","requestOps":[{"op":"legacy_generation_template","template":"openai_chat_completions"}],"responseParserKind":"openai_chat_generation_v1","reviewedAt":"2026-08-11","sourceRefs":["minimax.server_tools"],"transport":{"endpointClass":"chat_completions","protocol":"openai_chat","requiredHeaders":[],"streaming":"optional"}}}
              }
            }
        """.trimIndent()
    }

    private fun options(provider: Provider, transport: String) = ChatRequestOptions(
        capabilityEvidenceIdentity = CapabilityEvidenceIdentity(
            partitionId = "partition-1",
            connectionInstanceId = provider.id,
            connectionGeneration = "1",
            credentialEpoch = "1",
            providerKind = provider.kind.rawValue,
            authMode = provider.authMode.rawValue,
        ),
        capabilityExecutionCollector = CapabilityExecutionCollector().apply { noteInputDispatchTransport(transport) },
    )
}
