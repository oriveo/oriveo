package ai.oriveo.community.core.provider

import ai.oriveo.community.core.data.remote.MetadataClient
import ai.oriveo.community.core.data.remote.canonicalCapabilityTransport
import ai.oriveo.community.core.model.AIModel
import ai.oriveo.community.core.model.GenerationProfileRef
import ai.oriveo.community.core.model.LocalCapabilityCustomFragmentStore
import ai.oriveo.community.core.model.Provider

/**
 * The one projection from a capability's control state onto what the UI is allowed to show.
 *
 * [CapabilityControlResolution.Verdict] only carries a handful of wire states, but the panel
 * has to answer finer questions than that: is "unsupported" because the capability does not
 * exist, or because it only lives inside a separate external connector? Is "unknown" a route
 * that has not been published yet (worth waiting for), or one that was never configured for
 * this model (switch models instead)? Collapsing those into a single `unknown` leaves the
 * user unable to tell whether to wait, to switch, or to configure it by hand. An unavailable
 * state that cannot name its cause and its way out is not worth rendering.
 *
 * It runs one check that `resolve` does not: the recipe has to be written for the exact
 * transport this model actually goes out on. A recipe authored for another protocol is the
 * same as no recipe at all.
 */
enum class CapabilityControlPresentation {
    AutomaticAvailable,
    ForceUnsupported,
    CustomOnly,
    Pending,

    /**
     * The provider really does have this capability, but only as a standalone external
     * service or MCP connector - it is not reachable from this connection's chat request
     * path. This has to stay separable from [Unsupported] (it simply does not exist):
     * folding both into one "not supported" hides the boundary and makes it look like a
     * shortcoming of the model itself.
     */
    ExternalConnectorOnly,
    Unsupported,
    Unknown;

    /**
     * Whether the user can express an intent here at all. [ForceUnsupported] still counts as
     * configurable: it only says the "force" position is unavailable, while off and automatic
     * remain requests we can genuinely send.
     */
    val isConfigurable: Boolean
        get() = when (this) {
            AutomaticAvailable, ForceUnsupported, Unknown -> true
            CustomOnly, Pending, ExternalConnectorOnly, Unsupported -> false
        }

    companion object {
        fun status(
            state: String?,
            reasonCode: String?,
            exactTransportMatches: Boolean,
            forceRequested: Boolean = false,
        ): CapabilityControlPresentation = when (state) {
            "auto_available" ->
                if (!exactTransportMatches) Unknown
                else if (forceRequested) ForceUnsupported
                else AutomaticAvailable
            "custom_only" -> CustomOnly
            "unavailable" ->
                if (reasonCode == "external_connector_only") ExternalConnectorOnly else Unsupported
            // `unknown` stays configurable; the reason code only refines the cause of that one
            // state and must never be allowed to promote an unknown into an unavailable.
            // Kill-switch and pending routes are read-only sub-states of unknown.
            "unknown", null -> when (reasonCode) {
                "endpoint_route_pending", "model_route_pending", "official_source_insufficient",
                "source_review_expired", "provider_kill_switch",
                -> Pending
                else -> Unknown
            }
            else -> Unknown
        }
    }
}

/**
 * The panel, the composer summary and the outbound gate all have to answer the same question:
 * does this capability have an automatic configuration right now? Three separate copies of
 * that judgement would start disagreeing sooner or later, so it lives here once.
 */
object CapabilityControlPresentationResolver {
    fun presentation(
        provider: Provider,
        model: AIModel,
        capability: String,
        metadata: MetadataClient = MetadataClient.instance,
        effectiveTransport: String? = null,
    ): CapabilityControlPresentation {
        val verdict = CapabilityControlResolution.resolve(provider, model, capability, metadata, effectiveTransport)
        return CapabilityControlPresentation.status(
            state = verdict.state,
            reasonCode = verdict.reasonCode,
            // A subscription link has no recipe, so the "recipe transport == catalog transport"
            // check has nothing to compare. Its verdict comes from what the upstream declares
            // for this specific model, and the protocol is pinned by the link itself (see
            // `CapabilityControlResolution.subscriptionFinalTransport`), so a mismatch is
            // structurally impossible. Without this exemption `status(...)` would downgrade
            // every `auto_available` back to Unknown and the verdict above would be wasted.
            exactTransportMatches = verdict.viaLegacyProfile ||
                CapabilityControlResolution.isSubscriptionLink(provider) ||
                hasExactTransportRecipe(provider, model, capability, metadata),
        )
    }

