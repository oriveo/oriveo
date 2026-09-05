package ai.oriveo.community.feature.providers.detail

import java.io.File
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Pins row-level virtualization for the provider detail page's model catalog.
 *
 * This has regressed twice: the catalog was once flattened into top-level
 * items, then got folded back into "one item holding the whole Column" to
 * work around an outer `spacedBy(lg)` that pushed rows apart and broke the
 * rounded-corner card. That folded version degrades the whole catalog into a
 * single subcomposition -- with hundreds of models expanded, entering or
 * leaving the page has to add or remove thousands of LayoutNodes at once,
 * freezing the main thread and triggering an ANR on low-end devices.
 *
 * The spacing problem has to be solved in the outer layout (each section
 * carries its own bottom padding); virtualization must not be traded away
 * for it.
 *
 * The added-models section is the other half of the same root cause: adding
 * every model at once can write the whole catalog into `provider.models`,
 * and it isn't truncated on sync, so that section can reach the same row
 * counts, with `EnabledModelRow` containing a `SubcomposeLayout` of its own.
 * Both sections are pinned together.
 */
class ProviderCatalogVirtualizationTest {

    // Every assertion runs against comment-stripped source -- these rules are described in comments, so without stripping them the check would match itself.
    private val detailScreen = File(
        "src/main/java/ai/oriveo/community/feature/providers/detail/ProviderDetailScreen.kt",
    ).readText().withoutComments()

    private val catalogComponents = File(
        "src/main/java/ai/oriveo/community/feature/providers/detail/ProviderCatalogComponents.kt",
    ).readText().withoutComments()

    private val enabledModels = File(
        "src/main/java/ai/oriveo/community/feature/providers/detail/ProviderDetailEnabledModels.kt",
    ).readText().withoutComments()

    @Test
    fun `detail screen flattens catalog rows into the outer lazy column`() {
        assertTrue(
            "the catalog must call providerCatalogGroups to flatten it, otherwise it degrades into no virtualization at all",
            detailScreen.contains("providerCatalogGroups("),
        )
    }

    @Test
    fun `no composable packs the whole catalog into a single item`() {
        assertFalse(
            "ProviderCatalogGroupsColumn packs the whole catalog subtree into a single item and was removed after causing an ANR",
            detailScreen.contains("ProviderCatalogGroupsColumn"),
        )
        assertFalse(
            "ProviderCatalogGroupsColumn was removed after causing an ANR and must not be reintroduced",
            catalogComponents.contains("fun ProviderCatalogGroupsColumn"),
        )
    }

    @Test
    fun `outer lazy column keeps zero arrangement so rows can form one card`() {
        val lazyColumnHeader = detailScreen.requiredSlice(
            from = "LazyColumn(",
            to = "detailSection(key = \"back_button\")",
        )

        assertFalse(
            "an outer spacedBy would push model rows within the same card apart, tempting someone to fold the catalog back into a single item",
            lazyColumnHeader.contains("verticalArrangement"),
        )
        assertTrue(
            "section spacing is handled by detailSection instead",
            detailScreen.contains("private fun LazyListScope.detailSection("),
        )
    }

    @Test
    fun `detail screen flattens enabled model rows into the outer lazy column`() {
        assertTrue(
            "the added-models section must call providerDetailEnabledModels to flatten it",
            detailScreen.contains("providerDetailEnabledModels("),
        )
        assertFalse(
            "the added-models section must not be packed whole into a single detailSection",
            detailScreen.contains("detailSection(key = \"enabled_models_section\")"),
        )
        assertTrue(
            "must be a LazyListScope extension, otherwise row-level recycling isn't possible",
            enabledModels.contains("fun LazyListScope.providerDetailEnabledModels("),
        )
    }

    @Test
    fun `enabled model rows are emitted as individual lazy items`() {
        val flattened = enabledModels.requiredSlice(
            from = "fun LazyListScope.providerDetailEnabledModels(",
            to = "private val EnabledModelsCardRadius",
        )

        assertTrue(
            "added models must be emitted row by row as lazy items to get row-level recycling",
            flattened.contains("itemsIndexed("),
        )
        assertFalse(
            "packing the whole list into a single item's Column is exactly the ANR root cause and must not come back",
            flattened.contains("forEachIndexed"),
        )
    }

    @Test
    fun `no composable packs the whole enabled model list into a single item`() {
        assertFalse(
            "GroupedModelsPanel packed all added models into a single item and was removed after causing an ANR",
            enabledModels.contains("fun GroupedModelsPanel("),
        )
        assertFalse(
            "GroupedModelsPanel was removed after causing an ANR and must not be reintroduced",
            detailScreen.contains("GroupedModelsPanel"),
        )
    }

    /**
     * All three catalog item kinds must carry their own contentType. If all are
     * null, LazyList will try to reuse a header/spacer slot for a model row;
     * that reuse always fails and rebuilds the whole subtree, giving back
     * exactly the recomposition virtualization was meant to save.
     */
    @Test
    fun `catalog items declare distinct content types`() {
        val flattened = catalogComponents.requiredSlice(
            from = "fun LazyListScope.providerCatalogGroups(",
            to = "internal enum class CatalogRowPosition",
        )

        assertTrue("group header needs its own contentType", flattened.contains("contentType = CatalogHeaderContentType"))
        assertTrue("model row needs its own contentType", flattened.contains("contentType = { _, _ -> CatalogRowContentType }"))
        assertTrue("spacer needs its own contentType", flattened.contains("contentType = CatalogSpacerContentType"))
        assertTrue(
            "the added-model row also needs its own contentType",
            enabledModels.contains("contentType = { _, _ -> EnabledModelRowContentType }"),
        )
    }

    /**
     * Model rows skip `Modifier.animateItem()`: search is debounced, so a
     * single keystroke can add or remove the whole section at once, and the
     * spring animation never settles on low-end devices -- it just drops
     * frames. Group headers are bounded in count, so their animation stays.
     */
    @Test
    fun `catalog model rows do not animate item placement`() {
        val rows = catalogComponents.requiredSlice(
            from = "itemsIndexed(",
            to = "if (groupIndex < groups.lastIndex)",
        )

        assertFalse(
            "animateItem on a model row only drops frames in a large catalog",
            rows.contains("animateItem()"),
        )
        assertTrue(
            "animateItem on a group header stays",
            catalogComponents.requiredSlice(
                from = "CatalogGroupHeader(",
                to = "itemsIndexed(",
            ).contains("animateItem()"),
        )
    }

    @Test
    fun `catalog rows are emitted as individual lazy items`() {
        val flattened = catalogComponents.requiredSlice(
            from = "fun LazyListScope.providerCatalogGroups(",
            to = "internal enum class CatalogRowPosition",
        )

        assertTrue(
            "model rows must be emitted row by row as lazy items to get row-level recycling",
            flattened.contains("itemsIndexed("),
        )
    }
}

private fun String.withoutComments(): String =
    lineSequence()
        .filterNot {
            val trimmed = it.trimStart()
            trimmed.startsWith("//") || trimmed.startsWith("*") || trimmed.startsWith("/*")
        }
        .joinToString("\n")

private fun String.requiredSlice(from: String, to: String): String {
    val startIndex = indexOf(from)
    require(startIndex >= 0) { "Missing start boundary: $from" }
    val endIndex = indexOf(to, startIndex + from.length)
    require(endIndex >= 0) { "Missing end boundary: $to" }
    return substring(startIndex, endIndex)
}
