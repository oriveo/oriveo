package ai.oriveo.community.core.context

import ai.oriveo.community.core.context.ContextContractFixture.bool
import ai.oriveo.community.core.context.ContextContractFixture.id
import ai.oriveo.community.core.context.ContextContractFixture.int
import ai.oriveo.community.core.context.ContextContractFixture.intOrNull
import ai.oriveo.community.core.context.ContextContractFixture.objOrNull
import ai.oriveo.community.core.context.ContextContractFixture.stringOrNull
import ai.oriveo.community.core.util.DeterministicProviderId
import java.lang.reflect.Modifier
import java.nio.ByteBuffer
import java.time.Instant
import java.util.UUID
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.put
import kotlinx.serialization.json.putJsonArray
import kotlinx.serialization.json.putJsonObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

/** Memory item v2 contract: each *Cases group of memory-items.v2.json runs case by case through the production pure functions, with inputs / expectations using the fixture field names. */
class ContextContractMemoryItemsTest {

    private val fixture: JsonObject by lazy { ContextContractFixture.load("memory-items.v2.json") }
    private val constants: JsonObject by lazy { fixture["constants"]!!.jsonObject }
    private val fieldOrder: List<String> by lazy { fixture["fieldOrder"]!!.jsonArray.map { it.jsonPrimitive.content } }
    private val serverTimestampSentinel: String by lazy { constants.stringOrNull("serverTimestampSentinel")!! }

    // In production the tombstone time and the conflict original's mutationId come from the caller; the fixture does not compare them, so fixed values are used here.
    private val deletionTime = "2026-10-16T00:00:00Z"
    private val originalMutationId = "f0000000-0000-4000-8000-0000000000ff"

    @Test
    fun `constants and field order match fixture`() {
        val ns = constants["uuidNamespace"]!!.jsonObject
        assertEquals(ns.stringOrNull("value"), MemoryItems.UUID_NAMESPACE)
        assertEquals(ns.stringOrNull("url"), MemoryItems.UUID_NAMESPACE_URL)
        val urlNamespace = UUID.fromString("6ba7b811-9dad-11d1-80b4-00c04fd430c8")
        val urlBytes = ByteBuffer.allocate(16)
            .putLong(urlNamespace.mostSignificantBits).putLong(urlNamespace.leastSignificantBits).array()
        assertEquals(MemoryItems.UUID_NAMESPACE, DeterministicProviderId.uuidV5(urlBytes, MemoryItems.UUID_NAMESPACE_URL).lowercase())
        val legacy = constants["legacyKeys"]!!.jsonObject
        assertEquals(legacy.stringOrNull("memoryText"), MemoryItems.LEGACY_KEY_MEMORY_TEXT)
        assertEquals(legacy.stringOrNull("antiForget"), MemoryItems.LEGACY_KEY_ANTI_FORGET)
        assertEquals(constants.stringOrNull("migrationMutationSuffix"), MemoryItems.MIGRATION_MUTATION_SUFFIX)
        assertEquals(constants.int("contentMaxCodePoints"), MemoryItems.CONTENT_MAX_CODE_POINTS)
        assertEquals(constants.stringOrNull("organizeSystemPrompt"), MemoryItems.ORGANIZE_SYSTEM_PROMPT)
        assertEquals(constants.int("organizeMaxItems"), MemoryItems.ORGANIZE_MAX_ITEMS)
        assertEquals(constants.stringOrNull("rawViewSeparator"), MemoryItems.RAW_VIEW_SEPARATOR)
        assertEquals(fixture.int("version"), MemoryItems.SCHEMA_VERSION)
        val declared = MemoryItem::class.java.declaredFields.filterNot { Modifier.isStatic(it.modifiers) }.map { it.name }
        assertEquals(fieldOrder, declared)
    }

    @Test
    fun `canonicalCases`() = cases("canonicalCases", 2) { id, input, expected ->
        assertItem(id, expected.jsonObject, MemoryItems.canonical(item(input)))
    }

