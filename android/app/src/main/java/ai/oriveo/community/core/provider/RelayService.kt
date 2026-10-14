package ai.oriveo.community.core.provider

import ai.oriveo.community.core.model.ChatMessage
import ai.oriveo.community.core.model.ChatRequestOptions
import ai.oriveo.community.core.model.ProviderSyncResult
import ai.oriveo.community.core.model.RelayKind
import ai.oriveo.community.core.model.RelayRequestedConfig
import ai.oriveo.community.core.model.RelayTransport
import ai.oriveo.community.core.model.ReasoningMode
import ai.oriveo.community.core.model.StreamEvent
import ai.oriveo.community.core.provider.relay.RelayCapabilityTestResponse
import ai.oriveo.community.core.provider.relay.RelayChatBuildExtras
import ai.oriveo.community.core.provider.relay.RelayChatWireRequest
import ai.oriveo.community.core.provider.relay.RelayCatalogEndpointTypes
import ai.oriveo.community.core.provider.relay.RelayTransportCoordinator
import ai.oriveo.community.core.provider.relay.RelayWebProbe
import ai.oriveo.community.core.provider.relay.RelayWebProbeReply
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
    ): ProviderSyncResult {
        // The catalog is connection-level: take the root from the connection's default transport (no model).
        val catalogRoot = relayRequested?.let { RelayCatalogEndpointTypes.catalogRoot(it, baseUrl) }
        val result = coordinator.syncProvider(
            apiKey = apiKey,
            preferredModelID = preferredModelID,
            baseUrl = if (relayRequested != null) {
                requireConfigured(catalogRoot, apiKey, relayRequested)
            } else {
                RelayEndpointPolicy.requireSecure(baseUrl)
            },
            relayRequested = relayRequested,
        )
        // Catalog refresh and add-discovery also fill the endpoint types cache, with the key computed by the same function as the lazy-verification lookup.
        catalogRoot?.let { RelayCatalogEndpointTypes.record(it, result.relayEndpointTypes) }
        return result
    }

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
        requestOptions = routed(requestOptions, baseUrl, apiKey),
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
        requestOptions = routed(requestOptions, baseUrl, apiKey),
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
        modelTransport: RelayTransport? = null,
    ) {
        coordinator.pingRelay(
            apiKey,
            requireConfigured(baseUrl, apiKey, relayRequested),
            modelID,
            relayRequested,
            relayKind,
            modelTransport,
        )
    }

    /**
     * One item of the user-initiated "test capability": uses the same address validation, routing, and chat builders as [sendMessageStream],
     * sends once, reads the full response, and returns the HTTP status unchanged. [extras] are optional builder inputs (output cap / function tool / keep images).
     */
    internal suspend fun sendCapabilityTest(
        apiKey: String,
        modelID: String,
        message: ChatMessage,
        baseUrl: String?,
        requestOptions: ChatRequestOptions,
        extras: RelayChatBuildExtras,
    ): RelayCapabilityTestResponse = coordinator.sendRelayCapabilityTest(
        apiKey = apiKey,
        modelID = modelID,
        messages = listOf(message),
        baseUrl = requireConfigured(baseUrl, apiKey, requestOptions.relayRequested),
        requestOptions = routed(requestOptions, baseUrl, apiKey),
        extras = extras,
    )

    /**
     * The single request of the relay web probe: same address validation and routing as [sendCapabilityTest],
     * with the fragment placed by the caller in [ChatRequestOptions.relayWebFragments] (key = first-send transport) and merged the same way as chat.
     */
    internal suspend fun sendWebProbe(
        apiKey: String,
        modelID: String,
        baseUrl: String?,
        requestOptions: ChatRequestOptions,
    ): RelayWebProbeReply = coordinator.sendRelayWebProbe(
        apiKey = apiKey,
        modelID = modelID,
        messages = listOf(RelayWebProbe.message(modelID)),
        baseUrl = requireConfigured(baseUrl, apiKey, requestOptions.relayRequested),
        requestOptions = routed(requestOptions, baseUrl, apiKey),
        extras = RelayWebProbe.buildExtras(),
    )

    /** URL and request body of this chat streaming send (same address validation and routing as [sendCapabilityTest]); sends no request. */
    internal fun chatStreamWireRequest(
        apiKey: String,
        modelID: String,
        message: ChatMessage,
        baseUrl: String?,
        requestOptions: ChatRequestOptions,
        extras: RelayChatBuildExtras = RelayChatBuildExtras.None,
    ): RelayChatWireRequest = coordinator.buildRelayChatStreamRequest(
        apiKey = apiKey,
        modelID = modelID,
        messages = listOf(message),
        baseUrl = requireConfigured(baseUrl, apiKey, requestOptions.relayRequested),
        reasoningMode = ReasoningMode.Automatic,
        requestOptions = routed(requestOptions, baseUrl, apiKey),
        extras = extras,
    )

    /** URL and request body of this per-model probe (same address validation and construction as [pingRelay]); sends no request. */
    internal fun probeWireRequest(
        apiKey: String,
        baseUrl: String?,
        modelID: String,
        relayRequested: RelayRequestedConfig,
        modelTransport: RelayTransport? = null,
    ): RelayChatWireRequest = coordinator.buildRelayProbeRequest(
        apiKey,
        requireConfigured(baseUrl, apiKey, relayRequested),
        modelID,
        relayRequested,
        modelTransport,
    )

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
        modelTransport: RelayTransport? = null,
    ) = pingRelay(apiKey, baseUrl, modelID, relayRequested, relayKind, modelTransport)

    /**
     * Transport and API root for this outbound request: used as is when injected by the caller per (connection, model); otherwise computed from the
     * connection copy and activeModel in the request options (same resolver function). The root passes the same security-mode check as the connection address.
     */
    private fun routed(requestOptions: ChatRequestOptions, baseUrl: String?, apiKey: String): ChatRequestOptions {
        val requested = requestOptions.relayRequested
        val model = requestOptions.activeModel
        val transport = requestOptions.relayRouteTransport
            ?: RelayEndpointResolver.effectiveTransport(requested, model)
        val root = requestOptions.relayRouteAPIRoot?.takeIf { it.isNotBlank() }
            ?: RelayEndpointResolver.effectiveAPIRoot(requested, baseUrl, model)
        return requestOptions.copy(
            relayRouteTransport = transport,
            relayRouteAPIRoot = root?.let { requireConfigured(it, apiKey, requested) },
        )
    }

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
