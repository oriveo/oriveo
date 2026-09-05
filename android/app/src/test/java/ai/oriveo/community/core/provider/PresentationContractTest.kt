package ai.oriveo.community.core.provider

import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json
import org.junit.Assert.assertEquals
import org.junit.Test
import java.nio.file.Files
import java.nio.file.Path
import java.nio.file.Paths

/**
 * Golden tests for the presentation contract.
 *
 * Reads `shared/model-contracts/presentation_fixtures.v1.json`, feeds the fixture's
 * `leafCases` / `containerCases` / `stateCases` into the local pure selector functions
 * ([derivePresentation] / [deriveContainerPresentation] / [deriveStatePresentation]) and
 * asserts that every field of the output matches the fixture's `expectedRender`.
 *
 * These selectors are themselves the single source of truth for the presentation contract on
 * this platform: any rendering work (the Compose provider catalog, the model picker) has to
 * reuse these rules. When an implementation drifts away from the fixture this suite has to go
 * red, so that the drift cannot be committed.
 */
class PresentationContractTest {

    // ── Fixture schema ──

    @Serializable
    private data class FixtureFile(
        val contractVersion: Int,
        val leafCases: List<LeafCase> = emptyList(),
        val containerCases: List<ContainerCase> = emptyList(),
        val stateCases: List<StateCase> = emptyList(),
    )

    @Serializable
    private data class LeafCase(
        val id: String,
        val providerKind: String,
        val model: FixtureModel,
        val expectedRender: PresentationDescriptor,
    )

    @Serializable
    private data class ContainerCase(
        val id: String,
        val providerKind: String,
        val models: List<FixtureModel>,
        val expectedRender: ContainerDescriptor,
    )

    @Serializable
    private data class StateCase(
        val id: String,
        val providerKind: String,
        val metadataSource: String? = null,
        val providerData: FixtureProviderData,
        val manualRetainedModels: List<FixtureManualRetainedModel> = emptyList(),
        val expectedRender: StateDescriptor,
    )

    @Serializable
    private data class FixtureModel(
        val canonicalModelId: String,
        val displayName: String? = null,
        val vendorKey: String? = null,
        val vendorName: String? = null,
        val contextLength: Int? = null,
        val pricing: FixturePricing? = null,
        val pricingStatus: String,
        val capabilities: List<String> = emptyList(),
        val profiles: FixtureProfiles? = null,
        val uiHints: FixtureUiHints,
    )

    @Serializable
    private data class FixturePricing(
        val promptPerMToken: Double? = null,
        val completionPerMToken: Double? = null,
        val cachedInputPerMToken: Double? = null,
    )

    @Serializable
    private data class FixtureProfiles(
        val reasoning: String? = null,
        val webSearch: String? = null,
        val imageGen: String? = null,
    )

    @Serializable
    private data class FixtureUiHints(
        val groupKey: String? = null,
        val groupName: String? = null,
        val rank: Int? = null,
        val recommended: Boolean = false,
        val badgeOrder: List<String> = emptyList(),
    )

    @Serializable
    private data class FixtureProviderData(
        val displayName: String,
        val defaultModelId: String? = null,
        val validationModelId: String? = null,
        val resolveMap: Map<String, String> = emptyMap(),
        val models: Map<String, FixtureProviderModel> = emptyMap(),
    )

    /**
     * The model shape inside stateCases is simpler than in leafCases: a subset of the fields.
     * Only presence matters here, so everything is optional.
     */
    @Serializable
    private data class FixtureProviderModel(
        val canonicalModelId: String? = null,
        val displayName: String? = null,
        val pricingStatus: String? = null,
        val capabilities: List<String> = emptyList(),
        val uiHints: FixtureUiHints? = null,
    )

    @Serializable
    private data class FixtureManualRetainedModel(
        val modelId: String,
        val displayName: String? = null,
    )

    // Descriptors: the source-of-truth shape that expectedRender is compared against.

