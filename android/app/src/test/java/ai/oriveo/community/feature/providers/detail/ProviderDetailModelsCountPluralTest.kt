package ai.oriveo.community.feature.providers.detail

import android.content.Context
import android.content.res.Configuration
import androidx.test.core.app.ApplicationProvider
import java.io.File
import java.util.Locale
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config

/** The "N models" group header in the model library / enabled groups uses plurals; the 16 languages follow iOS; ar/ja/ko/zh use a single sentence without plural forms. */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [34])
class ProviderDetailModelsCountPluralTest {

    private fun count(locale: Locale, n: Int): String {
        val base = ApplicationProvider.getApplicationContext<Context>()
        val config = Configuration(base.resources.configuration).apply { setLocale(locale) }
        val res = base.createConfigurationContext(config).resources
        val id = res.getIdentifier("provider_detail_n_models", "plurals", base.packageName)
        assertTrue("provider_detail_n_models is plurals", id != 0)
        return res.getQuantityString(id, n, n)
    }

    @Test
    fun `RL2-PLURAL-01 group header count is pluralized`() {
        assertEquals("1 model", count(Locale.US, 1))
        assertEquals("2 models", count(Locale.US, 2))
        assertEquals("1 Modell", count(Locale.GERMAN, 1))
        assertEquals("1 модель", count(Locale.forLanguageTag("ru"), 1))
        assertEquals("2 модели", count(Locale.forLanguageTag("ru"), 2))
        assertEquals("3 модели", count(Locale.forLanguageTag("ru"), 3))
        assertEquals("5 моделей", count(Locale.forLanguageTag("ru"), 5))
        assertEquals("1 \u30e2\u30c7\u30eb", count(Locale.JAPANESE, 1))
        assertEquals("1 \u4e2a\u6a21\u578b", count(Locale.SIMPLIFIED_CHINESE, 1))
        assertEquals("٢ نموذجان", count(Locale.forLanguageTag("ar"), 2))
        assertEquals("7 mô hình", count(Locale.forLanguageTag("vi"), 7))
    }

    @Test
    fun `RL2-PLURAL-01 group headers read the plural resource`() {
        val catalog = source("feature/providers/detail/ProviderCatalogComponents.kt")
        val enabled = source("feature/providers/detail/ProviderDetailEnabledModels.kt")
        for (text in listOf(catalog, enabled)) {
            assertFalse("no longer a plain string", "R.string.provider_detail_n_models" in text)
            assertTrue("pluralStringResource(R.plurals.provider_detail_n_models" in text)
        }
        assertEquals("the community edition has no server-grouped managed panel, so only the relay header reads the plural", 1, Regex("R\\.plurals\\.provider_detail_n_models").findAll(enabled).count())
    }

    private fun source(path: String): String {
        val direct = File("src/main/java/ai/oriveo/community", path)
        return (if (direct.isFile) direct else File("app/src/main/java/ai/oriveo/community", path)).readText()
    }
}
