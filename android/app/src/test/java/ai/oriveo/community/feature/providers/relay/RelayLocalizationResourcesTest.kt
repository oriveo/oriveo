package ai.oriveo.community.feature.providers.relay

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import org.w3c.dom.Element
import java.io.File
import javax.xml.parsers.DocumentBuilderFactory

class RelayLocalizationResourcesTest {

    private val allowedEnglishTemplateKeys = setOf(
        "relay_endpoint_placeholder",
        "relay_api_key_placeholder",
        "relay_advanced_service_tier_placeholder",
        "relay_image_tool_model_placeholder",
        "relay_image_output_format_png",
        "relay_image_output_format_jpeg",
        // API endpoint / protocol brand name -- kept in English in every locale, per this project's convention of leaving industry terms untranslated
        "relay_family_claude_messages",
        "relay_family_codex_chat",
        "relay_family_codex_responses",
        "relay_family_gemini_generate",
        "relay_transport_anthropic_messages",
        "relay_transport_gemini_generate_content",
        "relay_transport_openai_chat_completions",
        "relay_transport_openai_responses",
        // German uses the loanword "Tools", identical to English.
        "relay_capability_test_tool",
        // The "Model" label actually consumed by the production form is a borrowed English word in Indonesian and Turkish.
        "relay_default_model_label",
        // Capability test panel: strings that are pure placeholders or protocol names look the same in every
        // language, and Chinese uses "s" for seconds just like English.
        "relay_cap_test_progress",
        "relay_cap_test_reason_http",
        "relay_cap_test_elapsed",
        "relay_cap_test_elapsed_running",
        // Key status: French "Active" (clé active) is identical to English.
        "relay_key_status_ok",
        // Default avatar icon name: French "Satellite" is spelled the same as English.
        "relay_avatar_icon_satellite",
        // Edit connection (taken verbatim from the iOS final copy): User-Agent is an HTTP header name, identical
        // in every language; "Headers" is a loanword in es / pt-BR.
        "relay_edit_user_agent",
        // The auth option name is the literal HTTP header name x-api-key, identical in every language (same as the iOS option name).
        "relay_auth_x_api_key",
        // The auth scheme name Bearer is the literal HTTP auth scheme name; with the English value set to "Bearer"
        // it is identical in every language (same as iOS).
        "relay_auth_bearer",
        "relay_edit_headers",
    )

    private val locales = listOf(
        "values-zh-rCN",
        "values-zh-rTW",
        "values-ja",
        "values-ko",
        "values-es",
        "values-fr",
        "values-de",
        "values-pt-rBR",
        "values-ar",
        "values-hi",
        "values-in",
        "values-vi",
        "values-th",
        "values-tr",
        "values-ru",
    )

    private val resDir: File by lazy {
        var dir = File(System.getProperty("user.dir") ?: ".")
        repeat(8) {
            val candidate = File(dir, "app/src/main/res")
            if (File(candidate, "values/strings.xml").exists()) return@lazy candidate
            dir = dir.parentFile ?: return@repeat
        }
        error("Cannot find Android res directory from ${System.getProperty("user.dir")}")
    }

    private fun parseStrings(valuesDir: String): Map<String, String> {
        val file = File(resDir, "$valuesDir/strings.xml")
        val doc = DocumentBuilderFactory.newInstance().newDocumentBuilder().parse(file)
        val nodeList = doc.getElementsByTagName("string")
        val map = mutableMapOf<String, String>()
        for (i in 0 until nodeList.length) {
            val element = nodeList.item(i) as Element
            // The DOM read gives the raw XML source text; restore it to the displayed value per Android string-resource rules before comparing against the golden values.
            map[element.getAttribute("name")] = element.textContent.replace("\\'", "'")
        }
        return map
    }

