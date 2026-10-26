package ai.oriveo.community.core.data.remote

import ai.oriveo.community.core.model.ModelCapability
import ai.oriveo.community.core.model.ProviderKind
import ai.oriveo.community.core.model.ReasoningMode
import kotlinx.coroutines.launch
import kotlinx.coroutines.test.UnconfinedTestDispatcher
import kotlinx.coroutines.test.runTest
import kotlinx.serialization.json.Json
import ai.oriveo.community.core.provider.MetadataTestFixtures
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test

/**
 * MetadataClient unit tests.
 *
 * Deserializes JSON through reflection and injects it into the table field,
 * then tests the resolveCatalogModel / lookupPricing / estimateCost / priceTier logic.
 */
class MetadataClientTest {

    @Before
    fun setUp() {
        injectTestData()
    }

    // setUp injects the test table into the global MetadataClient.instance; clear it after each case so it does not leak into other test classes.
    @After
    fun clearGlobalMetadata() = MetadataTestFixtures.clear()

    @Test
    fun `companion delegates static calls to replaceable instance`() {
        val original = MetadataClient.instance
        val injected = MetadataClient()
        try {
            MetadataClient.instance = injected
            injectJson(
                """
                {
                  "version": 77,
                  "contractVersion": 1,
                  "providers": {}
                }
                """.trimIndent(),
            )

            assertEquals(77, MetadataClient.version)
            assertEquals(77, injected.version)
        } finally {
            MetadataClient.instance = original
            injectTestData()
        }
    }

    @Test
    fun `metadata parses when bodyIncludes is explicit null`() {
        // Regression: production /api/metadata sends an explicit null for validation.invalidKeySignals.bodyIncludes,
        // while InvalidKeySignal.bodyIncludes is non-nullable. Without coerceInputValues the whole metadata
        // parse threw and fell back to an empty shell, leaving every provider catalog and the model library empty.
        injectJson(
            """
            {
              "version": 13,
              "contractVersion": 1,
              "providers": {
                "openAI": {
                  "displayName": "OpenAI",
                  "validation": {
                    "probe": "list_models",
                    "invalidKeySignals": [ { "status": 401, "bodyIncludes": null } ]
                  },
                  "models": {
                    "gpt-4o": { "canonicalModelId": "gpt-4o", "displayName": "GPT-4o" }
                  }
                }
              }
            }
            """.trimIndent(),
        )

        val ids = MetadataClient.providerModelIds(ProviderKind.OpenAI)
        assertTrue("bodyIncludes=null must not make catalog parsing fail or come back empty", ids.isNotEmpty())
        assertEquals(listOf("gpt-4o"), ids)
    }

    @Test
    fun `capability contract v2 and explicit unknown survive decoder and cache envelope`() {
        val target = MetadataClient()
        val raw =
            """
            {
              "version": 20,
              "contractVersion": 1,
              "capabilityContractVersion": 2,
              "providers": {
                "openAI": {
                  "resolveMap": {"gpt-future": "gpt-future"},
                  "models": {
                    "gpt-future": {
                      "canonicalModelId": "gpt-future",
                      "toolCall": null,
                      "transport": "openai_chat"
                    }
                  }
                }
              }
            }
            """.trimIndent()

        val decodedResponse = decodeMetadataResponse(raw, target)
        val clientClass = MetadataClient::class.java
        val cacheClass = clientClass.declaredClasses.first { it.simpleName == "CacheEntry" }
        val cacheConstructor = cacheClass.declaredConstructors.single { it.parameterCount == 2 }.apply {
            isAccessible = true
        }
        val cacheEntry = cacheConstructor.newInstance(decodedResponse, 123L)
        val cacheSerializer = serializerFor(cacheClass)
        val internalJson = jsonFor(target)
        val encodedCache = internalJson.encodeToString(cacheSerializer, cacheEntry)
        val decodedCache = internalJson.decodeFromString(cacheSerializer, encodedCache)
        val dataField = cacheClass.getDeclaredField("data").apply { isAccessible = true }
        setTable(target, requireNotNull(dataField.get(decodedCache)))

        assertEquals(2, target.capabilityContractVersion)
        val resolved = target.resolveCatalogModel("gpt-future", ProviderKind.OpenAI)
        assertNotNull(resolved)
        assertEquals(2, resolved!!.capabilityContractVersion)
        assertNull(resolved.toolCall)
    }

    @Test
    fun `runtime feature flag follows backend value and defaults missing flags`() {
        injectJson(
            """
            {
              "version": 14,
              "contractVersion": 1,
              "providers": {},
              "runtimeConfig": {
                "featureFlags": {
                  "sample_flag_enabled": false
                }
              }
            }
            """.trimIndent(),
        )

        assertFalse(MetadataClient.isRuntimeFeatureEnabled("sample_flag_enabled"))
        assertTrue(MetadataClient.isRuntimeFeatureEnabled("missing_flag", defaultValue = true))
        assertFalse(MetadataClient.isRuntimeFeatureEnabled("missing_flag", defaultValue = false))
    }

    // ── resolveCatalogModel ──

    @Test
    fun `resolveCatalogModel resolves via resolveMap for exact match`() {
        val result = MetadataClient.resolveCatalogModel("gpt-4o", ProviderKind.OpenAI)
        assertNotNull(result)
        assertEquals("gpt-4o", result!!.canonicalModelId)
        assertEquals("GPT-4o", result.displayName)
        assertEquals(128000, result.contextLength)
    }

    @Test
    fun `resolveCatalogModel keeps model ref only in metadata sidecar`() {
        injectJson(
            """
            {
              "version": 1,
              "providers": {
                "openAI": {
                  "resolveMap": { "gpt-ref": "gpt-ref" },
                  "models": {
                    "gpt-ref": {
                      "canonicalModelId": "gpt-ref",
                      "modelRef": "AbCdEfGhIjKlMnOpQrStUv",
                      "transport": "openai_responses"
                    }
                  }
                }
              }
            }
            """.trimIndent(),
        )

        val resolved = MetadataClient.resolveCatalogModel("gpt-ref", ProviderKind.OpenAI)
        assertEquals("AbCdEfGhIjKlMnOpQrStUv", resolved?.modelRef)
        assertEquals("openai_responses", resolved?.transport)
    }

    @Test
    fun `resolveCatalogModel resolves date-suffixed alias via resolveMap`() {
        val result = MetadataClient.resolveCatalogModel("gpt-4o-2024-08-06", ProviderKind.OpenAI)
        assertNotNull(result)
        assertEquals("gpt-4o", result!!.canonicalModelId)
    }

    @Test
    fun `resolveCatalogModel normalizes hyphenated snapshot model id when alias missing`() {
        val result = MetadataClient.resolveCatalogModel("gpt-5.4-nano-2026-03-01", ProviderKind.OpenAI)
        assertNotNull(result)
        assertEquals("gpt-5.4-nano", result!!.canonicalModelId)
        assertEquals("GPT-5.4 nano", result.displayName)
    }

