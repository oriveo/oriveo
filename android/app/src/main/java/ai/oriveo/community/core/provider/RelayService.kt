package ai.oriveo.community.core.provider

import ai.oriveo.community.core.model.ChatMessage
import ai.oriveo.community.core.model.ChatRequestOptions
import ai.oriveo.community.core.model.ProviderSyncResult
import ai.oriveo.community.core.model.RelayKind
import ai.oriveo.community.core.model.RelayRequestedConfig
import ai.oriveo.community.core.model.ReasoningMode
import ai.oriveo.community.core.model.StreamEvent
import ai.oriveo.community.core.provider.relay.RelayTransportCoordinator
import ai.oriveo.community.core.provider.transport.TransportRegistry
import io.ktor.client.HttpClient
import kotlinx.coroutines.flow.Flow
import kotlinx.serialization.json.Json

class RelayService(
    client: HttpClient,
    json: Json,
    transportRegistry: TransportRegistry,
) : ProviderService {
    private val coordinator = RelayTransportCoordinator(
        client = client,
        json = json,
        transportRegistry = transportRegistry,
    )

    override suspend fun syncProvider(
        apiKey: String,
        preferredModelID: String?,
        baseUrl: String?,
    ): ProviderSyncResult = syncProvider(apiKey, preferredModelID, baseUrl, relayRequested = null)

    /**
     * Directory sync for a configured relay has to hit the same probed API root as chat does,
     * including the /v1 suffix, and reuse the securityMode/authMode that were persisted with the
     * endpoint. A local engine and a relay that explicitly needs no auth are both legitimately
     * local_http + none, so a null engineProfile must not silently fall back to public HTTPS with
     * a placeholder Bearer header. Older callers that genuinely have no relayRequested still get
     * requireSecure, byte for byte as before.
     */
    override suspend fun syncProvider(
        apiKey: String,
        preferredModelID: String?,
        baseUrl: String?,
        relayRequested: RelayRequestedConfig?,
    ): ProviderSyncResult = coordinator.syncProvider(
        apiKey = apiKey,
        preferredModelID = preferredModelID,
        baseUrl = if (relayRequested != null) {
            requireConfigured(
                relayRequested.resolvedAPIBaseURL?.takeIf { it.isNotBlank() } ?: baseUrl,
                apiKey,
                relayRequested,
            )
        } else {
            RelayEndpointPolicy.requireSecure(baseUrl)
        },
        relayRequested = relayRequested,
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
    ): StreamEvent.Done = coordinator.sendMessage(
        apiKey = apiKey,
        modelID = modelID,
        messages = messages,
        baseUrl = requireConfigured(baseUrl, apiKey, requestOptions.relayRequested),
        supportsImageGen = supportsImageGen,
        reasoningMode = reasoningMode,
        webSearchEnabled = webSearchEnabled,
        requestOptions = requestOptions,
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
    ): Flow<StreamEvent> = coordinator.sendMessageStream(
        apiKey = apiKey,
        modelID = modelID,
        messages = messages,
        baseUrl = requireConfigured(baseUrl, apiKey, requestOptions.relayRequested),
        supportsImageGen = supportsImageGen,
        reasoningMode = reasoningMode,
        webSearchEnabled = webSearchEnabled,
        requestOptions = requestOptions,
    )

    /**
     * One-shot image generation for imageRoute = images_endpoint, which uses the separate
     * `/images/generations` endpoint.
     */
    suspend fun generateImageViaImagesEndpoint(
        apiKey: String,
        modelID: String,
        messages: List<ChatMessage>,
        baseUrl: String?,
        requestOptions: ChatRequestOptions,
    ): StreamEvent.Done = coordinator.generateImageViaImagesEndpoint(
        apiKey = apiKey,
        modelID = modelID,
        messages = messages,
        baseUrl = requireConfigured(baseUrl, apiKey, requestOptions.relayRequested),
        requestOptions = requestOptions,
    )

    suspend fun pingRelay(
        apiKey: String,
        baseUrl: String?,
        modelID: String,
        relayRequested: RelayRequestedConfig,
        relayKind: RelayKind? = null,
    ) {
        coordinator.pingRelay(
            apiKey,
            requireConfigured(baseUrl, apiKey, relayRequested),
            modelID,
            relayRequested,
            relayKind,
        )
    }

    /**
     * The 1-token real generation check used by the endpoint detail lifecycle; kept strictly
     * separate from directory sync.
     */
    suspend fun verifyGeneration(
        apiKey: String,
        baseUrl: String?,
        modelID: String,
        relayRequested: RelayRequestedConfig,
        relayKind: RelayKind? = null,
    ) = pingRelay(apiKey, baseUrl, modelID, relayRequested, relayKind)

    private fun requireConfigured(
        baseUrl: String?,
        apiKey: String,
        requested: RelayRequestedConfig?,
    ): String {
        val mode = requested?.securityMode
            ?: ai.oriveo.community.core.model.RelayConnectionSecurityMode.RemoteHttps
        return RelayEndpointPolicy.requireConfigured(
            baseUrl = baseUrl,
            securityMode = mode,
            // Saving relay settings in ProviderDetailViewModel.saveRelaySettings goes through this
            // same builder. The two sides have to agree forever, otherwise we persist a zombie
            // connection that saves cleanly and then has every request rejected on send.
            credentials = RelayEndpointPolicy.credentialsOf(requested, hasKey = apiKey.isNotBlank()),
        )
    }
}
