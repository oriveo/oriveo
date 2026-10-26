package ai.oriveo.community.feature.chat.modelcontrols

import androidx.annotation.StringRes
import ai.oriveo.community.R
import ai.oriveo.community.core.capability.truth.CapabilityTruthRegistry
import ai.oriveo.community.core.capability.truth.ProviderForm
import ai.oriveo.community.core.data.repository.relayImageSupportUnknown
import ai.oriveo.community.core.model.AIModel
import ai.oriveo.community.core.model.CapabilityWebPreference
import ai.oriveo.community.core.model.LocalCapabilityCustomFragmentStore.AdditionalBody
import ai.oriveo.community.core.model.Provider
import ai.oriveo.community.core.model.ProviderKind
import ai.oriveo.community.core.model.ReasoningMode
import ai.oriveo.community.core.model.RelayTransport
import ai.oriveo.community.core.provider.AdditionalRequestBody
import ai.oriveo.community.core.provider.AttachmentTransportResolver
import ai.oriveo.community.core.provider.CapabilityControlPresentation
import ai.oriveo.community.core.provider.LocalEngineChannels
import ai.oriveo.community.core.provider.RelayEndpointResolver
import ai.oriveo.community.core.provider.relay.RelayNegativeCache
import ai.oriveo.community.feature.chat.composer.ComposerAttachmentMenuItem
import ai.oriveo.community.feature.chat.modelcontrols.ModelOptionCapabilityShape.ConnectionCategory
import ai.oriveo.community.feature.chat.modelcontrols.ModelOptionCapabilityShape.CustomProtocol
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.booleanOrNull

/** The chat-template thinking switch of a custom connection: reads and writes `chat_template_kwargs.enable_thinking` in the additional request body. */
internal object ChatTemplateThinking {
    /**
     * - [On]: the item is boolean true and "send with request" is on.
     * - [Blocked]: the stored content is not a valid JSON object, is rejected by local validation, or `chat_template_kwargs` has a value that is not an object.
     * - [NotSending]: other fields exist besides this one while "send with request" is off, so flipping the switch would also send those fields for the user.
     * - [Off]: every other case (including sending off with no other fields).
     */
    enum class State { Off, On, Blocked, NotSending }

    sealed interface Write {
        data class Written(val body: AdditionalBody) : Write
        data object Unavailable : Write
    }

    private const val KWARGS = "chat_template_kwargs"
    private const val FLAG = "enable_thinking"

    fun state(body: AdditionalBody): State {
        if (body.rawJSON.isBlank()) return State.Off
        val root = parse(body.rawJSON) ?: return State.Blocked
        if (AdditionalRequestBody.validate(body.rawJSON) is AdditionalRequestBody.Validation.Rejected) return State.Blocked
        val kwargs = when (val existing = root[KWARGS]) {
            null -> JsonObject(emptyMap())
            is JsonObject -> existing
            else -> return State.Blocked
        }
        val hasOtherFields = root.keys.any { it != KWARGS } || kwargs.keys.any { it != FLAG }
        if (hasOtherFields && !body.sendWithRequest) return State.NotSending
        val flag = (kwargs[FLAG] as? JsonPrimitive)?.takeUnless { it.isString }?.booleanOrNull
        return if (flag == true && body.sendWithRequest) State.On else State.Off
    }

    /**
     * Changes only the `enable_thinking` value and turns sending on. Turning it off writes `false` instead of removing the key: many chat templates think by default,
     * so removing the key falls back to the template default and is not "off". Rewriting in place keeps the user's other fields, their order and formatting;
     * the result is used only if re-parsing it equals the object with just that value changed, otherwise everything is re-laid out with 2-space indentation and sorted keys.
     */
    fun write(body: AdditionalBody, enable: Boolean): Write {
        val state = state(body)
        if (state == State.Blocked || state == State.NotSending) return Write.Unavailable
        val raw = body.rawJSON
        val root = if (raw.isBlank()) JsonObject(emptyMap()) else parse(raw) ?: return Write.Unavailable
        val kwargs = root[KWARGS] as? JsonObject ?: JsonObject(emptyMap())
        val expected = JsonObject(LinkedHashMap(root).apply {
            put(KWARGS, JsonObject(LinkedHashMap(kwargs).apply { put(FLAG, JsonPrimitive(enable)) }))
        })
        val inPlace = if (raw.isBlank()) null else rewriteInPlace(raw, enable)
            ?.takeIf { candidate -> parse(candidate) == expected }
        return Write.Written(AdditionalBody(inPlace ?: pretty(expected), sendWithRequest = true))
    }

    private fun parse(raw: String): JsonObject? =
        runCatching { Json.parseToJsonElement(raw) }.getOrNull() as? JsonObject

    /** An object member: the raw key (inside the quotes, undecoded), the start and end index of the value, and the start index of the member. */
    private class Member(val rawKey: String, val keyStart: Int, val valueStart: Int, val valueEnd: Int)

