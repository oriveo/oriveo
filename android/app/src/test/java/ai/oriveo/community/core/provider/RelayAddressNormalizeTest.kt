package ai.oriveo.community.core.provider

import ai.oriveo.community.core.model.RelayRequestedConfig
import ai.oriveo.community.core.model.RelayTransport
import ai.oriveo.community.core.provider.relay.RelayCatalogEndpointTypes
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import org.junit.Assert.assertEquals
import org.junit.Test
import java.io.File

/**
 * Address normalization, driven by the shared fixture `relay/address-normalize.v1.json`:
 * one RD2-ADDR-PREVIEW-<caseId> / RD2-ADDR-CATALOG-<caseId> test per case.
 */
class RelayAddressNormalizeTest {

    // ── Preview (add page "Will request ...") ──

    @Test fun `RD2-ADDR-PREVIEW-bare_host_gets_https_and_v1`() = preview("bare_host_gets_https_and_v1")
    @Test fun `RD2-ADDR-PREVIEW-trailing_slash_is_dropped`() = preview("trailing_slash_is_dropped")
    @Test fun `RD2-ADDR-PREVIEW-explicit_v1_is_kept`() = preview("explicit_v1_is_kept")
    @Test fun `RD2-ADDR-PREVIEW-pasted_chat_route_is_trimmed_to_its_root`() = preview("pasted_chat_route_is_trimmed_to_its_root")
    @Test fun `RD2-ADDR-PREVIEW-proxy_prefix_is_kept`() = preview("proxy_prefix_is_kept")
    @Test fun `RD2-ADDR-PREVIEW-explicit_v1beta_is_kept`() = preview("explicit_v1beta_is_kept")
    @Test fun `RD2-ADDR-PREVIEW-pasted_messages_route_is_trimmed`() = preview("pasted_messages_route_is_trimmed")
    @Test fun `RD2-ADDR-PREVIEW-pasted_models_route_is_trimmed`() = preview("pasted_models_route_is_trimmed")
    @Test fun `RD2-ADDR-PREVIEW-existing_v4_segment_is_kept`() = preview("existing_v4_segment_is_kept")
    @Test fun `RD2-ADDR-PREVIEW-pasted_versionless_chat_route_completes_v1`() = preview("pasted_versionless_chat_route_completes_v1")
    @Test fun `RD2-ADDR-PREVIEW-empty_input_has_no_preview`() = preview("empty_input_has_no_preview")
    @Test fun `RD2-ADDR-PREVIEW-userinfo_has_no_preview`() = preview("userinfo_has_no_preview")
    @Test fun `RD2-ADDR-PREVIEW-embedded_query_has_no_preview`() = preview("embedded_query_has_no_preview")
    @Test fun `RD2-ADDR-PREVIEW-plain_http_remote_has_no_preview`() = preview("plain_http_remote_has_no_preview")

    // ── Catalog root (refresh / per key for multiple keys / extra keys when adding) ──

    @Test fun `RD2-ADDR-CATALOG-host_only_connection_refreshes_v1_models`() = catalog("host_only_connection_refreshes_v1_models")
    @Test fun `RD2-ADDR-CATALOG-verified_root_from_detection_wins`() = catalog("verified_root_from_detection_wins")
    @Test fun `RD2-ADDR-CATALOG-versionless_verified_root_is_not_versioned_again`() = catalog("versionless_verified_root_is_not_versioned_again")
    @Test fun `RD2-ADDR-CATALOG-per_transport_root_of_the_connection_transport_wins`() = catalog("per_transport_root_of_the_connection_transport_wins")
    @Test fun `RD2-ADDR-CATALOG-existing_v4_segment_is_not_versioned_again`() = catalog("existing_v4_segment_is_not_versioned_again")
    @Test fun `RD2-ADDR-CATALOG-stored_chat_route_is_trimmed_before_models`() = catalog("stored_chat_route_is_trimmed_before_models")
    @Test fun `RD2-ADDR-CATALOG-messages_connection_refreshes_its_v1_root`() = catalog("messages_connection_refreshes_its_v1_root")
    @Test fun `RD2-ADDR-CATALOG-gemini_connection_refreshes_its_v1beta_root`() = catalog("gemini_connection_refreshes_its_v1beta_root")

