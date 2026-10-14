package ai.oriveo.community.core.provider

import ai.oriveo.community.core.data.remote.MetadataClient
import ai.oriveo.community.core.data.remote.canonicalCapabilityTransport
import ai.oriveo.community.core.model.AIModel
import ai.oriveo.community.core.model.Provider
import ai.oriveo.community.core.model.ProviderKind
import java.util.Base64

/**
 * The runtime identity a model-control preference is stored against. Identity and mutation
 * ordering are deliberately unrelated: [runtimeRevision] is the capability-runtime revision
 * currently applied from the catalog, while preference records carry their own last-write-wins
 * revision and mutation id.
 */
data class ModelControlRuntimeIdentity(
    val connectionId: String,
    val canonicalModelId: String,
    val finalTransport: String,
    val runtimeRevision: String,
) {
    /**
     * Relay: the [canonicalModelId] slot holds the literal model ID (preferences are keyed by it); this is the old
     * canonical key read back when the literal key misses (preferences written by canonical before literalization).
     * It is null when identical to the literal or for official providers. It sits outside the primary constructor:
     * it takes no part in equals / [storageIdentity] (the negative cache compares the four-field identity).
     */
    var legacyModelId: String? = null
        internal set

    init {
        require(connectionId.isNotBlank()) { "connectionId is required" }
        require(canonicalModelId.isNotBlank()) { "canonicalModelId is required" }
        require(finalTransport.isNotBlank()) { "finalTransport is required" }
        require(runtimeRevision.isNotBlank()) { "runtimeRevision is required" }
    }

    /**
     * CapabilityPreferenceStore v1 has one opaque identity column. Encode the three non-connection
     * fields losslessly so old raw transport/template fingerprints remain dormant instead of being
     * guessed into the current identity. Connection id remains the store's separate providerID.
     */
    val storageIdentity: String
        get() = listOf(finalTransport, runtimeRevision)
            .joinToString(separator = ".", prefix = "r1.") { component ->
                Base64.getUrlEncoder().withoutPadding()
                    .encodeToString(component.toByteArray(Charsets.UTF_8))
            }

    companion object {
        fun decodeStorageIdentity(value: String): Pair<String, String>? {
            val components = value.split('.')
            if (components.size != 3 || components.first() != "r1") return null
            val decoded = components.drop(1).map { encoded ->
                runCatching {
                    String(Base64.getUrlDecoder().decode(encoded), Charsets.UTF_8)
                        .takeIf { it.isNotBlank() }
                }.getOrNull() ?: return null
            }
            return decoded[0] to decoded[1]
        }
    }
}

object ModelControlRuntimeIdentityResolver {
    /**
     * The invalidation dimension for a subscription link's identity. It deliberately does not
     * follow the catalog revision - that link has no recipe runtime at all - but the identity
     * still needs one stable dimension to store preferences against.
     */
    const val SUBSCRIPTION_RUNTIME_REVISION: String = "subscription"

    /**
     * Fallback dimension for a relay while metadata has not loaded (no runtime revision available; the same as iOS RelayWebSwitch's `relay-web`):
     * a relay identity never relied on the official catalog, this is the only missing piece; without it the web switch cannot be saved, read back or sent.
     * Once metadata arrives the identity switches to the real revision, and same-transport records are carried over by the preference store's lazy forwarding. Same value on all three platforms.
     */
    const val RELAY_FALLBACK_RUNTIME_REVISION: String = "relay-web"

