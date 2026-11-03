package ai.oriveo.community.core.voice.realtime

import ai.oriveo.community.core.model.Provider
import ai.oriveo.community.core.model.ProviderAuthMode
import ai.oriveo.community.core.model.ProviderKind
import ai.oriveo.community.core.voice.VoiceCatalog
import ai.oriveo.community.core.voice.VoiceCatalogState
import ai.oriveo.community.core.voice.VoiceOption
import ai.oriveo.community.core.voice.VoiceProviderCatalog
import ai.oriveo.community.core.voice.VoiceRealtimeEntry
import ai.oriveo.community.core.voice.VoiceTransport
import java.io.File
import kotlinx.coroutines.flow.flowOf
import kotlinx.coroutines.flow.toList
import kotlinx.coroutines.runBlocking
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.boolean
import kotlinx.serialization.json.booleanOrNull
import kotlinx.serialization.json.doubleOrNull
import kotlinx.serialization.json.int
import kotlinx.serialization.json.intOrNull
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.long
import org.junit.Assert.assertEquals
import org.junit.Test

/** Checks each case in shared/voice-contracts/realtime-model.v1.json against the five pure RealtimeModel functions. */
class RealtimeModelContractTest {

    private val fixture: JsonObject =
        Json.parseToJsonElement(workspaceFile("shared/voice-contracts/realtime-model.v1.json").readText()).jsonObject

    private fun JsonObject.present(key: String): JsonElement? = this[key].takeUnless { it == null || it is JsonNull }
    private fun JsonObject.str(key: String): String? = present(key)?.jsonPrimitive?.content
    private fun JsonObject.bool(key: String): Boolean? = present(key)?.jsonPrimitive?.booleanOrNull
    private fun JsonObject.dbl(key: String): Double? = present(key)?.jsonPrimitive?.doubleOrNull
    private fun JsonObject.integer(key: String): Int? = present(key)?.jsonPrimitive?.intOrNull
    private fun JsonObject.strList(key: String): List<String?> =
        present(key)?.jsonArray?.map { if (it is JsonNull) null else it.jsonPrimitive.content }.orEmpty()

    private fun cases(key: String, expectedCount: Int): List<JsonObject> {
        val list = fixture[key]!!.jsonArray.map { it.jsonObject }
        assertEquals("$key count", expectedCount, list.size)
        return list
    }

    @Test
    fun constantsAndCopyKeysMatchFixture() {
        val c = fixture["constants"]!!.jsonObject
        assertEquals(c["connectTimeoutMs"]!!.jsonPrimitive.long, RealtimeModel.CONNECT_TIMEOUT_MS)
        assertEquals(c["uplinkBacklogMs"]!!.jsonPrimitive.long, RealtimeModel.UPLINK_BACKLOG_MS)
        assertEquals(c["autoReopenAttempts"]!!.jsonPrimitive.int, RealtimeModel.AUTO_REOPEN_ATTEMPTS)
        assertEquals(c["geminiHandleReconnects"]!!.jsonPrimitive.int, RealtimeModel.GEMINI_HANDLE_RECONNECTS)

        val copy = fixture["copy"]!!.jsonObject
        fun strMap(key: String): Map<String, String?> = copy[key]!!.jsonObject.mapValues { (_, v) ->
            if (v is JsonNull) null else v.jsonPrimitive.content
        }
        assertEquals(strMap("failure"), RealtimeModel.COPY_FAILURE)
        assertEquals(RealtimeModel.CATEGORIES, copy["failure"]!!.jsonObject.keys.toList())
        assertEquals(strMap("failureArg"), RealtimeModel.COPY_FAILURE_ARG)
        assertEquals(strMap("actions"), RealtimeModel.COPY_ACTIONS)
        assertEquals(copy.strList("capability"), RealtimeModel.COPY_CAPABILITY)
        assertEquals(copy.strList("picker"), RealtimeModel.COPY_PICKER)
        assertEquals(copy.strList("migration"), RealtimeModel.COPY_MIGRATION)
        assertEquals(copy.strList("composer"), RealtimeModel.COPY_COMPOSER)
        assertEquals(copy.strList("disclosure"), RealtimeModel.COPY_DISCLOSURE)
    }

