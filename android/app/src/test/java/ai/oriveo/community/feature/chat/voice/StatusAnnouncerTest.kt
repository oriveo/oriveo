package ai.oriveo.community.feature.chat.voice

import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.test.advanceTimeBy
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/** The announcer speaks the status word only with a screen reader on and brackets it with onSpeaking. */
@OptIn(ExperimentalCoroutinesApi::class)
class StatusAnnouncerTest {

    @Test
    fun `screen reader off announces nothing`() = runTest {
        val spoken = mutableListOf<String>()
        val speaking = mutableListOf<Boolean>()
        val announcer = StatusAnnouncer(backgroundScope, { false }, { spoken += it }, { speaking += it })
        announcer.announce("Listening")
        announcer.announce("Thinking")
        advanceTimeBy(10_000)
        runCurrent()
        assertTrue(spoken.isEmpty())
        assertTrue(speaking.isEmpty())
    }

    @Test
    fun `screen reader on speaks status and toggles onSpeaking`() = runTest {
        val spoken = mutableListOf<String>()
        val speaking = mutableListOf<Boolean>()
        val announcer = StatusAnnouncer(backgroundScope, { true }, { spoken += it }, { speaking += it })
        announcer.announce("Listening")
        runCurrent()
        assertEquals(listOf("Listening"), spoken)
        assertEquals(listOf(true), speaking)

        // The same word again is not re-announced.
        announcer.announce("Listening")
        runCurrent()
        assertEquals(listOf("Listening"), spoken)

        advanceTimeBy(StatusAnnouncer.estimateMillis("Listening") - 1)
        runCurrent()
        assertEquals(listOf(true), speaking)
        advanceTimeBy(2)
        runCurrent()
        assertEquals(listOf(true, false), speaking)
    }
}