    @Serializable
    private data class PresentationDescriptor(
        val showsVendorSubtitle: Boolean,
        val vendorSubtitleText: String? = null,
        val showsRecommendedBadge: Boolean,
        val capabilityBadges: List<String>,
        val showsCachedPricing: Boolean,
        val pricingBranch: String,
        val showsReasoningPicker: Boolean,
        val showsWebSearchPicker: Boolean,
        val showsImageGenPicker: Boolean,
    )

    @Serializable
    private data class ContainerDescriptor(
        val groupHeaders: List<String>,
        val modelOrderWithinGroups: Map<String, List<String>>,
    )

    @Serializable
    private data class StateDescriptor(
        val showsEmptyStateCopy: Boolean,
        val showsRetryAction: Boolean,
        val showsCatalogList: Boolean,
        val showsOfflineBanner: Boolean,
        val showsManualRetainedSection: Boolean,
        val manualRetainedHeaderKey: String? = null,
    )

    private val json = Json { ignoreUnknownKeys = true; isLenient = true }

    private val fixture: FixtureFile by lazy {
        val path = fixtureCandidates()
            .firstOrNull { Files.exists(it) }
            ?.normalize()
            ?: error("presentation_fixtures.v1.json not found in any candidate path")
        json.decodeFromString(path.toFile().readText())
    }

    // ── Tests ──

    @Test
    fun `fixture loads with expected contract version`() {
        assertEquals(1, fixture.contractVersion)
    }

    @Test
    fun `leaf cases stay aligned`() {
        fixture.leafCases.forEach { case ->
            val actual = derivePresentation(case.model)
            assertEquals("leaf case `${case.id}`", case.expectedRender, actual)
        }
    }

    @Test
    fun `container cases stay aligned`() {
        fixture.containerCases.forEach { case ->
            val actual = deriveContainerPresentation(case.providerKind, case.models)
            assertEquals("container case `${case.id}`", case.expectedRender, actual)
        }
    }

    @Test
    fun `state cases stay aligned`() {
        fixture.stateCases.forEach { case ->
            val actual = deriveStatePresentation(
                metadataSource = case.metadataSource,
                providerData = case.providerData,
                manualRetainedModels = case.manualRetainedModels,
            )
            assertEquals("state case `${case.id}`", case.expectedRender, actual)
        }
    }

    // Selectors: the contract implementation. Pure functions taking fixture fields in and
    // returning a descriptor.

    /**
     * The rendering contract for a single model card. The rules follow the field-to-UI mapping
     * table in `00-metadata-contract-spec.md` exactly:
     *
     * - vendor subtitle  <= vendorKey and vendorName are both present and non-blank after trim
     * - recommended badge <= uiHints.recommended == true
     * - capability badges <= uiHints.badgeOrder, order preserved, with "text" dropped
     * - pricing branch    <= pricingStatus (priced / free / unknown); showsCachedPricing only
     *                        applies to priced
     * - selectors         <= whether profiles.{reasoning,webSearch,imageGen} are non-empty,
     *                        which is deliberately decoupled from capabilities
     */
    private fun derivePresentation(model: FixtureModel): PresentationDescriptor {
        val vendorKey = model.vendorKey?.trim().orEmpty()
        val vendorName = model.vendorName?.trim().orEmpty()
        val showsVendor = vendorKey.isNotEmpty() && vendorName.isNotEmpty()

        val badges = model.uiHints.badgeOrder.filter { it != "text" }

        val pricingBranch = when (model.pricingStatus) {
            "priced", "free", "unknown" -> model.pricingStatus
            else -> error("unknown pricingStatus `${model.pricingStatus}` in fixture")
        }

        val reasoningProfile = model.profiles?.reasoning?.takeIf { it.isNotBlank() }
        val webSearchProfile = model.profiles?.webSearch?.takeIf { it.isNotBlank() }
        val imageGenProfile = model.profiles?.imageGen?.takeIf { it.isNotBlank() }

        return PresentationDescriptor(
            showsVendorSubtitle = showsVendor,
            vendorSubtitleText = if (showsVendor) vendorName else null,
            showsRecommendedBadge = model.uiHints.recommended,
            capabilityBadges = badges,
            showsCachedPricing = pricingBranch == "priced",
            pricingBranch = pricingBranch,
            showsReasoningPicker = reasoningProfile != null,
            showsWebSearchPicker = webSearchProfile != null,
            showsImageGenPicker = imageGenProfile != null,
        )
    }

