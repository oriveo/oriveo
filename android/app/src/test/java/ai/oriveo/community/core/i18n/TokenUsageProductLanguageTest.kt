package ai.oriveo.community.core.i18n

import java.io.File
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * A semantic-direction gate for the token usage dialog's wording, across every shipped locale.
 *
 * Why this exists: a generic localization coverage check only looks for MISSING /
 * UNTRANSLATED / ENGLISH_PASSTHROUGH / VISIBLE_WIRE_ID -- it is completely blind to "translated,
 * but pointed in the wrong semantic direction". A translation can pass that check while most
 * locales' missing-state wording reads as "unavailable" and every locale's subtitle promises a
 * single request. This test is the only machine guard against that failure mode.
 *
 * A real incident: the missing-state wording started out as "no data yet". Later, the model
 * control panel reused the same `Unavailable` string to mean "this capability isn't supported",
 * and retranslating it for that meaning drifted several locales toward "not supported" -- so the
 * token usage dialog started reading as "this is broken", with nothing asserting against that
 * wording, all the way until release.
 *
 * The gate pins the *direction* of the wording, not today's exact text: the blacklist needs to
 * catch a future regression back toward that meaning, not just restate the current translation.
 */
class TokenUsageProductLanguageTest {

    /**
     * Words pointing toward "this capability isn't supported / can't be used". The missing-state
     * message is about the upstream not reporting this number -- a different cause and tense
     * entirely -- so matching any of these means the wording drifted in the wrong direction.
     */
    private val unsupportedDirection = listOf(
        "desteklenmez",
        "desteklenmiyor",
        "incompatível",
        "indisponible",
        "indisponível",
        "keine unterstützung",
        "không dùng được",
        "không hỗ trợ",
        "không khả dụng",
        "kullanılam",
        "mevcut değil",
        "nicht unterstütz",
        "nicht verfüg",
        "no compatible",
        "no disponible",
        "no soportado",
        "no support",
        "non disponible",
        "non pris en charge",
        "non supporté",
        "not available",
        "not supported",
        "não disponível",
        "não suportado",
        "pas disponible",
        "pas pris en charge",
        "sem suporte",
        "sin soporte",
        "tidak didukung",
        "tidak mendukung",
        "tidak tersedia",
        "unavailable",
        "unsupported",
        "unterstützt nicht",
        "не поддержив",
        "недоступн",
        "غير متاح",
        "غير متوفر",
        "غير مدعوم",
        "لا يدعم",
        "उपलब्ध नहीं",
        "समर्थन नहीं",
        "समर्थित नहीं",
        "ใช้ไม่ได้",
        "ไม่พร้อมใช้",
        "ไม่รองรับ",
        "サポートされ",
        "つかえません",
        "りようできません",
        "りようふか",
        "ひたいおう",
        "사용할 수 없",
        "이용할 수 없",
        "지원되지 않",
        "지원하지 않",
    )

    /**
     * Words that promise a single request. Continuing a reply can accumulate usage from several
     * turns onto the same message, so the number shown is a sum across N requests and the
     * wording must never promise a count of one.
     */
    private val countPromise = listOf(
        "bu istek",
        "bu sefer",
        "cette fois",
        "cette requête",
        "diese anfrage",
        "dieses mal",
        "esta solicitação",
        "esta solicitud",
        "esta vez",
        "lần này",
        "per request",
        "permintaan ini",
        "this model request",
        "this request",
        "this time",
        "this turn",
        "yêu cầu này",
        "этот запрос",
        "هذا الطلب",
        "इस बार",
        "यह अनुरोध",
        "ครั้งนี้",
        "このようきゅう",
        "こんかい",
        "이 요청",
        "이번",
    )

    private val resourceRoot = File("src/main/res")

    private fun localeEntries(): List<Pair<String, Map<String, String>>> {
        val default = "values" to strings(File(resourceRoot, "values/strings.xml"))
        val localized = resourceRoot.listFiles()
            ?.filter { it.name.startsWith("values-") }
            .orEmpty()
            // values-night only holds theme resources, no strings.xml, so it isn't a language locale
            .filter { File(it, "strings.xml").isFile }
            .map { it.name to strings(File(it, "strings.xml")) }
        return listOf(default) + localized
    }

    @Test
    fun `every shipped locale is covered`() {
        // 16 = values (default English) + 15 language directories. One missing means a locale got
        // skipped, and that skipped locale is exactly where the next silent regression would land.
        assertEquals(16, localeEntries().size)
    }

    @Test
    fun `missing-state wording means no data, never unsupported`() {
        localeEntries().forEach { (locale, entries) ->
            val text = entries["chat_token_usage_unavailable"]
            assertTrue("$locale is missing chat_token_usage_unavailable", !text.isNullOrBlank())
            val lowered = text!!.lowercase()
            unsupportedDirection.forEach { banned ->
                assertTrue(
                    "$locale's missing-state wording drifted toward \"capability not supported\": \"$text\" matches \"$banned\". " +
                        "This is about the upstream not reporting this number, not the feature being broken or unsupported.",
                    !lowered.contains(banned.lowercase()),
                )
            }
        }
    }

    @Test
    fun `subtitle never promises a single request`() {
        localeEntries().forEach { (locale, entries) ->
            val text = entries["chat_token_usage_subtitle"]
            assertTrue("$locale is missing chat_token_usage_subtitle", !text.isNullOrBlank())
            val lowered = text!!.lowercase()
            countPromise.forEach { banned ->
                assertTrue(
                    "$locale's subtitle promises a count: \"$text\" matches \"$banned\". " +
                        "Continuing a reply can accumulate usage from multiple turns onto one message, at which point it's a sum across N requests.",
                    !lowered.contains(banned.lowercase()),
                )
            }
        }
    }

    /**
     * The missing-state string and the "capability not supported" string must each use their
     * own key. Sharing one eventually gets pulled toward whichever side's requirements change
     * first -- which is exactly what caused the incident above.
     */
    @Test
    fun `missing-state key is not shared with any capability-unsupported context`() {
        val sources = File("src/main/java").walkTopDown()
            .filter { it.isFile && it.extension == "kt" }
            .filter { it.readText().contains("chat_token_usage_unavailable") }
            .map { it.relativeTo(File("src/main/java")).path }
            .toList()

        assertEquals(
            "chat_token_usage_unavailable must only be consumed by the token usage dialog; an extra call " +
                "site means it's shared with another context, and editing the translation would silently " +
                "leak into that context. Actual call sites: $sources",
            listOf("ai/oriveo/community/feature/chat/components/MessageBubble.kt"),
            sources,
        )

        // The capability side has its own key; the two must never be merged.
        val defaults = strings(File(resourceRoot, "values/strings.xml"))
        assertTrue(
            "the model control panel's \"this capability isn't supported\" wording must be its own string entry",
            defaults.containsKey("model_control_capability_unavailable_here"),
        )
    }

    private fun strings(file: File): Map<String, String> {
        val pattern = Regex("""<string name="([^"]+)">(.*?)</string>""", RegexOption.DOT_MATCHES_ALL)
        return pattern.findAll(file.readText()).associate { it.groupValues[1] to it.groupValues[2].trim() }
    }
}
