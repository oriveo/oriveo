package ai.oriveo.community.core.context

import ai.oriveo.community.core.context.ContextContractFixture.double
import ai.oriveo.community.core.context.ContextContractFixture.id
import ai.oriveo.community.core.context.ContextContractFixture.int
import ai.oriveo.community.core.context.ContextContractFixture.objOrNull
import ai.oriveo.community.core.context.ContextContractFixture.stringOrNull
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.booleanOrNull
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/** Write-intent contract: runs the shared memory-intent.v1 fixture case by case, expecting whole-object equality; failure messages start with the case id. */
class ContextContractMemoryIntentTest {

    private val fixture: JsonObject by lazy { ContextContractFixture.load("memory-intent.v1.json") }

    private fun JsonObject.strings(key: String): List<String> =
        this[key]!!.jsonArray.map { it.jsonPrimitive.content }

    private fun JsonObject.long(key: String): Long = stringOrNull(key)!!.toLong()

    private fun JsonObject.longOrNull(key: String): Long? = stringOrNull(key)?.toLong()

    private fun kind(wire: String?): MemoryKind? = wire?.let { MemoryKind.fromWire(it)!! }

    private fun scope(json: JsonObject): MemoryItemScope =
        MemoryItemScope(MemoryScopeType.fromWire(json.stringOrNull("type")!!)!!, json.stringOrNull("id"))

    private fun source(json: JsonObject): MemoryCandidateSource = MemoryCandidateSource(
        type = MemorySourceType.fromWire(json.stringOrNull("type")!!)!!,
        conversationId = json.stringOrNull("conversationId"),
        messageIds = json.strings("messageIds"),
        observedAtMs = json.longOrNull("observedAtMs"),
    )

    private fun record(json: JsonObject): MemoryCandidate = MemoryCandidate(
        id = json.stringOrNull("id")!!,
        status = MemoryCandidateStatus.fromWire(json.stringOrNull("status")!!)!!,
        proposedLayer = MemoryLayer.fromWire(json.stringOrNull("proposedLayer")!!)!!,
        proposedKind = kind(json.stringOrNull("proposedKind"))!!,
        content = json.stringOrNull("content")!!,
        scope = scope(json.objOrNull("scope")!!),
        source = source(json.objOrNull("source")!!),
        sensitivity = MemorySensitivity.fromWire(json.stringOrNull("sensitivity")!!)!!,
        confidence = json.double("confidence"),
        fingerprint = json.stringOrNull("fingerprint")!!,
        createdAtMs = json.long("createdAtMs"),
        expiresAtMs = json.long("expiresAtMs"),
        resolvedAtMs = json.longOrNull("resolvedAtMs"),
    )

    private fun draft(json: JsonObject): MemoryItemDraft = MemoryItemDraft(
        layer = MemoryLayer.fromWire(json.stringOrNull("layer")!!)!!,
        kind = kind(json.stringOrNull("kind"))!!,
        status = MemoryStatus.fromWire(json.stringOrNull("status")!!)!!,
        content = json.stringOrNull("content")!!,
        scope = scope(json.objOrNull("scope")!!),
        source = source(json.objOrNull("source")!!),
        sensitivity = MemorySensitivity.fromWire(json.stringOrNull("sensitivity")!!)!!,
        confidence = json.double("confidence"),
    )

    private fun classification(e: JsonObject): MemoryIntentClassification = MemoryIntentClassification(
        intent = MemoryIntent.Intent.fromWire(e.stringOrNull("intent")!!)!!,
        rule = e.stringOrNull("rule")?.let { MemoryIntentRule.fromWire(it)!! },
        span = e.stringOrNull("span"),
        proposition = e.stringOrNull("proposition"),
        kind = kind(e.stringOrNull("kind")),
        scope = e.stringOrNull("scope")?.let { MemoryIntentScope.fromWire(it)!! },
        sensitive = MemoryIntentSensitive.fromWire(e.stringOrNull("sensitive")!!)!!,
        blocked = e.stringOrNull("blocked")?.let { MemoryIntentBlocked.fromWire(it)!! },
        suggestion = MemoryIntentSuggestion.fromWire(e.stringOrNull("suggestion")!!)!!,
    )

