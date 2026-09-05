package ai.oriveo.community.feature.providers.openai

import ai.oriveo.community.core.provider.openai.OpenAISubscriptionAuthConfig
import ai.oriveo.community.core.provider.openai.OpenAISubscriptionError
import ai.oriveo.community.core.provider.openai.OpenAISubscriptionOAuthClient
import ai.oriveo.community.feature.providers.SubscriptionAuthorizationSnapshotStore
import io.ktor.client.HttpClient
import io.ktor.client.engine.mock.MockEngine
import io.ktor.client.engine.mock.respond
import io.ktor.http.HttpHeaders
import io.ktor.http.HttpStatusCode
import io.ktor.http.content.TextContent
import io.ktor.http.headersOf
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.util.Base64

/**
 * State machine for authorization: poll cadence, failure tiers, and treating transient
 * failures as recoverable rather than fatal.
 *
 * Distinct from `OpenAISubscriptionOAuthClientTest`, which pins the shape of a single request
 * and its response translation. This file pins how a full authorization round proceeds end to
 * end -- whether the two-step exchange still yields exactly one success and whether transport
 * hiccups can knock the user out of the flow.
 */
@OptIn(ExperimentalCoroutinesApi::class)
class OpenAISubscriptionAuthorizationModelTest {

    private val config = OpenAISubscriptionAuthConfig(
        clientId = "app_test",
        deviceAuthorizationEndpoint = "https://auth.openai.com/api/accounts/deviceauth/usercode",
        deviceTokenEndpoint = "https://auth.openai.com/api/accounts/deviceauth/token",
        tokenEndpoint = "https://auth.openai.com/oauth/token",
        verificationUrl = "https://auth.openai.com/codex/device",
        redirectUri = "https://auth.openai.com/deviceauth/callback",
        trustedVerificationHosts = listOf("auth.openai.com"),
        resourceBaseUrl = "https://chatgpt.com/backend-api/codex",
        requiredHeaders = mapOf("version" to "0.148.0"),
        modelsPath = "/models",
        chatPath = "/responses",
        modelsUrl = "https://chatgpt.com/backend-api/codex/models",
        responsesUrl = "https://chatgpt.com/backend-api/codex/responses",
        pollIntervalSeconds = 5,
        pollTimeoutSeconds = 900,
    )

    private val jsonHeaders = headersOf(HttpHeaders.ContentType, "application/json")

