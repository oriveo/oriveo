package ai.oriveo.community.core.network

import org.junit.Assert.assertEquals
import org.junit.Test

class NativeUserAgentTest {
    @Test
    fun `build formats native user agent`() {
        assertEquals(
            "Oriveo/1.2.3 (Android 15)",
            NativeUserAgent.build(versionName = "1.2.3", systemRelease = "15"),
        )
    }
}
