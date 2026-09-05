package ai.oriveo.community.feature.chat.composer

import ai.oriveo.community.R
import java.io.File
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Locks the simplified-Chinese wording for the reasoning/web-search tiers so all platforms stay
 * word-for-word aligned.
 *
 * Three things are pinned here:
 * 1. The set of intents comes from the shared contract `request_shape_contract.v2.json`, not a
 *    hand-maintained local list -- a local list is exactly how the platforms drift apart.
 * 2. The zh-Hans wording is byte-identical to the frozen table below, and to the web build's
 *    `messages/zh-Hans.json`.
 * 3. All sixteen locale resources are present, with no locale silently falling back to English.
 *
 * The "automatic" tier means the model decides for itself, without a tier being injected. Web
 * search is presented as "search when needed" vs. "search every message" rather than exposing the
 * raw enum names, since the enum name alone doesn't tell the user what timing they're picking. The
 * panel is named "Model options" and its parameter screen "Advanced settings". The reasoning tier
 * words (off / fast / balanced / deep / max) are unaffected -- only the presentation wording moved,
 * never the wire-level enum values.
 */
class ModelControlIntentVocabularyTest {
    private val json = Json { ignoreUnknownKeys = true }

    /** Frozen wording table, verbatim against what ships. */
    private val frozenReasoningZhHans = mapOf(
        "off" to "\u5173\u95ed",
        "low" to "\u5feb\u901f",
        "balanced" to "\u5747\u8861",
        "deep" to "\u6df1\u5ea6",
        "max" to "\u6781\u81f4",
    )
    private val frozenWebZhHans = mapOf(
        "off" to "\u5173\u95ed",
        "automatic" to "\u9700\u8981\u65f6\u641c\u7d22",
        "force" to "\u6bcf\u6761\u6d88\u606f\u90fd\u641c\u7d22",
    )
    private val automaticZhHans = "\u81ea\u52a8"

    /** One human-readable note per tier, verbatim against what ships. */
    private val frozenTierNotesZhHans = mapOf(
        "model_control_reasoning_note_off" to "\u76f4\u63a5\u56de\u7b54\uff0c\u4e0d\u82b1\u65f6\u95f4\u601d\u8003\u3002",
        "model_control_reasoning_note_automatic" to "\u7531\u6a21\u578b\u81ea\u5df1\u51b3\u5b9a\u3002",
        "model_control_reasoning_note_fast" to "\u7b80\u5355\u95ee\u9898\uff0c\u51e0\u79d2\u51fa\u7ed3\u679c\u3002",
        "model_control_reasoning_note_balanced" to "\u901f\u5ea6\u548c\u6df1\u5ea6\u517c\u987e\u3002",
        "model_control_reasoning_note_deep" to "\u590d\u6742\u95ee\u9898\uff0c\u591a\u60f3\u4e00\u4f1a\u513f\u3002",
        "model_control_reasoning_note_max" to "\u6700\u96be\u7684\u95ee\u9898\uff0c\u4e0d\u60dc\u65f6\u95f4\u3002",
    )

    /** Entry point / parameter screen naming. */
    private val frozenEntryNamesZhHans = mapOf(
        "model_controls" to "\u6a21\u578b\u9009\u9879",
        "generation_model_behavior" to "\u9ad8\u7ea7\u8bbe\u7f6e",
    )

    private val resourceRoot = File("src/main/res")

    /** The intent set must come from the shared contract, not a local list -- a local list is exactly how the wording drifts. */
    @Test
    fun `the reasoning ladder face comes from the shared contract`() {
        val contract = json.parseToJsonElement(
            workspaceFile("shared/model-contracts/request_shape_contract.v2.json").readText(),
        ).jsonObject
        val intents = contract["reasoningIntents"]!!.jsonObject["values"]!!.jsonArray
            .map { it.jsonPrimitive.content }
        assertEquals(listOf("off", "low", "balanced", "deep", "max"), intents)
        // Every intent must own its own string resource; no two tiers may share one (that would show the user two "deep" tiers).
        val byIntent = intents.associateWith(::intentLabelRes)
        assertEquals("the five tiers must map to five distinct resources", 5, byIntent.values.toSet().size)
        byIntent.forEach { (intent, res) ->
            assertNotEquals("$intent fell through to the \"automatic\" fallback", R.string.model_control_supplier_default, res)
        }
        // The layout's render order is exactly the contract's five tiers, no more, no less ("automatic" is a pseudo-intent, not part of this table).
        assertEquals(intents, ModelControlReasoningLayout.tierOrder)
        assertEquals(
            "\"automatic\" is a pseudo-intent and must not leak into the wire-level enum",
            R.string.model_control_supplier_default,
            intentLabelRes(ModelControlReasoningLayout.AUTOMATIC_INTENT),
        )

        val webIntents = contract["webIntents"]!!.jsonObject["values"]!!.jsonArray
            .map { it.jsonPrimitive.content }
        assertEquals(listOf("force"), webIntents)
    }

