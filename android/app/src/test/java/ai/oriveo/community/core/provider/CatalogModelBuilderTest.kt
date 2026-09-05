package ai.oriveo.community.core.provider

import ai.oriveo.community.core.data.remote.MetadataClient
import ai.oriveo.community.core.model.AIModel
import ai.oriveo.community.core.model.ModelCapability
import ai.oriveo.community.core.model.ProviderKind
import kotlinx.serialization.json.Json
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.After
import org.junit.Before
import org.junit.Test

/**
 * Unit tests for CatalogModelBuilder: buildCatalogModel and the stored-model enrichment path.
 */
class CatalogModelBuilderTest {

    @Before
    fun setUp() {
        injectTestData()
    }

    @After
    fun tearDown() {
        MetadataTestFixtures.clear()
    }

    // --- buildCatalogModel: the catalog has an entry ---

    @Test
    fun `buildCatalogModel uses metadata displayName`() {
        val model = CatalogModelBuilder.buildCatalogModel(
            providerKind = ProviderKind.OpenAI,
            runtimeModelId = "gpt-4o",
            fallbackName = "gpt-4o",
        )
        assertEquals("GPT-4o", model.name)
    }

    @Test
    fun `buildCatalogModel uses metadata capabilities`() {
        val model = CatalogModelBuilder.buildCatalogModel(
            providerKind = ProviderKind.OpenAI,
            runtimeModelId = "gpt-4o",
            fallbackName = "gpt-4o",
        )
        assertTrue(model.capabilities.contains(ModelCapability.Text))
        assertTrue(model.capabilities.contains(ModelCapability.Image))
        assertTrue(model.capabilities.contains(ModelCapability.Reasoning))
    }

    @Test
    fun `buildCatalogModel sets canonicalModelId`() {
        val model = CatalogModelBuilder.buildCatalogModel(
            providerKind = ProviderKind.OpenAI,
            runtimeModelId = "gpt-4o-2024-08-06",
            fallbackName = "gpt-4o-2024-08-06",
        )
        assertEquals("gpt-4o", model.canonicalModelId)
    }

    @Test
    fun `buildCatalogModel sets sortRank from uiHints`() {
        val model = CatalogModelBuilder.buildCatalogModel(
            providerKind = ProviderKind.OpenAI,
            runtimeModelId = "gpt-4o",
            fallbackName = "gpt-4o",
        )
        assertEquals(130, model.sortRank)
    }

    @Test
    fun `buildCatalogModel sets isRecommended from uiHints`() {
        val model = CatalogModelBuilder.buildCatalogModel(
            providerKind = ProviderKind.OpenAI,
            runtimeModelId = "gpt-4o",
            fallbackName = "gpt-4o",
        )
        assertTrue(model.isRecommended)
    }

    @Test
    fun `buildCatalogModel non-recommended model`() {
        val model = CatalogModelBuilder.buildCatalogModel(
            providerKind = ProviderKind.OpenAI,
            runtimeModelId = "gpt-4o-mini",
            fallbackName = "gpt-4o-mini",
        )
        assertFalse(model.isRecommended)
    }

    @Test
    fun `buildCatalogModel sets groupKey and groupName`() {
        val model = CatalogModelBuilder.buildCatalogModel(
            providerKind = ProviderKind.OpenAI,
            runtimeModelId = "gpt-4o",
            fallbackName = "gpt-4o",
        )
        assertEquals("gpt-4o", model.groupKey)
        assertEquals("GPT-4o", model.groupName)
    }

    @Test
    fun `buildCatalogModel sets reasoningProfile from profiles`() {
        val model = CatalogModelBuilder.buildCatalogModel(
            providerKind = ProviderKind.OpenAI,
            runtimeModelId = "gpt-4o",
            fallbackName = "gpt-4o",
        )
        assertEquals("oai_responses", model.reasoningProfile)
        assertNull(model.webSearchProfile)
        assertNull(model.imageGenProfile)
    }

    @Test
    fun `buildCatalogModel sets reasoningModeAvailable from profiles`() {
        val model = CatalogModelBuilder.buildCatalogModel(
            providerKind = ProviderKind.OpenAI,
            runtimeModelId = "gpt-4o",
            fallbackName = "gpt-4o",
        )
        assertTrue(model.reasoningModeAvailable)
    }

    @Test
    fun `buildCatalogModel sets isDefault from backend defaultModelId`() {
        val model = CatalogModelBuilder.buildCatalogModel(
            providerKind = ProviderKind.OpenAI,
            runtimeModelId = "gpt-4o",
            fallbackName = "gpt-4o",
        )
        assertTrue(model.isDefault)
    }

