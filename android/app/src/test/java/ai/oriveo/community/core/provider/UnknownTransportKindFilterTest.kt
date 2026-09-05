package ai.oriveo.community.core.provider

import ai.oriveo.community.core.data.remote.MetadataClient
import ai.oriveo.community.core.model.Provider
import ai.oriveo.community.core.model.ProviderConnectionState
import ai.oriveo.community.core.model.ProviderKind
import kotlinx.serialization.json.Json
import org.junit.After
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * A model whose declared transport kind this build does not understand must not show up in
 * the catalog.
 *
 * The metadata injected below carries two models:
 *  - transport="openai_chat" (known) must reach the catalog
 *  - transport="future_kind_v99" (unknown) must be filtered out
 */
class UnknownTransportKindFilterTest {

    @After
    fun tearDown() {
        MetadataTestFixtures.clear()
        ProviderCatalogResolver.resetForTest()
    }

    @Test
    fun `unknown transport kind models are filtered out of catalog`() {
        // Two models under openAI: one with a known transport, one with an unknown one.
        injectMetadata(
            """
            {
              "version": 1,
              "providers": {
                "openAI": {
                  "defaultModelId": "gpt-known",
                  "resolveMap": {
                    "gpt-known": "gpt-known",
                    "gpt-future": "gpt-future"
                  },
                  "models": {
                    "gpt-known": {
                      "canonicalModelId": "gpt-known",
                      "displayName": "GPT Known",
                      "capabilities": ["text"],
                      "transport": "openai_chat"
                    },
                    "gpt-future": {
                      "canonicalModelId": "gpt-future",
                      "displayName": "GPT Future",
                      "capabilities": ["text"],
                      "transport": "future_kind_v99"
                    }
                  }
                }
              }
            }
            """.trimIndent(),
        )

        val provider = Provider(
            id = "openai-1",
            kind = ProviderKind.OpenAI,
            status = ProviderConnectionState.Connected,
        )

        val resolved = ProviderCatalogResolver.resolve(provider, MetadataClient.instance)
        val catalogIds = resolved.catalog.map { it.model.id }

        assertTrue("gpt-known with known transport should appear in catalog", "gpt-known" in catalogIds)
        assertFalse(
            "gpt-future with unknown transport kind must be hidden",
            "gpt-future" in catalogIds,
        )
    }

    @Test
    fun `models without transport field still appear in catalog`() {
        // The catalog omitted the transport field entirely, so the client must not filter --
        // that keeps older catalog payloads working.
        injectMetadata(
            """
            {
              "version": 1,
              "providers": {
                "openAI": {
                  "defaultModelId": "gpt-legacy",
                  "resolveMap": {"gpt-legacy": "gpt-legacy"},
                  "models": {
                    "gpt-legacy": {
                      "canonicalModelId": "gpt-legacy",
                      "displayName": "GPT Legacy",
                      "capabilities": ["text"]
                    }
                  }
                }
              }
            }
            """.trimIndent(),
        )
        val provider = Provider(id = "openai-2", kind = ProviderKind.OpenAI)
        val resolved = ProviderCatalogResolver.resolve(provider, MetadataClient.instance)
        assertTrue("legacy model without transport should remain visible",
            resolved.catalog.any { it.model.id == "gpt-legacy" })
    }

    private fun injectMetadata(rawJson: String) {
        val clientClass = MetadataClient::class.java

        val jsonField = clientClass.getDeclaredField("json")
        jsonField.isAccessible = true
        val internalJson = jsonField.get(MetadataClient.instance) as Json

        val responseClass = clientClass.declaredClasses.first { it.simpleName == "MetadataResponse" }
        val companionField = responseClass.getDeclaredField("Companion")
        companionField.isAccessible = true
        val companion = companionField.get(null)
        val serializerMethod = companion.javaClass.getDeclaredMethod("serializer")
        serializerMethod.isAccessible = true
        @Suppress("UNCHECKED_CAST")
        val serializer = serializerMethod.invoke(companion) as kotlinx.serialization.KSerializer<Any>

        val decoded = internalJson.decodeFromString(serializer, rawJson)

        val tableField = clientClass.getDeclaredField("table")
        tableField.isAccessible = true
        tableField.set(MetadataClient.instance, decoded)
    }
}