    /** Parses an object ([open] points at '{') and returns its members and the index of '}'; null when it is not valid. */
    private class Scanner(val src: String) {
        fun ws(from: Int): Int { var i = from; while (i < src.length && src[i].isWhitespace()) i++; return i }
        fun stringEnd(from: Int): Int? { // from points at the opening quote; returns the index after the closing quote
            var i = from + 1
            while (i < src.length) {
                when (src[i]) { '\\' -> i += 2; '"' -> return i + 1; else -> i++ }
            }
            return null
        }
        fun valueEnd(from: Int): Int? = when (src.getOrNull(from)) {
            '"' -> stringEnd(from)
            '{' -> obj(from)?.second?.plus(1)
            '[' -> {
                var i = ws(from + 1)
                if (src.getOrNull(i) == ']') i + 1 else {
                    var end: Int? = null
                    while (true) {
                        i = valueEnd(i)?.let(::ws) ?: break
                        when (src.getOrNull(i)) { ',' -> i = ws(i + 1); ']' -> { end = i + 1; break }; else -> break }
                    }
                    end
                }
            }
            null -> null
            else -> { var i = from; while (i < src.length && src[i] !in ",}] \t\r\n") i++; i.takeIf { it > from } }
        }
        fun obj(open: Int): Pair<List<Member>, Int>? {
            val members = mutableListOf<Member>()
            var i = ws(open + 1)
            if (src.getOrNull(i) == '}') return members to i
            while (true) {
                if (src.getOrNull(i) != '"') return null
                val keyEnd = stringEnd(i) ?: return null
                val colon = ws(keyEnd)
                if (src.getOrNull(colon) != ':') return null
                val valueStart = ws(colon + 1)
                val end = valueEnd(valueStart) ?: return null
                members += Member(src.substring(i + 1, keyEnd - 1), i, valueStart, end)
                i = ws(end)
                when (src.getOrNull(i)) { ',' -> i = ws(i + 1); '}' -> return members to i; else -> return null }
            }
        }
    }

    private fun rewriteInPlace(raw: String, enable: Boolean): String? {
        val scanner = Scanner(raw)
        val rootOpen = scanner.ws(0).takeIf { raw.getOrNull(it) == '{' } ?: return null
        val (rootMembers, rootClose) = scanner.obj(rootOpen) ?: return null
        val flag = enable.toString()
        val kwargsMember = rootMembers.lastOrNull { it.rawKey == KWARGS }
        if (kwargsMember != null) {
            if (raw[kwargsMember.valueStart] != '{') return null
            val (members, close) = scanner.obj(kwargsMember.valueStart) ?: return null
            members.lastOrNull { it.rawKey == FLAG }?.let { member ->
                return raw.substring(0, member.valueStart) + flag + raw.substring(member.valueEnd)
            }
            return insertMember(raw, kwargsMember.valueStart, members, close, "\"$FLAG\": $flag") { _ -> "" }
        }
        return insertMember(raw, rootOpen, rootMembers, rootClose, null) { indent ->
            if (indent == null) "\"$KWARGS\": {\"$FLAG\": $flag}"
            else "\"$KWARGS\": {\n$indent$indent\"$FLAG\": $flag\n$indent}"
        }
    }

    /**
     * Inserts a member at the end of the object, reusing the line break and indentation before the last member; a single-line object uses `, `.
     * A non-null [fixed] is used as is; otherwise [build] produces it from the indentation (null for a single line).
     */
    private fun insertMember(
        raw: String,
        open: Int,
        members: List<Member>,
        close: Int,
        fixed: String?,
        build: (String?) -> String,
    ): String {
        val last = members.lastOrNull()
        if (last == null) {
            val text = fixed ?: build(null)
            return raw.substring(0, open + 1) + text + raw.substring(close)
        }
        val before = raw.substring(0, last.keyStart)
        val lineBreak = before.lastIndexOf('\n')
        val indent = if (lineBreak >= 0) before.substring(lineBreak + 1).takeIf { it.isBlank() } else null
        val separator = if (indent != null) ",\n$indent" else ", "
        val text = fixed ?: build(indent)
        return raw.substring(0, last.valueEnd) + separator + text + raw.substring(last.valueEnd)
    }

    /** Fallback format: 2-space indentation and sorted keys; no content is lost. */
    private fun pretty(value: JsonElement, depth: Int = 0): String {
        val pad = "  ".repeat(depth + 1)
        val closePad = "  ".repeat(depth)
        return when (value) {
            is JsonObject -> if (value.isEmpty()) "{}" else value.entries.sortedBy { it.key }.joinToString(
                separator = ",\n", prefix = "{\n", postfix = "\n$closePad}",
            ) { (key, child) -> "$pad${JsonPrimitive(key)}: ${pretty(child, depth + 1)}" }
            is JsonArray -> if (value.isEmpty()) "[]" else value.joinToString(
                separator = ",\n", prefix = "[\n", postfix = "\n$closePad]",
            ) { "$pad${pretty(it, depth + 1)}" }
            else -> value.toString()
        }
    }
}