    @Test
    fun `relay strings are localized in every supported android locale`() {
        val english = parseStrings("values")
        // Same coverage as this project's UI-term audit: some legacy resources have "relay" in
        // the middle of the key, and use_exact_model_id doesn't carry the entity name in its key
        // even though its value belongs to this module.
        val managedKey = Regex("(?:relay|custom_llm)|^use_exact_model_id$")
        val requiredLocalizedKeys = english.keys
            .filter { managedKey.containsMatchIn(it) || it == "local_compute_error_cleartext_credentials" }
            .sorted()
        val failures = mutableListOf<String>()

        if (requiredLocalizedKeys.isEmpty()) {
            failures += "English values file does not define any relay_* strings"
        }

        for (valuesDir in locales) {
            val localized = parseStrings(valuesDir)
            for (key in requiredLocalizedKeys) {
                val value = localized[key]
                if (value == null) {
                    failures += "$valuesDir missing $key"
                    continue
                }
                if (value.isBlank()) {
                    failures += "$valuesDir has blank $key"
                }
                if ("ZXPH" in value) {
                    failures += "$valuesDir still contains ZXPH in $key: $value"
                }
                val englishValue = english[key]
                if (
                    englishValue != null &&
                    englishValue == value &&
                    key !in allowedEnglishTemplateKeys
                ) {
                    failures += "$valuesDir still uses English template for $key: $value"
                }
            }
        }

        assertTrue(
            "Relay localization regressions found:\n${failures.joinToString("\n")}",
            failures.isEmpty(),
        )
    }

    @Test
    fun `relay setup product copy is aligned with iOS`() {
        val english = parseStrings("values")
        assertEquals("Custom Relay", english["provider_setup_relay_title"])
        assertEquals("Connection security", english["relay_security_mode_label"])
        assertEquals(
            "Connect your own model service.",
            english["provider_setup_relay_subtitle"],
        )
        assertEquals("Enter a request URL.", english["relay_no_endpoint_set"])
        // The parameters page is now named "Parameters"; all three platforms reuse their existing Parameters key.
        assertEquals("Parameters", english["generation_parameters_section"])
    }

    /**
     * Guidance sentences must name UI labels exactly as this platform renders them (letter case may
     * vary with the position in the sentence). The relay rate-limit guidance and the unreferenced
     * legacy web search tool hints have been removed.
     */
    @Test
    fun `relay guidance names the same ui labels android renders`() {
        val named = mapOf(
            "relay_guidance_codex_identity_switch_type" to listOf("model_library", "relay_model_advanced_title", "relay_advanced_transport"),
            "relay_guidance_codex_identity_still_rejected" to listOf("relay_detail_edit_connection", "relay_section_headers_query"),
            "relay_guidance_images_endpoint_unavailable" to listOf("model_library", "relay_model_advanced_title", "relay_advanced_transport"),
            "relay_guidance_responses_only_endpoint" to listOf("model_library", "relay_model_advanced_title", "relay_advanced_transport"),
            "relay_guidance_model_not_offered" to listOf("model_library"),
            "relay_guidance_responses_protocol_required" to listOf("model_library", "relay_model_advanced_title", "relay_advanced_transport"),
            "relay_guidance_store_param_rejected" to listOf("relay_detail_edit_connection", "relay_section_request_behavior", "relay_disable_response_storage_short"),
            "relay_guidance_service_tier_invalid" to listOf("relay_detail_edit_connection", "relay_section_request_behavior", "relay_advanced_service_tier"),
            "relay_guidance_max_tokens_required" to listOf("generation_parameters_section", "max_tokens"),
            "relay_guidance_anthropic_auth_header" to listOf("relay_detail_edit_connection", "relay_advanced_auth_mode"),
            "relay_guidance_image_schema_mismatch" to listOf("model_library", "relay_model_advanced_title", "relay_advanced_transport"),
            "relay_guidance_client_gated" to listOf("relay_keys_title"),
        )
        (listOf("values") + locales).forEach { valuesDir ->
            val strings = parseStrings(valuesDir)
            named.forEach { (guidanceKey, labelKeys) ->
                val guidance = strings[guidanceKey]
                assertTrue("$valuesDir is missing $guidanceKey", guidance != null)
                labelKeys.forEach { labelKey ->
                    val label = strings.getValue(labelKey)
                    assertTrue(
                        "$valuesDir $guidanceKey should name $labelKey \"$label\": $guidance",
                        guidance!!.contains(label, ignoreCase = true),
                    )
                }
            }
            assertTrue("$valuesDir is missing the web page sentence", strings.containsKey("relay_guidance_web_page_returned"))
            assertTrue("$valuesDir is missing the image parameter sentence", strings.containsKey("relay_guidance_image_response_format_rejected"))
            listOf(
                "relay_guidance_rate_limited",
                "relay_web_search_tool_hint_default",
                "relay_web_search_tool_hint_legacy",
                "relay_web_search_tool_hint_disabled",
                "relay_web_search_tool_disabled",
            ).forEach { removed -> assertTrue("$valuesDir still has $removed", !strings.containsKey(removed)) }
        }
    }

