package ai.oriveo.community.core.data.repository

import ai.oriveo.community.core.data.remote.MetadataClient
import ai.oriveo.community.core.model.AIModel
import ai.oriveo.community.core.model.Provider
import ai.oriveo.community.core.model.ProviderConnectionState
import ai.oriveo.community.core.model.ProviderKind
import ai.oriveo.community.core.model.RelayKey
import ai.oriveo.community.core.model.RelayKeyStatus
import ai.oriveo.community.core.model.RelayKind
import ai.oriveo.community.core.model.RelayRequestedConfig
import ai.oriveo.community.core.model.RelayTransport
import io.ktor.http.HttpMethod
import io.mockk.coEvery
import io.mockk.mockkObject
import io.mockk.unmockkObject
import kotlinx.coroutines.launch
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.test.runTest
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test

/**
 * Key status faithfully reflects real requests (RL2-KEYSTATUS-01 to 09 and 12): the production [ProviderRepository] re-verify / lazy verify /
 * test capability / add key / replace primary key / catalog refresh paths, with an upstream MockEngine; asserts the persisted `relayKeys`.
 */
class RelayKeyStatusWritebackTest {

    @Before
    fun setUp() {
        mockkObject(MetadataClient)
        coEvery { MetadataClient.refresh(any()) } returns Unit
    }

    @After
    fun tearDown() = unmockkObject(MetadataClient)

    private fun model(id: String, keyID: String? = null) = AIModel(id = id, name = id, relayKeyID = keyID)

    private fun relay(
        keys: List<RelayKey>? = null,
        enabled: List<AIModel> = listOf(model(MODEL)),
        transport: RelayTransport = RelayTransport.OpenAIChatCompletions,
    ) = Provider(
        id = PROVIDER_ID,
        kind = ProviderKind.Relay,
        customName = "relay.example.com",
        status = ProviderConnectionState.Connected,
        baseUrlText = BASE_URL,
        apiKey = PRIMARY,
        relayKind = RelayKind.OpenAICompatible,
        relayRequested = RelayRequestedConfig(
            transport = transport,
            resolvedAPIBaseURL = BASE_URL.takeIf { transport != RelayTransport.Auto },
        ),
        relayKeys = keys,
        models = enabled,
        catalogModels = enabled.map { it.copy(relayKeyID = null) },
    )

    private fun twoKeys(secondStatus: RelayKeyStatus? = null) =
        listOf(RelayKey("initial"), RelayKey("k-b", apiKey = SECOND, status = secondStatus))

    private fun RelayKeyStatusRepositoryHarness.status(keyID: String): RelayKeyStatus? =
        current().relayKeys?.firstOrNull { it.id == keyID }?.status

    private fun RelayKeyStatusRepositoryHarness.generations(): Int = requests.count { it.first == HttpMethod.Post }

    @Test
    fun `RL2-KEYSTATUS-01 single key reverify success marks the primary ok as a one-entry list`() = runTest {
        val harness = RelayKeyStatusRepositoryHarness(relay(), PRIMARY)
        harness.repository.reverifyRelayProvider(PROVIDER_ID)

        assertEquals(1, harness.generations())
        assertEquals(listOf("initial" to ""), harness.current().relayKeys?.map { it.id to it.apiKey })
        assertEquals("ok", harness.status("initial")?.state)
        assertNull("the model-level key field is not written", harness.current().models.single().relayKeyID)
    }

    @Test
    fun `RL2-KEYSTATUS-02 multi-key reverify 401 marks the sample model's effective key invalid`() = runTest {
        val harness = RelayKeyStatusRepositoryHarness(relay(keys = twoKeys(), enabled = listOf(model(MODEL, "k-b"))), PRIMARY)
        harness.generation = { secret -> if (secret == SECOND) 401 to INVALID_BODY else 200 to RelayKeyStatusRepositoryHarness.CHAT_OK }
        harness.repository.reverifyRelayProvider(PROVIDER_ID)

        assertEquals("the request uses the effective key of the sample model", listOf(HttpMethod.Post to "Bearer $SECOND"), harness.requests.toList())
        assertEquals("invalid", harness.status("k-b")?.state)
        assertEquals(401, harness.status("k-b")?.httpStatus)
        assertNull("primary key untouched", harness.status("initial"))
    }

