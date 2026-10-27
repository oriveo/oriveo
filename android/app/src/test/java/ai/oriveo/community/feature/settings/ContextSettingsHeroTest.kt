package ai.oriveo.community.feature.settings

import ai.oriveo.community.core.context.ContextBudget
import ai.oriveo.community.core.context.ContextBudgetCap
import ai.oriveo.community.feature.chat.ContextCapPresentation
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test
import java.io.File

/** Settings > Context overview card: reads the shared fixture shared/ui-contracts/context-settings-hero.v1.json (same-named cases on iOS). */
class ContextSettingsHeroTest {
    @Test fun `hero_auto`() = check("auto")

    @Test fun `hero_unlimited`() = check("unlimited")

    @Test fun `hero_custom_min_clamps_up`() = check("custom_min_clamps_up")

    @Test fun `hero_custom_half_default`() = check("custom_half_default")

    @Test fun `hero_custom_equals_auto_default`() = check("custom_equals_auto_default")

    @Test fun `hero_custom_huge_clamps_down`() = check("custom_huge_clamps_down")

    /** While custom, the overview card and the echo share one preview: 21000 is raised to the minimum 32000; an unparsable input falls back to the saved value; auto / unlimited are unchanged. */
    @Test
    fun `hero_custom_previews_typed_value`() {
        val stored = ContextBudgetCap.Custom(216_000)
        val hero = ContextCapPresentation.hero(ContextCapPresentation.heroPreviewCap(stored, "21000"))
        assertEquals(32_000, hero.valueTokens)
        assertEquals("settings_context_hero_caption_custom", hero.caption.key)
        assertEquals(ContextCapPresentation.echoValue("21000", u = null), hero.valueTokens)
        assertEquals(stored, ContextCapPresentation.heroPreviewCap(stored, "abc"))
        assertEquals(ContextBudgetCap.Auto, ContextCapPresentation.heroPreviewCap(ContextBudgetCap.Auto, "21000"))
        assertEquals(ContextBudgetCap.Unlimited, ContextCapPresentation.heroPreviewCap(ContextBudgetCap.Unlimited, "21000"))
    }

    @Test
    fun `hero_constants_match_fixture`() {
        val c = fixture["constants"]!!.jsonObject
        assertEquals(c.int("autoCapDefault"), ContextBudget.AUTO_CAP_DEFAULT)
        assertEquals(c.double("autoFill"), ContextCapPresentation.HERO_AUTO_FILL, 0.0)
        assertEquals(c.double("priceLineMarker"), ContextCapPresentation.HERO_PRICE_LINE_MARKER, 0.0)
        assertEquals(c.double("minFill"), ContextCapPresentation.HERO_MIN_FILL, 0.0)
        assertEquals(c.double("maxFill"), ContextCapPresentation.HERO_MAX_FILL, 0.0)
    }

    private fun check(name: String) {
        val case = fixture["cases"]!!.jsonArray.map { it.jsonObject }.single { it.str("name") == name }
        val cap = case["cap"]!!.jsonObject
        val stored = when (cap.str("kind")) {
            "auto" -> ContextBudgetCap.Auto
            "unlimited" -> ContextBudgetCap.Unlimited
            "custom" -> ContextBudgetCap.Custom(cap.int("tokens"))
            else -> error("unknown cap.kind")
        }
        val hero = ContextCapPresentation.hero(stored)
        when (case.str("valueKind")) {
            "count" -> assertEquals(name, case.int("valueTokens"), hero.valueTokens)
            "fullWindow" -> assertNull(name, hero.valueTokens)
            else -> error("unknown valueKind")
        }
        assertEquals(name, case.str("hasUnit").toBooleanStrict(), hero.hasUnit)
        assertEquals(name, case.str("captionKey"), hero.caption.key)
        assertEquals(name, case.double("fill"), hero.fill, 0.001)
        // The caption key exists in all 16 language resources
        LOCALE_DIRS.forEach { dir ->
            val xml = File("src/main/res/$dir/strings.xml").readText()
            assert(xml.contains("<string name=\"${hero.caption.key}\">")) { "$dir is missing ${hero.caption.key}" }
        }
    }

    private fun JsonObject.str(key: String): String = this[key]!!.jsonPrimitive.content
    private fun JsonObject.int(key: String): Int = str(key).toInt()
    private fun JsonObject.double(key: String): Double = str(key).toDouble()

    private companion object {
        val fixture: JsonObject by lazy {
            var dir: File? = File("").absoluteFile
            var file: File? = null
            while (dir != null && file == null) {
                file = File(dir, "shared/ui-contracts/context-settings-hero.v1.json").takeIf { it.exists() }
                dir = dir.parentFile
            }
            Json.parseToJsonElement(checkNotNull(file) { "context-settings-hero.v1.json not found" }.readText()).jsonObject
        }

        val LOCALE_DIRS = listOf(
            "values", "values-ar", "values-de", "values-es", "values-fr", "values-hi", "values-in",
            "values-ja", "values-ko", "values-pt-rBR", "values-ru", "values-th", "values-tr",
            "values-vi", "values-zh-rCN", "values-zh-rTW",
        )
    }
}
