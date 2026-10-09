package ai.oriveo.community.feature.chat.modelcontrols

import ai.oriveo.community.core.provider.CapabilityControlPresentation

/**
 * What one capability card in the model options panel looks like; the shape follows only from facts that are already resolved.
 *
 * The input is resolved facts only: presentation state, available tiers, connection category, writability, whether the protocol is still undecided, and the tiers the upstream rejected.
 * **Provider names and model ids are never looked at**: the same facts must draw the same card for every provider, and branching on a name is how
 * two models in the same state end up drawn differently. No copy is produced here: a shape carries semantic enums only and the UI layer maps them to `@StringRes`.
 *
 * [resolve] is a pure function: opening the panel only reads. When a stored tier is not in the current list it is simply not highlighted (or a fallback tier is shown),
 * and no value is ever written on the user's behalf.
 */
sealed interface ModelOptionCapabilityShape {
    /**
     * On and off only. [isOn] null means the user never chose, so the UI draws the model default and stores nothing for them.
     * [kind] tells the capability recipe's switch apart from the chat-template thinking switch of a custom connection (the latter reads and writes the additional request body).
     */
    data class Toggle(val isOn: Boolean?, val kind: ToggleKind = ToggleKind.Capability) : ModelOptionCapabilityShape

    /**
     * A multi-tier segmented control. [tiers] is already in render order: the automatic tier comes first when the recipe has one, "off" follows when present,
     * and the rest run from least to most effort; tiers the upstream rejected are already removed.
     */
    data class Tiers(
        val tiers: List<String>,
        val includesOff: Boolean,
        /** The tier currently highlighted; null when there is none (the user never chose and no default tier is known). */
        val selected: String?,
        /** The note at the top right; when the tiers have no "off" it says the model always thinks, instead of drawing a greyed-out off. */
        val trailingNote: TrailingNote?,
        /** The line under the segments: a caption that follows the highlighted tier. */
        val footnote: Footnote?,
        /** A tier the upstream rejected after a failed send; when set, the footnote slot talks about that instead. */
        val rejected: RejectedNotice?,
    ) : ModelOptionCapabilityShape

    /** An extra timing row, shown when web search is on and the recipe supports searching on every message. */
    data class ToggleWithTiming(
        val timings: List<String>,
        val selectedTiming: String,
    ) : ModelOptionCapabilityShape

    /** No usable switch, but there is something to say and a way forward. */
    data class Notice(val status: NoticeStatus, val body: NoticeBody, val escape: Escape) : ModelOptionCapabilityShape

    /** A one-line status whose whole row is tappable (switch models / see the reason). [value] is set only when the current tier is shown read-only. */
    data class Disclosure(val status: DisclosureStatus, val value: String? = null) : ModelOptionCapabilityShape

    /** The custom connection's protocol is still "automatic": the whole card collapses to one ask, choose a protocol first. */
    data object ProtocolUndecided : ModelOptionCapabilityShape

    enum class Capability { Web, Reasoning }
    enum class ConnectionCategory { CustomLLM, Other }
    enum class CustomProtocol { ChatCompletions, Other }
    enum class ToggleKind { Capability, ChatTemplateThinking }
    enum class TrailingNote { AlwaysThinks }
    /** Without an official configuration web search says it cannot be turned on for now; thinking says it follows the model default (it thinks by the model's default even when nothing is chosen). */
    enum class NoticeStatus { FollowsModelDefault, NeedsOwnConfiguration, NotAvailableYet }
    enum class NoticeBody {
        ReasoningNotCatalogued,
        WebNotCatalogued,
        ReasoningNoGenericSwitch,
        WebNoGenericSwitch,
        CustomThinkingUseAdditionalBody,
    }
    enum class Escape { SupportedModels, AdditionalBody }
    enum class DisclosureStatus {
        ModelDoesNotThink,
        ModelCannotSearch,
        ConnectionCannotSearch,
        FixedLevel,
        ReadOnlyValue,
    }

    data class Footnote(val tierCaption: String)

    /** [tier] is the rejected tier; [fallback] is the tier highlighted now (null when there is no known tier to fall back on). */
    data class RejectedNotice(val tier: String, val fallback: String?)

    data class Input(
        val capability: Capability,
        val presentation: CapabilityControlPresentation,
        /** `CapabilityControlResolution.resolve(...).intents`. */
        val availableIntents: List<String>,
        /** The stored intent: a tier id for thinking, `off` / `automatic` / `force` for web search; null when nothing is stored. */
        val selectedIntent: String?,
        val connection: ConnectionCategory,
        /** The panel is writable right now (not managed and not taken over by custom fields). */
        val isWritable: Boolean = true,
        val protocolUndecided: Boolean = false,
        /** The protocol a custom connection has settled on; null for a connection that is not custom. */
        val customProtocol: CustomProtocol? = null,
        val rejectedIntents: Set<String> = emptySet(),
        /** A known default tier (for example the default reasoning tier the upstream declares); a stored tier that is unavailable falls back to it. */
        val defaultIntent: String? = null,
        /** Current reading of a custom connection's chat-template thinking switch (`chat_template_kwargs.enable_thinking` in the additional request body). */
        val chatTemplateThinking: Boolean? = null,
    )