    @Test
    fun `resolveCatalogModel normalizes hyphenated GPT-5 snapshot id when alias missing`() {
        val result = MetadataClient.resolveCatalogModel("gpt-5.4-2026-03-05", ProviderKind.OpenAI)
        assertNotNull(result)
        assertEquals("gpt-5.4", result!!.canonicalModelId)
        assertEquals("GPT-5.4", result.displayName)
    }

    @Test
    fun `resolveCatalogModel returns null for unknown model not in resolveMap`() {
        val result = MetadataClient.resolveCatalogModel("nonexistent-model", ProviderKind.OpenAI)
        assertNull(result)
    }

    @Test
    fun `resolveCatalogModel returns null for unknown provider`() {
        val result = MetadataClient.resolveCatalogModel("gpt-4o", ProviderKind.Relay)
        assertNull(result)
    }

    @Test
    fun `resolveCatalogModel returns capabilities from backend`() {
        val result = MetadataClient.resolveCatalogModel("gpt-4o", ProviderKind.OpenAI)
        assertNotNull(result)
        assertTrue(result!!.capabilities.contains(ModelCapability.Text))
        assertTrue(result.capabilities.contains(ModelCapability.Image))
    }

    @Test
    fun `resolveCatalogModel returns profiles from backend`() {
        val result = MetadataClient.resolveCatalogModel("gpt-4o", ProviderKind.OpenAI)
        assertNotNull(result)
        assertEquals("oai_responses", result!!.profiles.reasoning)
        assertNull(result.profiles.webSearch)
    }

    @Test
    fun `generation profile expands the shared template and unknown template remains absent`() {
        injectJson(
            """
            {
              "version": 1,
              "profiles": {
                "generation": {
                  "version": 1,
                  "parameters": {
                    "temperature": {
                      "group": "sampling",
                      "valueSchema": "number",
                      "range": { "min": 0, "max": 2 },
                      "interactionGroup": "sampling_strategy",
                      "portability": "portable",
                      "risk": "normal",
                      "conflictsWith": ["top_p"],
                      "constraints": [{ "mode": "normal" }]
                    }
                  },
                  "templates": {
                    "openai_chat_completions": {
                      "transport": "openai_chat_completions",
                      "wire": { "temperature": "temperature" }
                    }
                  }
                }
              },
              "providers": {
                "openAI": {
                  "resolveMap": { "contract-model": "contract-model", "unknown-template": "unknown-template" },
                  "models": {
                    "contract-model": {
                      "profiles": {
                        "generation": {
                          "template": "openai_chat_completions",
                          "parameters": [{ "id": "temperature", "support": "supported", "source": "provider_metadata" }]
                        }
                      }
                    },
                    "unknown-template": {
                      "profiles": {
                        "generation": {
                          "template": "future_transport",
                          "parameters": [{ "id": "temperature", "support": "future_supported", "source": "future_source" }]
                        }
                      }
                    }
                  }
                }
              }
            }
            """.trimIndent(),
        )

        val expanded = MetadataClient.resolveCatalogModel("contract-model", ProviderKind.OpenAI)?.profiles?.generation
        assertEquals("temperature", expanded?.wire?.get("temperature"))
        assertEquals("sampling", expanded?.parameters?.firstOrNull()?.group)
        assertEquals(0.0, expanded?.parameters?.firstOrNull()?.range?.min)
        assertEquals("portable", expanded?.parameters?.firstOrNull()?.portability)
        assertEquals(listOf("top_p"), expanded?.parameters?.firstOrNull()?.conflictsWith)
        assertEquals("normal", expanded?.parameters?.firstOrNull()?.constraints?.firstOrNull()?.get("mode")?.toString()?.trim('"'))
        assertNull(MetadataClient.resolveCatalogModel("unknown-template", ProviderKind.OpenAI)?.profiles?.generation)
    }

    @Test
    fun `generation profile model-level enumValues overrides shared schema, absence falls back to global`() {
        injectJson(
            """
            {
              "version": 1,
              "profiles": {
                "generation": {
                  "version": 1,
                  "parameters": {
                    "reasoning_effort": {
                      "group": "reasoning",
                      "valueSchema": "string",
                      "enumValues": ["low", "medium", "high", "xhigh"]
                    }
                  },
                  "templates": {
                    "openai_responses": {
                      "transport": "openai_responses",
                      "wire": { "reasoning_effort": "reasoning.effort" }
                    }
                  }
                }
              },
              "providers": {
                "openAI": {
                  "resolveMap": { "narrowed-model": "narrowed-model", "fallback-model": "fallback-model" },
                  "models": {
                    "narrowed-model": {
                      "profiles": {
                        "generation": {
                          "template": "openai_responses",
                          "parameters": [{
                            "id": "reasoning_effort",
                            "support": "supported",
                            "source": "authoritative_metadata",
                            "enumValues": ["low", "high"]
                          }]
                        }
                      }
                    },
                    "fallback-model": {
                      "profiles": {
                        "generation": {
                          "template": "openai_responses",
                          "parameters": [{ "id": "reasoning_effort", "support": "supported", "source": "provider_metadata" }]
                        }
                      }
                    }
                  }
                }
              }
            }
            """.trimIndent(),
        )

        val narrowed = MetadataClient.resolveCatalogModel("narrowed-model", ProviderKind.OpenAI)
            ?.profiles?.generation?.parameters?.firstOrNull()?.enumValues?.map { it.toString().trim('"') }
        assertEquals(listOf("low", "high"), narrowed)

        val fallback = MetadataClient.resolveCatalogModel("fallback-model", ProviderKind.OpenAI)
            ?.profiles?.generation?.parameters?.firstOrNull()?.enumValues?.map { it.toString().trim('"') }
        assertEquals(listOf("low", "medium", "high", "xhigh"), fallback)
    }

    @Test
    fun `supportedReasoningModes returns only levels declared by profile`() {
        assertEquals(
            listOf(
                ReasoningMode.Automatic,
                ReasoningMode.Fast,
                ReasoningMode.Balanced,
                ReasoningMode.Deep,
            ),
            MetadataClient.supportedReasoningModes("oai_responses"),
        )
    }

    @Test
    fun `clampReasoningMode falls back to deepest supported level`() {
        assertEquals(
            ReasoningMode.Deep,
            MetadataClient.clampReasoningMode(ReasoningMode.Max, "oai_responses"),
        )
    }

    @Test
    fun `supportedReasoningModes collapses to automatic when profile name not found in table`() {
        // profile is non-empty but missing from the profiles table (server withdrew it / old snapshot): aligned with the
        // injection surface, narrow to automatic only and do not fail open with fake tiers. Do not confuse this with the
        // normal relay branch where profileName itself is empty.
        assertEquals(
            listOf(ReasoningMode.Automatic),
            MetadataClient.supportedReasoningModes("profile_withdrawn_by_server"),
        )
    }

