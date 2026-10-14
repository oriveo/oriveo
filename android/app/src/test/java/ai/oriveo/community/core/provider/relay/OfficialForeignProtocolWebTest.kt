package ai.oriveo.community.core.provider.relay

import ai.oriveo.community.core.model.AIModel
import ai.oriveo.community.core.model.CapabilityEvidenceIdentity
import ai.oriveo.community.core.model.ChatRequestOptions
import ai.oriveo.community.core.model.ProviderAuthMode
import ai.oriveo.community.core.model.ModelCapability
import ai.oriveo.community.core.model.ProviderKind
import ai.oriveo.community.core.model.ReasoningMode
import ai.oriveo.community.core.provider.MetadataTestFixtures
import ai.oriveo.community.core.provider.OfficialProtocolDispatch
import ai.oriveo.community.core.provider.ProviderService
import ai.oriveo.community.core.provider.ProviderTestFixtures
import ai.oriveo.community.core.provider.RelayService
import ai.oriveo.community.core.provider.transport.TransportRegistry
import io.ktor.client.HttpClient
import io.ktor.client.engine.mock.MockEngine
import io.ktor.client.engine.mock.respond
import io.ktor.http.HttpHeaders
import io.ktor.http.HttpStatusCode
import io.ktor.http.content.OutgoingContent
import io.ktor.http.content.TextContent
import io.ktor.http.headersOf
import io.mockk.mockk
import kotlinx.coroutines.flow.toList
import kotlinx.coroutines.test.runTest
import kotlinx.serialization.json.Json
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotEquals
import org.junit.Test

/**
 * When an official provider switches to the Relay builders per the delivered apiProtocol (OfficialProtocolDispatch), web behavior stays unchanged:
 * only the web tool the "relay" builders used to add automatically per preference was removed. Assertions come from the request bodies the production dispatch actually sends:
 * for the same official route and model, the request bodies sent with the chat web preference on / off match the earlier criterion (preference + outbound gate).
 */
class OfficialForeignProtocolWebTest {
    private val json = Json { ignoreUnknownKeys = true; encodeDefaults = true }
    private val clients = mutableListOf<HttpClient>()

    @After
    fun tearDown() {
        MetadataTestFixtures.clear()
        clients.forEach { it.close() }
    }

    private fun applyConfig(kind: String, base: String, protocol: String) {
        MetadataTestFixtures.applyRaw(
            """{"version":1,"providers":{},"providerConfigs":[{"kind":"$kind","displayName":"x","defaultBaseURL":"$base","apiProtocol":"$protocol"}]}""",
        )
    }

    private suspend fun body(kind: ProviderKind, web: Boolean): String {
        var body: String? = null
        val client = HttpClient(MockEngine { request ->
            if (body == null) body = bodyText(request.body)
            respond("data: [DONE]\n\n", HttpStatusCode.OK, headersOf(HttpHeaders.ContentType, "text/event-stream"))
        }).also { clients += it }
        val service = OfficialProtocolDispatch.service(kind, mockk<ProviderService>(relaxed = true), RelayService(client, json, TransportRegistry(json)))
        val model = AIModel(id = "m", name = "m", capabilities = listOf(ModelCapability.Text, ModelCapability.Web), webSearchProfile = "gem_web")
        runCatching {
            service.sendMessageStream(
                apiKey = "k",
                modelID = "m",
                messages = listOf(ProviderTestFixtures.userMessage("hi", kind, "m")),
                baseUrl = null,
                supportsImageGen = false,
                reasoningMode = ReasoningMode.Automatic,
                webSearchEnabled = web,
                requestOptions = ChatRequestOptions(
                    activeModel = model,
                    capabilityEvidenceIdentity = CapabilityEvidenceIdentity(
                        partitionId = "u1", connectionInstanceId = "official-${kind.rawValue}", connectionGeneration = "g1",
                        credentialEpoch = "c1", providerKind = kind.rawValue, metadataRevision = "m1", generationRevision = "g1",
                        authMode = ProviderAuthMode.ApiKey.rawValue,
                    ),
                ),
            ).toList()
        }
        return requireNotNull(body) { "$kind did not issue a request" }
    }

    @Test
    fun official_foreign_gemini_route_keeps_the_pre_D73_web_behaviour() = runTest {
        applyConfig("miniMax", "https://api.minimax.io/gemini", "gemini")
        val on = body(ProviderKind.MiniMax, web = true)
        val off = body(ProviderKind.MiniMax, web = false)
        assertEquals("no googleSearch when the preference is off：$off", false, off.contains("googleSearch"))
        // Same criterion as before: with the preference on, the request body attaches tools per the outbound gate; compared with the preference-off run it differs only by the web tool.
        assertEquals(EXPECTED_GEMINI_WEB_ON, on.contains("googleSearch"))
        if (EXPECTED_GEMINI_WEB_ON) assertNotEquals(on, off)
    }

    @Test
    fun official_foreign_responses_route_keeps_the_pre_D73_web_behaviour() = runTest {
        applyConfig("miniMax", "https://api.minimax.io/v1", "openai_responses")
        val on = body(ProviderKind.MiniMax, web = true)
        val off = body(ProviderKind.MiniMax, web = false)
        assertEquals("no web_search when the preference is off：$off", false, off.contains("web_search"))
        assertEquals(EXPECTED_RESPONSES_WEB_ON, on.contains("\"web_search\""))
    }

    private fun bodyText(body: OutgoingContent): String = when (body) {
        is TextContent -> body.text
        is OutgoingContent.ByteArrayContent -> body.bytes().decodeToString()
        else -> error("Unsupported request body type: ${body::class.java.name}")
    }

    private companion object {
        // Measured from the earlier builders: the outbound gate of the official foreign-protocol route (the Relay truth adapter only accepts relay declarations) never lets web through,
        // so even with the preference on no tool is attached. This must stay true after relay auto web was removed (official behavior unchanged).
        const val EXPECTED_GEMINI_WEB_ON = false
        const val EXPECTED_RESPONSES_WEB_ON = false
    }
}