    private fun context(json: JsonObject): MemoryCandidateContext = MemoryCandidateContext(
        conversationId = json.stringOrNull("conversationId")!!,
        folderId = json.stringOrNull("folderId"),
        messageId = json.stringOrNull("messageId")!!,
        nowMs = json.long("nowMs"),
        activeContents = json.strings("activeContents"),
        records = json["records"]!!.jsonArray.map { record(it.jsonObject) },
        // Absent counts as on (per the contract).
        autoSuggest = (json["autoSuggest"] as? JsonPrimitive)?.booleanOrNull ?: true,
    )

    private fun edit(json: JsonObject?): MemoryCandidateEdit? = json?.let {
        MemoryCandidateEdit(
            content = it.stringOrNull("content"),
            kind = kind(it.stringOrNull("kind")),
            scope = it.objOrNull("scope")?.let(::scope),
        )
    }

    private fun transition(e: JsonObject): MemoryCandidateTransition = MemoryCandidateTransition(
        record = e.objOrNull("record")?.let(::record),
        item = e.objOrNull("item")?.let(::draft),
        error = e.stringOrNull("error")?.let { MemoryCandidateError.fromWire(it)!! },
    )

    /** Case groups must be non-empty so a renamed fixture cannot pass vacuously. */
    private fun group(key: String): List<JsonObject> =
        ContextContractFixture.cases(fixture, key).also { assertTrue("$key is empty", it.isNotEmpty()) }

    // ---- Serialize the output back to JSON and compare the whole tree with expected (missing keys, extra keys and differing values all fail) ----

    private fun str(v: String?): JsonElement = v?.let(::JsonPrimitive) ?: JsonNull

    private fun num(v: Long?): JsonElement = v?.let(::JsonPrimitive) ?: JsonNull

    private fun obj(vararg pairs: Pair<String, JsonElement>): JsonObject = JsonObject(linkedMapOf(*pairs))

    private fun json(c: MemoryIntentClassification): JsonObject = obj(
        "intent" to str(c.intent.wire),
        "rule" to str(c.rule?.wire),
        "span" to str(c.span),
        "proposition" to str(c.proposition),
        "kind" to str(c.kind?.wire),
        "scope" to str(c.scope?.wire),
        "sensitive" to str(c.sensitive.wire),
        "blocked" to str(c.blocked?.wire),
        "suggestion" to str(c.suggestion.wire),
    )

    private fun json(scope: MemoryItemScope): JsonObject = obj("type" to str(scope.type.wire), "id" to str(scope.id))

    private fun json(source: MemoryCandidateSource): JsonObject = obj(
        "type" to str(source.type.wire),
        "conversationId" to str(source.conversationId),
        "messageIds" to JsonArray(source.messageIds.map(::JsonPrimitive)),
        "observedAtMs" to num(source.observedAtMs),
    )

    private fun json(r: MemoryCandidate): JsonObject = obj(
        "id" to str(r.id),
        "status" to str(r.status.wire),
        "proposedLayer" to str(r.proposedLayer.wire),
        "proposedKind" to str(r.proposedKind.wire),
        "content" to str(r.content),
        "scope" to json(r.scope),
        "source" to json(r.source),
        "sensitivity" to str(r.sensitivity.wire),
        "confidence" to JsonPrimitive(r.confidence),
        "fingerprint" to str(r.fingerprint),
        "createdAtMs" to num(r.createdAtMs),
        "expiresAtMs" to num(r.expiresAtMs),
        "resolvedAtMs" to num(r.resolvedAtMs),
    )

