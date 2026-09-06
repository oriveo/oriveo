package ai.oriveo.community.core.util

import android.content.ActivityNotFoundException
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class ExternalLaunchTest {

    @Test
    fun `missing external activity becomes unavailable instead of crashing`() {
        val outcome = launchExternalActivitySafely {
            throw ActivityNotFoundException("No document picker")
        }

        assertEquals(ExternalActivityLaunchOutcome.UNAVAILABLE, outcome)
    }

    @Test
    fun `security rejection becomes unavailable instead of crashing`() {
        val outcome = launchExternalActivitySafely {
            throw SecurityException("Launch blocked")
        }

        assertEquals(ExternalActivityLaunchOutcome.UNAVAILABLE, outcome)
    }

    @Test
    fun `successful launch is reported`() {
        var launched = false

        val outcome = launchExternalActivitySafely { launched = true }

        assertTrue(launched)
        assertEquals(ExternalActivityLaunchOutcome.LAUNCHED, outcome)
    }

    @Test(expected = IllegalStateException::class)
    fun `unexpected programming errors are not swallowed`() {
        launchExternalActivitySafely {
            throw IllegalStateException("Unexpected bug")
        }
    }
}