    /**
     * Whether the recipe's declared protocol and the protocol the catalog gives this model are
     * the same one. States other than `auto_available` have no recipe by contract, so this
     * check must not knock them down to unknown.
     */
    fun hasExactTransportRecipe(
        provider: Provider,
        model: AIModel,
        capability: String,
        metadata: MetadataClient = MetadataClient.instance,
    ): Boolean {
        val lookup = metadata.capabilityActionLookup(provider.kind, model.id, capability) ?: return false
        if (lookup.state != "auto_available") return true
        val recipeTransport = lookup.recipeTransport ?: return false
        val modelTransport = lookup.modelTransport ?: return false
        return canonicalCapabilityTransport(recipeTransport) == canonicalCapabilityTransport(modelTransport)
    }
}

/**
 * Stale-preference guard: will the stored web-search preference actually reach the wire right
 * now?
 *
 * The preference is stored per connection, model and transport, but whether it can go out
 * depends on the catalog metadata as it stands today. After the metadata rolls forward, a
 * recipe disappears, or the model moves to another transport, that stored `Automatic` has not
 * changed by a single byte - so the panel switch and the composer globe stay lit while the
 * request carries no web-search field at all. That is exactly how you end up with a lit globe
 * that never searches.
 *
 * This does not rewrite storage: the user's expressed intent stays, and comes back as soon as
 * they return to a model that supports it. It only stops lighting up a globe that cannot fire.
 */
object CapabilityWebPreferenceLiveness {
    /**
     * The pure predicate. Note it is deliberately *not* the same set as
     * [CapabilityControlPresentation.isConfigurable]: `ForceUnsupported` is still configurable
     * (off and automatic go out fine) but it does not light the globe right now.
     */
    fun reachesTheWire(
        status: CapabilityControlPresentation,
        customIsActive: Boolean,
    ): Boolean = status == CapabilityControlPresentation.AutomaticAvailable || customIsActive

    /**
     * Call sites outside the panel (the composer, the outbound gate) have no status at hand,
     * so this recomputes one from the same production source.
     *
     * @param forwardPortsStaleCustom also run the lazy forward-port of stale custom fragments.
     *   **Only discrete events may pass true** - the composer switching model, switching
     *   conversation, or closing the panel. On the recomposition hot path, ask the question but
     *   read only the conclusion: decoding SharedPreferences again on every recomposition is
     *   the classic "side effect inside the frame loop" mistake. The forward-port is idempotent,
     *   so firing it once per discrete event plus once on the send path is enough.
     */
    fun reachesTheWire(
        provider: Provider,
        model: AIModel,
        conversationID: String?,
        customFragmentStore: LocalCapabilityCustomFragmentStore,
        metadata: MetadataClient = MetadataClient.instance,
        effectiveTransport: String? = null,
        activeProfile: GenerationProfileRef? = null,
        forwardPortsStaleCustom: Boolean = false,
    ): Boolean {
        val status = CapabilityControlPresentationResolver.presentation(
            provider, model, "web", metadata, effectiveTransport,
        )
        if (status == CapabilityControlPresentation.AutomaticAvailable) return true
        val identity = ModelControlRuntimeIdentityResolver.resolve(provider, model, metadata) ?: return false
        // "Has a custom fragment taken over web right now" must mean exactly the same thing
        // here, in the UI and on the outbound path: enabled **and** this connection, model and
        // transport still has a usable web schema. Once the schema is withdrawn that JSON no
        // longer goes out (`fragmentsByOwner` already filters on the same predicate), so a lit
        // globe would be one more piece of fake state.
        val customIsActive = capabilityCustomFragmentAvailable(
            providerKind = provider.kind,
            modelID = model.id,
            finalTransport = identity.finalTransport,
            activeProfile = activeProfile,
            owner = "web",
        ) && customFragmentStore.effectiveConfiguration(
            providerID = provider.id,
            modelID = identity.canonicalModelId,
            conversationID = conversationID,
            transportIdentity = identity.storageIdentity,
            namespace = LocalCapabilityCustomFragmentStore.WEB_NAMESPACE,
            // Whether the globe lights depends on whether the fragment stored under an older
            // recipe version still counts.
            forwardPort = if (forwardPortsStaleCustom) {
                LocalCapabilityCustomFragmentStore.ForwardPortContext(
                    providerKind = provider.kind,
                    schemaModelID = model.id,
                    activeProfile = activeProfile,
                )
            } else {
                null
            },
        ).enabled
        return reachesTheWire(status, customIsActive)
    }
}
