package ai.oriveo.community.core.provider

import ai.oriveo.community.core.model.ChatMessage
import ai.oriveo.community.core.model.ChatRequestOptions
import ai.oriveo.community.core.model.ProviderSyncResult
import ai.oriveo.community.core.model.ReasoningMode
import ai.oriveo.community.core.model.RelayRequestedConfig
import ai.oriveo.community.core.model.StreamEvent
import kotlinx.coroutines.flow.Flow

/**
 * The common contract every provider service implements.
 *
 * Each provider (OpenRouter, OpenAI, Anthropic, Gemini, Groq, Together, Fireworks and the rest)
 * implements this interface, and ProviderRepository dispatches to one of them by ProviderKind.
 */
interface ProviderService {

    /**
     * Syncs the runtime model list.
     *
     * Registering or re-syncing a built-in provider does not call this method and does not validate
     * the key against the upstream: the model list for those comes from the published model
     * catalog. A Relay custom endpoint still probes its `/models` through this method.
     */
    suspend fun syncProvider(
        apiKey: String,
        preferredModelID: String? = null,
        baseUrl: String? = null,
    ): ProviderSyncResult

    /**
     * Catalog sync with relayRequested. Only Relay (RelayService) actually consumes it: in the
     * credential-free mode (authMode == None, i.e. a local engine) an empty key is legitimate, and
     * the request has to go to the exact API root that was probed, under the LAN safety mode. Every
     * other service takes this default implementation, which ignores the parameter.
     */
    suspend fun syncProvider(
        apiKey: String,
        preferredModelID: String?,
        baseUrl: String?,
        relayRequested: RelayRequestedConfig?,
    ): ProviderSyncResult = syncProvider(apiKey, preferredModelID, baseUrl)

    /**
     * Sends a message and streams the reply.
     *
     * @param reasoningMode the reasoning mode; Automatic omits the parameter and lets the API decide.
     * @param webSearchEnabled whether to enable web search (supported by OpenRouter and Gemini only).
     * @return Flow<StreamEvent>: Delta(text) -> ... -> Done(result).
     *         On failure the flow throws a ProviderServiceError.
     */
    fun sendMessageStream(
        apiKey: String,
        modelID: String,
        messages: List<ChatMessage>,
        baseUrl: String? = null,
        supportsImageGen: Boolean = false,
        reasoningMode: ReasoningMode = ReasoningMode.Automatic,
        webSearchEnabled: Boolean = false,
        requestOptions: ChatRequestOptions = ChatRequestOptions(),
    ): Flow<StreamEvent>

    /**
     * Sends a message without streaming, for cases such as image generation that need the complete
     * response in one piece. The default implementation collects every event of sendMessageStream
     * and returns the final result.
     */
    suspend fun sendMessage(
        apiKey: String,
        modelID: String,
        messages: List<ChatMessage>,
        baseUrl: String? = null,
        supportsImageGen: Boolean = false,
        reasoningMode: ReasoningMode = ReasoningMode.Automatic,
        webSearchEnabled: Boolean = false,
        requestOptions: ChatRequestOptions = ChatRequestOptions(),
    ): StreamEvent.Done {
        var result: StreamEvent.Done? = null
        sendMessageStream(
            apiKey = apiKey,
            modelID = modelID,
            messages = messages,
            baseUrl = baseUrl,
            supportsImageGen = supportsImageGen,
            reasoningMode = reasoningMode,
            webSearchEnabled = webSearchEnabled,
            requestOptions = requestOptions,
        )
            .collect { event -> if (event is StreamEvent.Done) result = event }
        return result ?: throw ai.oriveo.community.core.model.ProviderServiceError.EmptyResponse
    }
}
