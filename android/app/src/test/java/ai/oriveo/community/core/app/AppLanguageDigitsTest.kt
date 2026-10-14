package ai.oriveo.community.core.app

import android.content.Context
import android.content.res.Configuration
import androidx.test.core.app.ApplicationProvider
import ai.oriveo.community.R
import ai.oriveo.community.core.model.LanguageOption
import java.util.Locale
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config

/** Under the Arabic UI language, counted strings always use Latin digits; the language tag sent outbound carries no Unicode extension. */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [34])
class AppLanguageDigitsTest {

    @Test
    fun `explicit arabic gets latin digits in quantity strings`() {
        val tag = AppLanguageManager.applicationLocaleTag(LanguageOption.Arabic)
        assertEquals("ar-u-nu-latn", tag)
        val base = ApplicationProvider.getApplicationContext<Context>()
        val config = Configuration(base.resources.configuration).apply { setLocale(Locale.forLanguageTag(tag!!)) }
        val text = base.createConfigurationContext(config).resources.getQuantityString(R.plurals.provider_detail_n_models, 5, 5)
        assertTrue("ar resources still match: $text", "نموذج" in text)
        assertTrue("Latin 5: $text", "5" in text && "٥" !in text)
    }

    @Test
    fun `plain arabic without the extension gives arabic-indic digits`() {
        // Control: ar without nu=latn renders the Arabic-Indic digits, proving the Latin digits above come from the extension and not from the local data.
        val base = ApplicationProvider.getApplicationContext<Context>()
        val config = Configuration(base.resources.configuration).apply { setLocale(Locale("ar")) }
        val text = base.createConfigurationContext(config).resources.getQuantityString(R.plurals.provider_detail_n_models, 5, 5)
        assertTrue("plain ar renders the Arabic-Indic five: $text", "٥" in text && "5" !in text)
    }

    @Test
    fun `other languages and follow system are unchanged`() {
        assertEquals("en", AppLanguageManager.applicationLocaleTag(LanguageOption.English))
        assertEquals("zh-CN", AppLanguageManager.applicationLocaleTag(LanguageOption.ChineseSimplified))
        assertNull("follow system does not go through here", AppLanguageManager.applicationLocaleTag(LanguageOption.System))
    }

    @Test
    fun `outbound language tag drops unicode extensions`() {
        assertEquals("ar", AppLanguageManager.outboundLanguageTag(Locale.forLanguageTag("ar-u-nu-latn")))
        assertEquals("zh-CN", AppLanguageManager.outboundLanguageTag(Locale.forLanguageTag("zh-CN")))
    }
}
