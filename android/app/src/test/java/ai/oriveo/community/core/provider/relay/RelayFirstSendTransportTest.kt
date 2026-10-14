package ai.oriveo.community.core.provider.relay

import ai.oriveo.community.core.model.AIModel
import ai.oriveo.community.core.model.ModelCapability
import ai.oriveo.community.core.model.Provider
import ai.oriveo.community.core.model.ProviderKind
import ai.oriveo.community.core.model.RelayAuthMode
import ai.oriveo.community.core.model.RelayConnectionSecurityMode
import ai.oriveo.community.core.model.RelayKind
import ai.oriveo.community.core.model.RelayRequestedConfig
import ai.oriveo.community.core.model.RelayTransport
import ai.oriveo.community.core.model.RelayTransportSource
import ai.oriveo.community.core.provider.RelayEndpointResolver
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Test

/**
 * First-send protocol of an unverified model (RL2-FIRSTSEND-05): a pure function read identically by the first chat send, the negative-cache key and the advanced page "Auto =".
 * Candidates = this session's catalog endpoint types mapped in order; only when empty is the cached family table consulted; no request is made for the first send.
 */
class RelayFirstSendTransportTest {
    private val root = "https://first-send.example.com/v1"

    @After
    fun tearDown() {
        RelayCatalogEndpointTypes.record(root, emptyMap())
    }

    private fun relay(transport: RelayTransport = RelayTransport.Auto, engineProfile: String? = null) = Provider(
        id = "relay-first-send",
        kind = ProviderKind.Relay,
        baseUrlText = "https://first-send.example.com",
        relayKind = RelayKind.OpenAICompatible,
        relayRequested = RelayRequestedConfig(
            transport = transport,
            authMode = if (engineProfile != null) RelayAuthMode.None else RelayAuthMode.Bearer,
            securityMode = if (engineProfile != null) RelayConnectionSecurityMode.LocalHttp else RelayConnectionSecurityMode.RemoteHttps,
            engineProfile = engineProfile,
            resolvedAPIBaseURL = root,
        ),
    )

    private fun resolve(
        provider: Provider,
        model: AIModel?,
        types: List<String>? = null,
        family: String? = null,
    ) = RelayFirstSendTransport.resolve(
        provider = provider,
        model = model,
        endpointTypes = { _, _ -> types },
        family = { family },
    )