/** The status mark under the model name. */
internal enum class ModelOptionsStatusMark(@StringRes val labelRes: Int?) {
    Official(R.string.generation_parameter_source_official),
    Unverified(R.string.generation_parameter_unverified_badge),
    None(null),
    ;

    companion object {
        /** A custom connection sends by protocol, so it is unverified; otherwise an official recipe (any capability with an automatic configuration) means official configuration. */
        fun resolve(connection: ConnectionCategory, presentations: Collection<CapabilityControlPresentation>): ModelOptionsStatusMark =
            when {
                connection == ConnectionCategory.CustomLLM -> Unverified
                presentations.any {
                    it == CapabilityControlPresentation.AutomaticAvailable || it == CapabilityControlPresentation.ForceUnsupported ||
                        it == CapabilityControlPresentation.AlwaysOn
                } -> Official
                else -> None
            }
    }
}

/** Connection facts to shape inputs. Only the connection category and protocol field are read, never a provider name or model id. */
internal object ModelOptionsPanelInput {
    fun connectionCategory(kind: ProviderKind): ConnectionCategory = when (kind) {
        ProviderKind.Relay -> ConnectionCategory.CustomLLM
        else -> ConnectionCategory.Other
    }

    /** "Shows thinking": reads only the facade fact reasoning.thinking (each form's adapter produces it from that form's source); false when there is no model. */
    fun showsThinking(provider: Provider, model: AIModel?): Boolean =
        model != null && CapabilityTruthRegistry.thinking(provider, model)

    /** The same criterion as `ModelControlsIdentityGap`: neither the model nor the connection has chosen a protocol (or it is still "automatic"). */
    fun protocolUndecided(provider: Provider, model: AIModel? = null): Boolean =
        provider.kind == ProviderKind.Relay &&
            RelayEndpointResolver.declaredTransport(provider, model) == null

    /**
     * The "protocol undecided" criterion of the model options web row (the panel and the tests read the same one). The relay web row follows the first-send protocol,
     * which can always be determined (an unverified model on an auto connection has one too), so a relay model with web facts ([relayWeb] non-null) is not undecided; the switch listens only to the user.
     */
    fun webProtocolUndecided(provider: Provider, model: AIModel? = null): Boolean =
        protocolUndecided(provider, model) &&
            (model == null || ai.oriveo.community.core.provider.relay.RelayWebChat.of(provider, model) == null)

    /** The stored web-search preference to the intent the shape function understands; a tier taken over by custom fields is drawn as on. */
    fun webIntent(preference: CapabilityWebPreference): String = when (preference) {
        CapabilityWebPreference.Off -> ModelOptionCapabilityShape.OFF
        CapabilityWebPreference.Force -> ModelOptionCapabilityShape.FORCE
        CapabilityWebPreference.Automatic, CapabilityWebPreference.Custom -> ModelOptionCapabilityShape.AUTOMATIC
    }

    fun webPreference(intent: String): CapabilityWebPreference = when (intent) {
        ModelOptionCapabilityShape.OFF -> CapabilityWebPreference.Off
        ModelOptionCapabilityShape.FORCE -> CapabilityWebPreference.Force
        else -> CapabilityWebPreference.Automatic
    }

    /** Thinking-row facts of a local-engine connection: looks up the write-path table by engineProfile x channel; returns null when it is not a local engine or not in the table. */
    fun localEngineThinking(provider: Provider, model: AIModel? = null): ModelOptionCapabilityShape.LocalEngineThinking? {
        if (provider.kind != ProviderKind.Relay) return null
        val engineProfile = provider.relayRequested?.engineProfile?.takeIf(String::isNotBlank) ?: return null
        val channel = RelayEndpointResolver.declaredTransport(provider, model) ?: return null
        val writable = LocalEngineChannels.thinkingWritable(engineProfile, channel) ?: return null
        return ModelOptionCapabilityShape.LocalEngineThinking(
            writable = writable,
            nonChatChannel = channel == RelayTransport.LlamaCppNative,
            declaredThinking = model?.engineDeclaration?.thinking,
        )
    }

    /**
     * Relay web row facts: local engine -> the connection cannot do it; otherwise the first-send protocol's
     * [ai.oriveo.community.core.provider.relay.RelayWebChat] yields the switch / a greyed-out switch. Returns null for a non-relay or without a model.
     * [webPreference] = the resolved chat web preference (default layer included); null = never set, follows the default.
     */
    fun relayWeb(
        provider: Provider,
        model: AIModel?,
        store: ai.oriveo.community.core.provider.relay.RelayWebFragmentStore =
            ai.oriveo.community.core.provider.relay.RelayWebFragmentStore.shared,
        records: ai.oriveo.community.core.provider.relay.RelayWebProbeRecordStore =
            ai.oriveo.community.core.provider.relay.RelayWebProbeRecordStore.shared,
        webPreference: CapabilityWebPreference? = null,
    ): ModelOptionCapabilityShape.RelayWeb? {
        if (provider.kind != ProviderKind.Relay) return null
        if (!provider.relayRequested?.engineProfile.isNullOrBlank()) return ModelOptionCapabilityShape.RelayWeb.LocalEngine
        val chat = model?.let { ai.oriveo.community.core.provider.relay.RelayWebChat.of(provider, it, store, records) } ?: return null
        return relayWebToggle(chat, webPreference)
    }

