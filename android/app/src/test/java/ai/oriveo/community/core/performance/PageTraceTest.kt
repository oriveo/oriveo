package ai.oriveo.community.core.performance

import org.junit.Assert.assertEquals
import org.junit.Test

class PageTraceTest {

    @Test
    fun `begin and end keep the active page registry balanced`() {
        PageTrace.resetForTesting()

        PageTrace.begin("Settings")
        assertEquals(1, PageTrace.activeTraceCountForTesting())

        PageTrace.end("Settings", detail = "rendered")
        assertEquals(0, PageTrace.activeTraceCountForTesting())
    }

    @Test
    fun `ending an unknown page is ignored`() {
        PageTrace.resetForTesting()

        PageTrace.end("Unknown")

        assertEquals(0, PageTrace.activeTraceCountForTesting())
    }
}