    @Test
    fun `buildCatalogModel sets pricing`() {
        val model = CatalogModelBuilder.buildCatalogModel(
            providerKind = ProviderKind.OpenAI,
            runtimeModelId = "gpt-4o",
            fallbackName = "gpt-4o",
        )
        assertNotNull(model.promptPrice)
        assertNotNull(model.completionPrice)
        assertEquals(0.0000025, model.promptPrice!!, 1e-12)
        assertEquals(0.00001, model.completionPrice!!, 1e-12)
    }

    @Test
    fun `buildCatalogModel sets createdAt from runtime`() {
        val model = CatalogModelBuilder.buildCatalogModel(
            providerKind = ProviderKind.OpenAI,
            runtimeModelId = "gpt-4o",
            fallbackName = "gpt-4o",
            createdAt = 1700000000.0,
        )
        assertEquals(1700000000.0, model.createdAt!!, 1e-1)
    }

    @Test
    fun `buildCatalogModel priceTier is non-empty for priced model`() {
        val model = CatalogModelBuilder.buildCatalogModel(
            providerKind = ProviderKind.OpenAI,
            runtimeModelId = "gpt-4o",
            fallbackName = "gpt-4o",
        )
        assertTrue(model.priceTier.isNotEmpty())
    }

    @Test
    fun `buildCatalogModel renders explicit free pricing as Free`() {
        injectJson(
            """
            {
              "version": 1,
              "providers": {
                "openRouter": {
                  "defaultModelId": "meta-llama/llama-3.3-8b-instruct:free",
                  "resolveMap": {
                    "meta-llama/llama-3.3-8b-instruct:free": "meta-llama/llama-3.3-8b-instruct:free"
                  },
                  "models": {
                    "meta-llama/llama-3.3-8b-instruct:free": {
                      "canonicalModelId": "meta-llama/llama-3.3-8b-instruct:free",
                      "displayName": "Llama 3.3 8B Instruct",
                      "pricingStatus": "free",
                      "pricing": {"promptPerMToken": 0.0, "completionPerMToken": 0.0},
                      "capabilities": ["text"]
                    }
                  }
                }
              }
            }
            """.trimIndent()
        )

        val model = CatalogModelBuilder.buildCatalogModel(
            providerKind = ProviderKind.OpenRouter,
            runtimeModelId = "meta-llama/llama-3.3-8b-instruct:free",
            fallbackName = "meta-llama/llama-3.3-8b-instruct:free",
        )

        assertEquals("Free", model.priceTier)
        assertEquals(0.0, model.promptPrice!!, 1e-12)
        assertEquals(0.0, model.completionPrice!!, 1e-12)

        injectTestData()
    }

    @Test
    fun `buildCatalogModel renders non-token priced model as Non-standard billing`() {
        injectJson(
            """
            {
              "version": 1,
              "providers": {
                "openAI": {
                  "defaultModelId": "gpt-image-1",
                  "resolveMap": {
                    "gpt-image-1": "gpt-image-1"
                  },
                  "models": {
                    "gpt-image-1": {
                      "canonicalModelId": "gpt-image-1",
                      "displayName": "GPT Image 1",
                      "billingSku": "gpt-image-1/payg",
                      "pricingUnit": "per_image",
                      "sourceSummary": {
                        "sourceKind": "official_registry",
                        "sourceName": "OpenAI Pricing Registry",
                        "fetchedAt": "2026-04-20T10:00:00Z"
                      },
                      "pricingStatus": "priced",
                      "pricing": {
                        "promptPerMToken": null,
                        "completionPerMToken": null,
                        "costPerUnit": 0.04
                      },
                      "capabilities": ["text", "imageGeneration"]
                    }
                  }
                }
              }
            }
            """.trimIndent()
        )

        val model = CatalogModelBuilder.buildCatalogModel(
            providerKind = ProviderKind.OpenAI,
            runtimeModelId = "gpt-image-1",
            fallbackName = "gpt-image-1",
        )

        assertEquals("Non-standard billing", model.priceTier)
        assertNull(model.promptPrice)
        assertNull(model.completionPrice)
        assertEquals("gpt-image-1/payg", model.billingSku)
        assertEquals("per_image", model.pricingUnit)
        assertEquals("OpenAI Pricing Registry", model.sourceSummary?.sourceName)
        assertEquals(0.04, model.costPerUnit!!, 1e-12)

        injectTestData()
    }

