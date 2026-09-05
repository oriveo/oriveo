package ai.oriveo.community.core.model

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class AppPreferenceTest {

    // ── ThemeOption ──────────────────────────────────────────────

    @Test
    fun `ThemeOption has 3 cases`() {
        assertEquals(3, ThemeOption.entries.size)
    }

    @Test
    fun `ThemeOption displayName returns correct values`() {
        assertEquals("Follow System", ThemeOption.System.displayName)
        assertEquals("Light", ThemeOption.Light.displayName)
        assertEquals("Dark", ThemeOption.Dark.displayName)
    }

    // ── LanguageOption ───────────────────────────────────────────

    @Test
    fun `LanguageOption has 17 cases`() {
        assertEquals(17, LanguageOption.entries.size)
    }

    @Test
    fun `LanguageOption System displayName is empty`() {
        assertEquals("", LanguageOption.System.displayName)
    }

    @Test
    fun `LanguageOption displayName shows native language names`() {
        assertEquals("English", LanguageOption.English.displayName)
        assertEquals("\u7b80\u4f53\u4e2d\u6587", LanguageOption.ChineseSimplified.displayName)
        assertEquals("\u7e41\u9ad4\u4e2d\u6587", LanguageOption.ChineseTraditional.displayName)
        assertEquals("\u65e5\u672c\u8a9e", LanguageOption.Japanese.displayName)
        assertEquals("한국어", LanguageOption.Korean.displayName)
        assertEquals("Español", LanguageOption.Spanish.displayName)
        assertEquals("Français", LanguageOption.French.displayName)
        assertEquals("Deutsch", LanguageOption.German.displayName)
        assertEquals("Português", LanguageOption.Portuguese.displayName)
        assertEquals("العربية", LanguageOption.Arabic.displayName)
        assertEquals("हिन्दी", LanguageOption.Hindi.displayName)
        assertEquals("Bahasa Indonesia", LanguageOption.Indonesian.displayName)
        assertEquals("Tiếng Việt", LanguageOption.Vietnamese.displayName)
        assertEquals("ไทย", LanguageOption.Thai.displayName)
        assertEquals("Türkçe", LanguageOption.Turkish.displayName)
        assertEquals("Русский", LanguageOption.Russian.displayName)
    }

    @Test
    fun `LanguageOption System localeTag is null`() {
        assertNull(LanguageOption.System.localeTag)
    }

    @Test
    fun `LanguageOption localeTag returns correct Android locale tags`() {
        assertEquals("en", LanguageOption.English.localeTag)
        assertEquals("zh-CN", LanguageOption.ChineseSimplified.localeTag)
        assertEquals("zh-TW", LanguageOption.ChineseTraditional.localeTag)
        assertEquals("ja", LanguageOption.Japanese.localeTag)
        assertEquals("ko", LanguageOption.Korean.localeTag)
        assertEquals("es", LanguageOption.Spanish.localeTag)
        assertEquals("fr", LanguageOption.French.localeTag)
        assertEquals("de", LanguageOption.German.localeTag)
        assertEquals("pt-BR", LanguageOption.Portuguese.localeTag)
        assertEquals("ar", LanguageOption.Arabic.localeTag)
        assertEquals("hi", LanguageOption.Hindi.localeTag)
        assertEquals("id", LanguageOption.Indonesian.localeTag)
        assertEquals("vi", LanguageOption.Vietnamese.localeTag)
        assertEquals("th", LanguageOption.Thai.localeTag)
        assertEquals("tr", LanguageOption.Turkish.localeTag)
        assertEquals("ru", LanguageOption.Russian.localeTag)
    }

    @Test
    fun `all non-System languages have non-null localeTag`() {
        LanguageOption.entries.filter { it != LanguageOption.System }.forEach { lang ->
            assertTrue("$lang should have a localeTag", lang.localeTag != null)
        }
    }

    @Test
    fun `all non-System languages have non-empty displayName`() {
        LanguageOption.entries.filter { it != LanguageOption.System }.forEach { lang ->
            assertTrue("$lang should have non-empty displayName", lang.displayName.isNotEmpty())
        }
    }

    // ── AppPreference defaults ───────────────────────────────────

    @Test
    fun `AppPreference defaults to Dark theme and System language`() {
        // Dark is the product default: when the user hasn't explicitly set a theme, it falls back to Dark
        val pref = AppPreference()
        assertEquals(ThemeOption.Dark, pref.theme)
        assertEquals(LanguageOption.System, pref.language)
    }
}
