package ai.oriveo.community.ui.component

import ai.oriveo.community.R
import ai.oriveo.community.core.model.ProviderKind
import java.io.File
import javax.imageio.ImageIO
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class ProviderBadgeIconTest {
    @Test
    fun `provider badge uses safe area embedded in unified assets`() {
        assertEquals(1f, ProviderBadgeLogoMetrics.BrandContentScale, 0.0001f)
        assertEquals(0f, ProviderBadgeLogoMetrics.brandInset(28f), 0.0001f)
        assertEquals(0.92f, ProviderBadgeLogoMetrics.RelayFallbackContentScale, 0.0001f)
    }

    @Test
    fun `relay fallback mark is inset inside its badge canvas`() {
        assertEquals(
            0.04f,
            (1f - ProviderBadgeLogoMetrics.RelayFallbackContentScale) / 2f,
            0.0001f,
        )
    }

    /**
     * The Oriveo mark ships as a transparent cutout, not as an opaque tile.
     *
     * Every other provider asset is a transparent-background logo, so a mark with its own dark
     * square reads as a tile pasted onto the row - most obviously in a light theme. The assets are
     * generated, so this pins the property rather than trusting the generator.
     */
    @Test
    fun `the Oriveo mark is a transparent cutout, not an opaque tile`() {
        val file = resDrawable("drawable-xxhdpi/ic_oriveo_logo.png")
        val image = ImageIO.read(file) ?: error("cannot decode ic_oriveo_logo")
        assertTrue("ic_oriveo_logo needs an alpha channel", image.colorModel.hasAlpha())
        for ((x, y) in listOf(0 to 0, image.width - 1 to 0, 0 to image.height - 1)) {
            val alpha = image.getRGB(x, y) ushr 24
            assertEquals("ic_oriveo_logo corner ($x,$y) must be fully transparent", 0, alpha)
        }
    }

    private fun resDrawable(relative: String): File {
        var dir: File? = File(System.getProperty("user.dir") ?: ".").absoluteFile
        while (dir != null) {
            val candidate = File(dir, "src/main/res/$relative")
            if (candidate.isFile) return candidate
            dir = dir.parentFile
        }
        error("cannot find src/main/res/$relative")
    }

    @Test
    fun `providers expose explicit light and dark assets`() {
        assertEquals(R.drawable.ic_provider_grok, providerLogoRes(ProviderKind.Grok))
        assertEquals(R.drawable.ic_provider_grok_dark, providerLogoRes(ProviderKind.Grok, darkAppearance = true))
        assertEquals(R.drawable.ic_provider_kimi, providerLogoRes(ProviderKind.Moonshot))
        assertEquals(R.drawable.ic_provider_kimi_dark, providerLogoRes(ProviderKind.Moonshot, darkAppearance = true))
    }

    @Test
    fun `Mistral colored logo is shared across light and dark appearances`() {
        // A multi-colour mark reads correctly on both appearances, so no inverted _dark variant
        // exists for it (same situation as Together).
        assertEquals(R.drawable.ic_provider_mistral, providerLogoRes(ProviderKind.Mistral))
        assertEquals(R.drawable.ic_provider_mistral, providerLogoRes(ProviderKind.Mistral, darkAppearance = true))
    }
}