    /** The zh-Hans wording is byte-identical to the frozen table. */
    @Test
    fun `the frozen simplified chinese wording is exactly what ships`() {
        val zh = strings(File(resourceRoot, "values-zh-rCN/strings.xml"))
        frozenReasoningZhHans.forEach { (intent, expected) ->
            assertEquals("reasoning $intent", expected, zh[resourceName(intentLabelRes(intent))])
        }
        frozenWebZhHans.forEach { (intent, expected) ->
            val key = when (intent) {
                "off" -> "model_control_off"
                "automatic" -> "model_control_web_search_when_needed"
                else -> "model_control_web_search_every_message"
            }
            assertEquals("web search $intent", expected, zh[key])
        }
        assertEquals(automaticZhHans, zh["model_control_supplier_default"])
        frozenTierNotesZhHans.forEach { (key, expected) -> assertEquals("tier note $key", expected, zh[key]) }
        frozenEntryNamesZhHans.forEach { (key, expected) -> assertEquals("entry name $key", expected, zh[key]) }
    }

    /**
     * Byte-identical to the web build. Each platform hand-writing its own expected value would be
     * no lock at all, so this reads the web build's `messages/zh-Hans.json` directly -- it and the
     * Android resource must be the exact same string.
     */
    @Test
    fun `simplified chinese tier wording is byte-identical to the web build`() {
        val messages = json.parseToJsonElement(
            workspaceFile("web/apps/app/messages/zh-Hans.json").readText(),
        ).jsonObject
        val web = messages["pages"]!!.jsonObject["chat"]!!.jsonObject["reasoning"]!!.jsonObject
        val common = messages["common"]!!.jsonObject
        fun webText(key: String) = web[key]!!.jsonPrimitive.content
        fun commonText(key: String) = common[key]!!.jsonPrimitive.content

        val zh = strings(File(resourceRoot, "values-zh-rCN/strings.xml"))
        assertEquals(webText("fast"), zh["reasoning_fast"])
        assertEquals(webText("balanced"), zh["reasoning_balanced"])
        assertEquals(webText("deep"), zh["reasoning_deep"])
        assertEquals(webText("max"), zh["reasoning_max"])
        assertEquals(webText("off"), zh["model_control_off"])
        // The "supplierDefault" slot holds the "automatic" wording; the two web-search timing words
        // live on the web build's `auto` / `force` slots and Android's two matching resources, and
        // both platforms must still agree word-for-word.
        assertEquals(webText("supplierDefault"), zh["model_control_supplier_default"])
        assertEquals(webText("auto"), zh["model_control_web_search_when_needed"])
        assertEquals(webText("force"), zh["model_control_web_search_every_message"])
        assertEquals(commonText("modelControls"), zh["model_controls"])
        assertEquals(commonText("modelBehavior"), zh["generation_model_behavior"])
        mapOf(
            "model_control_reasoning_note_off" to "capabilityControlReasoningNoteOff",
            "model_control_reasoning_note_automatic" to "capabilityControlReasoningNoteAutomatic",
            "model_control_reasoning_note_fast" to "capabilityControlReasoningNoteFast",
            "model_control_reasoning_note_balanced" to "capabilityControlReasoningNoteBalanced",
            "model_control_reasoning_note_deep" to "capabilityControlReasoningNoteDeep",
            "model_control_reasoning_note_max" to "capabilityControlReasoningNoteMax",
        ).forEach { (androidKey, webKey) -> assertEquals(androidKey, commonText(webKey), zh[androidKey]) }
    }