    /** Entry for the local-engine and protocol-undecided rows (web-fragment presentationCases): only a fragment, no record and no override. */
    fun relayWeb(
        localEngine: Boolean,
        effectiveTransport: String,
        fragments: Map<String, kotlinx.serialization.json.JsonObject>,
    ): ModelOptionCapabilityShape.RelayWeb {
        if (localEngine) return ModelOptionCapabilityShape.RelayWeb.LocalEngine
        val transport = RelayTransport.entries.first { it.value == effectiveTransport }
        val saved = fragments[effectiveTransport]
        return relayWebToggle(
            ai.oriveo.community.core.provider.relay.RelayWebChat(
                transport = transport,
                saved = saved,
                effective = saved ?: ai.oriveo.community.core.provider.relay.RelayWebFragments.template(transport),
                record = null,
                userOverride = null,
            ),
            webPreference = null,
        )
    }

    fun relayWebToggle(
        chat: ai.oriveo.community.core.provider.relay.RelayWebChat,
        webPreference: CapabilityWebPreference?,
    ): ModelOptionCapabilityShape.RelayWebToggle = ModelOptionCapabilityShape.RelayWebToggle(
        isOn = chat.isOn(webPreference),
        enabled = !chat.userDisabled,
        status = chat.status,
        retest = chat.retest,
    )

    /** Vision card "unknown": a Relay form and the model has no positive vision evidence at all (the same predicate as the record check). */
    fun visionUnknown(
        provider: Provider,
        model: AIModel,
        relayIdentity: ai.oriveo.community.core.provider.CapabilityEvidenceFacade.QueryIdentity? = null,
    ): Boolean =
        ProviderForm.of(provider) == ProviderForm.Relay && relayImageSupportUnknown(provider, model, relayIdentity)

    /**
     * File card: computed with the same route resolution as before sending (web takes the panel's current switch, the tool loop uses false),
     * then the Relay `file` negative cache is layered on; the key is the same [RelayNegativeCache.keyFor] as the send side's fallback memory.
     */
    fun fileDelivery(
        provider: Provider,
        model: AIModel,
        webSearchEnabled: Boolean,
        reasoningMode: ReasoningMode,
        negativeCache: RelayNegativeCache = RelayNegativeCache.shared,
        // The outbound history (session history plus this turn's placeholder) has video: Gemini does not take Interactions, same as send / preflight.
        historyHasVideo: Boolean = false,
        // file_input projection unavailable (with a reason): native files cannot be sent and only inline text remains; unknown / available is judged by route.
        nativeFileUnavailable: Boolean = false,
    ): ModelOptionsTiles.FileDelivery {
        if (nativeFileUnavailable) return ModelOptionsTiles.FileDelivery.Text
        val route = AttachmentTransportResolver.resolve(provider, model, webSearchEnabled, reasoningMode, historyHasVideo)
        // A file override set to On beats the file negative cache, the same as the send side's fallback memory.
        val fileRejected = model.relayCapabilityOverrides?.file != true &&
            RelayNegativeCache.keyFor(provider, model)
                ?.let { negativeCache.isRejected(it, RelayNegativeCache.Kind.File) } == true
        return ModelOptionsTiles.fileDelivery(route, fileRejected)
    }

    fun customProtocol(provider: Provider, model: AIModel? = null): CustomProtocol? {
        if (provider.kind != ProviderKind.Relay) return null
        return if (RelayEndpointResolver.declaredTransport(provider, model) == RelayTransport.OpenAIChatCompletions) {
            CustomProtocol.ChatCompletions
        } else {
            CustomProtocol.Other
        }
    }
}

/** Shape semantics to copy slots. */
internal object ModelOptionsRender {
    /** The sentence that replaces the switch explanation when the chat-template switch cannot be toggled; null when it can. */
    @StringRes fun templateThinkingBlockedNoteRes(state: ChatTemplateThinking.State): Int? = when (state) {
        ChatTemplateThinking.State.Blocked -> R.string.additional_body_switch_blocked_invalid
        ChatTemplateThinking.State.NotSending -> R.string.additional_body_switch_blocked_off
        ChatTemplateThinking.State.Off, ChatTemplateThinking.State.On -> null
    }

    @StringRes fun tierLabelRes(tier: String): Int = when (tier) {
        // The automatic tier uses iOS's "Automatic" wording on all three platforms.
        ModelOptionCapabilityShape.AUTOMATIC -> R.string.model_control_supplier_default
        ModelOptionCapabilityShape.OFF -> R.string.model_control_off
        "low" -> R.string.reasoning_fast
        "balanced" -> R.string.reasoning_balanced
        "deep" -> R.string.reasoning_deep
        else -> R.string.reasoning_max
    }