    @Test
    fun failureCasesMatchFixture() {
        for (case in cases("failureCases", 26)) {
            val id = case.str("id")
            val i = case["input"]!!.jsonObject
            val signal = RealtimeModel.FailureSignal(
                httpStatus = i.integer("httpStatus"),
                errorCode = i.str("errorCode"),
                catalogHasModel = i.bool("catalogHasModel"),
                endedReason = i.str("endedReason"),
                elapsedSec = i.dbl("elapsedSec"),
                maxSessionSec = i.dbl("maxSessionSec"),
                connectError = i.bool("connectError"),
                connectTimedOut = i.bool("connectTimedOut"),
                reopenFailed = i.bool("reopenFailed"),
                uplinkBacklogMs = i.dbl("uplinkBacklogMs"),
                closeCode = i.integer("closeCode"),
            )
            val e = case["expected"]!!.jsonObject
            val expected = RealtimeModel.FailureResult(
                category = e.str("category")!!,
                copyKey = e.str("copyKey")!!,
                copyArg = e.str("copyArg")!!,
                actions = e.strList("actions").map { it!! },
                actionCopyKeys = e.strList("actionCopyKeys"),
            )
            assertEquals(id, expected, RealtimeModel.classifyFailure(signal))
        }
    }

    private fun parseConnections(input: JsonObject): List<RealtimeModel.Connection> =
        input.present("connections")?.jsonArray?.map { it.jsonObject }.orEmpty().map { c ->
            RealtimeModel.Connection(
                id = c.str("id")!!,
                providerKind = c.str("providerKind")!!,
                auth = c.str("auth")!!,
                textModels = c.present("textModels")?.jsonArray?.map { it.jsonObject }.orEmpty().map { m ->
                    RealtimeModel.TextModel(m.str("model")!!, m.bool("webSearch") == true, m.bool("thinking") == true)
                },
            )
        }

    private fun parseCatalog(input: JsonObject): Map<String, List<RealtimeModel.RealtimeCatalogEntry>> =
        input.present("realtimeCatalog")?.jsonObject.orEmpty().mapValues { (_, v) ->
            v.jsonArray.map { it.jsonObject }.map { RealtimeModel.RealtimeCatalogEntry(it.str("model")!!, it.bool("isDefault") == true) }
        }

    @Test
    fun pickerCasesMatchFixture() {
        for (case in cases("pickerCases", 15)) {
            val id = case.str("id")
            val i = case["input"]!!.jsonObject
            val actual = RealtimeModel.pickerRows(
                context = i.str("context")!!,
                filters = i.strList("filters").map { it!! },
                connections = parseConnections(i),
                realtimeCatalog = parseCatalog(i),
                selected = i.present("selected")?.jsonObject?.let { RealtimeModel.Selected(it.str("connectionId")!!, it.str("model")!!) },
            )
            val e = case["expected"]!!.jsonObject
            val expected = RealtimeModel.PickerResult(
                showsRealtimeFilter = e["showsRealtimeFilter"]!!.jsonPrimitive.boolean,
                groups = e["groups"]!!.jsonArray.map { it.jsonObject }.map { g ->
                    RealtimeModel.PickerGroup(
                        g.str("connectionId")!!,
                        g["rows"]!!.jsonArray.map { it.jsonObject }.map { RealtimeModel.PickerRow(it.str("model")!!, it.str("kind")!!) },
                    )
                },
                selectedRow = e.present("selectedRow")?.jsonObject?.let {
                    RealtimeModel.SelectedRow(it.str("connectionId")!!, it.str("model")!!, it.str("kind")!!)
                },
            )
            assertEquals(id, expected, actual)
        }
    }

    /** Fixture connection (providerKind + auth) -> production Provider: subscription uses subscription login, relay uses the relay kind. */
    private fun fixtureProvider(c: JsonObject?): Provider? {
        c ?: return null
        val auth = c.str("auth")!!
        val kind = when (auth) {
            "relay" -> ProviderKind.Relay
            else -> ProviderKind.fromRawValue(c.str("providerKind")!!)!!
        }
        val mode = if (auth == "subscription") ProviderAuthMode.Subscription else ProviderAuthMode.ApiKey
        return Provider(id = "conn", kind = kind, authMode = mode)
    }

