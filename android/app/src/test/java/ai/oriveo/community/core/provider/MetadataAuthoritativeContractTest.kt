package ai.oriveo.community.core.provider

import ai.oriveo.community.core.data.remote.MetadataClient
import ai.oriveo.community.core.model.ModelCapability
import ai.oriveo.community.core.model.ProviderKind
import kotlinx.serialization.KSerializer
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.jsonObject
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import java.nio.file.Files
import java.nio.file.Path
import java.nio.file.Paths

/**
 * Contract test over `shared/model-contracts/metadata_authoritative_contract.v1.json`: the fixture's `metadata`
 * subtree is injected into MetadataClient.table by reflection, then the parsing behaviour is asserted entry by entry.
 *
 * If the behaviour here drifts away from the shared fixture this test has to turn red, so the drift cannot be
 * committed.
 */
class MetadataAuthoritativeContractTest {

    // -- Fixture schema; only the parsing assertions need it, since the metadata subtree is injected as a JsonObject --

    @Serializable
    private data class ContractFile(
        val contractVersion: Int,
        val version: Int,
        val metadata: JsonObject,
        val topLevelExpectations: TopLevelExpectations,
        val providerExpectations: List<ProviderExpectation> = emptyList(),
        val modelExpectations: List<ModelExpectation> = emptyList(),
        val negativeExpectations: List<NegativeExpectation> = emptyList(),
        val vendorIntegrityExpectations: VendorIntegrityExpectations,
    )

    @Serializable
    private data class TopLevelExpectations(
        val expectedContractVersion: Int,
        val expectedVersion: Int,
        val requiredTopLevelFields: List<String> = emptyList(),
        val requiredProviderFields: List<String> = emptyList(),
    )

    @Serializable
    private data class ProviderExpectation(
        val id: String,
        val providerKind: String,
        val expectedDefaultModelId: String,
        val expectedCanonicalModelCount: Int,
        val expectedAttachmentSupport: AttachmentSupportExpectation,
    )

    @Serializable
    private data class AttachmentSupportExpectation(
        val image: Boolean,
        val nativeFile: Boolean,
        val textFileInline: Boolean,
    )

    @Serializable
    private data class ModelExpectation(
        val id: String,
        val providerKind: String,
        val query: String,
        val expectedCanonicalModelId: String,
        val expectedDisplayName: String? = null,
        val expectedContextLength: Int? = null,
        val expectedMaxOutputTokens: Int? = null,
        val expectedSupportsTemperature: Boolean? = null,
        val expectedPricingStatus: String,
        val expectedPromptPerMToken: Double? = null,
        val expectedCompletionPerMToken: Double? = null,
        val expectedCachedInputPerMToken: Double? = null,
        val expectedCapabilities: List<String> = emptyList(),
        val expectedReasoningProfile: String? = null,
        val expectedWebSearchProfile: String? = null,
        val expectedImageGenProfile: String? = null,
        val expectedVendorKey: String? = null,
        val expectedVendorName: String? = null,
        val expectedGroupKey: String? = null,
        val expectedGroupName: String? = null,
        val expectedRecommended: Boolean = false,
        val expectedBadgeOrder: List<String> = emptyList(),
        val expectedIsDefault: Boolean = false,
    )

    @Serializable
    private data class NegativeExpectation(
        val id: String,
        val providerKind: String,
        val query: String,
        val expectedResolved: Boolean,
    )

    @Serializable
    private data class VendorIntegrityExpectations(
        val aggregatorProviders: List<String> = emptyList(),
        val directProviders: List<String> = emptyList(),
        val expectations: List<VendorExpectation> = emptyList(),
    )

    @Serializable
    private data class VendorExpectation(
        val providerKind: String,
        val modelId: String,
        val vendorKey: String? = null,
        val vendorName: String? = null,
    )

    private val json = Json { ignoreUnknownKeys = true; isLenient = true }

    private val contract: ContractFile by lazy {
        val path = contractCandidates()
            .firstOrNull { Files.exists(it) }
            ?.normalize()
            ?: error("metadata authoritative contract fixture not found")
        json.decodeFromString(path.toFile().readText())
    }

    @Before
    fun setUp() {
        injectContractMetadata()
    }

    @After
    fun tearDown() {
        clearMetadataTable()
    }

    // ── Tests ──

