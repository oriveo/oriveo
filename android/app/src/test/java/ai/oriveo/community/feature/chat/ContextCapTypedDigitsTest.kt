package ai.oriveo.community.feature.chat

import java.io.File
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

// `\p{IsWhite_Space}` fails to compile on the Android 8 ICU regex engine, which used to crash ContextCapPresentation's initializer.
class ContextCapTypedDigitsTest {

    // The spelled-out code points must match Unicode White_Space exactly; the JVM knows the property, so use it as the oracle.
    @Test
    fun typedDigits_ignoresExactlyUnicodeWhiteSpaceAndGroupingMarks() {
        val whiteSpace = Regex("\\p{IsWhite_Space}")
        val grouping = setOf(',', '.', '\'', '’', '_')
        for (code in 0..0xFFFF) {
            val c = code.toChar()
            if (c.isSurrogate() || c in '0'..'9') continue
            val ignored = whiteSpace.matches(c.toString()) || c in grouping
            val expected = if (ignored) "12" else null
            assertEquals("U+%04X".format(code), expected, ContextCapPresentation.typedDigits("1${c}2"))
        }
    }

    // JVM tests cannot reproduce the Android ICU gap, so a source check keeps Java-only `\p{IsXxx}` classes out of main.
    @Test
    fun mainSources_doNotUseJavaOnlyUnicodePropertyRegex() {
        val offenders = File("src/main/java").walkTopDown()
            .filter { it.isFile && it.extension == "kt" }
            .filter { it.readText().contains("\\p{Is") }
            .map { it.path }
            .toList()
        assertTrue("Java-only \\p{Is…} regex in: $offenders", offenders.isEmpty())
    }
}