    @Test
    fun `RL2-KEYSTATUS-03 a lazy probe that passes marks the bound key ok`() = runTest {
        val harness = RelayKeyStatusRepositoryHarness(
            relay(keys = twoKeys(), enabled = listOf(model(MODEL, "k-b")), transport = RelayTransport.Auto),
            PRIMARY,
        )
        harness.repository.probeEnabledRelayModel(PROVIDER_ID, MODEL)

        assertTrue(harness.generations() >= 1)
        assertTrue(harness.requests.all { it.second == "Bearer $SECOND" })
        assertEquals("ok", harness.status("k-b")?.state)
        assertNull(harness.status("initial"))
    }

    @Test
    fun `RL2-KEYSTATUS-04 a lazy probe hitting route 404s leaves the key status alone`() = runTest {
        val harness = RelayKeyStatusRepositoryHarness(relay(transport = RelayTransport.Auto), PRIMARY)
        harness.generation = { 404 to "404 page not found" }
        harness.repository.probeEnabledRelayModel(PROVIDER_ID, MODEL)

        assertTrue("a probe was really sent", harness.generations() >= 1)
        assertFalse("no list is created and no status is written", harness.relayKeysPersisted())
    }

    // Each test-capability item has an overall time limit (withTimeoutOrNull): run on the real clock, since a virtual clock would time out requests waiting on IO immediately.
    @Test
    fun `RL2-KEYSTATUS-05 a capability test item answered 200 marks the key ok`() = runBlocking {
        val harness = RelayKeyStatusRepositoryHarness(relay(), PRIMARY)
        harness.repository.runRelayCapabilityTest(PROVIDER_ID, MODEL)

        assertTrue(harness.generations() >= 1)
        assertEquals("ok", harness.status("initial")?.state)
    }

    @Test
    fun `RL2-KEYSTATUS-05 a capability test item answered 401 marks the key invalid`() = runBlocking {
        val harness = RelayKeyStatusRepositoryHarness(relay(), PRIMARY)
        harness.generation = { 401 to INVALID_BODY }
        harness.repository.runRelayCapabilityTest(PROVIDER_ID, MODEL)

        assertEquals("invalid", harness.status("initial")?.state)
        assertEquals(401, harness.status("initial")?.httpStatus)
    }

    @Test
    fun `RL2-KEYSTATUS-06 adding a key refetches every key so the primary gets its status`() = runTest {
        val harness = RelayKeyStatusRepositoryHarness(
            relay(),
            PRIMARY,
            catalogs = mapOf(PRIMARY to listOf(MODEL), SECOND to listOf("claude-opus-4")),
        )
        harness.repository.addRelayKey(PROVIDER_ID, "k-b", null, SECOND)

        assertEquals(
            listOf(HttpMethod.Get to "Bearer $PRIMARY", HttpMethod.Get to "Bearer $SECOND"),
            harness.requests.toList(),
        )
        assertEquals("ok", harness.status("initial")?.state)
        assertEquals("ok", harness.status("k-b")?.state)
    }

    @Test
    fun `RL2-KEYSTATUS-07 replacing the single primary clears its status then the refetch writes the new one`() = runTest {
        val harness = RelayKeyStatusRepositoryHarness(
            relay(keys = listOf(RelayKey("initial", status = RelayKeyStatus("invalid", 401)))),
            PRIMARY,
            catalogs = mapOf(NEW_PRIMARY to listOf(MODEL)),
        )
        var statusDuringVerify: RelayKeyStatus? = RelayKeyStatus("unset")
        harness.onGeneration = { statusDuringVerify = harness.status("initial") }
        harness.repository.updateApiKey(PROVIDER_ID, NEW_PRIMARY)

        assertNull("replacing the value clears the status first", statusDuringVerify)
        assertEquals("ok", harness.status("initial")?.state)
        assertEquals(NEW_PRIMARY, harness.apiKey)
    }