    @Test
    fun `fixture loads and top-level contract is exposed`() {
        assertEquals(1, contract.contractVersion)
        assertEquals(999, contract.version)

        val top = contract.topLevelExpectations
        assertEquals(top.expectedContractVersion, MetadataClient.contractVersion)
        assertEquals(top.expectedVersion, MetadataClient.version)
        assertTrue(
            "contractVersion ${MetadataClient.contractVersion} must sit within supported window",
            MetadataClient.isContractVersionSupported,
        )
        assertFalse(MetadataClient.isContractVersionDegraded)

        // The required top-level fields exist in the fixture's metadata subtree
        val md = contract.metadata
        top.requiredTopLevelFields.forEach { field ->
            assertTrue("metadata missing required top-level field `$field`", md.containsKey(field))
        }
        // and so do the required fields of each provider
        val providers = (md["providers"] as? JsonObject)
            ?: error("fixture metadata missing `providers`")
        providers.forEach { (providerKey, providerNode) ->
            val providerObj = (providerNode as? JsonObject)
                ?: error("provider `$providerKey` is not an object")
            top.requiredProviderFields.forEach { field ->
                assertTrue(
                    "provider `$providerKey` missing required field `$field`",
                    providerObj.containsKey(field),
                )
            }
        }
    }

    @Test
    fun `provider expectations (default, attachmentSupport, canonical count) stay aligned`() {
        contract.providerExpectations.forEach { expect ->
            val kind = providerKind(expect.providerKind)

            assertEquals(
                "provider ${expect.id}: defaultModelId",
                expect.expectedDefaultModelId,
                MetadataClient.defaultModelId(kind),
            )
            assertEquals(
                "provider ${expect.id}: canonical model count",
                expect.expectedCanonicalModelCount,
                MetadataClient.providerModelIds(kind).size,
            )

            val attachment = MetadataClient.providerAttachmentSupport(kind)
            assertNotNull("provider ${expect.id}: attachmentSupport missing", attachment)
            attachment!!
            assertEquals(
                "provider ${expect.id}: attachmentSupport.image",
                expect.expectedAttachmentSupport.image,
                attachment.image,
            )
            assertEquals(
                "provider ${expect.id}: attachmentSupport.nativeFile",
                expect.expectedAttachmentSupport.nativeFile,
                attachment.nativeFile,
            )
            assertEquals(
                "provider ${expect.id}: attachmentSupport.textFileInline",
                expect.expectedAttachmentSupport.textFileInline,
                attachment.textFileInline,
            )
        }
    }

    @Test
    fun `validation contract parses probe path authMode headerProfile signals`() {
        // The list_models shape (qwen, miniMax, zhipu, siliconFlow): bearer + none + a 401 signal.
        listOf("qwen", "miniMax", "zhipu", "siliconFlow").forEach { kindRaw ->
            val kind = providerKind(kindRaw)
            val validation = MetadataClient.validation(kind)
            assertNotNull("$kindRaw has no validation contract", validation)
            validation!!
            assertEquals("$kindRaw probe mismatch", "list_models", validation.probe)
            assertEquals("$kindRaw probePath mismatch", "/models", validation.probePath)
            assertEquals("$kindRaw authMode mismatch", "bearer", validation.authMode)
            assertEquals("$kindRaw headerProfile mismatch", "none", validation.headerProfile)
            assertEquals("$kindRaw signal count mismatch", 1, validation.invalidKeySignals.size)
            assertEquals("$kindRaw signal status mismatch", 401, validation.invalidKeySignals.first().status)
            assertTrue(
                "$kindRaw signal bodyIncludes mismatch",
                validation.invalidKeySignals.first().bodyIncludes.isEmpty(),
            )
        }

        // The OpenRouter key_info shape: probe=key_info, probePath=/key, headerProfile=openrouter.
        val orValidation = MetadataClient.validation(ProviderKind.OpenRouter)
        assertNotNull("openRouter has no validation contract", orValidation)
        orValidation!!
        assertEquals("key_info", orValidation.probe)
        assertEquals("/key", orValidation.probePath)
        assertEquals("bearer", orValidation.authMode)
        assertEquals("openrouter", orValidation.headerProfile)
        assertEquals(401, orValidation.invalidKeySignals.first().status)
    }