    /** All sixteen locales are present, and no non-default locale is left holding the English default value. */
    @Test
    fun `every model control string has all sixteen locales`() {
        val keys = listOf(
            "reasoning_fast", "reasoning_balanced", "reasoning_deep", "reasoning_max",
            "model_control_off",
            "model_control_supplier_default",
            "model_control_reasoning_off_unavailable",
            "generation_parameter_class_unverified",
            "generation_parameter_class_not_adjustable",
            "generation_parameter_class_no_data",
            "generation_parameter_detail_accepted_unverified",
            "generation_parameter_detail_fixed",
            "generation_parameter_detail_unsupported",
            "generation_parameter_detail_mode_dependent",
            "generation_parameter_detail_unknown",
            "generation_parameter_detail_future_supported",
            "model_picker_filter_web",
            "model_picker_filter_reasoning",
            "model_picker_capability_filter_empty",
            // Panel title, status line, tier notes, managed banner, scope-upgrade row, developer
            // section -- the wording that underpins the current panel layout.
            "model_control_web_search",
            "model_control_thinking",
            "model_control_web_switch_note",
            "model_control_web_search_when_needed",
            "model_control_web_search_every_message",
            "model_control_not_supported_by_model",
            "model_control_web_no_official_config",
            "model_control_reasoning_note_off",
            "model_control_reasoning_note_automatic",
            "model_control_reasoning_note_fast",
            "model_control_reasoning_note_balanced",
            "model_control_reasoning_note_deep",
            "model_control_reasoning_note_max",
            "model_control_reasoning_fixed_level",
            "model_control_cannot_adjust_yet",
            "model_control_reasoning_no_official_config",
            "model_control_applied_to_conversation",
            "model_control_set_as_model_default",
            "model_control_model_default_saved",
            "model_control_go_to_advanced_settings",
            "model_control_custom_field_not_allowed",
            "model_control_custom_fields_footer",
            "model_control_custom_scope_conversation",
            "model_control_custom_scope_connection_model",
            "model_control_custom_delete_conversation",
            "model_control_custom_delete_connection",
            "model_control_custom_fields_active_note",
            "model_control_custom_only_reason",
            "model_control_state_not_ready",
            "model_control_state_unavailable",
            "model_control_advanced_settings_subtitle",
            // Carried over verbatim from the iOS string catalog.
            "model_control_capability_unavailable_here",
            "model_control_upstream_rejected",
            "model_control_state_manual",
            "model_control_state_custom",
            "model_control_status_pending",
            "model_control_status_unknown_route",
            "model_control_status_automatic_available",
            "model_control_fetch_again",
            "model_control_fetching",
            "model_control_set_protocol",
            "model_control_refresh_failed",
            "model_control_identity_snapshot_missing",
            "model_control_identity_relay_transport_undecided",
            "model_control_identity_model_not_in_catalog",
            "model_control_supported_models_header",
            "model_control_switch_to_model",
            "skill_capability_confirm_note",
            "generation_parameter_developer",
            "generation_parameter_custom_fields_not_in_use",
            "generation_parameter_custom_fields_in_use",
            "generation_parameter_custom_fields_requires_schema",
            "generation_parameter_temperature_note",
            "generation_parameter_max_tokens_note",
            "generation_parameter_unset_note",
            // Empty-state hint and the three rejection reasons for the custom field editor.
            "model_control_custom_json_placeholder",
            "model_control_custom_invalid_json",
            "model_control_custom_too_large",
            "model_control_custom_conflicts_managed",
        )
        val default = strings(File(resourceRoot, "values/strings.xml"))
        keys.forEach { key -> assertTrue("missing default value: $key", !default[key].isNullOrBlank()) }

        // A handful of Latin locales legitimately keep "Manual" identical to English (verified for
        // es / id / pt-BR) -- that is a correct translation, not a missed one. Listing them
        // explicitly keeps "identical to English" a judged conclusion rather than a free pass
        // anyone can add.
        val identicalByDesign = mapOf(
            "model_control_state_manual" to setOf("values-es", "values-in", "values-pt-rBR"),
        )
        val localeDirs = resourceRoot.listFiles().orEmpty()
            .filter { it.isDirectory && it.name.startsWith("values-") && File(it, "strings.xml").exists() }
        assertEquals("15 locale directories plus the default values = 16", 15, localeDirs.size)
        localeDirs.forEach { dir ->
            val table = strings(File(dir, "strings.xml"))
            keys.forEach { key ->
                val value = table[key]
                assertTrue("${dir.name} is missing $key", !value.isNullOrBlank())
                if (dir.name in identicalByDesign[key].orEmpty()) {
                    assertEquals("${dir.name}'s $key no longer matches English; remove it from the exemption list", default[key], value)
                } else {
                    assertNotEquals("${dir.name}'s $key is still the English default", default[key], value)
                }
            }
        }

        // The check above only asks "is it not the English default", which let a subtler defect
        // survive -- the rejection copy splits into grammar / size / conflict in English, but all
        // fifteen non-English locales collapsed onto the same generic sentence (inherited verbatim
        // from the same defect in the iOS string catalog). Each string looked translated and
        // non-English on its own, so the check passed, yet non-English users always saw the same
        // sentence and the three-way distinction didn't exist for them. The real judgment is that
        // semantically different sentences must stay distinct within the same locale.
        val mustDifferPerLocale = listOf(
            "model_control_custom_json_placeholder",
            "model_control_custom_invalid_json",
            "model_control_custom_too_large",
            "model_control_custom_conflicts_managed",
        )
        (localeDirs.map { it.name to strings(File(it, "strings.xml")) } + ("values" to default))
            .forEach { (name, table) ->
                val seen = mutableMapOf<String, String>()
                mustDifferPerLocale.forEach { key ->
                    val value = table.getValue(key)
                    assertTrue("$name's $key matches ${seen[value]}'s translation; the distinction is invisible", seen[value] == null)
                    seen[value] = key
                }
            }

        // Retired strings must be removed from all sixteen locales: production never keeps
        // abandoned entries, since keeping them makes the next reader assume the old layout is
        // still live and revert the panel back to it.
        val retired = listOf(
            "model_control_reasoning_switch", "model_control_reasoning_off_note",
            "model_control_tier_cost_note", "model_control_tier_needs_recipe",
            "model_control_web_auto_expectation", "model_control_fixed_tier",
            "model_control_force", "model_control_automatic", "model_control_unknown",
            "model_control_unavailable", "model_control_custom_only",
            "model_control_reason_relay_directory", "model_control_reason_route_pending",
            "model_control_reason_not_supported", "model_control_reason_pending_review",
            "model_control_review_connection", "model_control_preferences_unavailable",
            "model_control_customized", "model_control_no_custom_fields",
            "model_control_request_field_editor", "model_control_automatic_configuration",
            "model_control_apply_custom",
            "model_control_custom_scope_privacy", "model_control_view_supported_models_hint",
            "model_control_search_timing",
            "model_control_free_managed_description", "model_control_ai_managed_description",
            // The old global toggle pair and the previous editor's single-line hint / single-line
            // invalid message / single-line preview were retired together. `model_control_custom_request_fields`
            // is deliberately not in this list -- it now titles the custom fields screen and its
            // entry row (matching the iOS "Custom request fields" wording verbatim), so removing it
            // would leave that screen without a name.
            "model_control_developer_fields", "model_control_developer_fields_global_hint",
            "model_control_custom_json_hint", "model_control_redacted_delta",
            "model_control_custom_invalid",
        )
        (localeDirs.map { it.name to strings(File(it, "strings.xml")) } + ("values" to default))
            .forEach { (name, table) ->
                retired.forEach { key ->
                    assertTrue("$name still has the retired $key", table[key] == null)
                }
            }

        // A retired word must not just disappear from its own key -- it must not linger inside
        // another key's translation either. The web-search wording moved to "search when needed" /
        // "search every message", but `model_control_force_unavailable`'s zh value kept saying the
        // old wording -- the same value had two names on the panel, and the user reads two concepts.
        val retiredWordings = mapOf(
            "values-zh-rCN" to listOf("\u6bcf\u6b21\u90fd\u7528"),
            "values-zh-rTW" to listOf("\u6bcf\u6b21\u90fd\u7528"),
        )
        retiredWordings.forEach { (dir, words) ->
            val table = strings(File(File(resourceRoot, dir), "strings.xml"))
            words.forEach { word ->
                val offenders = table.filterValues { it.contains(word) }.keys
                assertEquals("$dir still uses the retired wording \"$word\"", emptySet<String>(), offenders)
            }
        }

        // These zh values were pinned by an explicit decision; don't let them drift back to the old wording.
        val zhCN = strings(File(File(resourceRoot, "values-zh-rCN"), "strings.xml"))
        assertEquals("\u5df2\u8c03\u6574 %1\$d \u9879", zhCN["model_control_behavior_adjusted"])
        assertEquals("\u8fd9\u4e2a\u6a21\u578b\u65e0\u6cd5\u5173\u95ed\u601d\u8003\u3002", zhCN["model_control_reasoning_off_unavailable"])
        // The two delete-confirmation sentences share one pattern; mixing "this removes ... and
        // cannot be undone" with "this deletes ... this action cannot be undone" on the same screen
        // would read like two different severities for the same kind of action.
        listOf("model_control_custom_delete_conversation", "model_control_custom_delete_connection").forEach { key ->
            val value = zhCN.getValue(key)
            assertTrue("$key has an inconsistent pattern: $value", value.startsWith("\u8fd9\u4f1a\u79fb\u9664") && value.endsWith("\uff0c\u4e14\u65e0\u6cd5\u64a4\u9500\u3002"))
        }

        // Filter chips with a count must not lose their placeholder in translation, or it throws a format exception at runtime.
        (localeDirs.map { strings(File(it, "strings.xml")) } + default).forEach { table ->
            listOf("model_picker_filter_web", "model_picker_filter_reasoning").forEach { key ->
                assertTrue("$key lost its count placeholder", table.getValue(key).contains("%1\$d"))
            }
        }
    }