    @Test
    fun `migrationCases`() = cases("migrationCases", 7) { id, input, expected ->
        val actual = MemoryItems.migrate(input.stringOrNull("uid")!!, input.stringOrNull("deviceId")!!, prefs(input))
        assertItems(id, expected.jsonArray, actual)
    }

    @Test
    fun `injectableCases`() = cases("injectableCases", 3) { id, input, expected ->
        val actual = MemoryItems.injectable(
            items(input["items"]!!),
            conversationId = input.stringOrNull("conversationId")!!,
            folderId = input.stringOrNull("folderId"),
            now = Instant.parse(input.stringOrNull("now")!!),
        )
        val e = expected.jsonObject
        assertEquals("$id: standingInstructions", strings(e["standingInstructions"]!!), actual.standingInstructions.map { it.id })
        assertEquals("$id: memory", strings(e["memory"]!!), actual.memory.map { it.id })
    }

    @Test
    fun `orderCases`() = cases("orderCases", 1) { id, input, expected ->
        assertEquals(id, strings(expected), MemoryItems.listOrder(items(input["items"]!!)).map { it.id })
    }

    @Test
    fun `tombstoneCases`() = cases("tombstoneCases", 1) { id, input, expected ->
        val actual = MemoryItems.tombstone(
            item(input["item"]!!.jsonObject),
            mutationId = input.stringOrNull("mutationId")!!,
            deviceId = input.stringOrNull("deviceId")!!,
            deletedAt = input.stringOrNull("deletedAt")!!,
        )
        assertItem(id, expected.jsonObject, actual)
    }

    @Test
    fun `mergeCases`() = cases("mergeCases", 17) { id, input, expected ->
        val actual = MemoryItems.merge(
            local = input.objOrNull("local")?.let(::version),
            remote = version(input["remote"]!!.jsonObject),
            pending = input.objOrNull("pending")?.let(::version),
        )
        val e = expected.jsonObject
        assertEquals("$id: result", e.stringOrNull("result"), actual.result.wire)
        assertEquals("$id: keep", strings(e["keep"]!!), actual.keep)
        assertEquals("$id: status", e.stringOrNull("status"), actual.status.wire)
    }

    @Test
    fun `pushCases`() = cases("pushCases", 14) { id, input, expected ->
        val actual = MemoryItems.push(input.objOrNull("remote")?.let(::version), version(input["pending"]!!.jsonObject))
        val e = expected.jsonObject
        assertEquals("$id: action", e.stringOrNull("action"), actual.action.wire)
        // The localOnly expectation writes baseRevision (the revision settled locally); production keeps it in the revision field.
        assertEquals("$id: revision", e.intOrNull("revision") ?: e.intOrNull("baseRevision"), actual.revision)
    }

    @Test
    fun `conflictCases`() = cases("conflictCases", 1) { id, input, expected ->
        val actual = MemoryItems.conflictCopy(
            itemId = input.stringOrNull("itemId")!!,
            pending = item(input["pending"]!!.jsonObject),
            remote = item(input["remote"]!!.jsonObject),
            mutationId = originalMutationId,
        )
        val e = expected.jsonObject
        assertItem("$id: original", e["original"]!!.jsonObject, actual.original)
        assertItem("$id: copy", e["copy"]!!.jsonObject, actual.copy)
    }

    @Test
    fun `legacySyncCases`() = cases("legacySyncCases", 9) { id, input, expected ->
        val actual = MemoryItems.legacySync(
            uid = input.stringOrNull("uid")!!,
            migrated = input.bool("migrated"),
            deviceId = input.stringOrNull("deviceId")!!,
            items = items(input["items"]!!),
            prefs = prefs(input["prefs"]!!.jsonObject),
            deletedAt = deletionTime,
        )
        val e = expected.jsonObject
        assertItems("$id: create", e["create"]!!.jsonArray, actual.create)
        assertItems("$id: update", e["update"]!!.jsonArray, actual.update)
        assertEquals("$id: writePrefs", e["writePrefs"]!!, actual.writePrefs?.let(::writeJson) ?: JsonNull)
    }

