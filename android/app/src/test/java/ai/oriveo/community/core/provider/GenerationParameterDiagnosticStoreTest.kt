package ai.oriveo.community.core.provider

import android.content.Context
import ai.oriveo.community.testing.TestSharedPreferences
import io.mockk.every
import io.mockk.mockk
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test

class GenerationParameterDiagnosticStoreTest {

    private val prefs = TestSharedPreferences()

    @Before
    fun setUp() {
        val context = mockk<Context>(relaxed = true)
        every { context.applicationContext } returns context
        every { context.getSharedPreferences(any(), any()) } returns prefs
        GenerationParameterDiagnosticStore.configure(context)
        GenerationParameterDiagnosticStore.clear()
    }

    // Regression: once 50 entries are stored, the one evicted has to be the oldest, not the entry just written.
    // The earlier `(list() + entry).takeLast(50)` appended the new entry after list(), which is already sorted newest
    // first by createdAt, so takeLast chopped off exactly the newest entries and the history froze on the oldest 49
    // forever. Every assertion below reads back through the production write path in record().
    @Test
    fun `record retains newest 50 entries and evicts the oldest when over capacity`() {
        repeat(51) { index ->
            GenerationParameterDiagnosticStore.record(
                parameter = "param_$index",
                status = "recovered",
                transport = "openai",
                errorClass = "unsupported_parameter",
                phase = "before_first_token",
                modelId = "model-1",
            )
        }

        val stored = GenerationParameterDiagnosticStore.list()

        assertEquals(50, stored.size)
        assertFalse("the oldest entry param_0 must be evicted", stored.any { it.parameter == "param_0" })
        assertTrue("the newest entry param_50 must be kept", stored.any { it.parameter == "param_50" })
        // list() returns newest first by createdAt, so the newest entry has to come out at the head
        assertEquals("param_50", stored.first().parameter)
    }
}