    /**
     * Production never keeps abandoned entries: every `model_control_*` / `generation_*` key must
     * have a production reference.
     *
     * The `retired` table above is a manual list, and manual lists only catch what someone
     * remembered to add. What actually slips through is the other half: a layout change quietly
     * stops rendering some key while its sixteen translations stay on disk -- the next reader sees
     * them and assumes that layout is still current, then reverts the UI to match it. This
     * assertion is the automatic complement to that manual list: whoever removes the last reference
     * to a key must decide, in the same change, whether to delete the string or restore its
     * rendering.
     */
    @Test
    fun `every model control string is actually referenced by production code`() {
        val keys = Regex("""<(?:string|string-array|plurals) name="((?:model_control_|generation_)[^"]+)"""")
            .findAll(File(resourceRoot, "values/strings.xml").readText())
            .map { it.groupValues[1] }
            .toSortedSet()
        assertTrue("found none at all, the key-extraction regex needs fixing", keys.size > 100)

        val sources = File(resourceRoot.parentFile, "java").walkTopDown()
            .filter { it.isFile && it.extension == "kt" }
            .map { it.readText() }
            .toList() +
            // References in layouts / menus / values count too (arrays can stash a key elsewhere).
            resourceRoot.walkTopDown()
                .filter { it.isFile && it.extension == "xml" }
                .map { it.readText() }
                .toList()

        val unreferenced = keys.filter { key ->
            val rx = Regex("""(R\.string\.|@string/)${Regex.escape(key)}(?![A-Za-z0-9_])""")
            sources.none { rx.containsMatchIn(it) }
        }
        assertEquals(
            "these strings have no production reference: either restore their rendering (copy what iOS renders) or delete them from all sixteen locales",
            emptyList<String>(),
            unreferenced,
        )
    }

    /** Resource id to resource name. There's no `Resources` object in the test environment, so look up the `R` field name instead. */
    private fun resourceName(id: Int): String =
        R.string::class.java.fields.first { it.getInt(null) == id }.name

    private fun strings(file: File): Map<String, String> =
        Regex("""<string name="([^"]+)"[^>]*>(.*?)</string>""", RegexOption.DOT_MATCHES_ALL)
            .findAll(file.readText())
            .associate { it.groupValues[1] to it.groupValues[2] }

    private fun workspaceFile(relative: String): File {
        var dir: File? = File("").absoluteFile
        while (dir != null) {
            val candidate = File(dir, relative)
            if (candidate.exists()) return candidate
            dir = dir.parentFile
        }
        throw IllegalStateException("cannot find $relative")
    }
}