    companion object {
        const val AUTOMATIC: String = "automatic"
        const val OFF: String = "off"
        const val FORCE: String = "force"

        /** From least to most effort; "automatic" and "off" are not in this table, [resolve] always puts them first. */
        val TIER_ORDER: List<String> = listOf("low", "balanced", "deep", "max")

        fun resolve(input: Input): ModelOptionCapabilityShape {
            if (input.connection == ConnectionCategory.CustomLLM) {
                if (input.protocolUndecided) return ProtocolUndecided
                if (input.capability == Capability.Reasoning) {
                    return if (input.customProtocol == CustomProtocol.ChatCompletions) {
                        Toggle(input.chatTemplateThinking, ToggleKind.ChatTemplateThinking)
                    } else {
                        Notice(NoticeStatus.NeedsOwnConfiguration, NoticeBody.CustomThinkingUseAdditionalBody, Escape.AdditionalBody)
                    }
                }
                if (!input.presentation.hasAutomaticConfig) return Disclosure(DisclosureStatus.ConnectionCannotSearch)
            }
            return when (input.capability) {
                Capability.Reasoning -> reasoning(input)
                Capability.Web -> web(input)
            }
        }

        private val CapabilityControlPresentation.hasAutomaticConfig: Boolean
            get() = this == CapabilityControlPresentation.AutomaticAvailable ||
                this == CapabilityControlPresentation.ForceUnsupported

        private fun reasoning(input: Input): ModelOptionCapabilityShape = when (input.presentation) {
            CapabilityControlPresentation.Unsupported, CapabilityControlPresentation.ExternalConnectorOnly ->
                Disclosure(DisclosureStatus.ModelDoesNotThink)
            CapabilityControlPresentation.CustomOnly ->
                Notice(NoticeStatus.NeedsOwnConfiguration, NoticeBody.ReasoningNoGenericSwitch, Escape.AdditionalBody)
            CapabilityControlPresentation.Pending, CapabilityControlPresentation.Unknown ->
                Notice(NoticeStatus.FollowsModelDefault, NoticeBody.ReasoningNotCatalogued, Escape.SupportedModels)
            CapabilityControlPresentation.AutomaticAvailable, CapabilityControlPresentation.ForceUnsupported ->
                reasoningTiers(input)
        }

        private fun reasoningTiers(input: Input): ModelOptionCapabilityShape {
            val declared = input.availableIntents.toSet()
            val ordered = buildList {
                if (AUTOMATIC in declared) add(AUTOMATIC)
                if (OFF in declared) add(OFF)
                TIER_ORDER.filter(declared::contains).forEach(::add)
            }
            val tiers = ordered.filterNot(input.rejectedIntents::contains)
            if (tiers.isEmpty()) return Disclosure(DisclosureStatus.FixedLevel)
            val selected = input.selectedIntent?.takeIf(tiers::contains)
                ?: input.defaultIntent?.takeIf(tiers::contains)
            if (!input.isWritable) return Disclosure(DisclosureStatus.ReadOnlyValue, selected)
            val rejectedTier = input.selectedIntent?.takeIf(input.rejectedIntents::contains)
                ?: ordered.firstOrNull(input.rejectedIntents::contains)
            val includesOff = OFF in tiers
            // On and off only: one "off" plus a single tier makes the segments just a switch split in two.
            if (includesOff && tiers.size == 2 && AUTOMATIC !in tiers && rejectedTier == null) {
                return Toggle(selected?.let { it != OFF })
            }
            return Tiers(
                tiers = tiers,
                includesOff = includesOff,
                selected = selected,
                trailingNote = if (includesOff) null else TrailingNote.AlwaysThinks,
                footnote = if (rejectedTier == null) selected?.let(::Footnote) else null,
                rejected = rejectedTier?.let { RejectedNotice(it, selected) },
            )
        }

        private fun web(input: Input): ModelOptionCapabilityShape = when (input.presentation) {
            CapabilityControlPresentation.Unsupported, CapabilityControlPresentation.ExternalConnectorOnly ->
                Disclosure(DisclosureStatus.ModelCannotSearch)
            CapabilityControlPresentation.CustomOnly ->
                Notice(NoticeStatus.NeedsOwnConfiguration, NoticeBody.WebNoGenericSwitch, Escape.AdditionalBody)
            CapabilityControlPresentation.Pending, CapabilityControlPresentation.Unknown ->
                Notice(NoticeStatus.NotAvailableYet, NoticeBody.WebNotCatalogued, Escape.SupportedModels)
            CapabilityControlPresentation.AutomaticAvailable, CapabilityControlPresentation.ForceUnsupported -> {
                val supportsForce = FORCE in input.availableIntents && FORCE !in input.rejectedIntents
                // The stored "search on every message" no longer exists in the current recipe: show "search when needed" and leave the stored value alone.
                val selection = input.selectedIntent?.let { if (it == FORCE && !supportsForce) AUTOMATIC else it }
                val isOn = selection?.let { it != OFF }
                when {
                    !input.isWritable -> Disclosure(DisclosureStatus.ReadOnlyValue, selection ?: OFF)
                    isOn == true && supportsForce -> ToggleWithTiming(listOf(AUTOMATIC, FORCE), selection)
                    else -> Toggle(isOn)
                }
            }
        }
    }
}