    @Test
    fun `RL2-KEYSTATUS-08 a draft test connection writes nothing`() = runTest {
        val harness = RelayKeyStatusRepositoryHarness(relay(), PRIMARY)
        val before = harness.stored
        harness.repository.verifyRelayGeneration(
            apiKey = "sk-draft-000000000001",
            baseUrl = BASE_URL,
            modelID = MODEL,
            relayRequested = RelayRequestedConfig(transport = RelayTransport.OpenAIChatCompletions, resolvedAPIBaseURL = BASE_URL),
        )
        assertEquals(1, harness.generations())
        assertEquals("a draft test does not persist", before, harness.stored)
    }

    @Test
    fun `RL2-KEYSTATUS-09 every single-key catalog refresh path writes the primary status`() = runTest {
        val catalogs = mapOf(PRIMARY to listOf(MODEL, "gpt-4.1"))

        val catalogOnly = RelayKeyStatusRepositoryHarness(relay(), PRIMARY, catalogs)
        assertTrue(catalogOnly.repository.refreshRelayCatalogOnly(PROVIDER_ID).catalogSucceeded)
        assertEquals("catalog-only", "ok", catalogOnly.status("initial")?.state)

        val resync = RelayKeyStatusRepositoryHarness(relay(), PRIMARY, catalogs)
        resync.repository.resyncProvider(PROVIDER_ID)
        assertEquals("resync", listOf(MODEL, "gpt-4.1").sorted(), resync.current().catalogModels.map { it.id }.sorted())
        assertEquals("resync", "ok", resync.status("initial")?.state)

        val resyncFailed = RelayKeyStatusRepositoryHarness(relay(), PRIMARY)
        resyncFailed.repository.resyncProvider(PROVIDER_ID)
        assertEquals("resync 401", "invalid", resyncFailed.status("initial")?.state)
        assertEquals("resync 401", 401, resyncFailed.status("initial")?.httpStatus)

        val redetect = RelayKeyStatusRepositoryHarness(relay(), PRIMARY, catalogs)
        redetect.repository.redetectRelayModels(PROVIDER_ID)
        assertEquals("redetect", "ok", redetect.status("initial")?.state)
    }

    @Test
    fun `RL2-KEYSTATUS-12 a connection changed during the request drops the status`() = runBlocking {
        val probe = RelayKeyStatusRepositoryHarness(relay(transport = RelayTransport.Auto), PRIMARY)
        probe.onGeneration = { probe.apiKey = NEW_PRIMARY }
        probe.repository.probeEnabledRelayModel(PROVIDER_ID, MODEL)
        assertTrue(probe.generations() >= 1)
        assertFalse("lazy verify: discarded when the identity changed", probe.relayKeysPersisted())

        val reverify = RelayKeyStatusRepositoryHarness(relay(), PRIMARY)
        reverify.onGeneration = { reverify.apiKey = NEW_PRIMARY }
        reverify.repository.reverifyRelayProvider(PROVIDER_ID)
        assertFalse("re-verify: discarded when the identity changed", reverify.relayKeysPersisted())

        val capability = RelayKeyStatusRepositoryHarness(relay(), PRIMARY)
        capability.onGeneration = { capability.apiKey = NEW_PRIMARY }
        capability.repository.runRelayCapabilityTest(PROVIDER_ID, MODEL)
        assertFalse("test capability: discarded when the identity changed", capability.relayKeysPersisted())
    }

    // ── Per-client follow-up cases──