    @Test
    fun `max tokens guidance uses localized parameters title`() {
        (listOf("values") + locales).forEach { valuesDir ->
            val strings = parseStrings(valuesDir)
            val parametersTitle = strings.getValue("generation_parameters_section")
            assertTrue(
                "$valuesDir max_tokens guidance must use the localized Parameters title",
                strings.getValue("relay_guidance_max_tokens_required").contains(parametersTitle),
            )
        }
    }

    @Test
    fun `setup page does not repeat the scenario choice after the user selects an entry`() {
        val source = File(
            "src/main/java/ai/oriveo/community/feature/providers/relay/RelaySetupScreen.kt",
        ).readText()

        assertTrue(!source.contains("SingleChoiceSegmentedButtonRow("))
        assertTrue(!source.contains("R.string.custom_llm_connection_method"))
        assertTrue(!source.contains("RelaySecurityModeControl("))
        // With manual setup merged into one page the top bar carries no title; the only page title is the Hero
        // (shared by quick setup and manual setup).
        assertTrue(!source.contains("R.string.provider_setup_relay_title"))
        assertTrue(source.contains("stringResource(board.heroTitle)"))
        // The new-page board: the top bar no longer shows the local title; the only page title is the Hero
        // (supplied by board.heroTitle).
        assertTrue(!source.contains("R.string.local_compute_title"))
        val localSource = File(
            "src/main/java/ai/oriveo/community/feature/providers/local/LocalComputeSetupScreen.kt",
        ).readText()
        assertTrue(localSource.contains("stringResource(board.heroTitle)"))
    }

