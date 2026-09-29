package ai.oriveo.community.feature.providers.detail

import java.io.File
import org.junit.Assert.assertTrue
import org.junit.Test

class ProviderDetailCatalogViewStateTest {

    @Test
    fun `catalogViewState re-reads metadata source on every refresh signal`() {
        // After a 304 the catalog content is unchanged and the deduplicated resolvedCatalog does not
        // emit; without following the refresh signal directly the state stays on the CachedOffline frame.
        val source = File(
            "src/main/java/ai/oriveo/community/feature/providers/detail/ProviderDetailViewModel.kt",
        ).readText()
        val block = source.substringAfter("val catalogViewState: StateFlow<CatalogViewState> = combine(")
            .substringBefore(".stateIn(")
        assertTrue(block.contains("metadataRefreshSignal.onStart { emit(Unit) }"))
    }
}
