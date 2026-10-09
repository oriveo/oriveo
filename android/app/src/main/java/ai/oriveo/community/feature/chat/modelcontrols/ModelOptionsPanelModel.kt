package ai.oriveo.community.feature.chat.modelcontrols

import androidx.annotation.StringRes
import ai.oriveo.community.R
import ai.oriveo.community.core.model.CapabilityWebPreference
import ai.oriveo.community.core.model.LocalCapabilityCustomFragmentStore.AdditionalBody
import ai.oriveo.community.core.model.Provider
import ai.oriveo.community.core.model.ProviderKind
import ai.oriveo.community.core.model.RelayTransport
import ai.oriveo.community.core.provider.AdditionalRequestBody
import ai.oriveo.community.core.provider.CapabilityControlPresentation
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
                    it == CapabilityControlPresentation.AutomaticAvailable || it == CapabilityControlPresentation.ForceUnsupported
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

    /** The same criterion as `ModelControlsIdentityGap`: no protocol chosen or still "automatic". */
    fun protocolUndecided(provider: Provider): Boolean =
        provider.kind == ProviderKind.Relay &&
            provider.relayRequested?.transport?.takeIf { it != RelayTransport.Auto } == null

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

    fun customProtocol(provider: Provider): CustomProtocol? {
        if (provider.kind != ProviderKind.Relay) return null
        return if (provider.relayRequested?.transport == RelayTransport.OpenAIChatCompletions) {
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
        ModelOptionCapabilityShape.AUTOMATIC -> R.string.reasoning_auto
        ModelOptionCapabilityShape.OFF -> R.string.model_control_off
        "low" -> R.string.reasoning_fast
        "balanced" -> R.string.reasoning_balanced
        "deep" -> R.string.reasoning_deep
        else -> R.string.reasoning_max
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
    }

    @StringRes fun noticeBodyRes(body: ModelOptionCapabilityShape.NoticeBody): Int = when (body) {
        ModelOptionCapabilityShape.NoticeBody.ReasoningNotCatalogued -> R.string.model_options_reasoning_not_catalogued
        ModelOptionCapabilityShape.NoticeBody.WebNotCatalogued -> R.string.model_options_web_not_catalogued
        ModelOptionCapabilityShape.NoticeBody.ReasoningNoGenericSwitch,
        ModelOptionCapabilityShape.NoticeBody.CustomThinkingUseAdditionalBody,
        -> R.string.model_options_reasoning_no_generic_switch
        ModelOptionCapabilityShape.NoticeBody.WebNoGenericSwitch -> R.string.model_options_web_no_generic_switch
    }

    @StringRes fun escapeRes(escape: ModelOptionCapabilityShape.Escape): Int = when (escape) {
        ModelOptionCapabilityShape.Escape.SupportedModels -> R.string.model_options_see_adjustable_models
        ModelOptionCapabilityShape.Escape.AdditionalBody -> R.string.model_options_open_additional_body
    }

    /** [ModelOptionCapabilityShape.DisclosureStatus.ReadOnlyValue] shows the tier itself and does not go through here. */
    @StringRes fun disclosureRes(status: ModelOptionCapabilityShape.DisclosureStatus): Int = when (status) {
        ModelOptionCapabilityShape.DisclosureStatus.ModelDoesNotThink -> R.string.model_options_no_thinking_mode
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
}
