package ai.oriveo.community.feature.providers.grok

import ai.oriveo.community.core.provider.grok.GrokSubscriptionAuthConfig
import ai.oriveo.community.core.provider.grok.GrokSubscriptionOAuthClient
import ai.oriveo.community.feature.providers.SubscriptionAuthorizationSnapshotStore
import io.ktor.client.HttpClient
import io.ktor.client.engine.mock.MockEngine
import io.ktor.client.engine.mock.respond
import io.ktor.http.HttpHeaders
import io.ktor.http.HttpStatusCode
import io.ktor.http.headersOf
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * State machine for Grok subscription authorization: **recomposition must not interrupt an
 * authorization already in progress**.
 *
 * Mirrors the like-named test in `OpenAISubscriptionAuthorizationModelTest` case by case -- this
 * piece of logic is the same shape in both flows, and a bug in one is a bug in both, so both need
 * the same regression pinned. Grok is single-step (polling exchanges directly for tokens), while
 * Codex is two-step, but that difference doesn't affect the `startIfIdle` guard: it only cares
 * whether pollJob is still running.
 */
@OptIn(ExperimentalCoroutinesApi::class)
class GrokSubscriptionAuthorizationModelTest {

    private val config = GrokSubscriptionAuthConfig(
        clientId = "app_test",
        scopes = "openid profile",
        deviceAuthorizationEndpoint = "https://accounts.x.ai/oauth2/device/code",
        tokenEndpoint = "https://accounts.x.ai/oauth2/token",
        revocationEndpoint = "https://accounts.x.ai/oauth2/revoke",
        trustedVerificationHosts = listOf("accounts.x.ai"),
        resourceBaseUrl = "https://api.x.ai/v1",
        requiredHeaders = mapOf("x-grok-client-version" to "1.0.0"),
        modelsUrl = "https://api.x.ai/v1/models",
        chatUrl = "https://api.x.ai/v1/chat/completions",
        pollIntervalSeconds = 5,
        pollTimeoutSeconds = 900,
    )

    private val jsonHeaders = headersOf(HttpHeaders.ContentType, "application/json")

    private fun deviceCodeBody(index: Int) =
        """{"device_code":"dc_$index","user_code":"CODE-$index",""" +
            """"verification_uri_complete":"https://accounts.x.ai/device?code=CODE-$index",""" +
            """"expires_in":600,"interval":5}"""

    private val tokensBody =
        """{"access_token":"at_1","refresh_token":"rt_1","expires_in":3600,"scope":"openid profile"}"""

    /**
     * **Regression: coming back should not trigger re-authorization.**
     *
     * Authorization requires the user to leave the app for the browser to approve, and by the
     * time they return the Activity may have been recreated, causing Compose to re-run
     * `LaunchedEffect(config)`. If that call was an unconditional `start()`, it would request a
     * new short code, invalidating the one the user just typed into the browser, and no coroutine
     * would be left polling the old device code.
     *
     * This test calls [GrokSubscriptionAuthorizationModel.startIfIdle] from inside the `sleep`
     * callback, at the exact moment pollJob is still alive and phase is sitting at
     * AwaitingAuthorization -- precisely when a recomposition could collide with it. The assertion
     * is that only one short code is ever requested throughout.
     */
    @Test
    fun `startIfIdle during recomposition does not interrupt an in-flight poll or request a new short code`() = runTest {
        var deviceCodeCount = 0
        var polls = 0
        var reentered = false
        lateinit var model: GrokSubscriptionAuthorizationModel

        val client = HttpClient(
            MockEngine { request ->
                val path = request.url.encodedPath
                if (path.endsWith("/device/code")) {
                    deviceCodeCount++
                    respond(deviceCodeBody(deviceCodeCount), HttpStatusCode.OK, jsonHeaders)
                } else {
                    polls++
                    if (polls == 1) {
                        respond(
                            """{"error":"authorization_pending"}""",
                            HttpStatusCode.BadRequest,
                            jsonHeaders,
                        )
                    } else {
                        respond(tokensBody, HttpStatusCode.OK, jsonHeaders)
                    }
                }
            }
        )

        model = GrokSubscriptionAuthorizationModel(
            client = GrokSubscriptionOAuthClient(client),
            scope = this,
            nowMillis = { 0L },
            sleep = {
                if (!reentered) {
                    reentered = true
                    // At this point we are inside the polling coroutine: pollJob is alive and the short code has already been handed to the user.
                    model.startIfIdle(config)
                }
            },
        )

        model.start(config)
        model.awaitCompletionForTest()

        assertEquals("recomposition should not request a short code again", 1, deviceCodeCount)
        assertTrue(reentered)
        val phase = model.phase
        assertTrue("actual phase was $phase", phase is GrokSubscriptionAuthorizationModel.Phase.Succeeded)
    }

