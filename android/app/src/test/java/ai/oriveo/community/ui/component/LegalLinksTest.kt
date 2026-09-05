package ai.oriveo.community.ui.component

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class LegalLinksTest {

    @Test
    fun `every destination points into the public repository`() {
        OriveoWebDestination.entries.forEach { destination ->
            assertTrue(
                "$destination must resolve inside $ORIVEO_REPOSITORY_URL",
                destination.url == ORIVEO_REPOSITORY_URL ||
                    destination.url.startsWith("$ORIVEO_REPOSITORY_URL/"),
            )
        }
    }

    @Test
    fun `legal destinations resolve to the licence and the community page`() {
        assertEquals("$ORIVEO_REPOSITORY_URL/blob/main/LICENSE", OriveoWebDestination.TermsOfService.url)
        assertEquals("$ORIVEO_REPOSITORY_URL/blob/main/COMMUNITY.md", OriveoWebDestination.PrivacyPolicy.url)
    }

    @Test
    fun `changelog and source destinations resolve to releases and the repository root`() {
        assertEquals("$ORIVEO_REPOSITORY_URL/releases", OriveoWebDestination.Changelog.url)
        assertEquals(ORIVEO_REPOSITORY_URL, OriveoWebDestination.SourceCode.url)
        assertEquals("$ORIVEO_REPOSITORY_URL/issues", OriveoWebDestination.Issues.url)
    }
}
