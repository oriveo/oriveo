package ai.oriveo.community.feature.chat.components

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/** The long user message fold rule; the web client's `user-message-fold.test.ts` checks the same cases. */
class UserMessageFoldTest {

    private fun arabic(length: Int): String {
        val sentence = "هذا نص عربي طويل جدا بدون أي سطر جديد. "
        return buildString { while (this.length < length) append(sentence) }
    }

    @Test
    fun `threshold boundary counts UTF-16 units`() {
        val atThreshold = "a".repeat(UserMessageFold.THRESHOLD_UTF16)
        assertFalse(UserMessageFold.shouldFold(atThreshold))
        assertTrue(UserMessageFold.shouldFold(atThreshold + "a"))
        assertFalse(UserMessageFold.shouldFold("😀".repeat(3_000)))
        assertTrue(UserMessageFold.shouldFold("😀".repeat(3_001)))
    }

    @Test
    fun `preview is a bounded prefix of the original`() {
        val text = arabic(200_000)
        val preview = UserMessageFold.preview(text)
        assertTrue(text.startsWith(preview))
        assertTrue(preview.length <= UserMessageFold.PREVIEW_UTF16)
        assertTrue(preview.length > UserMessageFold.PREVIEW_UTF16 - 30)
    }

    @Test
    fun `preview never splits an emoji sequence or a base letter from its marks`() {
        val family = "👩‍👩‍👧‍👦"
        val text = "a".repeat(UserMessageFold.PREVIEW_UTF16 - 1) + family + "b".repeat(8_000)
        assertEquals("a".repeat(UserMessageFold.PREVIEW_UTF16 - 1), UserMessageFold.preview(text))

        // ب + kasra + shadda is one grapheme; the prefix may only stop between graphemes.
        val marked = "بِّ".repeat(3_000)
        assertEquals(0, UserMessageFold.preview(marked).length % 3)
    }

    @Test
    fun `preview keeps at most 60 line breaks`() {
        val text = "line\n".repeat(5_000)
        val preview = UserMessageFold.preview(text)
        assertEquals(UserMessageFold.PREVIEW_LINE_CAP, preview.count { it == '\n' })
        assertTrue(text.startsWith(preview))
    }

    @Test
    fun `reading chunks keep every character and stay under the chunk cap`() {
        val text = arabic(200_000) + "\n\nsecond paragraph\n" + "한".repeat(5_000)
        val chunks = UserMessageFold.readingChunks(text)
        assertEquals(text.replace("\n", ""), chunks.joinToString(""))
        assertTrue(chunks.all { it.length <= UserMessageFold.READING_CHUNK_UTF16 })
        // A 200,000-character paragraph becomes about 100 chunks; the LazyColumn composes only the visible few.
        assertTrue(chunks.size in 100..140)
        // The Arabic text has periods and spaces: breaks land after a sentence end, so no chunk starts with whitespace.
        assertTrue(chunks.first().endsWith(". "))
    }

    @Test
    fun `reading chunks break long runs without spaces on grapheme boundaries`() {
        val text = "👍🏽".repeat(3_000)
        val chunks = UserMessageFold.readingChunks(text)
        assertEquals(text, chunks.joinToString(""))
        chunks.forEach { chunk -> assertEquals(0, chunk.length % 4) }
    }
}