    /**
     * Pending copy cleanup: legacy strings with no production reference are deleted in every locale;
     * the ones still referenced take the iOS sentence (16 languages, verbatim); the footnote under
     * the step 1 address row is dropped to follow iOS.
     */
    @Test
    fun `dead relay strings are gone and referenced ones take the iOS sentence`() {
        val deleted = listOf(
            "provider_setup_relay_description",
            "relay_api_key_privacy",
            "relay_default_model_recommended_footnote",
            "relay_quick_detected",
            "relay_quick_failed",
            "relay_quick_probe_protocol",
            "relay_request_url_footnote",
            "error_relay_upstream_title",
        )
        val expectedEnglish = mapOf(
            "provider_detail_relay_empty_description" to "No models added yet. Use the button below to add model IDs.",
            "relay_quick_rate_limited" to
                "The service at this address is rate limiting requests. Wait a moment and try again; Oriveo didn't switch to another key or protocol.",
            "relay_quick_temporary_failure" to "Couldn't connect to this address reliably. Check the address and try again.",
            "relay_quick_network_failure" to "Couldn't connect to this address reliably. Check the address and try again.",
        )
        val expectedChinese = mapOf(
            "provider_detail_relay_empty_description" to "\u8fd8\u6ca1\u6709\u6dfb\u52a0\u6a21\u578b\u3002\u4f7f\u7528\u4e0b\u65b9\u6309\u94ae\u6dfb\u52a0\u6a21\u578b ID\u3002",
            "relay_quick_rate_limited" to "\u8fd9\u4e2a\u5730\u5740\u4e0a\u7684\u670d\u52a1\u6b63\u5728\u9650\u6d41\u3002\u8bf7\u7a0d\u540e\u91cd\u8bd5\uff1bOriveo \u6ca1\u6709\u81ea\u52a8\u6362\u7528\u5176\u4ed6\u5bc6\u94a5\u6216\u534f\u8bae\u3002",
            "relay_quick_network_failure" to "\u65e0\u6cd5\u7a33\u5b9a\u8fde\u63a5\u5230\u8fd9\u4e2a\u5730\u5740\u3002\u8bf7\u68c0\u67e5\u5730\u5740\u540e\u91cd\u8bd5\u3002",
        )
        val english = parseStrings("values")
        expectedEnglish.forEach { (key, value) -> assertEquals(key, value, english[key]) }
        val chinese = parseStrings("values-zh-rCN")
        expectedChinese.forEach { (key, value) -> assertEquals(key, value, chinese[key]) }
        (listOf("values") + locales).forEach { valuesDir ->
            val strings = parseStrings(valuesDir)
            deleted.forEach { key -> assertTrue("$valuesDir still has $key", key !in strings) }
            expectedEnglish.keys.forEach { key -> assertTrue("$valuesDir is missing $key", !strings[key].isNullOrBlank()) }
        }
        // Terminology gate: the Arabic "client gated" guidance uses "حوّل" rather than "انقل" (changed the same way on iOS / Web).
        val arabicGated = parseStrings("values-ar").getValue("relay_guidance_client_gated")
        assertTrue(arabicGated, "حوّل المفتاح إلى مجموعة" in arabicGated && "انقل المفتاح" !in arabicGated)
        val setupSource = File("src/main/java/ai/oriveo/community/feature/providers/relay/RelaySetupScreen.kt").readText()
        assertTrue("the step 1 address row no longer has a footnote", "relay_request_url_footnote" !in setupSource)
    }

    @Test
    fun `two step setup no longer points the empty catalog sentence at a model field above`() {
        val source = File(
            "src/main/java/ai/oriveo/community/feature/providers/relay/RelaySetupScreen.kt",
        ).readText()
        // The step 2 empty state uses relay_setup_models_empty; the "Enter a model above" direction no longer holds.
        assertTrue(!source.contains("R.string.relay_quick_empty_catalog"))
        assertTrue(source.contains("R.string.relay_setup_models_empty"))
    }

    @Test
    fun `local compute release surface hides pairing until the desktop producer ships`() {
        val source = File(
            "src/main/java/ai/oriveo/community/feature/providers/local/LocalComputeSetupScreen.kt",
        ).readText()

        assertTrue(source.contains("LocalComputeSetupFields("))
        assertTrue(!source.contains("R.string.local_compute_pairing_code"))
        assertTrue(!source.contains("R.string.local_compute_scan_qr"))
        assertTrue(!source.contains("viewModel.applyPairingCode"))
        assertTrue(!source.contains("GmsBarcodeScanning"))

        // Having no call site in the source isn't enough: as long as the play-services-code-scanner
        // dependency is still present, manifest merge pulls GmsBarcodeScanningDelegateActivity into
        // the APK, and it has crashed in production when launched directly by an external caller
        // (ActivityNotFoundException, on devices missing that GMS module). The dependency was
        // removed together with the scan-code entry point; this guards against it coming back.
        // initialize=false only checks whether the class is on the classpath, without triggering
        // static initialization.
        assertTrue(
            "play-services-code-scanner dependency is back: it would bring GmsBarcodeScanningDelegateActivity back into the APK.",
            runCatching {
                Class.forName(
                    "com.google.mlkit.vision.codescanner.internal.GmsBarcodeScanningDelegateActivity",
                    false,
                    javaClass.classLoader,
                )
            }.isFailure,
        )
    }
}