    @Test
    fun `compileCases`() = cases("compileCases", 2) { id, input, expected ->
        val actual = MemoryItems.compileLegacy(input.stringOrNull("uid")!!, items(input["items"]!!))
        assertEquals(id, expected, compileJson(actual))
    }

    @Test
    fun `rawViewCases`() = cases("rawViewCases", 7) { id, input, expected ->
        val e = expected.jsonObject
        val items = items(input["items"]!!)
        if (e.containsKey("text")) {
            assertEquals(id, e.stringOrNull("text"), MemoryItems.rawRender(items))
            return@cases
        }
        val actual = MemoryItems.rawApply(items, input.stringOrNull("text")!!, strings(input["newIds"]!!))
        val json = when (actual) {
            is MemoryRawApply.TooLong -> buildJsonObject {
                put("error", "tooLong")
                put("index", actual.index)
            }
            is MemoryRawApply.Ops -> buildJsonObject {
                putJsonArray("ops") {
                    actual.ops.forEach { op ->
                        add(
                            when (op) {
                                is MemoryRawOp.Update -> buildJsonObject {
                                    put("op", "update")
                                    put("id", op.id)
                                    put("content", op.content)
                                }
                                is MemoryRawOp.Create -> buildJsonObject {
                                    put("op", "create")
                                    put("id", op.id)
                                    put("kind", op.kind.wire)
                                    put("content", op.content)
                                }
                                is MemoryRawOp.Delete -> buildJsonObject {
                                    put("op", "delete")
                                    put("id", op.id)
                                }
                            },
                        )
                    }
                }
            }
        }
        assertEquals(id, e, json)
    }

    @Test
    fun `organizeCases`() = cases("organizeCases", 5) { id, input, expected ->
        val content = input.stringOrNull("content")
        if (content != null) {
            val request = MemoryItems.organizeRequest(content)
            val json = buildJsonObject {
                put("system", request.system)
                putJsonArray("messages") {
                    request.messages.forEach { m ->
                        add(
                            buildJsonObject {
                                put("role", m.role.rawValue)
                                put("text", m.text)
                            },
                        )
                    }
                }
            }
            assertEquals(id, expected, json)
        } else {
            val parsed = MemoryItems.organizeParse(input.stringOrNull("response")!!)
            val json = JsonArray(
                parsed.map {
                    buildJsonObject {
                        put("kind", it.kind.wire)
                        put("content", it.content)
                    }
                },
            )
            assertEquals(id, expected, json)
        }
    }

    @Test
    fun `backupCases`() = cases("backupCases", 5) { id, input, expected ->
        val e = expected.jsonObject
        if (input.containsKey("items")) {
            val section = MemoryItems.backupSection(items(input["items"]!!))
            assertEquals("$id: memorySchemaVersion", e.int("memorySchemaVersion"), section.memorySchemaVersion)
            assertItems("$id: memoryItems", e["memoryItems"]!!.jsonArray, section.memoryItems)
            return@cases
        }
        val backup = input["backup"]!!.jsonObject
        val mode = MemoryBackupMode.valueOf(input.stringOrNull("mode")!!.uppercase())
        val local = items(input["local"]!!)
        val actual = MemoryItems.backupMerge(
            mode = mode,
            local = local,
            backup = MemoryBackup(
                memoryItems = backup["memoryItems"]?.let(::items),
                preferences = backup.objOrNull("preferences")?.let(::prefs),
            ),
            uid = input.stringOrNull("uid").orEmpty(),
            deviceId = input.stringOrNull("deviceId").orEmpty(),
        )
        assertItems("$id: items", e["items"]!!.jsonArray, actual)
        e["tombstonedIds"]?.let { tombstoned ->
            assertEquals("$id: tombstonedIds", strings(tombstoned), MemoryItems.backupReplaceTombstonedIds(local, actual))
        }
    }

    // ---- Fixture <-> production objects ----