    @Test
    fun `buildCatalogModel renders unknown pricing as Price unknown`() {
        injectJson(
            """
            {
              "version": 1,
              "providers": {
                "openAI": {
                  "defaultModelId": "gpt-unknown",
                  "resolveMap": {
                    "gpt-unknown": "gpt-unknown"
                  },
                  "models": {
                    "gpt-unknown": {
                      "canonicalModelId": "gpt-unknown",
                      "displayName": "GPT Unknown",
                      "pricingStatus": "unknown",
                      "pricing": null,
                      "capabilities": ["text"]
                    }
                  }
                }
              }
            }
            """.trimIndent()
        )

        val model = CatalogModelBuilder.buildCatalogModel(
            providerKind = ProviderKind.OpenAI,
            runtimeModelId = "gpt-unknown",
            fallbackName = "gpt-unknown",
        )

        assertEquals("Price unknown", model.priceTier)
        assertNull(model.promptPrice)
        assertNull(model.completionPrice)

        injectTestData()
    }

    // --- buildCatalogModel: no catalog entry (fallback) ---

    @Test
    fun `buildCatalogModel falls back to fallbackName when no metadata`() {
        val model = CatalogModelBuilder.buildCatalogModel(
            providerKind = ProviderKind.Relay,
            runtimeModelId = "custom-model",
            fallbackName = "Custom Model",
        )
        assertEquals("Custom Model", model.name)
    }

    @Test
    fun `buildCatalogModel defaults to Text capability when no metadata`() {
        val model = CatalogModelBuilder.buildCatalogModel(
            providerKind = ProviderKind.Relay,
            runtimeModelId = "custom-model",
            fallbackName = "Custom Model",
        )
        assertEquals(listOf(ModelCapability.Text), model.capabilities)
    }

    @Test
    fun `buildCatalogModel no metadata - no recommended, no sortRank, no profiles`() {
        val model = CatalogModelBuilder.buildCatalogModel(
            providerKind = ProviderKind.Relay,
            runtimeModelId = "custom-model",
            fallbackName = "Custom Model",
        )
        assertFalse(model.isRecommended)
        assertNull(model.sortRank)
        assertNull(model.canonicalModelId)
        assertNull(model.reasoningProfile)
        assertFalse(model.reasoningModeAvailable)
    }

    @Test
    fun `buildCatalogModel no metadata - empty priceTier`() {
        val model = CatalogModelBuilder.buildCatalogModel(
            providerKind = ProviderKind.Relay,
            runtimeModelId = "custom-model",
            fallbackName = "Custom Model",
        )
        assertEquals("", model.priceTier)
    }

    @Test
    fun `buildCatalogModel uses fallbackContextLength when no metadata`() {
        val model = CatalogModelBuilder.buildCatalogModel(
            providerKind = ProviderKind.Relay,
            runtimeModelId = "custom-model",
            fallbackName = "Custom Model",
            fallbackContextLength = 4096,
        )
        assertEquals("4K", model.summary)
    }

    @Test
    fun `buildCatalogModel uses fallbackSummary when provided`() {
        val model = CatalogModelBuilder.buildCatalogModel(
            providerKind = ProviderKind.Relay,
            runtimeModelId = "custom-model",
            fallbackName = "Custom Model",
            fallbackSummary = "A custom model",
        )
        assertEquals("A custom model", model.summary)
    }

    // --- enrichStoredModel: refreshing fields when the catalog is available ---

    @Test
    fun `enrichStoredModel updates capabilities and pricing from metadata`() {
        val stale = makeModel(id = "gpt-4o")
        val enriched = CatalogModelBuilder.enrichStoredModel(stale, ProviderKind.OpenAI)

        assertTrue(enriched.capabilities.contains(ModelCapability.Image))
        assertTrue(enriched.capabilities.contains(ModelCapability.File))
        assertTrue(enriched.capabilities.contains(ModelCapability.Reasoning))
        assertEquals("GPT-4o", enriched.name)
        assertEquals("gpt-4o", enriched.canonicalModelId)
        assertEquals(0.0000025, enriched.promptPrice!!, 1e-12)
        assertEquals(0.00001, enriched.completionPrice!!, 1e-12)
        assertTrue(enriched.priceTier.isNotEmpty())
        assertTrue(enriched.reasoningModeAvailable)
        assertEquals("oai_responses", enriched.reasoningProfile)
        assertEquals(130, enriched.sortRank)
        assertEquals("gpt-4o", enriched.groupKey)
        assertEquals("GPT-4o", enriched.groupName)
        assertTrue(enriched.isRecommended)
    }