    /** The note at the top right of the tier card (the [ModelOptionCapabilityShape.TrailingNote] the shape supplies). */
    @StringRes fun trailingNoteRes(note: ModelOptionCapabilityShape.TrailingNote): Int = when (note) {
        ModelOptionCapabilityShape.TrailingNote.AlwaysThinks -> R.string.model_options_always_thinks
    }

    /** The sentence under the segments that follows the highlighted tier. */
    @StringRes fun tierNoteRes(tier: String): Int? = when (tier) {
        ModelOptionCapabilityShape.AUTOMATIC -> R.string.model_control_reasoning_note_automatic
        ModelOptionCapabilityShape.OFF -> R.string.model_control_reasoning_note_off
        "low" -> R.string.model_control_reasoning_note_fast
        "balanced" -> R.string.model_control_reasoning_note_balanced
        "deep" -> R.string.model_control_reasoning_note_deep
        "max" -> R.string.model_control_reasoning_note_max
        else -> null
    }

    /** When the chosen tier has a level, adds a note that a higher tier is slower and may cost more. */
    fun appendsHigherLevelsNote(tier: String): Boolean = tier in ModelOptionCapabilityShape.TIER_ORDER

    @StringRes fun timingLabelRes(timing: String): Int =
        if (timing == ModelOptionCapabilityShape.FORCE) R.string.model_options_web_every_message else R.string.model_options_web_when_needed

    @StringRes fun toggleNoteRes(
        capability: ModelOptionCapabilityShape.Capability,
        kind: ModelOptionCapabilityShape.ToggleKind,
    ): Int = when {
        kind == ModelOptionCapabilityShape.ToggleKind.ChatTemplateThinking -> R.string.model_options_template_thinking_note
        capability == ModelOptionCapabilityShape.Capability.Web -> R.string.model_options_web_note
        else -> R.string.model_options_thinks_first_note
    }

    @StringRes fun noticeStatusRes(status: ModelOptionCapabilityShape.NoticeStatus): Int = when (status) {
        ModelOptionCapabilityShape.NoticeStatus.FollowsModelDefault -> R.string.model_options_uses_model_default
        ModelOptionCapabilityShape.NoticeStatus.NeedsOwnConfiguration -> R.string.model_options_needs_manual_setup
        ModelOptionCapabilityShape.NoticeStatus.NotAvailableYet -> R.string.model_options_not_available_yet
        ModelOptionCapabilityShape.NoticeStatus.AlwaysOn -> R.string.model_options_always_on
    }

    @StringRes fun noticeBodyRes(body: ModelOptionCapabilityShape.NoticeBody): Int = when (body) {
        ModelOptionCapabilityShape.NoticeBody.ReasoningNotCatalogued -> R.string.model_options_reasoning_not_catalogued
        ModelOptionCapabilityShape.NoticeBody.WebNotCatalogued -> R.string.model_options_web_not_catalogued
        ModelOptionCapabilityShape.NoticeBody.ReasoningNoGenericSwitch,
        ModelOptionCapabilityShape.NoticeBody.CustomThinkingUseAdditionalBody,
        -> R.string.model_options_reasoning_no_generic_switch
        ModelOptionCapabilityShape.NoticeBody.WebNoGenericSwitch -> R.string.model_options_web_no_generic_switch
        ModelOptionCapabilityShape.NoticeBody.SubscriptionAlwaysSearches -> R.string.model_options_subscription_always_searches
    }

    @StringRes fun escapeRes(escape: ModelOptionCapabilityShape.Escape): Int = when (escape) {
        ModelOptionCapabilityShape.Escape.SupportedModels -> R.string.model_options_see_adjustable_models
        ModelOptionCapabilityShape.Escape.AdditionalBody -> R.string.model_options_open_additional_body
    }

    /** [ModelOptionCapabilityShape.DisclosureStatus.ReadOnlyValue] shows the tier itself and does not go through here. */
    @StringRes fun disclosureRes(status: ModelOptionCapabilityShape.DisclosureStatus): Int = when (status) {
        ModelOptionCapabilityShape.DisclosureStatus.ModelDoesNotThink -> R.string.model_options_no_thinking_mode
        ModelOptionCapabilityShape.DisclosureStatus.ShowsThinkingFixed -> R.string.model_options_shows_thinking_fixed
        ModelOptionCapabilityShape.DisclosureStatus.ModelCannotSearch -> R.string.model_options_cannot_search
        ModelOptionCapabilityShape.DisclosureStatus.ConnectionCannotSearch -> R.string.model_options_connection_cannot
        ModelOptionCapabilityShape.DisclosureStatus.FixedLevel,
        ModelOptionCapabilityShape.DisclosureStatus.ReadOnlyValue,
        -> R.string.model_options_cant_switch_here
    }