    @Test
    fun `RL2-FIRSTSEND-05 first send is Messages only when the first candidate is Messages, otherwise effectiveTransport`() {
        val provider = relay()
        val model = AIModel(id = "claude-sonnet-4-5", name = "claude-sonnet-4-5")
        val chat = RelayEndpointResolver.effectiveTransport(provider, model)
        assertEquals(RelayTransport.OpenAIChatCompletions, chat)

        // endpoint types are mapped in order, first item anthropic -> Messages; if the first item is not Messages it is always effectiveTransport.
        assertEquals(RelayTransport.AnthropicMessages, resolve(provider, model, types = listOf("anthropic", "openai")))
        assertEquals(chat, resolve(provider, model, types = listOf("openai", "anthropic")))
        assertEquals("a first item of Responses does not change the first send either", chat, resolve(provider, model, types = listOf("openai-response")))
        assertEquals(chat, resolve(provider, model, types = listOf("gemini")))
        // Unknown ones are dropped before looking at the first item; if a protocol is mapped the family is not consulted.
        assertEquals(RelayTransport.AnthropicMessages, resolve(provider, model, types = listOf("mystery", "anthropic")))
        assertEquals("the family is ignored when endpoint types are non-empty", chat, resolve(provider, model, types = listOf("openai"), family = "anthropic"))

        // The family table is consulted only when endpoint types are empty / all unknown: anthropic -> [Messages, Chat], and for every other family the first item is not Messages.
        assertEquals(RelayTransport.AnthropicMessages, resolve(provider, model, types = null, family = "anthropic"))
        assertEquals(RelayTransport.AnthropicMessages, resolve(provider, model, types = listOf("mystery"), family = "anthropic"))
        assertEquals(chat, resolve(provider, model, family = "openai"))
        assertEquals(chat, resolve(provider, model, family = "google"))
        assertEquals("unknown family -> Chat", chat, resolve(provider, model, family = null))

        // A model with auto is treated as having no protocol of its own.
        val autoModel = model.copy(relayTransport = RelayTransport.Auto)
        assertEquals(RelayTransport.AnthropicMessages, resolve(provider, autoModel, family = "anthropic"))
        // A model with its own protocol (any source) -> effectiveTransport.
        for (source in RelayTransportSource.entries) {
            val own = model.copy(relayTransport = RelayTransport.OpenAIResponses, relayTransportSource = source)
            assertEquals(source.name, RelayTransport.OpenAIResponses, resolve(provider, own, types = listOf("anthropic"), family = "anthropic"))
        }
        // Following the selected connection -> the connection protocol.
        val explicit = relay(transport = RelayTransport.GeminiGenerateContent)
        assertEquals(RelayTransport.GeminiGenerateContent, resolve(explicit, model, types = listOf("anthropic"), family = "anthropic"))
        // Local -> effectiveTransport.
        val local = relay(engineProfile = "ollama")
        assertEquals(RelayTransport.OpenAIChatCompletions, resolve(local, model, types = listOf("anthropic"), family = "anthropic"))
        // Image generation (override or capability) -> effectiveTransport.
        val generator = model.copy(capabilities = listOf(ModelCapability.ImageGen))
        assertEquals(chat, resolve(provider, generator, types = listOf("anthropic")))
        // Not Relay / no model -> effectiveTransport.
        val official = provider.copy(kind = ProviderKind.Anthropic, relayRequested = null)
        assertEquals(RelayEndpointResolver.effectiveTransport(official, model), resolve(official, model, types = listOf("anthropic")))
        assertEquals(chat, resolve(provider, null, types = listOf("anthropic")))
    }

    @Test
    fun `RL2-FIRSTSEND-05 candidates come from the session endpoint type cache and the cached family only`() {
        val provider = relay()
        val model = AIModel(id = "claude-opus-4-1", name = "claude-opus-4-1")
        // Default parameters read the production cache: the endpoint types written by this session's catalog.
        RelayCatalogEndpointTypes.record(root, mapOf(model.id to listOf("anthropic")))
        assertEquals(listOf(RelayTransport.AnthropicMessages), RelayFirstSendTransport.candidates(provider, model.id))
        assertEquals(RelayTransport.AnthropicMessages, RelayFirstSendTransport.resolve(provider, model))
        // The catalog key is computed by the same function as the refresh write.
        assertEquals(
            RelayCatalogEndpointTypes.catalogRoot(provider.relayRequested, provider.baseUrlText),
            root,
        )
        // Candidates come from the same candidate function as probe fallback: at most 2, deduplicated.
        assertEquals(
            listOf(RelayTransport.AnthropicMessages, RelayTransport.OpenAIChatCompletions),
            RelayFirstSendTransport.candidates(provider, "x", endpointTypes = { _, _ -> null }, family = { "anthropic" }),
        )
        assertEquals(
            RelayProbeCandidates.fromEndpointTypes(listOf("anthropic", "anthropic", "openai", "gemini")),
            RelayFirstSendTransport.candidates(provider, "x", endpointTypes = { _, _ -> listOf("anthropic", "anthropic", "openai", "gemini") }, family = { null }),
        )
        // After the cache is cleared this session has no endpoint types and the family table was never fetched -> only Chat is tried, no request is sent.
        RelayCatalogEndpointTypes.record(root, emptyMap())
        assertEquals(listOf(RelayTransport.OpenAIChatCompletions), RelayFirstSendTransport.candidates(provider, model.id, family = { null }))
    }
}