    private fun cases(key: String, count: Int, body: (String, JsonObject, JsonElement) -> Unit) {
        val cases = ContextContractFixture.cases(fixture, key)
        assertEquals(key, count, cases.size)
        cases.forEach { case -> body(case.id(), case["input"]!!.jsonObject, case["expected"]!!) }
    }

    private fun strings(el: JsonElement): List<String> = el.jsonArray.map { it.jsonPrimitive.content }

    private fun items(el: JsonElement): List<MemoryItem> = el.jsonArray.map { item(it.jsonObject) }

    /** Fixture entry (missing keys take production defaults) to MemoryItem. */
    private fun item(o: JsonObject): MemoryItem {
        val base = MemoryItem(
            id = o.stringOrNull("id")!!,
            kind = MemoryKind.fromWire(o.stringOrNull("kind")!!)!!,
            content = o.stringOrNull("content")!!,
            mutationId = o.stringOrNull("mutationId")!!,
            deviceId = o.stringOrNull("deviceId")!!,
        )
        val scope = o.objOrNull("scope")?.let {
            MemoryItemScope(MemoryScopeType.fromWire(it.stringOrNull("type")!!)!!, it.stringOrNull("id"))
        }
        val source = o.objOrNull("source")?.let { s ->
            val d = MemoryItemSource()
            MemoryItemSource(
                type = s.stringOrNull("type")?.let { MemorySourceType.fromWire(it)!! } ?: d.type,
                conversationId = s.stringOrNull("conversationId"),
                messageIds = s["messageIds"]?.let(::strings) ?: d.messageIds,
                observedAt = s.stringOrNull("observedAt"),
            )
        }
        return base.copy(
            schemaVersion = o.intOrNull("schemaVersion") ?: base.schemaVersion,
            layer = o.stringOrNull("layer")?.let { MemoryLayer.fromWire(it)!! } ?: base.layer,
            status = o.stringOrNull("status")?.let { MemoryStatus.fromWire(it)!! } ?: base.status,
            scope = scope ?: base.scope,
            source = source ?: base.source,
            sensitivity = o.stringOrNull("sensitivity")?.let { MemorySensitivity.fromWire(it)!! } ?: base.sensitivity,
            confidence = o.stringOrNull("confidence")?.toDouble() ?: base.confidence,
            priority = o.intOrNull("priority") ?: base.priority,
            pinned = o["pinned"]?.let { o.bool("pinned") } ?: base.pinned,
            revision = o.intOrNull("revision") ?: base.revision,
            baseRevision = o.intOrNull("baseRevision") ?: base.baseRevision,
            conflictGroupId = o.stringOrNull("conflictGroupId") ?: base.conflictGroupId,
            occurredAt = o.stringOrNull("occurredAt") ?: base.occurredAt,
            validFrom = serverTime(o, "validFrom") ?: base.validFrom,
            lastConfirmedAt = serverTime(o, "lastConfirmedAt") ?: base.lastConfirmedAt,
            createdAt = serverTime(o, "createdAt") ?: base.createdAt,
            updatedAt = serverTime(o, "updatedAt") ?: base.updatedAt,
            expiresAt = o.stringOrNull("expiresAt") ?: base.expiresAt,
            deletedAt = o.stringOrNull("deletedAt") ?: base.deletedAt,
            supersedes = o["supersedes"]?.let(::strings) ?: base.supersedes,
        )
    }

    private fun serverTime(o: JsonObject, key: String): MemoryServerTime? = when (val raw = o.stringOrNull(key)) {
        null -> null
        serverTimestampSentinel -> MemoryServerTime.ServerTimestamp
        else -> MemoryServerTime.At(raw)
    }

    private fun serverTimeJson(t: MemoryServerTime?): JsonPrimitive = when (t) {
        null -> JsonNull
        is MemoryServerTime.At -> JsonPrimitive(t.rfc3339)
        MemoryServerTime.ServerTimestamp -> JsonPrimitive(serverTimestampSentinel)
    }

