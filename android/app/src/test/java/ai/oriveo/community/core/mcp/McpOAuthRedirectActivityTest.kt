package ai.oriveo.community.core.mcp

import android.content.Intent
import android.net.Uri
import ai.oriveo.community.MainActivity
import java.io.File
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import org.koin.core.context.startKoin
import org.koin.core.context.stopKoin
import org.koin.dsl.module
import org.robolectric.Robolectric
import org.robolectric.RobolectricTestRunner
import org.robolectric.Shadows.shadowOf

/**
 * Trampoline Activity for the OAuth redirect. This runs the real [McpOAuthRedirectActivity]: the system delivers the VIEW
 * intent to it, and the test asserts whether it handed the redirect to the waiting authorization and brought the main UI to the front.
 */
@RunWith(RobolectricTestRunner::class)
class McpOAuthRedirectActivityTest {

    private val router = McpOAuthCallbackRouter()

    @Before
    fun setUp() {
        startKoin { modules(module { single { router } }) }
    }

    @After
    fun tearDown() {
        stopKoin()
    }

    private fun deliver(url: String): Intent? {
        val controller = Robolectric.buildActivity(McpOAuthRedirectActivity::class.java, Intent(Intent.ACTION_VIEW, Uri.parse(url)))
        val activity = controller.create().get()
        assertTrue("the trampoline finishes itself right away", activity.isFinishing)
        return shadowOf(activity).nextStartedActivity
    }

    @Test
    fun `a claimed callback is handed over and the main screen comes back to the front`() {
        val waiting = router.register("st_1")

        val started = deliver("${McpClientMetadata.REDIRECT_URI}?code=ac&state=st_1")

        assertTrue(waiting.isCompleted)
        assertEquals(MainActivity::class.java.name, started?.component?.className)
    }

    /**
     * A redirect nobody claims (`state` does not match, the process that started it is gone, a duplicate delivery, or not a
     * redirect address at all): the trampoline just finishes and does **not** pull the app to the front, because nobody is waiting for that link.
     */
    @Test
    fun `an unclaimed callback finishes without bringing the app to the front`() {
        val waiting = router.register("st_1")

        for (url in listOf(
            "${McpClientMetadata.REDIRECT_URI}?code=ac&state=someone_else",
            "${McpClientMetadata.REDIRECT_URI}?code=ac",
            "${McpClientMetadata.REDIRECT_URI}/extra?code=ac&state=st_1",
            "https://app.example.com/mcp/oauth/callback?code=ac&state=st_1",
        )) {
            assertNull(url, deliver(url))
        }
        assertTrue("the authorization that is really waiting is unaffected", !waiting.isCompleted)
    }

    /** The intent filter in the manifest is exactly the redirect URI registered in code: one literal scheme, host and path. */
    @Test
    fun `the manifest registers exactly the custom scheme redirect`() {
        val manifest = generateSequence(File(System.getProperty("user.dir")).absoluteFile) { it.parentFile }
            .map { File(it, "src/main/AndroidManifest.xml") }
            .first { it.isFile }
            .readText()
        val filter = manifest.substringAfter(".core.mcp.McpOAuthRedirectActivity").substringBefore("</activity>")
        val uri = Uri.parse(McpClientMetadata.REDIRECT_URI)
        assertEquals("oriveo", uri.scheme)
        assertEquals("mcp", uri.host)
        assertEquals("/oauth/callback", uri.path)
        assertEquals(filter, 1, Regex("<intent-filter").findAll(filter).count())
        assertEquals(filter, 1, Regex("<data\\s").findAll(filter).count())
        assertTrue(
            filter,
            "android:scheme=\"${uri.scheme}\"" in filter && "android:host=\"${uri.host}\"" in filter && "android:path=\"${uri.path}\"" in filter,
        )
        assertTrue("the path is matched literally, not as a prefix or a pattern", "android:pathPrefix" !in filter && "android:pathPattern" !in filter)
        assertEquals(listOf("oriveo://mcp/oauth/callback"), McpClientMetadata.REDIRECT_URIS)
    }
}
