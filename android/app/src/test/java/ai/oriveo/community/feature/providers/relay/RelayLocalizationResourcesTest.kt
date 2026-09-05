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
        "relay_default_model_placeholder",
        "relay_advanced_service_tier_placeholder",
        "relay_image_tool_model_placeholder",
        "relay_image_output_format_png",
        "relay_image_output_format_jpeg",
        // Contains a brand name plus technical terms; some locales (e.g. hi) intentionally keep the English original
        "relay_kind_codex_style",
        // API endpoint / protocol brand name -- kept in English in every locale, per this project's convention of leaving industry terms untranslated
        "relay_family_claude_messages",
        "relay_family_codex_chat",
        "relay_family_codex_responses",
        "relay_family_gemini_generate",
        "relay_transport_anthropic_messages",
        "relay_transport_gemini_generate_content",
        "relay_transport_openai_chat_completions",
        "relay_transport_openai_responses",
        // The "Model" label actually consumed by the production form is a borrowed English word in Indonesian and Turkish.
        "relay_default_model_label",
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
        assertEquals("Add Custom Relay", english["relay_setup_page_title"])
        assertEquals("Connection security", english["relay_security_mode_label"])
        assertEquals(
            "Connect your own model service.",
            english["provider_setup_relay_subtitle"],
        )
        assertEquals(
            "Connect your own model service, or local & LAN compute.",
            english["provider_setup_relay_description"],
        )
        assertEquals("Invalid request URL", english["relay_setup_invalid_endpoint_title"])
        assertEquals("Enter a request URL.", english["relay_no_endpoint_set"])
        // The parameters page was renamed from "Model Behavior" to "Advanced Settings"; iOS
        // reuses the `Advanced Settings` key, and Android carries the new wording under the
        // same resource name.
        assertEquals("Advanced Settings", english["generation_model_behavior"])
    }

    @Test
    fun `max tokens guidance uses localized model behavior title`() {
        (listOf("values") + locales).forEach { valuesDir ->
            val strings = parseStrings(valuesDir)
            val modelBehaviorTitle = strings.getValue("generation_model_behavior")
            assertTrue(
                "$valuesDir max_tokens guidance must use the localized Model Behavior title",
                strings.getValue("relay_guidance_max_tokens_required").contains(modelBehaviorTitle),
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
        assertTrue(source.contains("R.string.provider_setup_relay_title"))
        assertTrue(source.contains("R.string.local_compute_title"))
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