    /** The two rows where the model itself cannot do it are tappable as a whole, leading to a model that can; when the connection cannot, switching models would not help. */
    fun disclosureOffersSupportedModels(status: ModelOptionCapabilityShape.DisclosureStatus): Boolean =
        status == ModelOptionCapabilityShape.DisclosureStatus.ModelDoesNotThink ||
            status == ModelOptionCapabilityShape.DisclosureStatus.ModelCannotSearch
    /** The whole row is tappable: the two rows that lead to switching models. */
    fun disclosureTappable(status: ModelOptionCapabilityShape.DisclosureStatus): Boolean =
        disclosureOffersSupportedModels(status)

    /** The status line under the relay web switch (fixture statusId -> this platform's copy). */
    @StringRes fun relayWebStatusRes(status: ai.oriveo.community.core.provider.relay.RelayWebChat.Status): Int = when (status) {
        ai.oriveo.community.core.provider.relay.RelayWebChat.Status.Searched -> R.string.model_options_relay_web_search_confirmed
        ai.oriveo.community.core.provider.relay.RelayWebChat.Status.Silent -> R.string.model_options_relay_web_no_search_in_test
        ai.oriveo.community.core.provider.relay.RelayWebChat.Status.Rejected -> R.string.model_options_relay_web_rejected
        ai.oriveo.community.core.provider.relay.RelayWebChat.Status.Unverified -> R.string.model_options_relay_web_set_unverified
        ai.oriveo.community.core.provider.relay.RelayWebChat.Status.Untested -> R.string.model_options_relay_web_untested
        ai.oriveo.community.core.provider.relay.RelayWebChat.Status.UserOff -> R.string.model_options_relay_web_user_off
        ai.oriveo.community.core.provider.relay.RelayWebChat.Status.UserOn -> R.string.relay_catalog_status_set_by_you
    }

    /** The retest link on a greyed-out row: a rejected stored fragment -> "Test again in web search settings", a rejected template -> "Test capabilities". */
    @StringRes fun relayWebRetestRes(retest: ai.oriveo.community.core.provider.relay.RelayWebChat.Retest): Int = when (retest) {
        ai.oriveo.community.core.provider.relay.RelayWebChat.Retest.OpenConnectionWebSearch -> R.string.model_options_relay_web_retest
        ai.oriveo.community.core.provider.relay.RelayWebChat.Retest.TestCapabilities -> R.string.relay_capability_test
    }
}

/**
 * The 2x2 capability cards of the model options panel, the "this turn actually sends" summary strip and the temperature row of the parameters card.
 * Pure functions: the web / thinking cards only turn a [ModelOptionCapabilityShape] into a card look and the shape function is untouched;
 * the vision / file cards are info cards whose inputs come from the same production decisions as the composer and the send path.
 */
internal object ModelOptionsTiles {
    enum class Kind { Web, Reasoning, Vision, File }

    /** The card's top-right corner: a switch / "N levels" / a tappable arrow / nothing / the three marks of an info card. */
    enum class Corner { Switch, Levels, Chevron, None, Check, Question, Cross }

    data class Tile(
        val kind: Kind,
        val corner: Corner,
        /** The status line. */
        @StringRes val statusRes: Int,
        /** Small text inside the card (the body of an explanation card); null means none. */
        @StringRes val bodyRes: Int? = null,
        /** The level count of [Corner.Levels]. */
        val levelCount: Int = 0,
        /** The whole card is tappable (explanation cards, status cards the model itself cannot do, protocol undecided). */
        val tappable: Boolean = false,
    )

    enum class Vision(@StringRes val statusRes: Int, val corner: Corner) {
        Available(R.string.model_options_vision_available, Corner.Check),
        Unknown(R.string.model_options_vision_unknown, Corner.Question),
        Hidden(R.string.model_options_vision_hidden, Corner.Cross),
    }

    /** A file can always be delivered, so all three states show a check at the top right. */
    enum class FileDelivery(@StringRes val statusRes: Int) {
        PdfNative(R.string.model_options_file_pdf_native),
        NativeWhenSupported(R.string.model_options_file_native_when_supported),
        Text(R.string.model_options_file_text),
    }

    sealed interface SummaryItem {
        data object WebOn : SummaryItem
        data class ThinkingLevel(val tier: String) : SummaryItem {
            @get:StringRes val tierRes: Int get() = ModelOptionsRender.tierLabelRes(tier)
        }
        data object ThinkingOn : SummaryItem
    }

    data class ParameterRows(
        /** The row with id `temperature` in advancedRows; null when the model has none. */
        val temperature: GenerationParameterRowModel?,
        /** The capsule of the entry row (temperature already excluded). */
        val entry: GenerationParameterRowModel.Summary,
    )

    private const val TEMPERATURE = "temperature"

    /** Entry not visible -> unavailable; visible and a Relay without positive evidence -> unknown; any other visible -> available. */
    fun vision(entryVisible: Boolean, relayWithoutPositiveEvidence: Boolean): Vision = when {
        !entryVisible -> Vision.Hidden
        relayWithoutPositiveEvidence -> Vision.Unknown
        else -> Vision.Available
    }

