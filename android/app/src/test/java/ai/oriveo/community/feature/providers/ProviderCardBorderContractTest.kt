package ai.oriveo.community.feature.providers

import java.io.File
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class ProviderCardBorderContractTest {
    private val sourceRoot = File("src/main/java/ai/oriveo/community")

    @Test
    fun `provider home connected status capsule has fill but no border`() {
        val heroSource = sourceRoot.resolve("feature/providers/ProviderHeroCard.kt").readText()
        val statusCapsule = heroSource
            .substringAfter("private fun HeroStatsColumn(")
            .substringBefore("private fun HeroCostView(")

        assertTrue(statusCapsule.contains(".background(Color.White.copy(alpha = 0.22f))"))
        assertFalse(statusCapsule.contains(".border("))
    }

    @Test
    fun `provider compact list rows do not draw individual borders`() {
        val listCardSource = sourceRoot.resolve("ui/component/ProviderListCard.kt").readText()
        val listCard = listCardSource
            .substringAfter("fun ProviderListCard(")
            .substringBefore("private fun BrandBar(")

        assertFalse(listCard.contains(".border("))
    }

    @Test
    fun `provider list cluster panel does not draw or allocate a border`() {
        val panelSource = sourceRoot.resolve("ui/component/OriveoGradientPanel.kt").readText()

        assertFalse(panelSource.contains(".border("))
        assertFalse(panelSource.contains("borderBrush"))
        assertFalse(panelSource.contains("BorderStroke"))
    }
}
