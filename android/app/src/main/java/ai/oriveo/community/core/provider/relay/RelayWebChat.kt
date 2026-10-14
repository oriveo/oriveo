package ai.oriveo.community.core.provider.relay

import ai.oriveo.community.core.model.AIModel
import ai.oriveo.community.core.model.CapabilityWebPreference
import ai.oriveo.community.core.model.Provider
import ai.oriveo.community.core.model.ProviderKind
import ai.oriveo.community.core.model.RelayCapabilityOverrides
import ai.oriveo.community.core.model.RelayTransport
import kotlinx.serialization.json.JsonObject

/**
 * Relay web search = a chat switch (fixture `web-probe.v1.json` presentationCases and chatCases).
 *
 * The panel follows the first-send protocol, while chat follows the protocol of each attempt: effective fragment = stored fragment ?? that protocol's template; a record is "current" when its hash == the effective fragment's hash.
 * The switch listens only to the user: it is greyed out only by a user override off; a rejected current record does not change the switch, it only makes this request carry no fragment and attaches a notice under the reply.
 * Switch storage reuses the official [CapabilityWebPreference] and the scope ladder; a relay has no timing tier (anything but off is on); the default when unset:
 * the first-send protocol has a stored fragment -> on, otherwise off. The model options web row, chat requests, truth (badge / globe) and the advanced page web row are all derived from this one set of facts.
 */