    @Test
    fun `RL2-KEYSTATUS-13 the fail-closed verify after replacing the single primary writes its result`() = runTest {
        val harness = RelayKeyStatusRepositoryHarness(relay(), PRIMARY)
        harness.generation = { 401 to INVALID_BODY }
        runCatching { harness.repository.updateApiKey(PROVIDER_ID, NEW_PRIMARY) }

        assertEquals("the new value is stored even when verification fails", NEW_PRIMARY, harness.apiKey)
        assertEquals("invalid", harness.status("initial")?.state)
        assertEquals(401, harness.status("initial")?.httpStatus)
    }

    /** Edit page verification fails with a new primary key value -> "Save anyway (unverified)": that key's status is cleared first, and if the failure itself says nothing about the key nothing is written. */
    @Test
    fun `RL2-KEYSTATUS-14 save unverified with a new primary value clears that key's status`() = runTest {
        val initial = relay(keys = listOf(RelayKey("initial", status = RelayKeyStatus("ok"))))
        val harness = RelayKeyStatusRepositoryHarness(initial, PRIMARY)
        harness.generation = { 503 to "busy" }
        val failed = harness.repository.verifyAndPersistRelayEdit(initial, NEW_PRIMARY, refreshCatalog = false, commitGuard = { true }, baseline = initial)
        assertFalse(failed.persisted)
        assertEquals("untouched when not persisted", "ok", harness.status("initial")?.state)

        val saved = harness.repository.persistRelayEditUnverified(initial, NEW_PRIMARY, failed.failureRevision!!, commitGuard = { true }, baseline = initial)
        assertTrue(saved.persisted)
        assertEquals(NEW_PRIMARY, harness.apiKey)
        assertNull("replacing the value clears it", harness.status("initial"))
    }

    @Test
    fun `RL2-KEYSTATUS-15 a request without a key writes no status and builds no list`() = runTest {
        val keyless = relay().copy(
            apiKey = "",
            relayRequested = RelayRequestedConfig(
                transport = RelayTransport.OpenAIChatCompletions,
                resolvedAPIBaseURL = BASE_URL,
                authMode = ai.oriveo.community.core.model.RelayAuthMode.None,
            ),
        )
        val harness = RelayKeyStatusRepositoryHarness(keyless, "", catalogs = mapOf("" to listOf(MODEL)))
        assertTrue(harness.repository.refreshRelayCatalogOnly(PROVIDER_ID).catalogSucceeded)
        harness.repository.reverifyRelayProvider(PROVIDER_ID)

        assertTrue(harness.requests.all { it.second == null })
        assertNull(harness.current().relayKeys)
        assertFalse(harness.relayKeysPersisted())
    }

    /** Edit-save verification writes to the key actually used (the primary key value) at persist time; not written when not persisted. */
    @Test
    fun `RL2-KEYSTATUS-16 the edit save verification is written when the save lands`() = runTest {
        val initial = relay(keys = listOf(RelayKey("initial", status = RelayKeyStatus("ok"))))
        val harness = RelayKeyStatusRepositoryHarness(initial, PRIMARY)
        harness.generation = { 401 to INVALID_BODY }
        val failed = harness.repository.verifyAndPersistRelayEdit(initial, NEW_PRIMARY, refreshCatalog = false, commitGuard = { true }, baseline = initial)
        assertEquals("not written when not persisted", "ok", harness.status("initial")?.state)

        harness.repository.persistRelayEditUnverified(initial, NEW_PRIMARY, failed.failureRevision!!, commitGuard = { true }, baseline = initial)
        assertEquals("invalid", harness.status("initial")?.state)
        assertEquals(401, harness.status("initial")?.httpStatus)

        val ok = RelayKeyStatusRepositoryHarness(relay(), PRIMARY)
        val edited = relay().copy(baseUrlText = "https://relay.example.com/v1/")
        assertTrue(ok.repository.verifyAndPersistRelayEdit(edited, null, refreshCatalog = false, commitGuard = { true }, baseline = relay()).persisted)
        assertEquals("ok", ok.status("initial")?.state)
    }