    /**
     * The rendering contract for the container, meaning the catalog list.
     *
     * - **Aggregator providers** (OpenRouter, SiliconFlow): grouped by `vendorName`; group
     *   headers ordered by first appearance of the vendor; within a vendor, descending
     *   `uiHints.rank`.
     * - **Direct providers** (everything else): grouped by `uiHints.groupName`; group headers
     *   ordered by each group's highest rank, descending; within a group, descending rank.
     */
    private fun deriveContainerPresentation(
        providerKind: String,
        models: List<FixtureModel>,
    ): ContainerDescriptor {
        val isAggregator = providerKind in AGGREGATOR_PROVIDER_KINDS

        return if (isAggregator) {
            val groups = linkedMapOf<String, MutableList<FixtureModel>>()
            models.forEach { model ->
                val header = model.vendorName.orEmpty().ifEmpty { "Unknown" }
                groups.getOrPut(header) { mutableListOf() }.add(model)
            }
            val headers = groups.keys.toList()
            val orderWithin = groups.mapValues { (_, vendorModels) ->
                vendorModels
                    .sortedByDescending { it.uiHints.rank ?: 0 }
                    .map { it.canonicalModelId }
            }
            ContainerDescriptor(groupHeaders = headers, modelOrderWithinGroups = orderWithin)
        } else {
            val groups = linkedMapOf<String, MutableList<FixtureModel>>()
            models.forEach { model ->
                val header = model.uiHints.groupName.orEmpty().ifEmpty { "Other" }
                groups.getOrPut(header) { mutableListOf() }.add(model)
            }
            val headers = groups.entries
                .sortedByDescending { (_, groupModels) ->
                    groupModels.maxOf { it.uiHints.rank ?: 0 }
                }
                .map { it.key }
            val orderWithin = groups.mapValues { (_, groupModels) ->
                groupModels
                    .sortedByDescending { it.uiHints.rank ?: 0 }
                    .map { it.canonicalModelId }
            }
            ContainerDescriptor(groupHeaders = headers, modelOrderWithinGroups = orderWithin)
        }
    }

    /**
     * The rendering contract for container-level state.
     *
     * - providerData.models empty     -> show the empty state plus a retry button, and no
     *                                    catalog list
     * - providerData.models non-empty -> show the catalog list
     * - metadataSource == "cachedOffline" -> show the offline banner at the top
     * - manualRetainedModels non-empty -> show the Manual-Retained group as its own section
     */
    private fun deriveStatePresentation(
        metadataSource: String?,
        providerData: FixtureProviderData,
        manualRetainedModels: List<FixtureManualRetainedModel>,
    ): StateDescriptor {
        val hasModels = providerData.models.isNotEmpty()
        val hasManualRetained = manualRetainedModels.isNotEmpty()
        val isOffline = metadataSource == "cachedOffline"

        return StateDescriptor(
            showsEmptyStateCopy = !hasModels,
            showsRetryAction = !hasModels,
            showsCatalogList = hasModels,
            showsOfflineBanner = isOffline,
            showsManualRetainedSection = hasManualRetained,
            manualRetainedHeaderKey =
                if (hasManualRetained) MANUAL_RETAINED_HEADER_KEY else null,
        )
    }

    // ── Helpers ──

    private fun fixtureCandidates(): List<Path> {
        val cwd = Paths.get("").toAbsolutePath().normalize()
        return generateSequence(cwd) { current -> current.parent }
            .take(8)
            .map { current ->
                current.resolve("shared/model-contracts/presentation_fixtures.v1.json")
            }
            .toList()
    }

    private companion object {
        /** Matches the providerKind strings used in the fixture, that is the raw values. */
        val AGGREGATOR_PROVIDER_KINDS = setOf("openRouter", "siliconFlow")

        const val MANUAL_RETAINED_HEADER_KEY = "providers.catalog.manualRetainedHeader"
    }
}
