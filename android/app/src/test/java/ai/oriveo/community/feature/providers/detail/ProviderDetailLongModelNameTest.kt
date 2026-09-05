package ai.oriveo.community.feature.providers.detail

import ai.oriveo.community.R
import ai.oriveo.community.core.model.AIModel
import ai.oriveo.community.core.model.ModelCapability
import java.io.File
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Test

class ProviderDetailLongModelNameTest {

    @Test
    fun `enabled model rows allow long model names to wrap`() {
        val source = File(
            "src/main/java/ai/oriveo/community/feature/providers/detail/ProviderDetailEnabledModels.kt",
        ).readText()
        val rowSource = source.requiredSlice(
            from = "private fun EnabledModelRow(",
            to = "@Composable\nprivate fun EnabledModelMetadataRow",
        )
        val titleSource = rowSource.requiredSlice(
            from = "text = model.name",
            to = "EnabledModelMetadataRow(",
        )

        assertFalse(titleSource.contains("maxLines = 1"))
        assertFalse(titleSource.contains("overflow = TextOverflow.Ellipsis"))
    }

    @Test
    fun `enabled model metadata omits the default badge`() {
        val source = File(
            "src/main/java/ai/oriveo/community/feature/providers/detail/ProviderDetailEnabledModels.kt",
        ).readText()
        val metadataSource = source.requiredSlice(
            from = "private fun EnabledModelMetadataRow",
            to = "@Composable\nprivate fun EnabledModelPriceLabel",
        )

        assertFalse(metadataSource.contains("default_model_short"))
        assertFalse(metadataSource.contains("isDefault"))
    }

    @Test
    fun `catalog model rows allow long model names to wrap`() {
        val source = File(
            "src/main/java/ai/oriveo/community/feature/providers/detail/ProviderCatalogComponents.kt",
        ).readText()
        val rowSource = source.requiredSlice(
            from = "private fun CatalogModelRow(",
            to = "val priceTier = model.normalizedPriceTierLabel()",
        )
        val titleSource = rowSource.requiredSlice(
            from = "text = model.name",
            to = "ModelListMetadataRow(",
        )

        assertFalse(titleSource.contains("maxLines = 2"))
        assertFalse(titleSource.contains("overflow = TextOverflow.Ellipsis"))
    }

    @Test
    fun `missing cache prices do not create cache specification chips`() {
        val specifications = modelSpecifications(
            AIModel(
                id = "sparse-model",
                name = "Sparse Model",
                capabilities = listOf(ModelCapability.Text),
                promptPrice = 0.00000125,
                completionPrice = 0.00000375,
            ),
        )

        assertEquals(
            listOf(R.string.price_input, R.string.price_output),
            specifications.map { it.labelRes },
        )
    }
}

private fun String.requiredSlice(from: String, to: String): String {
    val startIndex = indexOf(from)
    require(startIndex >= 0) { "Missing start boundary: $from" }
    val endIndex = indexOf(to, startIndex + from.length)
    require(endIndex >= 0) { "Missing end boundary: $to" }
    return substring(startIndex, endIndex)
}