    /** Multiple keys: edit-save verification is sent with the sample model's effective key (same as re-verify), the status is written to that key, primary key untouched. */
    @Test
    fun `RL2-KEYSTATUS-16 the edit save verification uses and writes the sample model's effective key`() = runTest {
        val initial = relay(keys = twoKeys(), enabled = listOf(model(MODEL, "k-b")))
        val harness = RelayKeyStatusRepositoryHarness(initial, PRIMARY)
        val edited = initial.copy(baseUrlText = "https://relay.example.com/v1/")
        assertTrue(harness.repository.verifyAndPersistRelayEdit(edited, null, refreshCatalog = false, commitGuard = { true }, baseline = initial).persisted)

        assertEquals("the request uses the effective key of the sample model", listOf(HttpMethod.Post to "Bearer $SECOND"), harness.requests.toList())
        assertEquals("ok", harness.status("k-b")?.state)
        assertNull("primary key untouched", harness.status("initial"))

        // After a failure, "Save anyway": the result is likewise written to that key.
        val failing = RelayKeyStatusRepositoryHarness(initial, PRIMARY)
        failing.generation = { secret -> if (secret == SECOND) 401 to INVALID_BODY else 200 to RelayKeyStatusRepositoryHarness.CHAT_OK }
        val failed = failing.repository.verifyAndPersistRelayEdit(edited, null, refreshCatalog = false, commitGuard = { true }, baseline = initial)
        assertFalse(failed.persisted)
        failing.repository.persistRelayEditUnverified(edited, null, failed.failureRevision!!, commitGuard = { true }, baseline = initial)
        assertEquals("invalid", failing.status("k-b")?.state)
        assertNull(failing.status("initial"))
    }

    // ── Cases added after review──

    /** Chat-send write-back is bound to the identity at initiation: discarded if that key's value was replaced in flight; written as usual otherwise. */
    @Test
    fun `RL2-KEYSTATUS-19 a send whose key changed in flight writes no key status`() = runTest {
        val invalid = ai.oriveo.community.core.provider.relay.RelayKeyAccess.signal(401, INVALID_BODY)

        val changed = RelayKeyStatusRepositoryHarness(relay(), PRIMARY)
        val sent = changed.current()
        changed.apiKey = NEW_PRIMARY
        changed.repository.recordRelayKeyAccessSuccess(PROVIDER_ID, MODEL, "initial", sent)
        changed.repository.recordRelayKeyAccess(PROVIDER_ID, MODEL, "initial", invalid, sent)
        assertFalse("single key: not written when the value is replaced in flight", changed.relayKeysPersisted())

        val multi = RelayKeyStatusRepositoryHarness(relay(keys = twoKeys(), enabled = listOf(model(MODEL, "k-b"))), PRIMARY)
        val multiSent = multi.current()
        multi.secrets["k-b"] = "sk-b-000000000077"
        multi.repository.recordRelayKeyAccess(PROVIDER_ID, MODEL, "k-b", invalid, multiSent)
        assertNull("multiple keys: not written when that key's value is replaced in flight", multi.status("k-b"))

        val same = RelayKeyStatusRepositoryHarness(relay(), PRIMARY)
        same.repository.recordRelayKeyAccess(PROVIDER_ID, MODEL, "initial", invalid, same.current())
        assertEquals("written as usual when the identity is unchanged", "invalid", same.status("initial")?.state)
    }

    /** Re-verify checks identity against the value of the key actually used: the sample model is bound to k-b and k-b's value is replaced in flight (entity unchanged) -> not written. */
    @Test
    fun `RL2-KEYSTATUS-12 reverify drops the status when the sent non-primary key changed in flight`() = runTest {
        val harness = RelayKeyStatusRepositoryHarness(relay(keys = twoKeys(), enabled = listOf(model(MODEL, "k-b"))), PRIMARY)
        harness.onGeneration = { harness.secrets["k-b"] = "sk-b-000000000077" }
        harness.repository.reverifyRelayProvider(PROVIDER_ID)
        assertEquals(1, harness.generations())
        assertNull(harness.status("k-b"))
    }

