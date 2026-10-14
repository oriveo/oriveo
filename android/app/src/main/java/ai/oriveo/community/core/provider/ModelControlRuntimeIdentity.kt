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
        val runtimeRevision = metadata.currentCapabilityRuntimeRevision() ?: return null
        val canonicalModelId: String
        val finalTransport: String
        var legacyModelId: String? = null
        if (provider.kind == ProviderKind.Relay) {
            val requestedTransport = RelayEndpointResolver.declaredTransport(provider, model)?.value
                ?: return null
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