    /** Fixture realtimeCatalog -> production VoiceCatalog; null = catalog not ready. */
    private fun fixtureCatalog(element: JsonElement?): VoiceCatalog? {
        val obj = element?.takeUnless { it is JsonNull }?.jsonObject ?: return null
        return VoiceCatalog(
            schemaVersion = 2,
            providers = obj.entries.associate { (raw, list) ->
                ProviderKind.fromRawValue(raw)!! to VoiceProviderCatalog(
                    realtime = list.jsonArray.map { it.jsonObject }.map {
                        VoiceRealtimeEntry(
                            model = it.str("model")!!,
                            transport = VoiceTransport.OpenAIRealtime,
                            path = "/v1/realtime",
                            contextWindow = 32_000,
                            voices = listOf(VoiceOption("marin", isDefault = true)),
                            isDefault = it.bool("isDefault") == true,
                        )
                    },
                )
            },
        )
    }

    @Test
    fun selectionCasesMatchFixture() {
        for (case in cases("selectionCases", 8)) {
            val id = case.str("id")
            val i = case["input"]!!.jsonObject
            val e = case["expected"]!!.jsonObject
            // Hosted free-tier connections have no ProviderKind in Community Edition; skip them.
            if (i.present("connection")?.jsonObject?.str("auth") == "free") continue
            val catalog = fixtureCatalog(i["realtimeCatalog"])
            val entry = RealtimeSelection.realtimeEntry(fixtureProvider(i.present("connection")?.jsonObject), i.str("model"), catalog)
            assertEquals("$id isRealtime", e.bool("isRealtime"), entry != null)
            assertEquals("$id catalogReady", e.bool("catalogReady"), catalog != null)
        }
    }

    @Test
    fun catalogSequenceCasesMatchFixture() {
        for (case in cases("catalogSequenceCases", 2)) {
            val id = case.str("id")
            val i = case["input"]!!.jsonObject
            val provider = fixtureProvider(i.present("connection")?.jsonObject)
            val catalogs = i["catalogs"]!!.jsonArray.map { fixtureCatalog(it) }
            val expected = case["expected"]!!.jsonArray.map { it.jsonObject }
            // Production re-judges once per catalog state emitted by realtimeCatalogChanges.
            val states = catalogs.map { c -> c?.let { VoiceCatalogState.Available(it) } }
            val emitted = runBlocking { flowOf(*states.toTypedArray()).realtimeCatalogChanges().toList() }
            val recomputed = catalogs.filterIndexed { n, _ -> expected[n].bool("recompute") == true }
            assertEquals("$id recompute", recomputed, emitted)
            catalogs.forEachIndexed { n, c ->
                assertEquals("$id[$n] isRealtime", expected[n].bool("isRealtime"), RealtimeSelection.isRealtime(provider, i.str("model"), c))
            }
        }
    }

    @Test
    fun capabilityCasesMatchFixture() {
        for (case in cases("capabilityCases", 3)) {
            val id = case.str("id")
            val i = case["input"]!!.jsonObject
            val e = case["expected"]!!.jsonObject
            val expected = RealtimeModel.Capability(
                attachments = e.str("attachments")!!,
                attachmentsReasonKey = e.str("attachmentsReasonKey"),
                webSearch = e.str("webSearch")!!,
                webSearchReasonKey = e.str("webSearchReasonKey"),
                thinking = e.str("thinking")!!,
                thinkingReasonKey = e.str("thinkingReasonKey"),
                tools = e.str("tools")!!,
                toolsReasonKey = e.str("toolsReasonKey"),
                sendsTools = e.bool("sendsTools")!!,
                regenerateEdit = e.str("regenerateEdit")!!,
                setAsDefault = e.str("setAsDefault")!!,
                writesLastUsedModel = e.bool("writesLastUsedModel")!!,
                dictation = e.str("dictation")!!,
                voiceEntry = e.str("voiceEntry")!!,
                visionTile = e.str("visionTile")!!,
                fileTile = e.str("fileTile")!!,
                panelSummary = e.str("panelSummary")!!,
            )
            assertEquals(id, 17, e.size)
            assertEquals(id, expected, RealtimeModel.capability(i.str("modelKind")!!, i.str("mode")!!))
        }
    }