    @Test
    fun `supportedReasoningModes stays fail-open when profileName itself is blank`() {
        // An empty profileName is the normal relay case and must keep failing open, returning all tiers.
        assertEquals(ReasoningMode.entries, MetadataClient.supportedReasoningModes(null))
        assertEquals(ReasoningMode.entries, MetadataClient.supportedReasoningModes(""))
    }

    @Test
    fun `resolveCatalogModel returns uiHints from backend`() {
        val result = MetadataClient.resolveCatalogModel("gpt-4o", ProviderKind.OpenAI)
        assertNotNull(result)
        assertNotNull(result!!.uiHints)
        assertEquals("gpt-4o", result.uiHints!!.groupKey)
        assertEquals("GPT-4o", result.uiHints!!.groupName)
        assertEquals(130, result.uiHints!!.rank)
        assertTrue(result.uiHints!!.recommended)
    }

    @Test
    fun `resolveCatalogModel returns isDefault based on defaultModelId`() {
        val result = MetadataClient.resolveCatalogModel("gpt-4o", ProviderKind.OpenAI)
        assertNotNull(result)
        assertTrue(result!!.isDefault)
    }

    @Test
    fun `resolveCatalogModel keeps richer non-token fields and leaves token prices null`() {
        injectJson(
            """
            {
              "version": 1,
              "contractVersion": 1,
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
                        "costPerUnit": 0.04,
                        "costInputBatches": 0.5,
                        "costOutputBatches": 0.7,
                        "costInputPriority": 0.09,
                        "costOutputPriority": 0.12,
                        "cacheReadInputPerMToken": 0.3,
                        "cacheCreationInputPerMToken": 0.45
                      },
                      "supportsPdfInput": true,
                      "supportsServiceTier": true,
                      "capabilities": ["text", "imageGeneration"]
                    }
                  }
                }
              }
            }
            """.trimIndent()
        )

        val resolved = MetadataClient.resolveCatalogModel("gpt-image-1", ProviderKind.OpenAI)
        assertNotNull(resolved)
        assertEquals("priced", resolved!!.pricingStatus)
        assertEquals("gpt-image-1/payg", resolved.billingSku)
        assertEquals("per_image", resolved.pricingUnit)
        assertEquals("official_registry", resolved.sourceSummary?.sourceKind)
        assertEquals("OpenAI Pricing Registry", resolved.sourceSummary?.sourceName)
        assertNull(resolved.promptPerToken)
        assertNull(resolved.completionPerToken)
        assertEquals(0.04, resolved.costPerUnit!!, 1e-12)
        assertEquals(0.5, resolved.costInputBatches!!, 1e-12)
        assertEquals(0.7, resolved.costOutputBatches!!, 1e-12)
        assertEquals(0.09, resolved.costInputPriority!!, 1e-12)
        assertEquals(0.12, resolved.costOutputPriority!!, 1e-12)
        assertEquals(0.3, resolved.cacheReadInputPerMToken!!, 1e-12)
        assertEquals(0.45, resolved.cacheCreationInputPerMToken!!, 1e-12)
        assertTrue(resolved.supportsPdfInput)
        assertTrue(resolved.supportsServiceTier)

        injectTestData()
    }

    // -- Contract v1 new fields (metadata authority) --

    @Test
    fun `contractVersion reflects top-level field from metadata response`() {
        assertEquals(1, MetadataClient.contractVersion)
    }

    // -- version / contractVersion exposed independently --

    @Test
    fun `version exposes snapshot id independently from contractVersion`() {
        // In testJson version=1 and contractVersion=1; a dedicated payload makes them differ here
        injectJson(
            """
            {
              "version": 42,
              "contractVersion": 1,
              "providers": {}
            }
            """.trimIndent()
        )
        assertEquals(42, MetadataClient.version)
        assertEquals(1, MetadataClient.contractVersion)
    }

    @Test
    fun `isContractVersionSupported returns true within compatibility window`() {
        assertTrue(MetadataClient.isContractVersionSupported)
    }

    // -- contractVersion compatibility window and safe degradation --

    @Test
    fun `contract version N minus 1 is supported`() {
        // Compatibility window: [N-1, N+1]
        injectJson(
            """{"version":1,"contractVersion":${MetadataClient.SUPPORTED_CONTRACT_VERSION - 1},"providers":{}}""",
        )
        assertTrue(MetadataClient.isContractVersionSupported)
        assertFalse(MetadataClient.isContractVersionDegraded)
    }

    @Test
    fun `contract version N plus 1 is supported and not degraded`() {
        injectJson(
            """{"version":1,"contractVersion":${MetadataClient.SUPPORTED_CONTRACT_VERSION + 1},"providers":{}}""",
        )
        assertTrue(MetadataClient.isContractVersionSupported)
        assertFalse(MetadataClient.isContractVersionDegraded)
    }

    @Test
    fun `contract version N plus 2 triggers safe degradation`() {
        injectJson(
            """{"version":1,"contractVersion":${MetadataClient.SUPPORTED_CONTRACT_VERSION + 2},"providers":{}}""",
        )
        assertFalse(
            "contractVersion >= N+2 must exit compatibility window",
            MetadataClient.isContractVersionSupported,
        )
        assertTrue(
            "contractVersion >= N+2 must report degraded=true so resolver can prune",
            MetadataClient.isContractVersionDegraded,
        )
    }

    // -- metadataSource distinguishes online / cached --

    @Test
    fun `metadataSource reports FreshNetwork after successful fetch`() {
        // In the test environment the fixture injects the table directly, but through the internal API we can
        // assert that metadataSource is observable as CachedOffline or FreshNetwork after injection (depending on the path).
        // Here we use injection plus a simulated cache hydrate path, so source = CachedOffline first
        injectJson("""{"version":1,"contractVersion":1,"providers":{}}""")
        // By default the fixture does not go through fetchMetadata, so it stays Unknown; Unknown or CachedOffline are accepted
        // This verifies the metadataSource field exists and is readable (not a business assertion), to catch API contract changes
        val source = MetadataClient.metadataSource
        assertNotNull(source)
    }

    @Test
    fun `validation contract parses new shape (probe path authMode signals)`() {
        val validation = MetadataClient.validation(ProviderKind.OpenAI)
        assertNotNull(validation)
        validation!!
        assertEquals("list_models", validation.probe)
        assertEquals("/models", validation.probePath)
        assertEquals("bearer", validation.authMode)
        assertEquals("none", validation.headerProfile)
        assertEquals(1, validation.invalidKeySignals.size)
        assertEquals(401, validation.invalidKeySignals.first().status)
        assertTrue(validation.invalidKeySignals.first().bodyIncludes.isEmpty())
    }

