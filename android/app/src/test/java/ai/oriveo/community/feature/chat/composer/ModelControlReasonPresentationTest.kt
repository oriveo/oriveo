package ai.oriveo.community.feature.chat.composer

import ai.oriveo.community.core.provider.CapabilityControlPresentation
import java.io.File
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class ModelControlReasonPresentationTest {

    private fun status(state: String?, reasonCode: String? = null, exact: Boolean = true) =
        CapabilityControlPresentation.status(state, reasonCode, exactTransportMatches = exact)

    @Test
    fun `server state stays primary and reason codes only refine it`() {
        assertEquals(CapabilityControlPresentation.AutomaticAvailable, status("auto_available"))

        assertEquals(CapabilityControlPresentation.Unknown, status("auto_available", exact = false))

        assertEquals(CapabilityControlPresentation.CustomOnly, status("custom_only", "transport_not_supported"))
        assertEquals(CapabilityControlPresentation.CustomOnly, status("custom_only", "future_reason_code"))
    }

    @Test
    fun `pending is a read only sub state of unknown and never becomes unavailable`() {
        listOf(
            "endpoint_route_pending", "model_route_pending", "official_source_insufficient",
            "source_review_expired", "provider_kill_switch",
        ).forEach { code ->
            assertEquals(code, CapabilityControlPresentation.Pending, status("unknown", code))
        }
        assertEquals(CapabilityControlPresentation.Unknown, status("unknown", "relay_user_directory"))
        assertEquals(CapabilityControlPresentation.Unknown, status("unknown", "future_server_code"))
        assertEquals(CapabilityControlPresentation.Unknown, status(null))
        assertEquals(CapabilityControlPresentation.Unknown, status("something_new"))
        listOf("endpoint_route_pending", "provider_kill_switch", "future_server_code").forEach { code ->
            assertNotEquals(CapabilityControlPresentation.Unsupported, status("unknown", code))
        }
    }

    @Test
    fun `external connector only stays distinct from plain unsupported`() {
        assertEquals(
            CapabilityControlPresentation.ExternalConnectorOnly,
            status("unavailable", "external_connector_only"),
        )
        listOf(
            "no_official_managed_search", "model_capability_absent", "transport_not_supported",
            "retired_model_alias", "upstream_parameter_not_declared", null,
        ).forEach { code ->
            assertEquals(code.toString(), CapabilityControlPresentation.Unsupported, status("unavailable", code))
        }
        assertNotEquals(
            modelControlStatusTextRes(CapabilityControlPresentation.ExternalConnectorOnly),
            modelControlStatusTextRes(CapabilityControlPresentation.Unsupported),
        )

        listOf("relay_user_directory", "official_source_insufficient", "provider_kill_switch").forEach { code ->
            assertEquals(CapabilityControlPresentation.Unsupported, status("unavailable", code))
        }
    }

    @Test
    fun `unknown remains configurable while every genuinely blocked state does not`() {
        listOf(
            CapabilityControlPresentation.AutomaticAvailable,
            CapabilityControlPresentation.ForceUnsupported,
            CapabilityControlPresentation.Unknown,
        ).forEach { assertTrue("$it", it.isConfigurable) }
        listOf(
            CapabilityControlPresentation.CustomOnly,
            CapabilityControlPresentation.Pending,
            CapabilityControlPresentation.ExternalConnectorOnly,
            CapabilityControlPresentation.Unsupported,
        ).forEach { assertFalse("$it", it.isConfigurable) }
    }

    @Test
    fun `capability action strings have complete non-English locale parity`() {
        val keys = listOf(
            "model_control_view_supported_models",
            "model_control_no_supported_models",
            "model_control_switch_model_hint",
            "model_control_supported_models_header",
            "model_control_switch_to_model",
            "model_control_reason_external_connector_only",
            "model_control_capability_unavailable_here",
            "model_control_upstream_rejected",
        )
        val resourceRoot = File("src/main/res")
        val default = strings(File(resourceRoot, "values/strings.xml"))
        keys.forEach { assertTrue("default locale must define $it", !default[it].isNullOrBlank()) }

        val localized = resourceRoot.listFiles()
            ?.filter { it.name.startsWith("values-") && File(it, "strings.xml").isFile }
            .orEmpty()
            .map { it.name to strings(File(it, "strings.xml")) }

        assertTrue("all shipped non-default locales must be discovered", localized.size >= 15)
        localized.forEach { (locale, entries) ->
            keys.forEach { key ->
                val text = entries[key]
                assertTrue("$locale is missing $key", !text.isNullOrBlank())
                assertFalse("$locale leaves $key as the default English placeholder", text == default[key])
            }
        }
    }

    private fun strings(file: File): Map<String, String> {
        val xml = file.readText()
        val pattern = Regex("""<string name=\"([^\"]+)\">(.*?)</string>""", RegexOption.DOT_MATCHES_ALL)
        return pattern.findAll(xml).associate { it.groupValues[1] to it.groupValues[2].trim() }
    }
}