    /** Lazy verify is cancelled after getting a 200 and before write-back: key-level evidence is still written as ok; the model row is treated as cancelled and not recorded as "unreachable". */
    @Test
    fun `RL2-KEYSTATUS-20 a lazy probe cancelled after its response still writes the key status`() = runBlocking {
        val harness = RelayKeyStatusRepositoryHarness(relay(transport = RelayTransport.Auto), PRIMARY)
        var responded = false
        lateinit var job: kotlinx.coroutines.Job
        harness.onGeneration = { responded = true }
        harness.onRead = {
            if (responded) {
                responded = false
                job.cancel()
            }
        }
        job = launch { harness.repository.probeEnabledRelayModel(PROVIDER_ID, MODEL) }
        job.join()

        assertTrue(job.isCancelled)
        assertEquals("ok", harness.status("initial")?.state)
        assertNull("the model row records neither unreachable nor verifying", harness.repository.relayModelProbeStates(PROVIDER_ID)[MODEL])
        assertNull("the protocol is not pinned after cancellation", harness.current().models.single().relayTransport)
    }

    /** An empty list is treated as no list: it is still materialized into one entry (same as iOS / Web). */
    @Test
    fun `RL2-KEYSTATUS an empty key list is treated as no list`() {
        val written = ai.oriveo.community.core.provider.relay.RelayKeyAccess.withKeyStatuses(
            relay(keys = emptyList()),
            mapOf("initial" to RelayKeyStatus("ok")),
            1L,
        )
        assertEquals(listOf("initial" to "ok"), written.relayKeys?.map { it.id to it.status?.state })
    }

    /** Test connection: written when saved and unchanged (the result is persisted to provider.status); drafts are not written (see case 08). */
    @Test
    fun `RL2-KEYSTATUS-17 testing a saved connection writes the key status`() = runTest {
        val harness = RelayKeyStatusRepositoryHarness(relay(), PRIMARY)
        harness.generation = { 429 to "{\"error\":{\"code\":\"insufficient_quota\"}}" }
        harness.repository.verifyPersistedRelayGeneration(PROVIDER_ID)
        assertEquals("limited", harness.status("initial")?.state)
        assertEquals(429, harness.status("initial")?.httpStatus)
    }

    @Test
    fun `RL2-KEYSTATUS-18 a 2xx web page or unreadable body is not a success`() = runBlocking {
        val capability = RelayKeyStatusRepositoryHarness(relay(), PRIMARY)
        capability.generation = { 200 to "<!doctype html><html><body>console</body></html>" }
        capability.generationContentType = "text/html"
        capability.repository.runRelayCapabilityTest(PROVIDER_ID, MODEL)
        assertTrue(capability.generations() >= 1)
        assertFalse("test capability: a web page does not write ok", capability.relayKeysPersisted())

        val reverify = RelayKeyStatusRepositoryHarness(relay(), PRIMARY)
        reverify.generation = { 200 to "<!doctype html><html><body>console</body></html>" }
        reverify.generationContentType = "text/html"
        reverify.repository.reverifyRelayProvider(PROVIDER_ID)
        assertEquals(1, reverify.generations())
        assertFalse("re-verify: a web page does not write ok", reverify.relayKeysPersisted())
    }

    private companion object {
        const val PROVIDER_ID = "44444444-4444-4444-8444-444444444444"
        const val BASE_URL = "https://relay.example.com/v1"
        const val MODEL = "gpt-4o"
        const val PRIMARY = "sk-a-000000000001"
        const val NEW_PRIMARY = "sk-a-000000000099"
        const val SECOND = "sk-b-000000000002"
        const val INVALID_BODY = "{\"error\":{\"message\":\"Invalid API key\"}}"
    }
}