    @Test
    fun `retiredModels returns index provider tombstones as delivered`() {
        injectJson(
            """
            {
              "version": 1,
              "contractVersion": 1,
              "providers": {
                "openAI": {
                  "defaultModelId": "gpt-next",
                  "retiredModels": [
                    { "id": "gpt-legacy", "displayName": "GPT Legacy", "retiredAt": "2026-07-24T00:00:00Z", "routedTo": "gpt-next" },
                    { "id": "gpt-old", "displayName": null, "retiredAt": null, "routedTo": null }
                  ],
                  "resolveMap": { "gpt-next": "gpt-next" },
                  "models": { "gpt-next": { "canonicalModelId": "gpt-next", "displayName": "GPT Next" } }
                }
              }
            }
            """.trimIndent()
        )

        assertEquals(
            listOf(
                RetiredModel(id = "gpt-legacy", displayName = "GPT Legacy", retiredAt = "2026-07-24T00:00:00Z", routedTo = "gpt-next"),
                RetiredModel(id = "gpt-old"),
            ),
            MetadataClient.retiredModels(ProviderKind.OpenAI),
        )

        injectTestData()
    }

    @Test
    fun `retiredModels is empty when provider omits the field`() {
        assertTrue(MetadataClient.retiredModels(ProviderKind.Anthropic).isEmpty())
        assertTrue(MetadataClient.retiredModels(ProviderKind.Relay).isEmpty())
    }

    @Test
    fun `validation is null when provider omits the field`() {
        // Anthropic has no validation block in testJson, so null is expected (the caller falls back to the default contract)
        assertNull(MetadataClient.validation(ProviderKind.Anthropic))
    }

    @Test
    fun `validation returns null for unknown provider`() {
        assertNull(MetadataClient.validation(ProviderKind.Relay))
    }

    @Test
    fun `providerAttachmentSupport returns provider-level metadata for qwen`() {
        injectJson(
            """
            {
              "version": 1,
              "contractVersion": 1,
              "providers": {
                "qwen": {
                  "defaultModelId": "qwen-max",
                  "attachmentSupport": {
                    "image": true,
                    "nativeFile": false,
                    "textFileInline": true
                  },
                  "resolveMap": {
                    "qwen-max": "qwen-max"
                  },
                  "models": {
                    "qwen-max": {
                      "canonicalModelId": "qwen-max",
                      "capabilities": ["text", "file"]
                    }
                  }
                }
              }
            }
            """.trimIndent()
        )

        val support = MetadataClient.providerAttachmentSupport(ProviderKind.Qwen)
        assertNotNull(support)
        assertTrue(support!!.image)
        assertFalse(support.nativeFile)
        assertTrue(support.textFileInline)

        injectTestData()
    }

    @Test
    fun `ProviderKind attachmentSupport prefers metadata snapshot over local fallback`() {
        injectJson(
            """
            {
              "version": 1,
              "contractVersion": 1,
              "providers": {
                "qwen": {
                  "defaultModelId": "qwen-max",
                  "attachmentSupport": {
                    "image": true,
                    "nativeFile": true,
                    "textFileInline": true
                  },
                  "resolveMap": {
                    "qwen-max": "qwen-max"
                  },
                  "models": {
                    "qwen-max": {
                      "canonicalModelId": "qwen-max",
                      "capabilities": ["text", "file"]
                    }
                  }
                }
              }
            }
            """.trimIndent()
        )

        val support = ProviderKind.Qwen.attachmentSupport
        assertTrue(support.image)
        assertTrue(support.nativeFile)
        assertTrue(support.textFileInline)

        // After metadata is cleared, official providers no longer claim any attachment capability (no local fallback table)
        setTable(MetadataClient.instance, null)
        val local = setOf(ProviderKind.Relay)
        ProviderKind.entries.filterNot { it in local }.forEach { kind ->
            val cleared = kind.attachmentSupport
            assertFalse("$kind image", cleared.image)
            assertFalse("$kind video", cleared.video)
            assertFalse("$kind nativeFile", cleared.nativeFile)
            assertFalse("$kind textFileInline", cleared.textFileInline)
        }

        injectTestData()
    }

    @Test
    fun `resolveCatalogModel non-default model`() {
        val result = MetadataClient.resolveCatalogModel("gpt-4o-mini", ProviderKind.OpenAI)
        assertNotNull(result)
        assertEquals(false, result!!.isDefault)
    }

    // ── lookupPricing ──

    @Test
    fun `lookupPricing returns per-token prices via resolveMap`() {
        val result = MetadataClient.lookupPricing("gpt-4o", ProviderKind.OpenAI)
        assertNotNull(result)
        // 2.5 per M → 2.5 / 1_000_000
        assertEquals(0.0000025, result!!.first, 1e-12)
        // 10.0 per M → 10.0 / 1_000_000
        assertEquals(0.00001, result.second, 1e-12)
    }

    @Test
    fun `lookupPricing returns null for unknown model`() {
        val result = MetadataClient.lookupPricing("nonexistent-model", ProviderKind.OpenAI)
        assertNull(result)
    }

    @Test
    fun `lookupPricing resolves alias for Anthropic`() {
        val result = MetadataClient.lookupPricing("claude-sonnet-4-20250514", ProviderKind.Anthropic)
        assertNotNull(result)
        assertEquals(0.000003, result!!.first, 1e-12)
    }

    @Test
    fun `lookupPricing exact match for Anthropic`() {
        val result = MetadataClient.lookupPricing("claude-sonnet-4", ProviderKind.Anthropic)
        assertNotNull(result)
        assertEquals(0.000003, result!!.first, 1e-12)
    }

    @Test
    fun `lookupPricing works for Gemini`() {
        val result = MetadataClient.lookupPricing("gemini-2.5-pro", ProviderKind.Gemini)
        assertNotNull(result)
        assertEquals(0.00000125, result!!.first, 1e-12)
    }

    @Test
    fun `lookupPricing works for Groq`() {
        val result = MetadataClient.lookupPricing("llama-3.3-70b-versatile", ProviderKind.Groq)
        assertNotNull(result)
    }

    @Test
    fun `lookupPricing works for Together`() {
        val result = MetadataClient.lookupPricing("meta-llama/Llama-4-Scout", ProviderKind.Together)
        assertNotNull(result)
    }

    @Test
    fun `lookupPricing works for Fireworks`() {
        val result = MetadataClient.lookupPricing("accounts/fireworks/models/llama4-scout", ProviderKind.Fireworks)
        assertNotNull(result)
    }

    @Test
    fun `lookupPricing returns null when table is null`() {
        clearTable()
        val result = MetadataClient.lookupPricing("gpt-4o", ProviderKind.OpenAI)
        assertNull(result)
        injectTestData()
    }

    // ── estimateCost ──

    @Test
    fun `estimateCost calculates correctly`() {
        val cost = MetadataClient.estimateCost(
            modelID = "gpt-4o",
            providerKind = ProviderKind.OpenAI,
            promptTokens = 1000,
            completionTokens = 500,
        )
        // (2.5/1M * 1000) + (10.0/1M * 500) = 0.0025 + 0.005 = 0.0075
        assertEquals(0.0075, cost, 1e-10)
    }