    @Test
    fun `model expectations stay aligned`() {
        contract.modelExpectations.forEach { expect ->
            val kind = providerKind(expect.providerKind)
            val resolved = MetadataClient.resolveCatalogModel(expect.query, kind)
            assertNotNull("model ${expect.id}: resolveCatalogModel returned null", resolved)
            resolved!!

            assertEquals(
                "model ${expect.id}: canonicalModelId",
                expect.expectedCanonicalModelId,
                resolved.canonicalModelId,
            )
            assertEquals(
                "model ${expect.id}: displayName",
                expect.expectedDisplayName,
                resolved.displayName,
            )
            assertEquals(
                "model ${expect.id}: contextLength",
                expect.expectedContextLength,
                resolved.contextLength,
            )
            assertEquals(
                "model ${expect.id}: maxOutputTokens",
                expect.expectedMaxOutputTokens,
                resolved.maxOutputTokens,
            )
            assertEquals(
                "model ${expect.id}: supportsTemperature",
                expect.expectedSupportsTemperature,
                resolved.supportsTemperature,
            )
            assertEquals(
                "model ${expect.id}: pricingStatus",
                expect.expectedPricingStatus,
                resolved.pricingStatus,
            )

            // Pricing goes through the public lookupPricing API: null when unknown, and restored per 1M tokens when priced or free
            val pricing = MetadataClient.lookupPricing(expect.query, kind)
            when (expect.expectedPricingStatus) {
                "unknown" -> assertNull(
                    "model ${expect.id}: unknown pricing must surface as null",
                    pricing,
                )
                "priced", "free" -> {
                    assertNotNull("model ${expect.id}: pricing must be present", pricing)
                    val (prompt, completion) = pricing!!
                    assertDoubleEquals(
                        "model ${expect.id}: promptPerToken",
                        (expect.expectedPromptPerMToken ?: 0.0) / 1_000_000.0,
                        prompt,
                    )
                    assertDoubleEquals(
                        "model ${expect.id}: completionPerToken",
                        (expect.expectedCompletionPerMToken ?: 0.0) / 1_000_000.0,
                        completion,
                    )
                }
            }

            // Capabilities arrive as serialName strings and are order sensitive (Text first, then badgeOrder)
            val expectedCaps = expect.expectedCapabilities.map(::capabilityOf)
            assertEquals(
                "model ${expect.id}: capabilities",
                expectedCaps,
                resolved.capabilities,
            )

            // Profiles
            assertEquals(
                "model ${expect.id}: reasoning profile",
                expect.expectedReasoningProfile,
                resolved.profiles.reasoning,
            )
            assertEquals(
                "model ${expect.id}: webSearch profile",
                expect.expectedWebSearchProfile,
                resolved.profiles.webSearch,
            )
            assertEquals(
                "model ${expect.id}: imageGen profile",
                expect.expectedImageGenProfile,
                resolved.profiles.imageGen,
            )

            // Vendor identity
            assertEquals(
                "model ${expect.id}: vendorKey",
                expect.expectedVendorKey,
                resolved.vendorKey,
            )
            assertEquals(
                "model ${expect.id}: vendorName",
                expect.expectedVendorName,
                resolved.vendorName,
            )

            // UI hints
            val hints = resolved.uiHints
            assertNotNull("model ${expect.id}: uiHints expected but missing", hints)
            hints!!
            assertEquals(
                "model ${expect.id}: uiHints.groupKey",
                expect.expectedGroupKey,
                hints.groupKey,
            )
            assertEquals(
                "model ${expect.id}: uiHints.groupName",
                expect.expectedGroupName,
                hints.groupName,
            )
            assertEquals(
                "model ${expect.id}: uiHints.recommended",
                expect.expectedRecommended,
                hints.recommended,
            )

            // badgeOrder: normalizeUIHints filters the Text capability out and keeps only the non-Text ones
            val expectedBadgeOrder = expect.expectedBadgeOrder
                .map(::capabilityOf)
                .filter { it != ModelCapability.Text }
            assertEquals(
                "model ${expect.id}: uiHints.badgeOrder",
                expectedBadgeOrder,
                hints.badgeOrder ?: emptyList<ModelCapability>(),
            )

            // isDefault
            assertEquals(
                "model ${expect.id}: isDefault",
                expect.expectedIsDefault,
                resolved.isDefault,
            )
        }
    }

    @Test
    fun `negative expectations do not resolve`() {
        contract.negativeExpectations.forEach { expect ->
            val kind = providerKind(expect.providerKind)
            val resolved = MetadataClient.resolveCatalogModel(expect.query, kind)
            assertNull(
                "negative ${expect.id}: query `${expect.query}` must not resolve, got $resolved",
                resolved,
            )
        }
    }