    /**
     * The route cannot be decided (catalog not arrived / image-generation model / subscription protocol pending, [route] is null), the route does not carry native files, the model has no allow-list,
     * or the Relay `file` negative cache has not expired -> convert to text; otherwise pdfNativeDefault true -> native PDF; otherwise -> native for supported formats.
     */
    fun fileDelivery(route: AttachmentTransportResolver.Route?, relayFileRejected: Boolean): FileDelivery {
        val model = route?.model
        return when {
            route == null || !route.transport.allowsNativeFiles || model == null -> FileDelivery.Text
            model.nativeFileMimes.isEmpty() || relayFileRejected -> FileDelivery.Text
            model.pdfNativeDefault -> FileDelivery.PdfNative
            else -> FileDelivery.NativeWhenSupported
        }
    }

    /** Both rows have an undecided protocol: only the full-width callout (when there is one) shows, no four cards. */
    fun showsCalloutOnly(web: ModelOptionCapabilityShape, reasoning: ModelOptionCapabilityShape): Boolean =
        web == ModelOptionCapabilityShape.ProtocolUndecided && reasoning == ModelOptionCapabilityShape.ProtocolUndecided

    /**
     * The vision card shows three values from the composer's image item (produced by the vision_input projection):
     * not tappable -> unavailable (reason in [ComposerAttachmentMenuItem.disabledReasonRes]);
     * tappable but projection unknown (first-attachment hint) -> unknown, never "available"; otherwise -> available.
     */
    fun vision(image: ComposerAttachmentMenuItem): Vision = when {
        !image.enabled -> Vision.Hidden
        image.firstAttachHint -> Vision.Unknown
        else -> Vision.Available
    }

    /**
     * The capability cards: the web / thinking order keeps the existing chat-template exception - when thinking is the chat-template switch (blocked included) thinking comes first,
     * otherwise web comes first; after that vision, then file, fixed. Empty when only the callout shows.
     */
    fun board(
        web: ModelOptionCapabilityShape,
        reasoning: ModelOptionCapabilityShape,
        vision: Vision,
        file: FileDelivery,
        @StringRes reasoningToggleBlockedNoteRes: Int? = null,
        /** The reason line inside the card when vision / file is unavailable (`capability_input_disabled_<reason>_<media>`); null = write nothing. */
        @StringRes visionReasonRes: Int? = null,
        @StringRes fileReasonRes: Int? = null,
    ): List<Tile> {
        if (showsCalloutOnly(web, reasoning)) return emptyList()
        val webTile = capabilityTile(ModelOptionCapabilityShape.Capability.Web, web)
        val reasoningTile = capabilityTile(ModelOptionCapabilityShape.Capability.Reasoning, reasoning, reasoningToggleBlockedNoteRes)
        val templateFirst = (reasoning as? ModelOptionCapabilityShape.Toggle)?.kind ==
            ModelOptionCapabilityShape.ToggleKind.ChatTemplateThinking
        return (if (templateFirst) listOf(reasoningTile, webTile) else listOf(webTile, reasoningTile)) +
            listOf(
                visionTile(vision, visionReasonRes),
                fileTile(file, fileReasonRes.takeIf { file == FileDelivery.Text }),
            )
    }

    /** Vision card: when unavailable with a disabled reason, the status line is that reason (`capability_input_disabled_<reason>_image`); with no reason (the old subscription wording) the enum status sentence is kept. */
    fun visionTile(vision: Vision, @StringRes reasonRes: Int? = null): Tile {
        val reason = reasonRes.takeIf { vision == Vision.Hidden }
        return Tile(Kind.Vision, vision.corner, reason ?: vision.statusRes)
    }

    fun fileTile(file: FileDelivery, @StringRes reasonRes: Int? = null): Tile =
        Tile(Kind.File, Corner.Check, file.statusRes, bodyRes = reasonRes)