    @Test
    fun `enrichStoredModel preserves original when no metadata available`() {
        val original = AIModel(
            id = "unknown-model-xyz",
            name = "My Custom Model",
            capabilities = listOf(ModelCapability.Text, ModelCapability.Image),
            isAvailable = true,
            isDefault = true,
            priceTier = "$5/M",
            promptPrice = 0.00001,
        )
        val enriched = CatalogModelBuilder.enrichStoredModel(original, ProviderKind.OpenAI)

        assertEquals("My Custom Model", enriched.name)
        assertEquals(listOf(ModelCapability.Text, ModelCapability.Image), enriched.capabilities)
        assertEquals("$5/M", enriched.priceTier)
        assertEquals(0.00001, enriched.promptPrice!!, 1e-12)
        assertTrue(enriched.isDefault)
    }

    @Test
    fun `enrichStoredModel preserves user settings like isDefault`() {
        val stale = makeModel(id = "gpt-4o").copy(isDefault = true, isAvailable = false)
        val enriched = CatalogModelBuilder.enrichStoredModel(stale, ProviderKind.OpenAI)

        // User settings must be preserved.
        assertTrue(enriched.isDefault)
        assertFalse(enriched.isAvailable)
        // Catalog-owned fields must be refreshed.
        assertTrue(enriched.capabilities.contains(ModelCapability.File))
    }

    @Test
    fun `enrichStoredModel clears stale price when pricingStatus is unknown`() {
        injectJson(
            """
            {
              "version": 1,
              "providers": {
                "openAI": {
                  "defaultModelId": "gpt-3.5-turbo-0125",
                  "resolveMap": {
                    "gpt-3.5-turbo-0125": "gpt-3.5-turbo-0125"
                  },
                  "models": {
                    "gpt-3.5-turbo-0125": {
                      "canonicalModelId": "gpt-3.5-turbo-0125",
                      "displayName": "GPT-3.5 Turbo",
                      "pricingStatus": "unknown",
                      "pricing": {"promptPerMToken": 0.0, "completionPerMToken": 0.0},
                      "capabilities": ["text"]
                    }
                  }
                }
              }
            }
            """.trimIndent()
        )

        val stale = AIModel(
            id = "gpt-3.5-turbo-0125",
            name = "GPT-3.5 Turbo",
            capabilities = listOf(ModelCapability.Text),
            isAvailable = true,
            isDefault = false,
            priceTier = "Free",
            promptPrice = 0.0,
            completionPrice = 0.0,
        )
        val enriched = CatalogModelBuilder.enrichStoredModel(stale, ProviderKind.OpenAI)

        assertEquals("Price unknown", enriched.priceTier)
        assertNull(enriched.promptPrice)
        assertNull(enriched.completionPrice)

        injectTestData()
    }

    @Test
    fun `enrichStoredModel clears stale group metadata when latest uiHints disappear`() {
        injectJson(
            """
            {
              "version": 1,
              "providers": {
                "openRouter": {
                  "defaultModelId": "openai/gpt-4o",
                  "resolveMap": {
                    "openai/gpt-4o": "openai/gpt-4o"
                  },
                  "models": {
                    "openai/gpt-4o": {
                      "canonicalModelId": "openai/gpt-4o",
                      "displayName": "GPT-4o",
                      "pricingStatus": "unknown",
                      "capabilities": ["text"]
                    }
                  }
                }
              }
            }
            """.trimIndent()
        )

        val stale = AIModel(
            id = "openai/gpt-4o",
            name = "GPT-4o",
            capabilities = listOf(ModelCapability.Text),
            isAvailable = true,
            isDefault = false,
            priceTier = "",
            groupKey = "openai",
            groupName = "OpenAI",
            sortRank = 120,
            badgeOrder = listOf(ModelCapability.Reasoning),
            isRecommended = true,
        )

        val enriched = CatalogModelBuilder.enrichStoredModel(stale, ProviderKind.OpenRouter)

        assertNull(enriched.groupKey)
        assertNull(enriched.groupName)
        assertNull(enriched.sortRank)
        assertNull(enriched.badgeOrder)
        assertFalse(enriched.isRecommended)

        injectTestData()
    }