    @Test
    fun migrationCasesMatchFixture() {
        for (case in cases("migrationCases", 10)) {
            val id = case.str("id")
            val i = case["input"]!!.jsonObject
            val oldChoice = i.present("oldChoice")?.jsonObject?.let {
                RealtimeModel.OldChoice(it.str("providerKind")!!, it.str("model")!!, it.str("connectionId")!!)
            }
            val actual = RealtimeModel.migration(
                oldKeyPresent = i.bool("oldKeyPresent") == true,
                oldChoice = oldChoice,
                realtimeCatalog = parseCatalog(i),
                connections = parseConnections(i),
                consented = i.bool("consented") == true,
                answer = i.str("answer"),
                disclosureDeclined = i.bool("disclosureDeclined") == true,
            )
            val e = case["expected"]!!.jsonObject
            val expected = RealtimeModel.MigrationResult(
                showPrompt = e.bool("showPrompt")!!,
                result = e.str("result")!!,
                deleteOldKeys = e.bool("deleteOldKeys")!!,
                showDisclosure = e.bool("showDisclosure")!!,
            )
            assertEquals(id, expected, actual)
        }
    }

    @Test
    fun lifecycleCasesMatchFixture() {
        for (case in cases("lifecycleCases", 6)) {
            val id = case.str("id")
            val e = case["expected"]!!.jsonObject
            val expected = RealtimeModel.LifecycleResult(e.str("action")!!, e.str("reducerInput"))
            assertEquals(id, expected, RealtimeModel.lifecycle(case["input"]!!.jsonObject.str("event")!!))
        }
    }

    @Test
    fun afterDropCasesMatchFixture() {
        for (case in cases("afterDropCases", 12)) {
            val id = case.str("id")
            val i = case["input"]!!.jsonObject
            val e = case["expected"]!!.jsonObject
            val expected = RealtimeModel.AfterDropResult(e.str("action")!!, e.str("code"), e.bool("refetchCatalog")!!)
            val actual = RealtimeModel.afterDrop(
                stage = i.str("stage") ?: RealtimeModel.DROP_STAGE_DROP,
                provider = i.str("provider")!!,
                category = i.str("category") ?: RealtimeModel.CATEGORY_UNKNOWN,
                muted = i.bool("muted") ?: false,
                reopenedWithoutProgress = i.bool("reopenedWithoutProgress") ?: false,
            )
            assertEquals(id, expected, actual)
        }
    }

    @Test
    fun backToStageCasesMatchFixture() {
        for (case in cases("backToStageCases", 3)) {
            val id = case.str("id")
            val i = case["input"]!!.jsonObject
            val e = case["expected"]!!.jsonObject
            val expected = RealtimeModel.BackToStageResult(e.str("action")!!, e.bool("interruptsPlayback")!!)
            val actual = RealtimeModel.backToStage(
                session = i.str("session")!!,
                assistantSpeaking = i.bool("assistantSpeaking") ?: false,
            )
            assertEquals(id, expected, actual)
        }
    }

    @Test
    fun typedSendCasesMatchFixture() {
        for (case in cases("typedSendCases", 7)) {
            val id = case.str("id")
            val i = case["input"]!!.jsonObject
            val e = case["expected"]!!.jsonObject
            val expected = RealtimeModel.TypedSendOutcome(e.bool("inputKeepsText")!!, e.bool("conversationCreated")!!)
            assertEquals(id, expected, RealtimeModel.typedSendOutcome(i.str("context")!!, i.str("outcome")!!))
        }
    }

    @Test
    fun connectionAuthMapsOnlyOfficialApiKeyConnections() {
        assertEquals("apiKey", RealtimeModel.connectionAuth(ProviderKind.OpenAI, ProviderAuthMode.ApiKey))
        assertEquals("apiKey", RealtimeModel.connectionAuth(ProviderKind.Gemini, ProviderAuthMode.ApiKey))
        assertEquals("other", RealtimeModel.connectionAuth(ProviderKind.OpenAI, ProviderAuthMode.Subscription))
        assertEquals("other", RealtimeModel.connectionAuth(ProviderKind.Relay, ProviderAuthMode.ApiKey))
    }

    private fun workspaceFile(relative: String): File {
        var dir: File? = File("").absoluteFile
        while (dir != null) {
            val candidate = File(dir, relative)
            if (candidate.exists()) return candidate
            dir = dir.parentFile
        }
        throw IllegalStateException("not found: $relative")
    }
}
