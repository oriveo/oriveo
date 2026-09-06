package ai.oriveo.community.core.provider

import ai.oriveo.community.core.data.remote.MetadataClient
import ai.oriveo.community.core.data.remote.canonicalCapabilityTransport
import ai.oriveo.community.core.model.AIModel
import ai.oriveo.community.core.model.ModelCapability
import ai.oriveo.community.core.model.Provider
import ai.oriveo.community.core.model.ProviderAuthMode
import ai.oriveo.community.core.model.ProviderKind
import ai.oriveo.community.core.model.ReasoningMode
import ai.oriveo.community.core.provider.openai.codexReasoningEffort
import ai.oriveo.community.core.provider.grok.GrokSubscriptionAuthResolver
import ai.oriveo.community.core.provider.transport.TransportKind

/**
 * The single capability verdict for one provider/model/capability triple.
 *
 * Model-library badges, the model picker and the chat page's model controls all read their
 * conclusion from here, which makes "the library says web search works but the chat page will
 * not let me turn it on" structurally impossible. The client once had two sources of truth -
 * badges went through CapabilityEvidence profiles while the chat controls went through the
 * catalog's v2 `capabilityControls` - and when that was measured across a full catalog, dozens
 * of models came out with opposite conclusions on the two paths.
 *
 * Priority:
 *   1. an exact v2 control with a definite conclusion wins, **including `unavailable`**
 *   2. `unknown`, or a missing exact control, stays `unknown`; older reasoning/webSearch
 *      profiles are not read back in to manufacture an automatic configuration
 */
object CapabilityControlResolution {

    data class Verdict(
        val state: String,
        val intents: List<String> = emptyList(),
        val reasonCode: String? = null,
        val viaLegacyProfile: Boolean = false,
    ) {
        /** Whether the user can actually use this capability in the UI - the shared predicate
         * behind both the badge and the control. */
        val isAvailable: Boolean get() = state == "auto_available"
    }

    private const val STATE_UNKNOWN = "unknown"
    private const val STATE_AUTO_AVAILABLE = "auto_available"
    private const val STATE_UNAVAILABLE = "unavailable"

    /** The upstream said **nothing at all** about this capability, which is not the same as
     *  saying it is unsupported. The user's next move differs between the two. */
    private const val REASON_UPSTREAM_SILENT = "upstream_parameter_not_declared"
    private const val REASON_SUBSCRIPTION_DECLARED = "subscription_upstream_declared"

    fun resolve(
        provider: Provider,
        model: AIModel,
        capability: String,
        metadata: MetadataClient = MetadataClient.instance,
        effectiveTransport: String? = null,
    ): Verdict {
        // Subscription links (Codex / Grok) have to bail out **before** the catalog control is
        // read. Subscription models are not in the catalog, so they will never have a v2
        // `capabilityControls` entry or a recipe; taking the path below always ends in
        // `unknown`, and the UI then collapses the web toggle and the reasoning levels into a
        // single "not adjustable" row, leaving the user with no way to express an intent at
        // all. The authority for this link is the upstream `/models` per-model declaration, so
        // it is folded here into the same shape a catalog recipe would produce and everything
        // downstream - layout, persistence, outbound compilation - carries on unchanged
        // instead of growing its own copy.
        if (isSubscriptionLink(provider)) {
            return subscriptionVerdict(provider, model, capability)
        }
        val finalTransport = effectiveTransport ?: finalTransport(provider, model, metadata)
        val runtimeIdentity = ModelControlRuntimeIdentityResolver.resolve(provider, model, metadata)
            ?.takeIf { finalTransport != null }
            ?.copy(finalTransport = canonicalCapabilityTransport(finalTransport))
        val control = finalTransport
            ?.let { metadata.capabilityControlPresentation(provider.kind, model.id, it)[capability] }
        if (
            runtimeIdentity != null && control?.recipeRef != null &&
            ModelControlRejectionCache.rejectedSettings(
                runtimeIdentity,
                capability,
                "provider_recipe",
                recipeRef = control.recipeRef,
            ).isNotEmpty()
        ) {
            return Verdict(state = STATE_UNKNOWN, reasonCode = "upstream_setting_dormant")
        }

        val state = control?.state
        if (state != null && state != STATE_UNKNOWN) {
            return Verdict(
                state = state,
                intents = control.availableIntents,
                reasonCode = control.reasonCode ?: control.reason,
            )
        }
        return Verdict(state = STATE_UNKNOWN, reasonCode = control?.reasonCode ?: control?.reason)
    }

    /**
     * Whether this connection is a subscription link - the user's own ChatGPT or SuperGrok
     * allowance, reached through the CLI proxy backend.
     *
     * The test is the **shape of the connection's credential**, not the provider kind: the same
     * OpenAI provider can be a pay-as-you-go API key instance or a subscription instance, and
     * the two have completely different capability sources of truth.
     */
    fun isSubscriptionLink(provider: Provider): Boolean =
        provider.authMode == ProviderAuthMode.Subscription