    /**
     * Resolve only facts available to the production dispatch path. There is no model-id or
     * provider-kind heuristic and no generation template participates in this identity.
     */
    fun resolve(
        provider: Provider,
        model: AIModel,
        metadata: MetadataClient = MetadataClient.instance,
    ): ModelControlRuntimeIdentity? {
        // A subscription link (Codex / Grok) derives its identity without touching the catalog:
        // subscription models are not in the catalog, so `resolveCatalogModel` below is always
        // null, the whole function returns null, and the capability panel decides the runtime
        // identity is unavailable and goes read-only - meaning not one byte of the user's chosen
        // reasoning level or web-search toggle can be saved. All three facts are known for this link: the transport is pinned by the link itself
        // (see [CapabilityControlResolution.subscriptionFinalTransport]), the canonical id is
        // the slug the subscription directory hands us, and runtimeRevision is a fixed string -
        // there is no recipe runtime here, and folding the catalog revision in would invalidate
        // everything the user had saved every time a new catalog is published. The guard against
        // the upstream renaming its levels lives elsewhere: the panel only renders the levels
        // `subscriptionVerdict` lists right now.
        CapabilityControlResolution.subscriptionFinalTransport(provider, model)?.let { subscriptionTransport ->
            val slug = model.canonicalModelId?.trim()?.takeIf { it.isNotEmpty() }
                ?: model.id.trim().takeIf { it.isNotEmpty() }
                ?: return null
            return ModelControlRuntimeIdentity(
                connectionId = provider.id,
                canonicalModelId = slug,
                finalTransport = canonicalCapabilityTransport(subscriptionTransport),
                runtimeRevision = SUBSCRIPTION_RUNTIME_REVISION,
            )
        }
        val runtimeRevision = metadata.currentCapabilityRuntimeRevision()
            ?: RELAY_FALLBACK_RUNTIME_REVISION.takeIf { provider.kind == ProviderKind.Relay }
            ?: return null
        val canonicalModelId: String
        val finalTransport: String
        var legacyModelId: String? = null
        if (provider.kind == ProviderKind.Relay) {
            // When neither the model nor the connection picks a transport (an unverified model on an auto connection), use the first-send transport:
            // chat's first send and the panel's web row both read this one, without it the web switch cannot be saved in a new conversation.
            // If the system rewrites the transport later, the store carries the preference over across transports.
            val requestedTransport = (
                RelayEndpointResolver.declaredTransport(provider, model)
                    ?: ai.oriveo.community.core.provider.relay.RelayFirstSendTransport.resolve(provider, model)
                ).value
            // Relay keys by literal ID: gpt-4o and gpt-4o-2024-08-06 each have their own preferences.
            canonicalModelId = ModelSelectionUtils.preferredStoredModelIdentifier(model, provider.kind)
                .takeIf { it.isNotEmpty() }
                ?: return null
            legacyModelId = model.canonicalModelId?.trim()?.takeIf { it.isNotEmpty() && it != canonicalModelId }
            finalTransport = canonicalCapabilityTransport(requestedTransport)
        } else {
            val resolved = metadata.resolveCatalogModel(model.id, provider.kind) ?: return null
            canonicalModelId = resolved.canonicalModelId.trim().takeIf { it.isNotEmpty() } ?: return null
            finalTransport = canonicalCapabilityTransport(resolved.transport)
        }
        if (finalTransport.isBlank()) return null
        return ModelControlRuntimeIdentity(
            connectionId = provider.id,
            canonicalModelId = canonicalModelId,
            finalTransport = finalTransport,
            runtimeRevision = runtimeRevision,
        ).also { it.legacyModelId = legacyModelId }
    }
}

/**
 * The fixed identity of the web switch preference for a relay (not a local engine) (fixture `web-probe.v1.json` preferenceIdentity):
 * finalTransport `relay`, runtimeRevision `relay-web`, wire `r1.cmVsYXk.cmVsYXktd2Vi`, the same on all three platforms; canonicalModelId =
 * the model's stored literal id (taken the same way as the relay generation-parameter key). It does not change with the model protocol (decided or not, fallback rewrites) or the metadata version, so cross-device sync lines up.
 * It carries only the web switch; the thinking tier and other preferences still use the protocol-bearing identity from [ModelControlRuntimeIdentityResolver].
 */
object RelayWebPreferenceIdentity {
    const val FINAL_TRANSPORT: String = "relay"
    const val RUNTIME_REVISION: String = "relay-web"
    const val STORAGE_IDENTITY: String = "r1.cmVsYXk.cmVsYXktd2Vi"

    /** Returns null for a non-relay, a local-engine connection, or a model without a literal id (those use the protocol-bearing identity). */
    fun resolve(provider: Provider, model: AIModel): ModelControlRuntimeIdentity? {
        if (provider.kind != ProviderKind.Relay || !provider.relayRequested?.engineProfile.isNullOrBlank()) return null
        val literal = ModelSelectionUtils.preferredStoredModelIdentifier(model, provider.kind).takeIf { it.isNotEmpty() }
            ?: return null
        return ModelControlRuntimeIdentity(
            connectionId = provider.id,
            canonicalModelId = literal,
            finalTransport = FINAL_TRANSPORT,
            runtimeRevision = RUNTIME_REVISION,
        ).also { check(it.storageIdentity == STORAGE_IDENTITY) }
    }
}