    @Test
    fun `enrichStoredModel clears stale profiles when metadata removes them`() {
        injectJson(
            """
            {
              "version": 1,
              "providers": {
                "openAI": {
                  "defaultModelId": "gpt-4o",
                  "resolveMap": {
                    "gpt-4o": "gpt-4o"
                  },
                  "models": {
                    "gpt-4o": {
                      "canonicalModelId": "gpt-4o",
                      "displayName": "GPT-4o",
                      "pricingStatus": "unknown",
                      "capabilities": ["text"],
                      "profiles": {}
                    }
                  }
                }
              }
            }
            """.trimIndent()
        )

        val stale = AIModel(
            id = "gpt-4o",
            name = "GPT-4o",
            capabilities = listOf(ModelCapability.Text, ModelCapability.Reasoning),
            reasoningModeAvailable = true,
            isAvailable = true,
            isDefault = false,
            priceTier = "",
            reasoningProfile = "old_reasoning",
            webSearchProfile = "old_web",
            imageGenProfile = "old_image",
        )

        val enriched = CatalogModelBuilder.enrichStoredModel(stale, ProviderKind.OpenAI)

        assertFalse(enriched.reasoningModeAvailable)
        assertNull(enriched.reasoningProfile)
        assertNull(enriched.webSearchProfile)
        assertNull(enriched.imageGenProfile)

        injectTestData()
    }

    @Test
    fun `v2 explicit unknown clears stale verdict while legacy payload preserves it`() {
        val stale = makeModel("gpt-future").copy(toolCall = true)

        injectJson(
            """
            {
                "version": 2,
                "capabilityContractVersion": 2,
                "providers": {
                    "openAI": {
                        "resolveMap": {"gpt-future": "gpt-future"},
                        "models": {
                            "gpt-future": {
                                "canonicalModelId": "gpt-future",
                                "toolCall": null
                            }
                        }
                    }
                }
            }
            """.trimIndent(),
        )

        val v2 = CatalogModelBuilder.enrichStoredModel(stale, ProviderKind.OpenAI)
        assertNull(v2.toolCall)

        injectJson(
            """
            {
                "version": 1,
                "capabilityContractVersion": 1,
                "providers": {
                    "openAI": {
                        "resolveMap": {"gpt-future": "gpt-future"},
                        "models": {
                            "gpt-future": {
                                "canonicalModelId": "gpt-future",
                                "toolCall": null
                            }
                        }
                    }
                }
            }
            """.trimIndent(),
        )

        val legacy = CatalogModelBuilder.enrichStoredModel(stale, ProviderKind.OpenAI)
        assertEquals(true, legacy.toolCall)

        injectTestData()
    }

    @Test
    fun `catalog miss keeps stored verdict only as temporary compatibility data`() {
        val stored = makeModel("not-in-catalog").copy(toolCall = true)

        assertEquals(stored, CatalogModelBuilder.enrichStoredModel(stored, ProviderKind.OpenAI))
    }

    // ── Helpers ──

    private fun makeModel(
        id: String,
        isRecommended: Boolean = false,
        sortRank: Int? = null,
        isAvailable: Boolean = true,
        createdAt: Double? = null,
    ) = AIModel(
        id = id,
        name = id,
        capabilities = listOf(ModelCapability.Text),
        isAvailable = isAvailable,
        isRecommended = isRecommended,
        sortRank = sortRank,
        createdAt = createdAt,
    )

    private val testJson = """
    {
        "version": 1,
        "providers": {
            "openAI": {
                "defaultModelId": "gpt-4o",
                "resolveMap": {
                    "gpt-4o": "gpt-4o",
                    "gpt-4o-2024-08-06": "gpt-4o",
                    "gpt-4o-mini": "gpt-4o-mini"
                },
                "models": {
                    "gpt-4o": {
                        "canonicalModelId": "gpt-4o",
                        "displayName": "GPT-4o",
                        "contextLength": 128000,
                        "pricing": {"promptPerMToken": 2.5, "completionPerMToken": 10.0},
                        "capabilities": ["text", "image", "file", "reasoning"],
                        "profiles": {"reasoning": "oai_responses"},
                        "uiHints": {"groupKey": "gpt-4o", "groupName": "GPT-4o", "rank": 130, "recommended": true}
                    },
                    "gpt-4o-mini": {
                        "canonicalModelId": "gpt-4o-mini",
                        "displayName": "GPT-4o Mini",
                        "contextLength": 128000,
                        "pricing": {"promptPerMToken": 0.15, "completionPerMToken": 0.60},
                        "capabilities": ["text", "image"],
                        "profiles": {},
                        "uiHints": {"groupKey": "gpt-4o", "groupName": "GPT-4o", "rank": 80, "recommended": false}
                    }
                }
            }
        }
    }
    """.trimIndent()

    private fun injectTestData() {
        injectJson(testJson)
    }

    private fun injectJson(rawJson: String) {
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
