package ai.oriveo.community.ui.component

import ai.oriveo.community.R
import org.junit.Assert.assertEquals
import org.junit.Test

class ModelVendorIconTest {

    @Test
    fun `official public group aliases map to brand logos`() {
        val expected = mapOf(
            "google-gemini" to R.drawable.ic_provider_gemini,
            "xai-grok" to R.drawable.ic_provider_grok,
            "kimi" to R.drawable.ic_provider_kimi,
            "zhipu-glm" to R.drawable.ic_provider_zhipu,
        )

        expected.forEach { (alias, drawable) ->
            assertEquals(drawable, vendorLogoRes(alias))
        }
    }

    @Test
    fun `official public group aliases select dark assets`() {
        val expected = mapOf(
            "google-gemini" to R.drawable.ic_provider_gemini_dark,
            "xai-grok" to R.drawable.ic_provider_grok_dark,
            "kimi" to R.drawable.ic_provider_kimi_dark,
            "zhipu-glm" to R.drawable.ic_provider_zhipu_dark,
        )

        expected.forEach { (alias, drawable) ->
            assertEquals(drawable, vendorLogoRes(alias, darkAppearance = true))
        }
    }

    @Test
    fun `vendorMonogram generates correct letters for Z-ai group`() {

        val monogram = vendorMonogramForTest("Z.ai / GLM")

        assert(monogram.length <= 2) { "Monogram should be at most 2 chars" }
        assert(monogram.isNotBlank()) { "Monogram should not be blank" }
    }

    private fun vendorMonogramForTest(value: String): String {
        val parts = value
            .split(Regex("[^A-Za-z0-9]+"))
            .filter { it.isNotBlank() }

        return when {
            parts.size >= 2 -> parts.take(2).joinToString("") { it.take(1) }.uppercase()
            parts.isNotEmpty() -> parts.first().take(2).uppercase()
            else -> "AI"
        }
    }
}