    private fun jwt(payload: String): String {
        val encode = { value: String ->
            Base64.getUrlEncoder().withoutPadding().encodeToString(value.toByteArray(Charsets.UTF_8))
        }
        return "${encode("""{"alg":"RS256","typ":"JWT"}""")}.${encode(payload)}.signature"
    }

    private val accountId = "5c0d9a3e-1f2b-4c8d-9e7a-0b1c2d3e4f50"

    private val idToken = jwt(
        """{"sub":"u","https://api.openai.com/auth":{"chatgpt_account_id":"$accountId","chatgpt_plan_type":"plus"}}"""
    )

    private fun usercodeBody(expiresIn: Int = 600, interval: Int = 5) =
        """{"device_auth_id":"da_1","user_code":"ABCD-1234","expires_in":$expiresIn,"interval":$interval}"""

    private val exchangedTokens =
        """{"access_token":"at_1","refresh_token":"rt_1","id_token":"$idToken","expires_in":3600}"""

    /**
     * The short code is what the user types in, so polling must send `user_code` along with it --
     * sending only the device code (as Grok's flow does) leaves upstream unable to recognize the
     * authorization, so it never reaches success.
     */
    @Test
    fun `polling sends both device_auth_id and the short code, and the two-step exchange still yields exactly one success`() = runTest {
        val bodies = mutableListOf<String>()
        val client = HttpClient(
            MockEngine { request ->
                val path = request.url.encodedPath
                when {
                    path.endsWith("/usercode") -> respond(usercodeBody(), HttpStatusCode.OK, jsonHeaders)
                    path.endsWith("/deviceauth/token") -> {
                        bodies += (request.body as TextContent).text
                        respond(
                            """{"authorization_code":"ac_1","code_verifier":"cv_1"}""",
                            HttpStatusCode.OK,
                            jsonHeaders,
                        )
                    }
                    else -> respond(exchangedTokens, HttpStatusCode.OK, jsonHeaders)
                }
            }
        )
        val model = OpenAISubscriptionAuthorizationModel(
            client = OpenAISubscriptionOAuthClient(client),
            scope = this,
            nowMillis = { 0L },
            sleep = { },
        )

        model.start(config)
        model.awaitCompletionForTest()

        val phase = model.phase
        assertTrue("actual phase was $phase", phase is OpenAISubscriptionAuthorizationModel.Phase.Succeeded)
        val tokens = (phase as OpenAISubscriptionAuthorizationModel.Phase.Succeeded).tokens
        assertEquals("at_1", tokens.accessToken)
        assertEquals(accountId, tokens.accountId)
        assertEquals(1, bodies.size)
        assertTrue(bodies[0].contains(""""device_auth_id":"da_1""""))
        assertTrue(bodies[0].contains(""""user_code":"ABCD-1234""""))
    }

    /**
     * **The most important test in this file**: authorization requires the user to switch away
     * into Custom Tabs, which puts the app in the background while an in-flight poll request gets
     * killed by the system. Treating that transport failure as terminal would mean the very act of
     * completing authorization breaks it (seen on a real device: the connection reads as failed
     * before the user even finishes entering the code, right after switching back). A real
     * disconnect is still caught by the deadline.
     */
    @Test
    fun `a transient network interruption during polling is not treated as fatal, and polling succeeds once connectivity returns`() = runTest {
        var poll = 0
        val client = HttpClient(
            MockEngine { request ->
                val path = request.url.encodedPath
                when {
                    path.endsWith("/usercode") -> respond(usercodeBody(), HttpStatusCode.OK, jsonHeaders)
                    path.endsWith("/deviceauth/token") -> {
                        poll += 1
                        // The first two rounds simulate the connection being cut while the app is backgrounded; by the third round the user has approved.
                        if (poll <= 2) throw java.io.IOException("Software caused connection abort")
                        respond(
                            """{"authorization_code":"ac_1","code_verifier":"cv_1"}""",
                            HttpStatusCode.OK,
                            jsonHeaders,
                        )
                    }
                    else -> respond(exchangedTokens, HttpStatusCode.OK, jsonHeaders)
                }
            }
        )
        val model = OpenAISubscriptionAuthorizationModel(
            client = OpenAISubscriptionOAuthClient(client),
            scope = this,
            nowMillis = { 0L },
            sleep = { },
        )

        model.start(config)
        model.awaitCompletionForTest()

        val phase = model.phase
        assertTrue("actual phase was $phase", phase is OpenAISubscriptionAuthorizationModel.Phase.Succeeded)
        assertEquals(3, poll)
    }

    /** RFC 8628: after a `slow_down`, interval += 5; polling too eagerly just earns more slow_down responses. */
    @Test
    fun `pending keeps waiting, slow_down adds 5 seconds to the interval`() = runTest {
        var poll = 0
        val slept = mutableListOf<Long>()
        val client = HttpClient(
            MockEngine { request ->
                val path = request.url.encodedPath
                when {
                    path.endsWith("/usercode") -> respond(usercodeBody(), HttpStatusCode.OK, jsonHeaders)
                    path.endsWith("/deviceauth/token") -> {
                        poll += 1
                        when (poll) {
                            1 -> respond(
                                """{"error":"authorization_pending"}""",
                                HttpStatusCode.BadRequest,
                                jsonHeaders,
                            )
                            2 -> respond("""{"error":"slow_down"}""", HttpStatusCode.BadRequest, jsonHeaders)
                            else -> respond(
                                """{"authorization_code":"ac_1","code_verifier":"cv_1"}""",
                                HttpStatusCode.OK,
                                jsonHeaders,
                            )
                        }
                    }
                    else -> respond(exchangedTokens, HttpStatusCode.OK, jsonHeaders)
                }
            }
        )
        val model = OpenAISubscriptionAuthorizationModel(
            client = OpenAISubscriptionOAuthClient(client),
            scope = this,
            nowMillis = { 0L },
            sleep = { millis -> slept += millis },
        )

        model.start(config)
        model.awaitCompletionForTest()

        assertTrue(model.phase is OpenAISubscriptionAuthorizationModel.Phase.Succeeded)
        assertEquals(listOf(5_000L, 5_000L, 10_000L), slept)
    }

    /** An ineligible tier is a dead end: stop immediately rather than give the user a retry that can never succeed. */
    @Test
    fun `an ineligible tier moves to a failed state and stops polling`() = runTest {
        var poll = 0
        val client = HttpClient(
            MockEngine { request ->
                if (request.url.encodedPath.endsWith("/usercode")) {
                    respond(usercodeBody(), HttpStatusCode.OK, jsonHeaders)
                } else {
                    poll += 1
                    respond("""{"error":"usage_not_included"}""", HttpStatusCode.BadRequest, jsonHeaders)
                }
            }
        )
        val model = OpenAISubscriptionAuthorizationModel(
            client = OpenAISubscriptionOAuthClient(client),
            scope = this,
            nowMillis = { 0L },
            sleep = { },
        )

        model.start(config)
        model.awaitCompletionForTest()

        assertEquals(
            OpenAISubscriptionAuthorizationModel.Phase.Failed(
                OpenAISubscriptionError.SubscriptionNotEligible,
            ),
            model.phase,
        )
        assertEquals(1, poll)
    }

    /** Continuing to poll after the short code has expired is pointless and just sends useless traffic upstream. */
    @Test
    fun `polling stops and reports the short code as expired once expires_in has elapsed`() = runTest {
        var poll = 0
        var clock = 0L
        val client = HttpClient(
            MockEngine { request ->
                if (request.url.encodedPath.endsWith("/usercode")) {
                    respond(usercodeBody(expiresIn = 10, interval = 5), HttpStatusCode.OK, jsonHeaders)
                } else {
                    poll += 1
                    respond("""{"error":"authorization_pending"}""", HttpStatusCode.BadRequest, jsonHeaders)
                }
            }
        )
        val model = OpenAISubscriptionAuthorizationModel(
            client = OpenAISubscriptionOAuthClient(client),
            scope = this,
            nowMillis = { clock },
            sleep = { millis -> clock += millis },
        )

        model.start(config)
        model.awaitCompletionForTest()

        assertEquals(
            OpenAISubscriptionAuthorizationModel.Phase.Failed(OpenAISubscriptionError.CodeExpired),
            model.phase,
        )
        // deadline=10s, interval=5s: once two polls exceed the deadline, polling stops rather than continuing forever.
        assertEquals(2, poll)
    }

    /**
     * **Regression: coming back should not trigger re-authorization.**
     *
     * The device code flow requires the user to leave the app for the browser to approve, and by
     * the time they return the Activity may well have been recreated (rotation, dark mode toggle,
     * being reclaimed in the background, "don't keep activities"). After recreation, Compose
     * re-runs `LaunchedEffect(config)` -- if that call was an unconditional `start()`, it would
     * request a brand-new short code, invalidating the one the user just typed into the browser,
     * and no coroutine would be left polling the old `deviceAuthId`.
     *
     * This test calls [OpenAISubscriptionAuthorizationModel.startIfIdle] from inside the `sleep`
     * callback, at the exact moment pollJob is still alive and phase is sitting at
     * AwaitingAuthorization -- precisely when a recomposition could collide with it. The assertion
     * is that only one short code is ever requested; without the guard, `start()` would cancel the
     * current poll and request again, bumping the count to 2.
     */
    @Test
    fun `startIfIdle during recomposition does not interrupt an in-flight poll or request a new short code`() = runTest {
        var usercodeCount = 0
        var polls = 0
        var reentered = false
        lateinit var model: OpenAISubscriptionAuthorizationModel

        val client = HttpClient(
            MockEngine { request ->
                val path = request.url.encodedPath
                when {
                    path.endsWith("/usercode") -> {
                        usercodeCount++
                        // Give a different short code each time, to prove the one the user has isn't swapped out.
                        respond(
                            """{"device_auth_id":"da_$usercodeCount","user_code":"CODE-$usercodeCount","expires_in":600,"interval":5}""",
                            HttpStatusCode.OK,
                            jsonHeaders,
                        )
                    }
                    path.endsWith("/deviceauth/token") -> {
                        polls++
                        if (polls == 1) {
                            respond(
                                """{"error":"authorization_pending"}""",
                                HttpStatusCode.BadRequest,
                                jsonHeaders,
                            )
                        } else {
                            respond(
                                """{"authorization_code":"ac_1","code_verifier":"cv_1"}""",
                                HttpStatusCode.OK,
                                jsonHeaders,
                            )
                        }
                    }
                    else -> respond(exchangedTokens, HttpStatusCode.OK, jsonHeaders)
                }
            }
        )

        model = OpenAISubscriptionAuthorizationModel(
            client = OpenAISubscriptionOAuthClient(client),
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

        assertEquals("recomposition should not request a short code again", 1, usercodeCount)
        assertTrue(reentered)
        val phase = model.phase
        assertTrue("actual phase was $phase", phase is OpenAISubscriptionAuthorizationModel.Phase.Succeeded)
    }

    /**
     * On first entry to the panel (Idle), startIfIdle must actually kick off authorization -- the
     * guard above must not overreach and block the normal entry path too.
     */
    @Test
    fun `startIfIdle from idle starts authorization normally`() = runTest {
        var usercodeCount = 0
        val client = HttpClient(
            MockEngine { request ->
                val path = request.url.encodedPath
                when {
                    path.endsWith("/usercode") -> {
                        usercodeCount++
                        respond(usercodeBody(), HttpStatusCode.OK, jsonHeaders)
                    }
                    path.endsWith("/deviceauth/token") -> respond(
                        """{"authorization_code":"ac_1","code_verifier":"cv_1"}""",
                        HttpStatusCode.OK,
                        jsonHeaders,
                    )
                    else -> respond(exchangedTokens, HttpStatusCode.OK, jsonHeaders)
                }
            }
        )
        val model = OpenAISubscriptionAuthorizationModel(
            client = OpenAISubscriptionOAuthClient(client),
            scope = this,
            nowMillis = { 0L },
            sleep = { },
        )

        model.startIfIdle(config)
        model.awaitCompletionForTest()

        assertEquals(1, usercodeCount)
        assertTrue(model.phase is OpenAISubscriptionAuthorizationModel.Phase.Succeeded)
    }

    /**
     * A terminal state is the UI's cue for what to do next (a failure shows a retry button), and
     * recomposition must not quietly clear it and start a fresh round -- otherwise the user would
     * never get to see a conclusion like "your tier isn't eligible" that they need to act on.
     */
    @Test
    fun `startIfIdle does not restart a round once in a failed terminal state`() = runTest {
        var usercodeCount = 0
        val client = HttpClient(
            MockEngine { request ->
                val path = request.url.encodedPath
                when {
                    path.endsWith("/usercode") -> {
                        usercodeCount++
                        respond(usercodeBody(), HttpStatusCode.OK, jsonHeaders)
                    }
                    else -> respond(
                        """{"error":"access_denied"}""",
                        HttpStatusCode.Forbidden,
                        jsonHeaders,
                    )
                }
            }
        )
        val model = OpenAISubscriptionAuthorizationModel(
            client = OpenAISubscriptionOAuthClient(client),
            scope = this,
            nowMillis = { 0L },
            sleep = { },
        )

        model.start(config)
        model.awaitCompletionForTest()
        assertTrue(model.phase is OpenAISubscriptionAuthorizationModel.Phase.Failed)

        model.startIfIdle(config)

        assertEquals(1, usercodeCount)
        assertTrue(model.phase is OpenAISubscriptionAuthorizationModel.Phase.Failed)
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
     * A ViewModel only survives configuration changes -- `ComponentActivity` calls
     * `clear()` on its ViewModelStore on any non-configuration-change destruction. The device code
     * flow sends the user off to the browser, which is exactly when a backgrounded app is most
     * likely to be killed. This test builds a fresh model (standing in for a new ViewModel after
     * process recreation) that reads the same snapshot, and asserts it never requests a new short code.
     */
    @Test
    fun `startIfIdle after process recreation resumes polling from the snapshot without requesting a new short code`() = runTest {
        var usercodeCount = 0
        val client = HttpClient(
            MockEngine { request ->
                val path = request.url.encodedPath
                when {
                    path.endsWith("/usercode") -> {
                        usercodeCount++
                        respond(usercodeBody(), HttpStatusCode.OK, jsonHeaders)
                    }
                    path.endsWith("/deviceauth/token") -> respond(
                        """{"authorization_code":"ac_1","code_verifier":"cv_1"}""",
                        HttpStatusCode.OK,
                        jsonHeaders,
                    )
                    else -> respond(exchangedTokens, HttpStatusCode.OK, jsonHeaders)
                }
            }
        )
        val store = RecordingSnapshotStore(
            """{"deviceAuthId":"da_saved","userCode":"SAVED-CODE",""" +
                """"verificationUrl":"https://auth.openai.com/codex/device",""" +
                """"interval":5,"expiresIn":600,"deadlineMillis":600000}"""
        )

        val model = OpenAISubscriptionAuthorizationModel(
            client = OpenAISubscriptionOAuthClient(client),
            scope = this,
            nowMillis = { 0L },
            sleep = { },
            snapshotStore = store,
        )

        model.startIfIdle(config)
        model.awaitCompletionForTest()

        assertEquals("a restored short code should not be clobbered by a fresh request", 0, usercodeCount)
        assertTrue(model.phase is OpenAISubscriptionAuthorizationModel.Phase.Succeeded)
        // Success is terminal, so the snapshot must be cleared -- keeping it around would mean next time we poll an already-used short code.
        assertEquals(null, store.writes.last())
    }

    /**
     * An expired snapshot can't be used: restoring it would just waste a poll before reporting
     * expiry, showing the user a short code that's already dead. The correct move is to request a
     * fresh one and discard the stale snapshot.
     */
    @Test
    fun `a snapshot past its deadline is discarded and a new short code is requested normally`() = runTest {
        var usercodeCount = 0
        val client = HttpClient(
            MockEngine { request ->
                val path = request.url.encodedPath
                when {
                    path.endsWith("/usercode") -> {
                        usercodeCount++
                        respond(usercodeBody(), HttpStatusCode.OK, jsonHeaders)
                    }
                    path.endsWith("/deviceauth/token") -> respond(
                        """{"authorization_code":"ac_1","code_verifier":"cv_1"}""",
                        HttpStatusCode.OK,
                        jsonHeaders,
                    )
                    else -> respond(exchangedTokens, HttpStatusCode.OK, jsonHeaders)
                }
            }
        )
        val store = RecordingSnapshotStore(
            """{"deviceAuthId":"da_old","userCode":"OLD-CODE",""" +
                """"verificationUrl":"https://auth.openai.com/codex/device",""" +
                """"interval":5,"expiresIn":600,"deadlineMillis":1000}"""
        )

        val model = OpenAISubscriptionAuthorizationModel(
            client = OpenAISubscriptionOAuthClient(client),
            scope = this,
            // Already past the snapshot's deadlineMillis=1000.
            nowMillis = { 5_000L },
            sleep = { },
            snapshotStore = store,
        )

        model.startIfIdle(config)
        model.awaitCompletionForTest()

        assertEquals(1, usercodeCount)
        assertTrue(store.writes.contains(null))
        assertTrue(model.phase is OpenAISubscriptionAuthorizationModel.Phase.Succeeded)
    }

    /** The short code must be snapshotted as soon as it's received, or there's nothing to recover if the process is killed. */
    @Test
    fun `receiving a short code writes a snapshot that contains no credentials`() = runTest {
        val client = HttpClient(
            MockEngine { request ->
                val path = request.url.encodedPath
                when {
                    path.endsWith("/usercode") ->
                        respond(usercodeBody(), HttpStatusCode.OK, jsonHeaders)
                    path.endsWith("/deviceauth/token") -> respond(
                        """{"authorization_code":"ac_1","code_verifier":"cv_1"}""",
                        HttpStatusCode.OK,
                        jsonHeaders,
                    )
                    else -> respond(exchangedTokens, HttpStatusCode.OK, jsonHeaders)
                }
            }
        )
        val store = RecordingSnapshotStore()
        val model = OpenAISubscriptionAuthorizationModel(
            client = OpenAISubscriptionOAuthClient(client),
            scope = this,
            nowMillis = { 0L },
            sleep = { },
            snapshotStore = store,
        )

        model.start(config)
        model.awaitCompletionForTest()

        val persisted = store.writes.first()
        assertTrue("the first write should be a snapshot, but was $persisted", persisted != null)
        assertTrue(persisted!!.contains("da_1"))
        assertTrue(persisted.contains("ABCD-1234"))
        // SavedStateHandle gets written into saved instance state by the system, so credentials must never end up in it.
        assertTrue("snapshot must not contain the access token", !persisted.contains("at_1"))
        assertTrue("snapshot must not contain the refresh token", !persisted.contains("rt_1"))
    }

    @Test
    fun `cancelling returns to idle and clears the flag marking the authorization page as open`() = runTest {
        val client = HttpClient(
            MockEngine { respond(usercodeBody(), HttpStatusCode.OK, jsonHeaders) }
        )
        val model = OpenAISubscriptionAuthorizationModel(
            client = OpenAISubscriptionOAuthClient(client),
            scope = this,
            nowMillis = { 0L },
            sleep = { },
        )

        model.start(config)
        model.markVerificationPageOpened()
        model.cancel()

        assertEquals(OpenAISubscriptionAuthorizationModel.Phase.Idle, model.phase)
        assertEquals(false, model.didOpenVerificationPage)
        assertNull(model.deviceAuthorization)
    }
}