    @Test
    fun `vendor integrity is honored across aggregator and direct providers`() {
        contract.vendorIntegrityExpectations.expectations.forEach { expect ->
            val kind = providerKind(expect.providerKind)
            val resolved = MetadataClient.resolveCatalogModel(expect.modelId, kind)
            assertNotNull(
                "vendor integrity: ${expect.providerKind}/${expect.modelId} must resolve",
                resolved,
            )
            resolved!!
            assertEquals(
                "vendor integrity: ${expect.providerKind}/${expect.modelId} vendorKey",
                expect.vendorKey,
                resolved.vendorKey,
            )
            assertEquals(
                "vendor integrity: ${expect.providerKind}/${expect.modelId} vendorName",
                expect.vendorName,
                resolved.vendorName,
            )
        }

        // Every model under an aggregating provider must carry a non-empty vendorKey
        contract.vendorIntegrityExpectations.aggregatorProviders.forEach { providerRaw ->
            val kind = providerKind(providerRaw)
            val modelIds = MetadataClient.providerModelIds(kind)
            assertFalse(
                "aggregator $providerRaw must have at least one model",
                modelIds.isEmpty(),
            )
            modelIds.forEach { modelId ->
                val resolved = MetadataClient.resolveCatalogModel(modelId, kind)
                assertNotNull("aggregator $providerRaw/$modelId must resolve", resolved)
                val vendorKey = resolved!!.vendorKey
                assertTrue(
                    "aggregator $providerRaw/$modelId vendorKey must be non-blank, got `$vendorKey`",
                    !vendorKey.isNullOrBlank(),
                )
            }
        }

        // Every model under a direct provider must have a null vendorKey (an empty string is already reduced to null by takeIf)
        contract.vendorIntegrityExpectations.directProviders.forEach { providerRaw ->
            val kind = providerKind(providerRaw)
            MetadataClient.providerModelIds(kind).forEach { modelId ->
                val resolved = MetadataClient.resolveCatalogModel(modelId, kind)
                assertNotNull("direct $providerRaw/$modelId must resolve", resolved)
                assertNull(
                    "direct $providerRaw/$modelId vendorKey must be null",
                    resolved!!.vendorKey,
                )
                assertNull(
                    "direct $providerRaw/$modelId vendorName must be null",
                    resolved.vendorName,
                )
            }
        }
    }

    @Test
    fun `image generation model resolves without adapter filtering`() {
        // The resolver for a vendor's own catalog must not depend on the adapter's capability filtering: Qwen's qwen-image
        // in the fixture is an image generation model and still has to come back from resolveCatalogModel with all its fields.
        val resolved = MetadataClient.resolveCatalogModel("qwen-image", ProviderKind.Qwen)
        assertNotNull("qwen-image should resolve via metadata even if adapter excludes it", resolved)
        resolved!!
        assertEquals("qwen-image", resolved.canonicalModelId)
        assertTrue(
            "qwen-image capabilities must contain ImageGen, got ${resolved.capabilities}",
            resolved.capabilities.contains(ModelCapability.ImageGen),
        )
        assertEquals("qwen_image_v1", resolved.profiles.imageGen)
    }

    // ── Helpers ──

    private fun injectContractMetadata() {
        val metadataJson = contract.metadata.toString()

        val clientClass = MetadataClient::class.java

        val jsonField = clientClass.getDeclaredField("json").apply { isAccessible = true }
        val internalJson = jsonField.get(MetadataClient.instance) as Json

        val responseClass = clientClass.declaredClasses
            .first { it.simpleName == "MetadataResponse" }
        val companion = responseClass.getDeclaredField("Companion")
            .apply { isAccessible = true }
            .get(null)
        val serializer = companion.javaClass.getDeclaredMethod("serializer")
            .apply { isAccessible = true }
            .invoke(companion) as KSerializer<Any>

        val decoded = internalJson.decodeFromString(serializer, metadataJson)

        val tableField = clientClass.getDeclaredField("table").apply { isAccessible = true }
        tableField.set(MetadataClient.instance, decoded)
    }

    private fun clearMetadataTable() {
        val tableField = MetadataClient::class.java.getDeclaredField("table")
            .apply { isAccessible = true }
        tableField.set(MetadataClient.instance, null)
    }

    private fun providerKind(raw: String): ProviderKind =
        ProviderKind.fromRawValue(raw) ?: error("unknown provider kind in fixture: $raw")

    /** The fixture spells capabilities as serialName strings (the @SerialName values), which are mapped back onto the enum. */
    private fun capabilityOf(raw: String): ModelCapability = when (raw) {
        "reasoning" -> ModelCapability.Reasoning
        "text" -> ModelCapability.Text
        "image" -> ModelCapability.Image
        "file" -> ModelCapability.File
        "web" -> ModelCapability.Web
        "imageGeneration" -> ModelCapability.ImageGen
        else -> error("unknown capability in fixture: $raw")
    }

    private fun assertDoubleEquals(message: String, expected: Double, actual: Double) {
        assertEquals(message, expected, actual, 1e-12)
    }

    private fun contractCandidates(): List<Path> {
        val cwd = Paths.get("").toAbsolutePath().normalize()
        return generateSequence(cwd) { current -> current.parent }
            .take(8)
            .map { current ->
                current.resolve("shared/model-contracts/metadata_authoritative_contract.v1.json")
            }
            .toList()
    }

    // Keeps the explicit references to JsonElement/jsonObject from being reported as unused; they are only needed by the reflection path
    @Suppress("unused")
    private fun touchImports(element: JsonElement) {
        element.jsonObject
    }
}
