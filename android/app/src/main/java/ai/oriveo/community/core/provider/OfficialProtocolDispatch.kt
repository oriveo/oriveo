package ai.oriveo.community.core.provider

import ai.oriveo.community.core.data.remote.MetadataClient
import ai.oriveo.community.core.model.ChatMessage
import ai.oriveo.community.core.model.ChatRequestOptions
import ai.oriveo.community.core.model.ProviderKind
import ai.oriveo.community.core.model.ReasoningMode
import ai.oriveo.community.core.model.RelayAuthMode
import ai.oriveo.community.core.model.RelayRequestedConfig
import ai.oriveo.community.core.model.RelayTransport
import ai.oriveo.community.core.model.StreamEvent
import ai.oriveo.community.core.provider.transport.EndpointResolver
import kotlinx.coroutines.flow.Flow

/**
 * An official provider's outbound transport is decided by metadata `providerConfigs[].apiProtocol`.
 *
 * If the delivered value equals this provider's native transport family, is missing, or is unrecognized -> use the per-provider service (request body byte-for-byte unchanged, guarded by golden tests);
 * if it is another transport -> use the Relay per-transport builders, with the root address taken from the base URL delivered for this provider (checked against the trust table),
 * and providerKind decides only the auth method and extra headers.
 */
object OfficialProtocolDispatch {

    /** The Relay transport this provider should switch to right now; null = use the native service. */
    fun foreignTransport(kind: ProviderKind, apiProtocol: String? = MetadataClient.apiProtocol(kind)): RelayTransport? {
        if (kind == ProviderKind.Relay) return null
        val protocol = apiProtocol?.trim()?.lowercase()?.takeIf { it.isNotEmpty() } ?: return null
        if (protocol in nativeFamily(kind)) return null
        return when (protocol) {
            "anthropic", "anthropic_messages" -> RelayTransport.AnthropicMessages
            "gemini", "gemini_generate_content" -> RelayTransport.GeminiGenerateContent
            "openai_responses" -> RelayTransport.OpenAIResponses
            else -> null
        }
    }

    private fun nativeFamily(kind: ProviderKind): Set<String> = when (kind) {
        ProviderKind.Anthropic -> setOf("anthropic", "anthropic_messages")
        ProviderKind.Gemini -> setOf("gemini", "gemini_generate_content")
        else -> setOf("openai", "openai_compatible", "openai_chat_completions")
    }

    /**
     * Auth method. Both official Anthropic and MiniMax's Anthropic-compatible endpoint accept `x-api-key` (consistent with [MiniMaxService]'s
     * Messages web-search route); Gemini uses `x-goog-api-key`; the OpenAI family uses Bearer.
     */
    fun authMode(transport: RelayTransport): RelayAuthMode = when (transport) {
        RelayTransport.AnthropicMessages -> RelayAuthMode.XApiKey
        RelayTransport.GeminiGenerateContent -> RelayAuthMode.XGoogApiKey
        else -> RelayAuthMode.Bearer
    }

    /**
     * Pick the outbound service for this provider. When the delivered transport is the native family / not delivered / unrecognized, or the delivered base URL is missing or fails the trust table,
     * return [native] unchanged (fail to today's behavior; never send to an untrusted address).
     */
    fun service(kind: ProviderKind, native: ProviderService, relay: RelayService): ProviderService {
        val transport = foreignTransport(kind) ?: return native
        val base = EndpointResolver.trustedOfficialBase(kind, MetadataClient.publicProviderConfig(kind)?.defaultBaseURL)
            ?: return native
        val requested = RelayRequestedConfig(
            transport = transport,
            authMode = authMode(transport),
            // Official providers are not relays: no Codex identity header
            codexCompatIdentity = false,
        )
        val root = RelayEndpointResolver.effectiveAPIRoot(requested, base, null) ?: return native
        return OfficialRelayService(native, relay, requested, transport, root)
    }

    private class OfficialRelayService(
        private val native: ProviderService,
        private val relay: RelayService,
        private val requested: RelayRequestedConfig,
        private val transport: RelayTransport,
        private val root: String,
    ) : ProviderService by native {

        private fun routed(options: ChatRequestOptions) = options.copy(
            relayRequested = requested,
            relayRouteTransport = transport,
            relayRouteAPIRoot = root,
        )

        override fun sendMessageStream(
            apiKey: String,
            modelID: String,
            messages: List<ChatMessage>,
            baseUrl: String?,
            supportsImageGen: Boolean,
            reasoningMode: ReasoningMode,
            webSearchEnabled: Boolean,
            requestOptions: ChatRequestOptions,
        ): Flow<StreamEvent> = relay.sendMessageStream(
            apiKey = apiKey,
            modelID = modelID,
            messages = messages,
            baseUrl = root,
            supportsImageGen = supportsImageGen,
            reasoningMode = reasoningMode,
            webSearchEnabled = webSearchEnabled,
            requestOptions = routed(requestOptions),
        )

        override suspend fun sendMessage(
            apiKey: String,
            modelID: String,
            messages: List<ChatMessage>,
            baseUrl: String?,
            supportsImageGen: Boolean,
            reasoningMode: ReasoningMode,
            webSearchEnabled: Boolean,
            requestOptions: ChatRequestOptions,
        ): StreamEvent.Done = relay.sendMessage(
            apiKey = apiKey,
            modelID = modelID,
            messages = messages,
            baseUrl = root,
            supportsImageGen = supportsImageGen,
            reasoningMode = reasoningMode,
            webSearchEnabled = webSearchEnabled,
            requestOptions = routed(requestOptions),
        )
    }
}
