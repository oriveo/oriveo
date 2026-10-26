package ai.oriveo.community.core.voice

import android.annotation.SuppressLint
import android.content.Context
import android.os.Build
import android.view.textclassifier.TextClassificationManager
import android.view.textclassifier.TextLanguage
import androidx.annotation.RequiresApi
import kotlinx.coroutines.CoroutineDispatcher
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext

/** Source of language hypotheses for the read-aloud text; the result goes to [CloudReadAloudRules.readingLanguage] to pick the reading language. */
fun interface ReadingLanguageDetector {
    /** Language hypotheses for [text]; empty if undetectable. May be called on any thread; the implementation switches to a background thread itself. */
    suspend fun detect(text: String): List<LanguageHypothesis>

    companion object {
        /** No detection: read-aloud always uses the UI locale. */
        val NONE = ReadingLanguageDetector { emptyList() }
    }
}

/** Production implementation: TextClassifier.detectLanguage (API 29+, IO thread); always empty below 29 or on error. */
class AndroidReadingLanguageDetector internal constructor(
    private val sdkInt: Int,
    private val io: CoroutineDispatcher,
    private val classify: (String) -> TextLanguage?,
) : ReadingLanguageDetector {
    constructor(context: Context) : this(
        sdkInt = Build.VERSION.SDK_INT,
        io = Dispatchers.IO,
        classify = platformClassifier(context.applicationContext),
    )

    // sdkInt is injected for tests and lint cannot see this version check; API below 29 already returns on the first line
    @SuppressLint("NewApi")
    override suspend fun detect(text: String): List<LanguageHypothesis> {
        if (sdkInt < Build.VERSION_CODES.Q) return emptyList()
        return withContext(io) {
            runCatching {
                classify(text.take(MAX_DETECT_CHARS))?.let(::hypotheses).orEmpty()
            }.getOrDefault(emptyList())
        }
    }

    internal companion object {
        private const val MAX_DETECT_CHARS = 2000

        /** Take each locale hypothesis's BCP-47 tag and confidence as is. */
        @RequiresApi(Build.VERSION_CODES.Q)
        fun hypotheses(result: TextLanguage): List<LanguageHypothesis> =
            (0 until result.localeHypothesisCount).map { index ->
                val locale = result.getLocale(index)
                LanguageHypothesis(locale.toLanguageTag(), result.getConfidenceScore(locale).toDouble())
            }

        private fun platformClassifier(context: Context): (String) -> TextLanguage? = { text ->
            if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) {
                null
            } else {
                context.getSystemService(TextClassificationManager::class.java)
                    ?.textClassifier
                    ?.detectLanguage(TextLanguage.Request.Builder(text).build())
            }
        }
    }
}