    /** A fake store that records every write, used to assert the lifecycle of the snapshot. */
    private class RecordingSnapshotStore(
        private var value: String? = null,
    ) : SubscriptionAuthorizationSnapshotStore {
        val writes = mutableListOf<String?>()
        override fun read(): String? = value
        override fun write(value: String?) {
            this.value = value
            writes += value
        }
    }

    /**
     * **Regression (second layer): polling the same short code must resume even after the process is killed.**
     *
     * A ViewModel only survives configuration changes; a non-configuration-change destruction
     * clears the ViewModelStore directly, and the app is backgrounded exactly while the user is
     * off authorizing in the browser. This test builds a fresh model (standing in for a new
     * ViewModel after process recreation) that reads the same snapshot, and asserts it never
     * requests a new short code. Mirrors the like-named test on the Codex side.
     */
    @Test
    fun `startIfIdle after process recreation resumes polling from the snapshot without requesting a new short code`() = runTest {
        var deviceCodeCount = 0
        val client = HttpClient(
            MockEngine { request ->
                if (request.url.encodedPath.endsWith("/device/code")) {
                    deviceCodeCount++
                    respond(deviceCodeBody(9), HttpStatusCode.OK, jsonHeaders)
                } else {
                    respond(tokensBody, HttpStatusCode.OK, jsonHeaders)
                }
            }
        )
        val store = RecordingSnapshotStore(
            """{"deviceCode":"dc_saved","userCode":"SAVED-CODE",""" +
                """"verificationUrl":"https://accounts.x.ai/device?code=SAVED-CODE",""" +
                """"expiresIn":600,"interval":5,"deadlineMillis":600000}"""
        )

        val model = GrokSubscriptionAuthorizationModel(
            client = GrokSubscriptionOAuthClient(client),
            scope = this,
            nowMillis = { 0L },
            sleep = { },
            snapshotStore = store,
        )

        model.startIfIdle(config)
        model.awaitCompletionForTest()

        assertEquals("a restored short code should not be clobbered by a fresh request", 0, deviceCodeCount)
        assertTrue(model.phase is GrokSubscriptionAuthorizationModel.Phase.Succeeded)
        assertEquals(null, store.writes.last())
    }

    /** On first entry (Idle), authorization must actually kick off -- the guard above must not overreach and block the normal entry path too. */
    @Test
    fun `startIfIdle from idle starts authorization normally`() = runTest {
        var deviceCodeCount = 0
        val client = HttpClient(
            MockEngine { request ->
                if (request.url.encodedPath.endsWith("/device/code")) {
                    deviceCodeCount++
                    respond(deviceCodeBody(1), HttpStatusCode.OK, jsonHeaders)
                } else {
                    respond(tokensBody, HttpStatusCode.OK, jsonHeaders)
                }
            }
        )
        val model = GrokSubscriptionAuthorizationModel(
            client = GrokSubscriptionOAuthClient(client),
            scope = this,
            nowMillis = { 0L },
            sleep = { },
        )

        model.startIfIdle(config)
        model.awaitCompletionForTest()

        assertEquals(1, deviceCodeCount)
        assertTrue(model.phase is GrokSubscriptionAuthorizationModel.Phase.Succeeded)
    }
}