data class RelayWebChat(
    val transport: RelayTransport,
    /** The stored fragment of the first-send protocol (including read-time mapping of legacy fields); null = none stored. */
    val saved: JsonObject?,
    /** Effective fragment = [saved] ?? template; null when the protocol has no template. */
    val effective: JsonObject?,
    /** The current record result under the effective fragment; untested or a stale hash = null. */
    val record: RelayWebProbeResult?,
    /** The web override whose source is user; a tested mirror does not count. */
    val userOverride: Boolean?,
) {
    /** The id of the status line under the chat model options web row (fixture statusId). */
    enum class Status(val wire: String) {
        Searched("web_probe_searched"),
        Silent("web_probe_silent"),
        Rejected("web_probe_rejected"),
        Unverified("web_probe_unverified"),
        Untested("web_probe_untested"),
        UserOff("web_user_off"),
        UserOn("web_user_on"),
    }

    /** Where the retest of a greyed-out row leads: a rejected stored fragment -> the web search settings page; a rejected template -> this model's capability test. */
    enum class Retest(val wire: String) {
        OpenConnectionWebSearch("openConnectionWebSearch"),
        TestCapabilities("testCapabilities"),
    }

    /** The advanced page web row: the status looks only at the record, [source] = user / tested / null. */
    data class Advanced(val status: Status, val source: String?)

    /** The user overrode web to off in the advanced page: the web row is greyed out, the switch shows off, nothing is sent (the only kind of greying out). */
    val userDisabled: Boolean
        get() = userOverride == false

    /** This protocol's current record is rejected and the user has not overridden it on: the switch can still be turned on, but this request carries no fragment. */
    val rejectedForSend: Boolean
        get() = userOverride != true && record == RelayWebProbeResult.Rejected

    /** The default preference when unset: a stored fragment -> on (keeps the behavior of connections that stored a fragment earlier), otherwise null (= off). */
    val defaultPreference: CapabilityWebPreference?
        get() = CapabilityWebPreference.Automatic.takeIf { saved != null }

    /** [preference] = the resolved chat web preference, null = never set (falls back to [defaultPreference]). */
    fun isOn(preference: CapabilityWebPreference?): Boolean =
        !userDisabled && ((preference ?: defaultPreference)?.let { it != CapabilityWebPreference.Off } ?: false)

    /** The fragment merged into the request while the switch is on; null when off, overridden off by the user, or the current record is rejected. */
    fun sentFragment(on: Boolean): JsonObject? = effective?.takeIf { on && !userDisabled && !rejectedForSend }

    /** Reply notice (fixture `replyNotice`): switch on but this request carries no fragment -> web_not_used; no notice when the switch is off. */
    fun replyNotice(on: Boolean): RelayWebReplyNotices.Notice? =
        RelayWebReplyNotices.Notice.WebNotUsed.takeIf { on && !userDisabled && sentFragment(on) == null }

    private val recordStatus: Status
        get() = when (record) {
            RelayWebProbeResult.Searched -> Status.Searched
            RelayWebProbeResult.Silent -> Status.Silent
            RelayWebProbeResult.Rejected -> Status.Rejected
            else -> if (saved != null) Status.Unverified else Status.Untested
        }

    val status: Status
        get() = when (userOverride) {
            false -> Status.UserOff
            true -> Status.UserOn
            null -> recordStatus
        }

    /** Only a rejected row has a retest target; a user override off is changed in the advanced page, not here. */
    val retest: Retest?
        get() = if (status == Status.Rejected) {
            if (saved != null) Retest.OpenConnectionWebSearch else Retest.TestCapabilities
        } else {
            null
        }

    /** Truth: user override > current record (searched = supported, rejected = unsupported) > unknown (null). */
    val truth: String?
        get() = when (userOverride) {
            true -> "supported"
            false -> "unsupported"
            null -> when (record) {
                RelayWebProbeResult.Searched -> "supported"
                RelayWebProbeResult.Rejected -> "unsupported"
                else -> null
            }
        }

    val advanced: Advanced
        get() = Advanced(
            status = recordStatus,
            source = when {
                userOverride != null -> RelayCapabilityOverrides.SOURCE_USER
                record == RelayWebProbeResult.Searched || record == RelayWebProbeResult.Rejected ->
                    RelayCapabilityOverrides.SOURCE_TESTED
                else -> null
            },
        )

    companion object {
        /** The protocols a chat may try (the first send plus the protocol-fallback targets within the same send). */
        private val CHAT_TRANSPORTS = listOf(
            RelayTransport.OpenAIChatCompletions,
            RelayTransport.OpenAIResponses,
            RelayTransport.AnthropicMessages,
            RelayTransport.GeminiGenerateContent,
        )

        /**
         * The fragment to carry per protocol for one chat send (key = protocol value): the first send and protocol fallback both take from here,
         * and whichever protocol it falls back to is recomputed from that protocol's stored / template fragment and current record. Empty when no fragment can be carried.
         */
        fun fragmentsForSend(
            provider: Provider,
            model: AIModel,
            webOn: Boolean,
            fragments: RelayWebFragmentStore = RelayWebFragmentStore.shared,
            records: RelayWebProbeRecordStore = RelayWebProbeRecordStore.shared,
        ): Map<String, JsonObject> {
            if (!webOn) return emptyMap()
            return CHAT_TRANSPORTS.mapNotNull { transport ->
                of(provider, model, fragments, records, transport)?.sentFragment(true)?.let { transport.value to it }
            }.toMap()
        }

        /** Returns null for a non-relay or a local-engine connection (the local-engine row is in the web-fragment presentationCases). */
        fun of(
            provider: Provider,
            model: AIModel,
            fragments: RelayWebFragmentStore = RelayWebFragmentStore.shared,
            records: RelayWebProbeRecordStore = RelayWebProbeRecordStore.shared,
            /** The first-send protocol actually used this round (chat's forSend, decided by attachments); default = the first-send protocol without attachments. */
            transport: RelayTransport = RelayFirstSendTransport.resolve(provider, model),
        ): RelayWebChat? {
            if (provider.kind != ProviderKind.Relay || !provider.relayRequested?.engineProfile.isNullOrBlank()) return null
            val saved = fragments.effective(provider)[transport.value]?.takeIf { it.isNotEmpty() }
            val effective = saved ?: RelayWebFragments.template(transport)
            val overrides = model.relayCapabilityOverrides
            return RelayWebChat(
                transport = transport,
                saved = saved,
                effective = effective,
                record = effective?.let { records.currentResult(provider.id, model.id, transport.value, it) },
                userOverride = overrides?.web?.takeIf { overrides.sourceOf("web") == RelayCapabilityOverrides.SOURCE_USER },
            )
        }
    }
}
