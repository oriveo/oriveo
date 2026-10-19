package ai.oriveo.community.core.context

import ai.oriveo.community.core.context.ContextContractFixture.bool
import ai.oriveo.community.core.context.ContextContractFixture.id
import ai.oriveo.community.core.context.ContextContractFixture.int
import ai.oriveo.community.core.context.ContextContractFixture.stringOrNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/** Persistent directive detector contract: runs the shared directive-detector.v2 fixture case by case; failure messages start with the case id. */
class ContextContractDirectiveDetectorTest {

    private val fixture: JsonObject by lazy { ContextContractFixture.load("directive-detector.v2.json") }

    private fun JsonObject.strings(key: String): List<String> =
        this[key]!!.jsonArray.map { it.jsonPrimitive.content }

    private fun expectedDetection(e: JsonObject): DirectiveDetection =
        if (!e.bool("isDirective")) {
            DirectiveDetection.NONE
        } else {
            DirectiveDetection(
                isDirective = true,
                span = e.stringOrNull("span"),
                kind = DirectiveKind.entries.first { it.raw == e.stringOrNull("kind") },
                scope = DirectiveScope.entries.first { it.raw == e.stringOrNull("scope") },
            )
        }

    @Test
    fun cases() {
        val failures = ContextContractFixture.cases(fixture, "cases").mapNotNull { c ->
            val expected = expectedDetection(c["expected"]!!.jsonObject)
            val actual = DirectiveDetector.detect(c.stringOrNull("text")!!)
            if (actual == expected) null else "${c.id()}: expected $expected, got $actual"
        }
        assertTrue(failures.joinToString("\n"), failures.isEmpty())
    }

    @Test
    fun stylePrefixCases() {
        val failures = ContextContractFixture.cases(fixture, "stylePrefixCases").mapNotNull { c ->
            val expected = c.stringOrNull("expected")
            val actual = DirectiveDetector.imageStylePrefix(c.stringOrNull("instructions")!!)
            if (actual == expected) null else "${c.id()}: expected <$expected>, got <$actual>"
        }
        assertTrue(failures.joinToString("\n"), failures.isEmpty())
    }

    @Test
    fun lexicon_matches_fixture() {
        val lexicon = fixture["lexicon"]!!.jsonObject
        assertEquals(lexicon.keys.toList(), DirectiveLexicon.languages.map { it.code })
        DirectiveLexicon.languages.forEach { lang ->
            val l = lexicon[lang.code]!!.jsonObject
            assertEquals("${lang.code} mode", l.stringOrNull("mode"), lang.mode.name.lowercase())
            val embedded = mapOf(
                "markers" to lang.markers,
                "verbs" to lang.verbs,
                "starts" to lang.starts,
                "vetoes" to lang.vetoes,
                "fillers" to lang.fillers,
                "questionParticlesAtEnd" to lang.questionParticlesAtEnd,
                "languageWords" to lang.languageWords,
                "formatWords" to lang.formatWords,
                "styleWords" to lang.styleWords,
                "imageStyleWords" to lang.imageStyleWords,
                "globalMarkers" to lang.globalMarkers,
            )
            assertEquals("${lang.code} keys", l.keys - "mode", embedded.keys)
            embedded.forEach { (key, terms) -> assertEquals("${lang.code} $key", l.strings(key), terms) }
        }
    }

    @Test
    fun constants_match_fixture() {
        assertEquals(fixture.int("version"), DirectiveLexicon.VERSION)
        assertEquals(fixture.int("maxScanCodePoints"), DirectiveLexicon.MAX_SCAN_CODE_POINTS)
        assertEquals(fixture.int("imageStylePrefixMax"), DirectiveLexicon.IMAGE_STYLE_PREFIX_MAX)
        assertEquals(fixture.strings("sentenceEnders"), DirectiveLexicon.sentenceEnders)
        assertEquals(fixture.strings("questionEnders"), DirectiveLexicon.questionEnders)
        assertEquals(fixture.strings("questionStarters"), DirectiveLexicon.questionStarters)
        assertEquals(
            fixture["quotePairs"]!!.jsonArray.map { p -> p.jsonArray.let { it[0].jsonPrimitive.content to it[1].jsonPrimitive.content } },
            DirectiveLexicon.quotePairs,
        )
    }
}