    private fun json(d: MemoryItemDraft): JsonObject = obj(
        "layer" to str(d.layer.wire),
        "kind" to str(d.kind.wire),
        "status" to str(d.status.wire),
        "content" to str(d.content),
        "scope" to json(d.scope),
        "source" to json(d.source),
        "sensitivity" to str(d.sensitivity.wire),
        "confidence" to JsonPrimitive(d.confidence),
    )

    private fun json(d: MemoryCandidateDecision): JsonObject = obj(
        "action" to str(d.action.wire),
        "reason" to str(d.reason?.wire),
        "candidate" to (d.candidate?.let(::json) ?: JsonNull),
    )

    /** Contract shape: {record, item}, {record} (reject) or {error}; no key with a null value appears. */
    private fun json(t: MemoryCandidateTransition): JsonObject = JsonObject(
        buildMap {
            t.record?.let { put("record", json(it)) }
            t.item?.let { put("item", json(it)) }
            t.error?.let { put("error", str(it.wire)) }
        },
    )

    /** Describes the path of the first difference; numbers compare as Double (fixture 1 equals output 1.0), everything else compares strictly by JSON type and content. */
    private fun treeDiff(path: String, expected: JsonElement, actual: JsonElement): String? = when {
        expected is JsonObject && actual is JsonObject ->
            if (expected.keys != actual.keys) {
                "$path keys: expected ${expected.keys}, got ${actual.keys}"
            } else {
                expected.keys.firstNotNullOfOrNull { k -> treeDiff("$path.$k", expected[k]!!, actual[k]!!) }
            }
        expected is JsonArray && actual is JsonArray ->
            if (expected.size != actual.size) {
                "$path size: expected ${expected.size}, got ${actual.size}"
            } else {
                expected.indices.firstNotNullOfOrNull { i -> treeDiff("$path[$i]", expected[i], actual[i]) }
            }
        expected is JsonNull || actual is JsonNull ->
            if (expected is JsonNull && actual is JsonNull) null else "$path: expected $expected, got $actual"
        expected is JsonPrimitive && actual is JsonPrimitive -> {
            val en = expected.content.toDoubleOrNull()
            val an = actual.content.toDoubleOrNull()
            val same = if (!expected.isString && !actual.isString && en != null && an != null) {
                en == an
            } else {
                expected.isString == actual.isString && expected.content == actual.content
            }
            if (same) null else "$path: expected $expected, got $actual"
        }
        else -> "$path: expected $expected, got $actual"
    }

    @Test
    fun cases() {
        val failures = group("cases").mapNotNull { c ->
            val expectedJson = c["expected"]!!.jsonObject
            val expected = classification(expectedJson)
            val actual = MemoryIntent.classify(c.stringOrNull("text")!!)
            val diff = treeDiff("expected", expectedJson, json(actual))
            if (actual == expected && diff == null) null else "${c.id()}: ${diff ?: ""} expected $expected, got $actual"
        }
        assertTrue(failures.joinToString("\n"), failures.isEmpty())
    }

    @Test
    fun fingerprintCases() {
        val failures = group("fingerprintCases").mapNotNull { c ->
            val e = c["expected"]!!.jsonObject
            val content = c.stringOrNull("content")!!
            val expected = e.stringOrNull("canonical") to e.stringOrNull("fingerprint")
            val actual = MemoryIntent.canonical(content) to MemoryIntent.fingerprint(content)
            if (actual == expected) null else "${c.id()}: expected $expected, got $actual"
        }
        assertTrue(failures.joinToString("\n"), failures.isEmpty())
    }

    @Test
    fun candidateCases() {
        val failures = group("candidateCases").mapNotNull { c ->
            val e = c["expected"]!!.jsonObject
            val expected = MemoryCandidateDecision(
                action = MemoryCandidateAction.fromWire(e.stringOrNull("action")!!)!!,
                reason = e.stringOrNull("reason")?.let { MemoryCandidateSkipReason.fromWire(it)!! },
                candidate = e.objOrNull("candidate")?.let(::record),
            )
            val classified = MemoryIntent.classify(c.stringOrNull("text")!!)
            val actual = MemoryIntent.makeCandidate(classified, context(c["context"]!!.jsonObject))
            val diff = treeDiff("expected", e, json(actual))
            if (actual == expected && diff == null) null else "${c.id()}: ${diff ?: ""} expected $expected, got $actual"
        }
        assertTrue(failures.joinToString("\n"), failures.isEmpty())
    }

