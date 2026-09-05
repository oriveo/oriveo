package ai.oriveo.community.feature.chat.components

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class CitationsBlockTest {
    @Test
    fun `only HTTPS URLs with a host can be opened`() {
        assertTrue(isOpenableCitationUrl("https://docs.example.com/page"))

        assertFalse(isOpenableCitationUrl("http://example.com"))
        assertFalse(isOpenableCitationUrl("javascript:alert(1)"))
        assertFalse(isOpenableCitationUrl("intent://example.com/#Intent;scheme=https;end"))
        assertFalse(isOpenableCitationUrl("file:///tmp/document"))
        assertFalse(isOpenableCitationUrl("https://user@example.com/private"))
        assertFalse(isOpenableCitationUrl("https:///missing-host"))
        assertFalse(isOpenableCitationUrl("example.com/page"))
    }
}