    /**
     * The final outbound protocol for a subscription link.
     *
     * Subscription models cannot resolve a catalog transport (they are not in the catalog at
     * all), but this link only ever has **one** road: the Codex backend is pinned to
     * `/responses` and the Grok CLI proxy to `/chat/completions` (see the two subscription
     * branches in `OpenAICompatibleService.sendMessageStream`). So this is a known value, not
     * an unresolved one. Persisted identity and the capability verdict share this one source.
     */
    fun subscriptionFinalTransport(provider: Provider, model: AIModel? = null): String? {
        if (!isSubscriptionLink(provider)) return null
        return when (provider.kind) {
            ProviderKind.OpenAI -> TransportKind.OpenAIResponses.wireValue
            ProviderKind.Grok -> model?.upstreamApiBackend
                ?.let(GrokSubscriptionAuthResolver::transportKind)
                ?: (MetadataClient.grokSubscriptionAvailability() as? ai.oriveo.community.core.provider.grok.GrokSubscriptionAvailability.Available)
                    ?.config?.apiBackend?.let(GrokSubscriptionAuthResolver::transportKind)
                // The proxy's chat backend is Responses-only. Missing declarations must not fall
                // back to chat, where the model emits fake <web_search> text instead of searching.
                ?: TransportKind.OpenAIResponses.wireValue
            else -> null
        }
    }

    /** The capability verdict for a subscription link: **copy what the upstream declared**.
     *  Missing means unavailable; never guess from the model id. */
    fun subscriptionVerdict(provider: Provider, model: AIModel, capability: String): Verdict =
        when (capability) {
            "web" -> subscriptionWebVerdict(provider, model)
            "reasoning" -> subscriptionReasoningVerdict(provider.kind, model)
            // Generation and the other capabilities have no declaration source on a
            // subscription link at all, so report an honest unknown.
            else -> Verdict(state = STATE_UNKNOWN)
        }

    private fun subscriptionWebVerdict(provider: Provider, model: AIModel): Verdict {
        if (provider.kind == ProviderKind.Grok &&
            subscriptionFinalTransport(provider, model) != TransportKind.OpenAIResponses.wireValue
        ) {
            return Verdict(state = STATE_UNAVAILABLE, reasonCode = "upstream_transport_without_web_search")
        }
        if (!model.capabilities.contains(ModelCapability.Web)) {
            return Verdict(state = STATE_UNAVAILABLE, reasonCode = "model_capability_absent")
        }
        return Verdict(
            state = STATE_AUTO_AVAILABLE,
            intents = if (provider.kind == ProviderKind.Grok) listOf("automatic")
                else listOf("off", "automatic"),
            reasonCode = REASON_SUBSCRIPTION_DECLARED,
        )
    }

    /**
     * The selectable levels are computed with **the same function the outbound path uses**
     * ([codexReasoningEffort]): every level the UI offers must land on a value the upstream
     * really accepts. Two implementations of this would drift apart eventually, and from then
     * on the level the user picked and the value in the request would be different things -
     * which is precisely how "I chose one thing and it sent another" happens.
     */
    private fun subscriptionReasoningVerdict(providerKind: ProviderKind, model: AIModel): Verdict {
        val declared = subscriptionDeclaredReasoningLevels(providerKind, model)
        val intents = listOf(ReasoningMode.Fast, ReasoningMode.Balanced, ReasoningMode.Deep, ReasoningMode.Max)
            .mapNotNull { mode ->
                mode.intentValue?.takeIf { codexReasoningEffort(mode.rawValue, declared) != null }
            }
        if (intents.isEmpty()) {
            return Verdict(state = STATE_UNAVAILABLE, reasonCode = REASON_UPSTREAM_SILENT)
        }
        return Verdict(
            state = STATE_AUTO_AVAILABLE,
            intents = intents,
            reasonCode = REASON_SUBSCRIPTION_DECLARED,
        )
    }

    /** Subscription `/models` declaration > persisted models.dev facts > unknown. */
    fun subscriptionDeclaredReasoningLevels(providerKind: ProviderKind, model: AIModel): List<String> =
        model.upstreamReasoningLevels.takeIf { it.isNotEmpty() }
            ?: MetadataClient.modelFacts(providerKind, model.id)?.reasoningEfforts.orEmpty()

    fun subscriptionDefaultReasoningLevel(providerKind: ProviderKind, model: AIModel?): String? {
        val declaredDefault = model?.upstreamDefaultReasoningLevel ?: return null
        val levels = model.let { subscriptionDeclaredReasoningLevels(providerKind, it) }.orEmpty()
        return declaredDefault.takeIf { it in levels }
    }

    /**
     * The catalog transport is the only authoritative final carrier available before dispatch.
     * Relay deliberately returns null: its directory comes from the user's own machine and is
     * not a published capability recipe.
     */
    private fun finalTransport(
        provider: Provider,
        model: AIModel,
        metadata: MetadataClient,
    ): String? {
        if (provider.kind == ProviderKind.Relay) return null
        return metadata.resolveCatalogModel(model.id, provider.kind)?.transport?.takeIf { it.isNotBlank() }
    }
}