    @Test
    fun transitionCases() {
        val failures = group("transitionCases").mapNotNull { c ->
            val expectedJson = c["expected"]!!.jsonObject
            val expected = transition(expectedJson)
            val record = record(c["record"]!!.jsonObject)
            val nowMs = c.long("nowMs")
            val actual = when (val op = c.stringOrNull("op")) {
                "accept" -> MemoryIntent.accept(record, edit(c.objOrNull("edit")), nowMs)
                "reject" -> MemoryIntent.reject(record, nowMs)
                else -> error("unknown op $op")
            }
            val diff = treeDiff("expected", expectedJson, json(actual))
            if (actual == expected && diff == null) null else "${c.id()}: ${diff ?: ""} expected $expected, got $actual"
        }
        assertTrue(failures.joinToString("\n"), failures.isEmpty())
    }

    @Test
    fun sweepCases() {
        val failures = group("sweepCases").mapNotNull { c ->
            val e = c["expected"]!!.jsonObject
            val expected = MemoryCandidateSweep(
                keptIds = e.strings("keptIds"),
                expiredIds = e.strings("expiredIds"),
                supersededIds = e.strings("supersededIds"),
                purgedIds = e.strings("purgedIds"),
            )
            val actual = MemoryIntent.sweep(
                c["records"]!!.jsonArray.map { record(it.jsonObject) },
                c.strings("activeContents"),
                c.long("nowMs"),
            )
            if (actual == expected) null else "${c.id()}: expected $expected, got $actual"
        }
        assertTrue(failures.joinToString("\n"), failures.isEmpty())
    }

    @Test
    fun lexicon_matches_fixture() {
        val lexicon = fixture["lexicon"]!!.jsonObject
        val modes = fixture["lexiconModes"]!!.jsonObject
        assertTrue("lexicon is empty", MemoryIntentLexicon.languages.isNotEmpty())
        assertEquals(lexicon.keys.toList(), MemoryIntentLexicon.languages.map { it.code })
        assertEquals(modes.keys.toList(), MemoryIntentLexicon.languages.map { it.code })
        MemoryIntentLexicon.languages.forEach { lang ->
            val l = lexicon[lang.code]!!.jsonObject
            assertEquals("${lang.code} mode", modes.stringOrNull(lang.code), lang.mode.name.lowercase())
            val embedded = mapOf(
                "memoryWords" to lang.memoryWords,
                "metaTerms" to lang.metaTerms,
                "recallAddressees" to lang.recallAddressees,
                "recallTerms" to lang.recallTerms,
                "deleteTerms" to lang.deleteTerms,
                "deleteExceptions" to lang.deleteExceptions,
                "supersedeTerms" to lang.supersedeTerms,
                "transientTerms" to lang.transientTerms,
                "transientExceptions" to lang.transientExceptions,
                "persistStarts" to lang.persistStarts,
                "reminderStarts" to lang.reminderStarts,
                "ackTerms" to lang.ackTerms,
                "reminisceStarts" to lang.reminisceStarts,
                "politePrefixes" to lang.politePrefixes,
                "linkers" to lang.linkers,
                "anaphorOnly" to lang.anaphorOnly,
                "anaphorDirective" to lang.anaphorDirective,
                "uncertainMarkers" to lang.uncertainMarkers,
                "implicitMarkers" to lang.implicitMarkers,
                "folderMarkers" to lang.folderMarkers,
                "conversationMarkers" to lang.conversationMarkers,
                "secretTerms" to lang.secretTerms,
                "specialTerms" to lang.specialTerms,
            )
            assertEquals("${lang.code} keys", l.keys - "kindStarts", embedded.keys)
            embedded.forEach { (key, terms) -> assertEquals("${lang.code} $key", l.strings(key), terms) }
            val kindStarts = l["kindStarts"]!!.jsonObject
            val embeddedKinds = mapOf(
                "project" to lang.kindProject,
                "goal" to lang.kindGoal,
                "preference" to lang.kindPreference,
                "identity" to lang.kindIdentity,
            )
            assertEquals("${lang.code} kindStarts keys", kindStarts.keys.toList(), embeddedKinds.keys.toList())
            embeddedKinds.forEach { (key, terms) ->
                assertEquals("${lang.code} kindStarts.$key", kindStarts.strings(key), terms)
            }
        }
    }