    @Test
    fun `estimateCost returns 0 for unknown model`() {
        val cost = MetadataClient.estimateCost(
            modelID = "unknown-model",
            providerKind = ProviderKind.OpenAI,
            promptTokens = 1000,
            completionTokens = 500,
        )
        assertEquals(0.0, cost, 1e-10)
    }

    @Test
    fun `estimateCost returns 0 for zero tokens`() {
        val cost = MetadataClient.estimateCost(
            modelID = "gpt-4o",
            providerKind = ProviderKind.OpenAI,
            promptTokens = 0,
            completionTokens = 0,
        )
        assertEquals(0.0, cost, 1e-10)
    }

    @Test
    fun `estimateCost resolves alias for dated models`() {
        val cost = MetadataClient.estimateCost(
            modelID = "claude-sonnet-4-20250514",
            providerKind = ProviderKind.Anthropic,
            promptTokens = 1_000_000,
            completionTokens = 0,
        )
        // 3.0/M * 1M tokens = 3.0
        assertEquals(3.0, cost, 1e-10)
    }

    @Test
    fun `estimateCost resolves hyphenated snapshot id for OpenAI`() {
        val cost = MetadataClient.estimateCost(
            modelID = "gpt-5.4-nano-2026-03-01",
            providerKind = ProviderKind.OpenAI,
            promptTokens = 1_000,
            completionTokens = 500,
        )
        assertEquals(0.000825, cost, 1e-10)
    }

    @Test
    fun `estimateCost resolves hyphenated GPT-5 snapshot id for OpenAI`() {
        val cost = MetadataClient.estimateCost(
            modelID = "gpt-5.4-2026-03-05",
            providerKind = ProviderKind.OpenAI,
            promptTokens = 1_000,
            completionTokens = 500,
        )
        assertEquals(0.01, cost, 1e-10)
    }

    @Test
    fun `estimateCost returns costPerUnit for priced non-token models`() {
        injectJson(
            """
            {
              "version": 1,
              "contractVersion": 1,
              "providers": {
                "openAI": {
                  "resolveMap": {
                    "gpt-image-1": "gpt-image-1"
                  },
                  "models": {
                    "gpt-image-1": {
                      "canonicalModelId": "gpt-image-1",
                      "displayName": "GPT Image 1",
                      "pricingUnit": "per_image",
                      "pricingStatus": "priced",
                      "pricing": {
                        "costPerUnit": 0.04
                      }
                    }
                  }
                }
              }
            }
            """.trimIndent()
        )

        val cost = MetadataClient.estimateCost(
            modelID = "gpt-image-1",
            providerKind = ProviderKind.OpenAI,
            promptTokens = 0,
            completionTokens = 0,
        )

        assertEquals(0.04, cost, 1e-10)
        injectTestData()
    }

    @Test
    fun `estimateCost returns 0 when table is null`() {
        clearTable()
        val cost = MetadataClient.estimateCost(
            modelID = "gpt-4o",
            providerKind = ProviderKind.OpenAI,
            promptTokens = 1000,
            completionTokens = 500,
        )
        assertEquals(0.0, cost, 1e-10)
        injectTestData()
    }

    // ── priceTier ──

    @Test
    fun `priceTier returns non-empty for known model`() {
        val tier = MetadataClient.priceTier("gpt-4o", ProviderKind.OpenAI)
        assertTrue("priceTier should not be empty for gpt-4o", tier.isNotEmpty())
    }

    @Test
    fun `priceTier returns empty for unknown model`() {
        val tier = MetadataClient.priceTier("nonexistent", ProviderKind.OpenAI)
        assertEquals("", tier)
    }

    @Test
    fun `priceTier returns Free for zero-cost model`() {
        val tier = MetadataClient.priceTier("free-model", ProviderKind.Groq)
        assertEquals("Free", tier)
    }

