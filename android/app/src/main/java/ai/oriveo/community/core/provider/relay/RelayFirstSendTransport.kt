package ai.oriveo.community.core.provider.relay

import ai.oriveo.community.core.attachments.AttachmentDelivery
import ai.oriveo.community.core.attachments.AttachmentTransportProfile
import ai.oriveo.community.core.data.remote.RelayModelFamilyLookup
import ai.oriveo.community.core.model.AIModel
import ai.oriveo.community.core.model.AttachmentKind
import ai.oriveo.community.core.model.ChatMessage
import ai.oriveo.community.core.model.Provider
import ai.oriveo.community.core.model.ProviderKind
import ai.oriveo.community.core.model.RelayTransport
import ai.oriveo.community.core.provider.RelayEndpointResolver

/**
 * First-send protocol of an unverified model: the first chat send, the negative-cache read/write key, and the advanced page Auto = all read this one function,
 * so the three places never compute different protocols.
 *
 * Messages is sent first only when it is a relay, not local, the model has no protocol of its own, it does not follow the chosen connection, no image output, and the first candidate is Messages;
 * everything else uses [RelayEndpointResolver.effectiveTransport]. Candidates and probe fallback are the same [RelayProbeCandidates],
 * reading only the catalog endpoint types and family table cached in this session, and sending no request for the first send.
 */
object RelayFirstSendTransport {
    fun candidates(
        provider: Provider,
        modelID: String,
        endpointTypes: (String?, String) -> List<String>? = RelayCatalogEndpointTypes::lookup,
        family: (String) -> String? = RelayModelFamilyLookup.shared::cachedFamily,
    ): List<RelayTransport> {
        val root = RelayCatalogEndpointTypes.catalogRoot(provider.relayRequested, provider.baseUrlText)
        RelayProbeCandidates.fromEndpointTypes(endpointTypes(root, modelID)).takeIf { it.isNotEmpty() }?.let { return it }
        return RelayProbeCandidates.forFamily(family(modelID))
    }

    fun resolve(
        provider: Provider,
        model: AIModel?,
        endpointTypes: (String?, String) -> List<String>? = RelayCatalogEndpointTypes::lookup,
        family: (String) -> String? = RelayModelFamilyLookup.shared::cachedFamily,
    ): RelayTransport {
        val effective = RelayEndpointResolver.effectiveTransport(provider, model)
        if (provider.kind != ProviderKind.Relay || model == null) return effective
        if (!provider.relayRequested?.engineProfile.isNullOrBlank()) return effective
        if (model.relayTransport != null && model.relayTransport != RelayTransport.Auto) return effective
        if (RelayProbeCandidates.connectionIsExplicit(provider.relayRequested)) return effective
        if (relayDispatchesImageGeneration(provider, model)) return effective
        val first = candidates(provider, model.id, endpointTypes, family).firstOrNull()
        return if (first == RelayTransport.AnthropicMessages) RelayTransport.AnthropicMessages else effective
    }

    /**
     * The protocol the first chat send actually uses = [resolve] then the attachment criterion: Messages first, but none of the files to send has extracted text
     * and Messages cannot send any of them natively, so switching would leave nothing to send and the first-send protocol is left unchanged. It affects only the first send; the negative-cache read key and the advanced page still read [resolve].
     */
    fun forSend(
        provider: Provider,
        model: AIModel?,
        messages: List<ChatMessage>,
        endpointTypes: (String?, String) -> List<String>? = RelayCatalogEndpointTypes::lookup,
        family: (String) -> String? = RelayModelFamilyLookup.shared::cachedFamily,
    ): RelayTransport {
        val first = resolve(provider, model, endpointTypes, family)
        val effective = RelayEndpointResolver.effectiveTransport(provider, model)
        if (model == null || first == effective || first != RelayTransport.AnthropicMessages) return first
        val files = messages.flatMap { it.attachments.orEmpty() }.filter { it.kind == AttachmentKind.File }
        if (files.isEmpty() || files.any(AttachmentDelivery::hasUsableText)) return first
        val native = AttachmentDelivery.plan(
            "",
            files,
            relayRouterModel(model.id, ProviderKind.Anthropic, model),
            AttachmentTransportProfile.RelayAnthropicMessages,
        ).native
        return if (native.isEmpty()) effective else first
    }
}