    @Test
    fun constants_match_fixture() {
        assertEquals(fixture.int("version"), MemoryIntentLexicon.VERSION)
        val constants = fixture["constants"]!!.jsonObject
        assertEquals(constants.long("candidateTtlMs"), MemoryIntentLexicon.CANDIDATE_TTL_MS)
        assertEquals(constants.int("contentMaxCodePoints"), MemoryIntentLexicon.CONTENT_MAX_CODE_POINTS)
        assertEquals(constants.stringOrNull("uuidNamespace"), MemoryIntentLexicon.UUID_NAMESPACE)
        // makeCandidate's UUIDv5 goes through MemoryItems.uuid; the namespace must match this contract.
        assertEquals(MemoryItems.UUID_NAMESPACE, MemoryIntentLexicon.UUID_NAMESPACE)
        val confidence = constants["confidence"]!!.jsonObject
        assertEquals(confidence.double("explicit_persist"), MemoryIntentLexicon.CONFIDENCE_EXPLICIT, 0.0)
        assertEquals(confidence.double("implicit_persist"), MemoryIntentLexicon.CONFIDENCE_IMPLICIT, 0.0)
        assertEquals(constants.stringOrNull("codeTokenChars"), MemoryIntentLexicon.CODE_TOKEN_CHARS)
        assertEquals(constants.stringOrNull("separators"), MemoryIntentLexicon.SEPARATORS)
        assertTrue("secretPatterns is empty", MemoryIntentLexicon.secretPatterns.isNotEmpty())
        assertEquals(
            fixture["secretPatterns"]!!.jsonArray.map { p ->
                val o = p.jsonObject
                MemoryIntentLexicon.SecretPattern(o.stringOrNull("id")!!, o.stringOrNull("regex")!!, o["luhn"]!!.jsonPrimitive.content.toBooleanStrict())
            },
            MemoryIntentLexicon.secretPatterns,
        )
    }

    @Test
    fun no_classification_writes_active() {
        val context = MemoryCandidateContext(
            conversationId = "3f1c9a52-7d4e-4b8a-9c21-5e6f7a8b9c0d",
            folderId = null,
            messageId = "0b1c2d3e-4f50-4617-8899-aabbccddeeff",
            nowMs = 1792137600000L,
            activeContents = emptyList(),
            records = emptyList(),
        )
        var created = 0
        group("cases").forEach { c ->
            val decision = MemoryIntent.makeCandidate(MemoryIntent.classify(c.stringOrNull("text")!!), context)
            if (decision.action != MemoryCandidateAction.CREATE) {
                assertNull(c.id(), decision.candidate)
                return@forEach
            }
            created++
            val candidate = decision.candidate
            assertNotNull(c.id(), candidate)
            candidate!!
            assertEquals(c.id(), MemoryCandidateStatus.PENDING, candidate.status)
            val accepted = MemoryIntent.accept(candidate, null, context.nowMs)
            assertEquals(c.id(), MemoryCandidateStatus.ACCEPTED, accepted.record?.status)
            assertEquals(c.id(), MemoryStatus.ACTIVE, accepted.item?.status)
        }
        assertTrue("no create decisions", created > 0)
    }
}