    /** MemoryItem to fixture shape (all fieldOrder keys); the server-time placeholder is written as a sentinel. */
    private fun itemJson(item: MemoryItem): JsonObject = buildJsonObject {
        put("id", item.id)
        put("schemaVersion", item.schemaVersion)
        put("layer", item.layer.wire)
        put("kind", item.kind.wire)
        put("status", item.status.wire)
        put("content", item.content)
        putJsonObject("scope") {
            put("type", item.scope.type.wire)
            put("id", item.scope.id)
        }
        putJsonObject("source") {
            put("type", item.source.type.wire)
            put("conversationId", item.source.conversationId)
            putJsonArray("messageIds") { item.source.messageIds.forEach { add(JsonPrimitive(it)) } }
            put("observedAt", item.source.observedAt)
        }
        put("sensitivity", item.sensitivity.wire)
        val confidence = item.confidence
        if (confidence % 1.0 == 0.0) put("confidence", confidence.toLong()) else put("confidence", confidence)
        put("priority", item.priority)
        put("pinned", item.pinned)
        put("revision", item.revision)
        put("baseRevision", item.baseRevision)
        put("mutationId", item.mutationId)
        put("deviceId", item.deviceId)
        put("conflictGroupId", item.conflictGroupId)
        put("occurredAt", item.occurredAt)
        put("validFrom", serverTimeJson(item.validFrom))
        put("lastConfirmedAt", serverTimeJson(item.lastConfirmedAt))
        put("createdAt", serverTimeJson(item.createdAt))
        put("updatedAt", serverTimeJson(item.updatedAt))
        put("expiresAt", item.expiresAt)
        put("deletedAt", item.deletedAt)
        putJsonArray("supersedes") { item.supersedes.forEach { add(JsonPrimitive(it)) } }
    }

    /** Compares every key present in expected (a full entry means all keys are compared). */
    private fun assertItem(label: String, expected: JsonObject, actual: MemoryItem) {
        val json = itemJson(actual)
        assertEquals("$label: keys", fieldOrder, json.keys.toList())
        expected.forEach { (key, value) -> assertEquals("$label.$key", value, json[key]) }
    }

    private fun assertItems(label: String, expected: JsonArray, actual: List<MemoryItem>) {
        assertEquals("$label: count", expected.size, actual.size)
        expected.zip(actual).forEachIndexed { i, (e, a) -> assertItem("$label[$i]", e.jsonObject, a) }
    }

    private fun version(o: JsonObject): MemoryItemVersion = MemoryItemVersion(
        revision = o.intOrNull("revision"),
        mutationId = o.stringOrNull("mutationId")!!,
        status = MemoryStatus.fromWire(o.stringOrNull("status")!!)!!,
        content = o.stringOrNull("content")!!,
        baseRevision = o.intOrNull("baseRevision"),
        sensitivity = o.stringOrNull("sensitivity")?.let { MemorySensitivity.fromWire(it)!! } ?: MemorySensitivity.NORMAL,
    )

    private fun prefs(o: JsonObject): MemoryLegacyPrefs {
        val base = MemoryLegacyPrefs(memoryText = o.stringOrNull("memoryText")!!)
        return base.copy(
            memoryTextDigest = o.stringOrNull("memoryTextDigest") ?: base.memoryTextDigest,
            antiForgetEnabled = o["antiForgetEnabled"]?.let { o.bool("antiForgetEnabled") } ?: base.antiForgetEnabled,
            antiForgetText = o.stringOrNull("antiForgetText") ?: base.antiForgetText,
            memoryUpdatedAt = o.stringOrNull("memoryUpdatedAt") ?: base.memoryUpdatedAt,
        )
    }

    private fun compileJson(c: MemoryLegacyCompile): JsonObject = buildJsonObject {
        put("memoryText", c.memoryText)
        put("memoryTextDigest", c.memoryTextDigest)
    }

    private fun writeJson(w: MemoryLegacyWrite): JsonObject = buildJsonObject {
        put("memoryText", w.memoryText)
        put("memoryTextDigest", w.memoryTextDigest)
        put("textChanged", w.textChanged)
    }
}