    /** A new fixture case must come with its test in the same change, otherwise this goes red. */
    @Test
    fun `every fixture case has a named test`() {
        val declared = RelayAddressNormalizeTest::class.java.declaredMethods.map { it.name }.toSet()
        val expected = AddressNormalizeFixture.previewIds().map { "RD2-ADDR-PREVIEW-$it" } +
            AddressNormalizeFixture.catalogIds().map { "RD2-ADDR-CATALOG-$it" }
        assertEquals(emptyList<String>(), expected.filterNot(declared::contains))
    }

    private fun preview(caseId: String) {
        val case = AddressNormalizeFixture.previewCase(caseId)
        val input = case.getValue("input").jsonPrimitive.content
        val expect = case["expect"]?.takeUnless { it is JsonNull }?.jsonPrimitive?.content
        assertEquals(caseId, expect, RelayEndpointResolver.previewAPIRoot(input))
    }

    private fun catalog(caseId: String) {
        val (requested, baseUrl, expectURL) = AddressNormalizeFixture.catalogCase(caseId)
        val root = RelayEndpointResolver.catalogAPIRoot(requested, baseUrl)
        assertEquals(caseId, expectURL, root?.let { "$it/models" })
        // The endpoint types cache key uses the same root as the catalog GET, so that lazy verify can find it
        assertEquals(caseId, root, RelayCatalogEndpointTypes.catalogRoot(requested, baseUrl))
    }
}

/** Fixture reader (RD2-REFRESH in RelayServiceTest uses it too). */
internal object AddressNormalizeFixture {
    private val fixture: JsonObject by lazy {
        Json.parseToJsonElement(
            generateSequence(File(System.getProperty("user.dir") ?: ".").absoluteFile) { it.parentFile }
                .map { File(it, "shared/test-fixtures/relay/address-normalize.v1.json") }
                .first { it.isFile }
                .readText(Charsets.UTF_8),
        ).jsonObject
    }

    private fun cases(key: String): List<JsonObject> = fixture.getValue(key).jsonArray.map { it.jsonObject }

    fun previewIds(): List<String> = cases("previewCases").map { it.getValue("caseId").jsonPrimitive.content }

    fun catalogIds(): List<String> = cases("catalogCases").map { it.getValue("caseId").jsonPrimitive.content }

    fun previewCase(caseId: String): JsonObject =
        cases("previewCases").single { it.getValue("caseId").jsonPrimitive.content == caseId }

    data class CatalogCase(val requested: RelayRequestedConfig, val baseUrl: String, val catalogURL: String)

    fun catalogCase(caseId: String): CatalogCase {
        val case = cases("catalogCases").single { it.getValue("caseId").jsonPrimitive.content == caseId }
        val provider = case.getValue("provider").jsonObject
        val raw = provider.getValue("relayRequested").jsonObject
        val requested = RelayRequestedConfig(
            transport = RelayTransport.entries.first { it.value == raw.getValue("transport").jsonPrimitive.content },
            resolvedAPIBaseURL = raw["resolvedAPIBaseURL"]?.jsonPrimitive?.content,
            resolvedAPIBaseURLs = raw["resolvedAPIBaseURLs"]?.jsonObject
                ?.mapValues { it.value.jsonPrimitive.content },
        )
        return CatalogCase(
            requested = requested,
            baseUrl = provider.getValue("baseURL").jsonPrimitive.content,
            catalogURL = case.getValue("expect").jsonObject.getValue("catalogURL").jsonPrimitive.content,
        )
    }
}
