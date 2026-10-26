package ai.oriveo.community.core.voice

import android.icu.util.ULocale
import android.view.textclassifier.TextLanguage
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config

/** Production [AndroidReadingLanguageDetector]: the API gate and platform TextLanguage -> hypothesis list. */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [34])
class ReadingLanguageDetectorTest {

    @Test
    fun `api below 29 returns no hypothesis`() = runBlocking {
        var classified = false
        val detector = AndroidReadingLanguageDetector(sdkInt = 28, io = Dispatchers.Unconfined) {
            classified = true
            TextLanguage.Builder().putLocale(ULocale.ENGLISH, 0.9f).build()
        }

        assertTrue(detector.detect("Hello there.").isEmpty())
        assertEquals(false, classified)
    }

    @Test
    fun `maps text language scores to hypotheses`() = runBlocking {
        val detector = AndroidReadingLanguageDetector(sdkInt = 29, io = Dispatchers.Unconfined) {
            TextLanguage.Builder()
                .putLocale(ULocale.forLanguageTag("ja"), 0.75f)
                .putLocale(ULocale.forLanguageTag("zh-Hans"), 0.25f)
                .build()
        }

        val result = detector.detect("\u4eca\u65e5\u306f\u3044\u3044\u5929\u6c17\u3067\u3059\u306d\u3002")

        assertEquals(setOf("ja", "zh-Hans"), result.map { it.language }.toSet())
        assertEquals(0.75, result.first { it.language == "ja" }.confidence, 1e-6)
        assertEquals(0.25, result.first { it.language == "zh-Hans" }.confidence, 1e-6)
        assertEquals("ja", CloudReadAloudRules.readingLanguage(result, "en"))
    }
}