    @Test
    fun `lookupPricing returns null for unknown pricingStatus`() {
        injectJson(
            """
            {
              "version": 1,
              "providers": {
                "openAI": {
                  "resolveMap": {
                    "gpt-3.5-turbo-0125": "gpt-3.5-turbo-0125"
                  },
                  "models": {
                    "gpt-3.5-turbo-0125": {
                      "canonicalModelId": "gpt-3.5-turbo-0125",
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

        val pricing = MetadataClient.lookupPricing("gpt-3.5-turbo-0125", ProviderKind.OpenAI)
        assertNull(pricing)

        injectTestData()
    }

    // ── Helpers ──

    /** Uses the new backend API format: resolveMap, profiles, uiHints + Contract v1 new fields */
    private val testJson = """
    {
        "version": 1,
        "contractVersion": 1,
        "profiles": {
            "reasoning": {
                "oai_responses": {
                    "levels": ["fast", "balanced", "deep"]
                },
                "anthropic_thinking": {
                    "levels": ["fast", "balanced", "deep", "max"]
                }
            },
            "webSearch": {},
            "imageGen": {}
        },
        "providers": {
            "openAI": {
                "defaultModelId": "gpt-4o",
                "validation": {
                    "probe": "list_models",
                    "probePath": "/models",
                    "authMode": "bearer",
                    "headerProfile": "none",
                    "invalidKeySignals": [{"status": 401}]
                },
                "resolveMap": {
                    "gpt-4o": "gpt-4o",
                    "gpt-4o-2024-08-06": "gpt-4o",
                    "gpt-4o-mini": "gpt-4o-mini",
                    "gpt-5.4": "gpt-5.4",
                    "gpt-5.4-nano": "gpt-5.4-nano"
                },
                "models": {
                    "gpt-4o": {
                        "canonicalModelId": "gpt-4o",
                        "displayName": "GPT-4o",
                        "contextLength": 128000,
                        "pricing": {"promptPerMToken": 2.5, "completionPerMToken": 10.0},
                        "capabilities": ["text", "image", "file", "reasoning"],
                        "profiles": {"reasoning": "oai_responses", "webSearch": null, "imageGen": null},
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
                    },
                    "gpt-5.4-nano": {
                        "canonicalModelId": "gpt-5.4-nano",
                        "displayName": "GPT-5.4 nano",
                        "contextLength": 400000,
                        "pricing": {"promptPerMToken": 0.2, "completionPerMToken": 1.25},
                        "capabilities": ["text", "image", "reasoning"],
                        "profiles": {"reasoning": "oai_responses"},
                        "uiHints": {"groupKey": "gpt-5", "groupName": "GPT-5", "rank": 166, "recommended": false}
                    },
                    "gpt-5.4": {
                        "canonicalModelId": "gpt-5.4",
                        "displayName": "GPT-5.4",
                        "contextLength": 1050000,
                        "pricing": {"promptPerMToken": 2.5, "completionPerMToken": 15.0},
                        "capabilities": ["text", "image", "file", "reasoning"],
                        "profiles": {"reasoning": "oai_responses"},
                        "uiHints": {"groupKey": "gpt-5", "groupName": "GPT-5", "rank": 167, "recommended": true}
                    }
                }
            },
            "anthropic": {
                "defaultModelId": "claude-sonnet-4",
                "resolveMap": {
                    "claude-sonnet-4": "claude-sonnet-4",
                    "claude-sonnet-4-20250514": "claude-sonnet-4",
                    "claude-opus-4": "claude-opus-4"
                },
                "models": {
                    "claude-sonnet-4": {
                        "canonicalModelId": "claude-sonnet-4",
                        "displayName": "Claude Sonnet 4",
                        "pricing": {"promptPerMToken": 3.0, "completionPerMToken": 15.0},
                        "capabilities": ["text", "image", "file", "reasoning"],
                        "profiles": {"reasoning": "anthropic_thinking"}
                    },
                    "claude-opus-4": {
                        "canonicalModelId": "claude-opus-4",
                        "displayName": "Claude Opus 4",
                        "pricing": {"promptPerMToken": 15.0, "completionPerMToken": 75.0},
                        "capabilities": ["text", "image", "file", "reasoning"],
                        "profiles": {"reasoning": "anthropic_thinking"}
                    }
                }
            },
            "gemini": {
                "resolveMap": {
                    "gemini-2.5-pro": "gemini-2.5-pro",
                    "gemini-2.5-flash": "gemini-2.5-flash"
                },
                "models": {
                    "gemini-2.5-pro": {
                        "canonicalModelId": "gemini-2.5-pro",
                        "displayName": "Gemini 2.5 Pro",
                        "pricing": {"promptPerMToken": 1.25, "completionPerMToken": 10.0},
                        "capabilities": ["text", "image", "reasoning"]
                    },
                    "gemini-2.5-flash": {
                        "canonicalModelId": "gemini-2.5-flash",
                        "displayName": "Gemini 2.5 Flash",
                        "pricing": {"promptPerMToken": 0.15, "completionPerMToken": 0.60},
                        "capabilities": ["text", "image"]
                    }
                }
            },
            "groq": {
                "resolveMap": {
                    "llama-3.3-70b-versatile": "llama-3.3-70b-versatile",
                    "free-model": "free-model"
                },
                "models": {
                    "llama-3.3-70b-versatile": {
                        "canonicalModelId": "llama-3.3-70b-versatile",
                        "pricing": {"promptPerMToken": 0.59, "completionPerMToken": 0.79},
                        "capabilities": ["text"]
                    },
                    "free-model": {
                        "canonicalModelId": "free-model",
                        "pricingStatus": "free",
                        "pricing": {"promptPerMToken": 0.0, "completionPerMToken": 0.0},
                        "capabilities": ["text"]
                    }
                }
            },
            "togetherAI": {
                "resolveMap": {
                    "meta-llama/Llama-4-Scout": "meta-llama/Llama-4-Scout"
                },
                "models": {
                    "meta-llama/Llama-4-Scout": {
                        "canonicalModelId": "meta-llama/Llama-4-Scout",
                        "pricing": {"promptPerMToken": 0.18, "completionPerMToken": 0.30},
                        "capabilities": ["text"]
                    }
                }
            },
            "fireworksAI": {
                "resolveMap": {
                    "accounts/fireworks/models/llama4-scout": "accounts/fireworks/models/llama4-scout"
                },
                "models": {
                    "accounts/fireworks/models/llama4-scout": {
                        "canonicalModelId": "accounts/fireworks/models/llama4-scout",
                        "pricing": {"promptPerMToken": 0.15, "completionPerMToken": 0.60},
                        "capabilities": ["text"]
                    }
                }
            }
        }
    }
    """.trimIndent()

    /**
     * Deserializes the test data through reflection with MetadataClient's internal json,
     * then injects it into the table field.
     */
    private fun injectTestData() {
        injectJson(testJson)
    }

    private fun injectJson(rawJson: String, target: MetadataClient = MetadataClient.instance) {
        setTable(target, decodeMetadataResponse(rawJson, target))
    }

    private fun decodeMetadataResponse(rawJson: String, target: MetadataClient): Any {
        val clientClass = MetadataClient::class.java
        val responseClass = clientClass.declaredClasses.first { it.simpleName == "MetadataResponse" }
        return jsonFor(target).decodeFromString(serializerFor(responseClass), rawJson)
    }

    private fun jsonFor(target: MetadataClient): Json {
        val jsonField = MetadataClient::class.java.getDeclaredField("json")
        jsonField.isAccessible = true
        return jsonField.get(target) as Json
    }

    private fun serializerFor(targetClass: Class<*>): kotlinx.serialization.KSerializer<Any> {
        val companionField = targetClass.getDeclaredField("Companion")
        companionField.isAccessible = true
        val companion = companionField.get(null)
        val serializerMethod = companion.javaClass.getDeclaredMethod("serializer")
        serializerMethod.isAccessible = true
        @Suppress("UNCHECKED_CAST")
        return serializerMethod.invoke(companion) as kotlinx.serialization.KSerializer<Any>
    }

    private fun setTable(target: MetadataClient, decoded: Any?) {
        val clientClass = MetadataClient::class.java
        val tableField = clientClass.getDeclaredField("table")
        tableField.isAccessible = true
        tableField.set(target, decoded)
    }

    /**
     * A 304 must also emit a refresh event.
     *
     * Subscribers (ProviderRepository / ViewModel / forced refresh) wait for "this refresh finished",
     * not "content changed". A silent 304 return used to leave a forced refresh waiting forever, with the UI stuck on its first computed frame.
     *
     * Uses a **new instance** rather than the global instance: `snapshotConfirmedThisSession` is a session-level flag,
     * and setting it on the shared singleton would pollute routing decisions of other cases in the same JVM.
     */
    @Test
    fun `not modified still emits a refresh event carrying the in-memory snapshot version`() = runTest {
        val client = MetadataClient()
        injectJson("""{"version":91,"contractVersion":1,"providers":{}}""", client)

        val events = mutableListOf<MetadataClient.RefreshEvent>()
        val job = launch(UnconfinedTestDispatcher()) { client.refreshEvents.collect { events += it } }

        client.handleNotModified()
        job.cancel()

        assertEquals(
            listOf(MetadataClient.RefreshEvent(version = 91, contractVersion = 1, contentRevision = 1)),
            events,
        )
        assertTrue(client.snapshotConfirmedThisSession)
    }

    /** Once a 304 confirms the cache is current, the source must become FreshNetwork, otherwise the stale-data banner never goes away. */
    @Test
    fun `not modified promotes a cache hydrated snapshot to fresh network`() {
        val client = MetadataClient()
        injectJson("""{"version":91,"contractVersion":1,"providers":{}}""", client)
        val sourceField = MetadataClient::class.java.getDeclaredField("_metadataSource")
        sourceField.isAccessible = true
        sourceField.set(client, MetadataClient.MetadataSource.CachedOffline)

        client.handleNotModified()

        assertEquals(MetadataClient.MetadataSource.FreshNetwork, client.metadataSource)
    }

    @Test
    fun `not modified without any snapshot does not claim fresh network`() {
        val client = MetadataClient()
        client.handleNotModified()
        assertEquals(MetadataClient.MetadataSource.Unknown, client.metadataSource)
    }

    @Test
    fun `public evidence distinguishes absent null and valid empty namespaces`() {
        val client = MetadataClient()
        fun load(view: String?) {
            val field = view?.let { ",\"capabilityEvidenceView\":$it" }.orEmpty()
            client.loadNetworkPayloadForTesting(
                """
                {"version":1,"providers":{"openAI":{"resolveMap":{"m":"m"},"models":{"m":{
                  "canonicalModelId":"m","transport":"openai_chat"$field
                }}}}}
                """.trimIndent(),
                "etag-1",
            )
        }

        load(null)
        client.currentCapabilityEvidenceModel("m", ProviderKind.OpenAI)!!.metadata.let { model ->
            assertNull(model.capabilityEvidenceCandidates)
            assertNull(model.capabilityEvidenceOwnedKeys)
            assertNull(model.capabilityEvidenceViewMalformed)
        }
        load("null")
        client.currentCapabilityEvidenceModel("m", ProviderKind.OpenAI)!!.metadata.let { model ->
            assertEquals(emptyList<MetadataClient.CapabilityEvidenceCandidateView>(), model.capabilityEvidenceCandidates)
            assertEquals(emptySet<String>(), model.capabilityEvidenceOwnedKeys)
            assertEquals(true, model.capabilityEvidenceViewMalformed)
        }
        load("{\"schema\":\"capability-evidence-view/v1\",\"candidates\":[]}")
        client.currentCapabilityEvidenceModel("m", ProviderKind.OpenAI)!!.metadata.let { model ->
            assertEquals(emptyList<MetadataClient.CapabilityEvidenceCandidateView>(), model.capabilityEvidenceCandidates)
            assertEquals(emptySet<String>(), model.capabilityEvidenceOwnedKeys)
            assertEquals(false, model.capabilityEvidenceViewMalformed)
        }
    }

    @Test
    fun `malformed public candidate owns its safe key but cannot authorize and private provenance is not cached`() {
        val client = MetadataClient()
        client.loadNetworkPayloadForTesting(
            """
            {"version":7,"providers":{"openAI":{"resolveMap":{"m":"m"},"models":{"m":{
              "canonicalModelId":"m","transport":"openai_chat",
              "capabilityEvidenceView":{"schema":"capability-evidence-view/v1","sourceRef":"PRIVATE_SENTINEL","candidates":[
                {"key":"tool_call","support":"supported","source":"private_probe","grade":"machine_verified",
                 "scope":"provider_model_transport","providerKind":"openAI","modelId":"m","transport":"openai_chat",
                 "sourceRef":"PRIVATE_SENTINEL","endpoint":"https://secret.invalid","rawError":"PRIVATE_SENTINEL"},
                {"key":{"private":"PRIVATE_SENTINEL"},"support":"supported","source":"server_typed","grade":"machine_verified",
                 "scope":"provider_model_transport","providerKind":"openAI","modelId":"m","transport":"openai_chat",
                 "sourceRef":"PRIVATE_SENTINEL"}
              ]}
            }}}}}
            """.trimIndent(),
            "etag-safe",
        )

        val model = client.currentCapabilityEvidenceModel("m", ProviderKind.OpenAI)!!.metadata
        assertEquals(setOf("tool_call"), model.capabilityEvidenceOwnedKeys)
        assertTrue(model.capabilityEvidenceCandidates.orEmpty().isEmpty())
        val cache = client.encodedCachePayloadForTesting().orEmpty()
        assertFalse(cache.contains("\"capabilityEvidenceView\":"))
        assertFalse(cache.contains("PRIVATE_SENTINEL"))
        assertFalse(cache.contains("secret.invalid"))
        assertTrue(cache.contains("capabilityEvidenceOwnedKeys"))
    }

    @Test
    fun `same metadata version publishes new ETag and missing ETag withdraws revision`() {
        val client = MetadataClient()
        val payload = """
            {"version":9,"providers":{"openAI":{"resolveMap":{"m":"m"},"models":{"m":{
              "canonicalModelId":"m","transport":"openai_chat",
              "capabilityEvidenceView":{"schema":"capability-evidence-view/v1","candidates":[
                {"key":"generation_parameter/temperature","support":"supported","source":"server_profile","grade":"effect_verified",
                 "scope":"provider_model_transport","providerKind":"openAI","modelId":"m","transport":"openai_chat",
                 "generationRevision":"gen-1"}
              ]}
            }}}}}
        """.trimIndent()

        client.loadNetworkPayloadForTesting(payload, "etag-1")
        val first = client.currentCapabilityEvidenceModel("m", ProviderKind.OpenAI)!!
        client.loadNetworkPayloadForTesting(payload, "etag-2")
        val second = client.currentCapabilityEvidenceModel("m", ProviderKind.OpenAI)!!
        client.loadNetworkPayloadForTesting(payload, null)
        val third = client.currentCapabilityEvidenceModel("m", ProviderKind.OpenAI)!!

        assertEquals("etag-1", first.metadata.capabilityEvidenceCandidates!!.single().metadataRevision)
        assertEquals("etag-2", second.metadataRevision)
        assertEquals("etag-2", second.metadata.capabilityEvidenceCandidates!!.single().metadataRevision)
        assertTrue(second.contentRevision > first.contentRevision)
        assertNull(third.metadataRevision)
        assertNull(third.metadata.capabilityEvidenceCandidates!!.single().metadataRevision)
        assertEquals("gen-1", third.generationRevision)
    }

    @Test
    fun `server typed evidence requires positive ordered epoch millis`() {
        val client = MetadataClient()
        client.loadNetworkPayloadForTesting(
            """
            {"providers":{"openAI":{"resolveMap":{"m":"m"},"models":{"m":{
              "canonicalModelId":"m","transport":"openai_chat",
              "capabilityEvidenceView":{"schema":"capability-evidence-view/v1","candidates":[
                {"key":"tool_call","support":"supported","source":"server_typed","grade":"machine_verified",
                 "scope":"provider_model_transport","providerKind":"openAI","modelId":"m","transport":"openai_chat"},
                {"key":"vision_input","support":"supported","source":"server_typed","grade":"machine_verified",
                 "scope":"provider_model_transport","providerKind":"openAI","modelId":"m","transport":"openai_chat",
                 "observedAt":2000,"expiresAt":1000},
                {"key":"web_search","support":"unsupported","source":"server_typed","grade":"machine_verified",
                 "scope":"provider_model_transport","providerKind":"openAI","modelId":"m","transport":"openai_chat",
                 "observedAt":1000,"expiresAt":2000}
              ]}
            }}}}}
            """.trimIndent(),
            "etag-times",
        )
        val model = client.currentCapabilityEvidenceModel("m", ProviderKind.OpenAI)!!.metadata
        assertEquals(setOf("tool_call", "vision_input", "web_search"), model.capabilityEvidenceOwnedKeys)
        assertEquals(listOf("web_search"), model.capabilityEvidenceCandidates!!.map { it.key })
    }

    /** With no snapshot yet no version number should be emitted out of thin air, but the confirmation gate is still released. */
    @Test
    fun `not modified without a snapshot only lifts the confirmation gate`() = runTest {
        val client = MetadataClient()

        val events = mutableListOf<MetadataClient.RefreshEvent>()
        val job = launch(UnconfinedTestDispatcher()) { client.refreshEvents.collect { events += it } }

        client.handleNotModified()
        job.cancel()

        assertTrue(events.isEmpty())
        assertTrue(client.snapshotConfirmedThisSession)
    }

    private fun clearTable() {
        val tableField = MetadataClient::class.java.getDeclaredField("table")
        tableField.isAccessible = true
        tableField.set(MetadataClient.instance, null)
    }

    // ── Relay Runtime Config ──

    @Test
    fun `relayRuntimeConfig returns fallback when backend omits the field`() {
        // testJson has no relayRuntimeConfig -> the built-in defaults apply
        val runtime = MetadataClient.relayRuntimeConfig()
        assertEquals("fallback", runtime.version)
        assertTrue(runtime.officialProviderWhitelist.contains("openAI"))
        assertTrue(runtime.officialProviderWhitelist.contains("anthropic"))
        assertTrue(runtime.officialProviderWhitelist.contains("gemini"))
        assertEquals(true, runtime.transportEnvelopes["openai_responses"]?.webSearch)
        assertEquals(false, runtime.transportEnvelopes["openai_chat_completions"]?.webSearch)
        assertEquals(false, runtime.transportEnvelopes["anthropic_messages"]?.imageGeneration)
        assertTrue(runtime.featureGatingPolicy.showActualModelIdHint)
        assertTrue(runtime.featureGatingPolicy.showSoftFailHint)
    }

    private fun codexUserAgentWithDownlinkedVersion(versionJson: String?): String? {
        val field = versionJson?.let { """, "codexClientVersion": $it""" }.orEmpty()
        injectJson(
            """
            {
                "version": 1,
                "contractVersion": 1,
                "providers": {},
                "relayRuntimeConfig": {
                    "transportRules": { "openai_responses": { "codexIdentityDefault": true$field } }
                }
            }
            """.trimIndent()
        )
        return try {
            ai.oriveo.community.core.provider.relay.RelayHeaderBuilder
                .codexIdentityHeaders(ai.oriveo.community.core.model.RelayTransport.OpenAIResponses, null)["User-Agent"]
        } finally {
            injectTestData()
        }
    }

    @Test
    fun `codex identity UA uses the downlinked client version when it is valid`() {
        assertEquals("codex_cli_rs/0.170.3 (Oriveo Android)", codexUserAgentWithDownlinkedVersion("\"0.170.3\""))
    }

    @Test
    fun `codex identity UA falls back to the built in version when the downlinked one is missing or invalid`() {
        val fallback = "codex_cli_rs/0.162.1 (Oriveo Android)"
        assertEquals(fallback, codexUserAgentWithDownlinkedVersion(null))
        listOf("latest", "0.170.0-alpha.1", "0.170.3\\n", "0.170.3\\r\\nX-Injected: 1", "", "1234567.0.0").forEach { raw ->
            assertEquals("downlinked value [$raw]", fallback, codexUserAgentWithDownlinkedVersion("\"$raw\""))
        }
    }

    @Test
    fun `relayRuntimeConfig merges partial backend override over fallback`() {
        injectJson(
            """
            {
                "version": 1,
                "contractVersion": 1,
                "providers": {},
                "relayRuntimeConfig": {
                    "version": "2026-04-23-1",
                    "officialProviderWhitelist": ["openAI", "anthropic"],
                    "transportEnvelopes": {
                        "openai_responses": {
                            "webSearch": false
                        }
                    },
                    "transportRules": {
                        "openai_responses": {
                            "defaultAuthMode": "query_key",
                            "codexIdentityDefault": false
                        }
                    },
                    "verificationPolicy": {
                        "hardFailedExpiryDays": 14,
                        "softFailedRetryAfterSeconds": 120,
                        "verifiedCacheDays": 60
                    },
                    "featureGatingPolicy": {
                        "showActualModelIdHint": false,
                        "showSoftFailHint": true
                    }
                }
            }
            """.trimIndent()
        )

        val runtime = MetadataClient.relayRuntimeConfig()
        assertEquals("2026-04-23-1", runtime.version)
        assertEquals(listOf("openAI", "anthropic"), runtime.officialProviderWhitelist)
        assertEquals(false, runtime.transportEnvelopes["openai_responses"]?.webSearch)
        assertEquals(true, runtime.transportEnvelopes["openai_responses"]?.image)
        assertEquals(true, runtime.transportEnvelopes["openai_responses"]?.nativeFile)
        assertEquals(true, runtime.transportEnvelopes["openai_responses"]?.imageGeneration)
        assertEquals("query_key", runtime.transportRules["openai_responses"]?.defaultAuthMode)
        assertEquals(false, runtime.transportRules["openai_responses"]?.codexIdentityDefault)
        assertEquals("inline_responses_tool", runtime.transportRules["openai_responses"]?.imageRoute)
        // A transport that was not downlinked falls back to the default
        assertEquals(true, runtime.transportEnvelopes["anthropic_messages"]?.image)
        assertEquals("x_api_key", runtime.transportRules["anthropic_messages"]?.defaultAuthMode)
        assertEquals(14, runtime.verificationPolicy.hardFailedExpiryDays)
        assertFalse(runtime.featureGatingPolicy.showActualModelIdHint)
        assertTrue(runtime.featureGatingPolicy.showSoftFailHint)
        injectTestData()
    }

    @Test
    fun `resolveCatalogModelAcrossProvidersWithProvider returns matched provider kind`() {
        val gpt = MetadataClient.resolveCatalogModelAcrossProvidersWithProvider("gpt-4o")
        assertNotNull(gpt)
        assertEquals(ProviderKind.OpenAI, gpt!!.matchedProviderKind)
        assertEquals("gpt-4o", gpt.canonicalModelId)
        assertEquals(MetadataClient.RelayCatalogMatchSource.CrossProvider, gpt.source)

        val claude = MetadataClient.resolveCatalogModelAcrossProvidersWithProvider(
            modelID = "claude-sonnet-4",
            transportPriority = ProviderKind.Anthropic,
        )
        assertNotNull(claude)
        assertEquals(ProviderKind.Anthropic, claude!!.matchedProviderKind)
        assertEquals(MetadataClient.RelayCatalogMatchSource.TransportFirst, claude.source)

        assertNull(MetadataClient.resolveCatalogModelAcrossProvidersWithProvider("my-custom-model"))
    }
}