    /** Web / thinking card: shape -> top-right control and status line (the copy slots reuse [ModelOptionsRender]). */
    fun capabilityTile(
        capability: ModelOptionCapabilityShape.Capability,
        shape: ModelOptionCapabilityShape,
        @StringRes toggleBlockedNoteRes: Int? = null,
    ): Tile {
        val kind = if (capability == ModelOptionCapabilityShape.Capability.Web) Kind.Web else Kind.Reasoning
        return when (shape) {
            is ModelOptionCapabilityShape.Toggle ->
                Tile(kind, Corner.Switch, toggleBlockedNoteRes ?: ModelOptionsRender.toggleNoteRes(capability, shape.kind))
            is ModelOptionCapabilityShape.ToggleWithTiming ->
                Tile(kind, Corner.Switch, ModelOptionsRender.toggleNoteRes(capability, ModelOptionCapabilityShape.ToggleKind.Capability))
            // Relay web switch: the status line is the test verdict / source; when greyed out the switch cannot be toggled and the UI layer wires the retest link.
            is ModelOptionCapabilityShape.RelayWebToggle ->
                Tile(kind, Corner.Switch, ModelOptionsRender.relayWebStatusRes(shape.status))
            // With no selected tier the status line uses the shape's top-right status sentence; the rejected-tier warning stays below the grid.
            is ModelOptionCapabilityShape.Tiers -> Tile(
                kind = kind,
                corner = Corner.Levels,
                statusRes = shape.selected?.let(ModelOptionsRender::tierLabelRes)
                    ?: shape.trailingNote?.let(ModelOptionsRender::trailingNoteRes)
                    ?: R.string.model_options_uses_model_default,
                levelCount = shape.tiers.size,
            )
            // A notice with no way out is a read-only note: no chevron, the whole card is not tappable.
            is ModelOptionCapabilityShape.Notice -> Tile(
                kind = kind,
                corner = if (shape.escape != null) Corner.Chevron else Corner.None,
                statusRes = ModelOptionsRender.noticeStatusRes(shape.status),
                bodyRes = ModelOptionsRender.noticeBodyRes(shape.body),
                tappable = shape.escape != null,
            )
            is ModelOptionCapabilityShape.Disclosure -> {
                val tappable = shape.tappable && ModelOptionsRender.disclosureTappable(shape.status)
                Tile(kind, if (tappable) Corner.Chevron else Corner.None, disclosureStatusRes(capability, shape), tappable = tappable)
            }
            ModelOptionCapabilityShape.ProtocolUndecided -> Tile(
                kind = kind,
                corner = Corner.Chevron,
                statusRes = R.string.model_options_choose_protocol_first,
                bodyRes = R.string.model_options_protocol_auto_note,
                tappable = true,
            )
        }
    }

    @StringRes
    private fun disclosureStatusRes(
        capability: ModelOptionCapabilityShape.Capability,
        shape: ModelOptionCapabilityShape.Disclosure,
    ): Int {
        if (shape.status != ModelOptionCapabilityShape.DisclosureStatus.ReadOnlyValue) return ModelOptionsRender.disclosureRes(shape.status)
        val value = shape.value ?: return R.string.model_options_cant_switch_here
        return when {
            capability == ModelOptionCapabilityShape.Capability.Reasoning -> ModelOptionsRender.tierLabelRes(value)
            value == ModelOptionCapabilityShape.OFF -> R.string.model_control_off
            else -> ModelOptionsRender.timingLabelRes(value)
        }
    }

    /** The web switch is on right now (including the "every message" timing row). */
    fun webIsOn(web: ModelOptionCapabilityShape): Boolean =
        web is ModelOptionCapabilityShape.ToggleWithTiming || (web as? ModelOptionCapabilityShape.Toggle)?.isOn == true ||
            (web as? ModelOptionCapabilityShape.RelayWebToggle)?.isOn == true

    /**
     * "This turn actually sends" lists only the choices that rewrite the request right now, in the fixed order web -> thinking: web on; a non-automatic thinking tier that is selected ("off" included);
     * the thinking switch (chat template included) on. No item at all -> empty, no strip.
     */
    fun summary(web: ModelOptionCapabilityShape, reasoning: ModelOptionCapabilityShape): List<SummaryItem> = buildList {
        if (webIsOn(web)) add(SummaryItem.WebOn)
        when (reasoning) {
            is ModelOptionCapabilityShape.Tiers -> reasoning.selected
                ?.takeIf { it != ModelOptionCapabilityShape.AUTOMATIC }
                ?.let { add(SummaryItem.ThinkingLevel(it)) }
            is ModelOptionCapabilityShape.Toggle -> if (reasoning.isOn == true) add(SummaryItem.ThinkingOn)
            else -> Unit
        }
    }

    /** The two rows of the parameters card: the temperature row (omitted when the model has none) plus the original entry row (capsule without temperature). */
    fun parameterRows(rows: List<GenerationParameterRowModel>): ParameterRows = ParameterRows(
        temperature = rows.firstOrNull { it.id == TEMPERATURE },
        entry = GenerationParameterRowModel.summary(rows.filterNot { it.id == TEMPERATURE }),
    )

    /** Thinking card segments draw icons only (all three platforms follow iOS): automatic -> sparkle, off -> dash, the rest -> bars (number of filled bars = effort level). */
    sealed interface TierGlyph {
        data object Automatic : TierGlyph
        data object Off : TierGlyph
        data class Bars(val filled: Int) : TierGlyph
    }

    fun tierGlyph(tier: String): TierGlyph = when (tier) {
        ModelOptionCapabilityShape.AUTOMATIC -> TierGlyph.Automatic
        ModelOptionCapabilityShape.OFF -> TierGlyph.Off
        else -> TierGlyph.Bars(ModelOptionCapabilityShape.TIER_ORDER.indexOf(tier) + 1)
    }

    /** Accessibility large font (fontScale >= 1.5) -> single column. */
    fun singleColumn(fontScale: Float): Boolean = fontScale >= 1.5f
}
