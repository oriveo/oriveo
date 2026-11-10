package ai.oriveo.community.core.studio

import android.content.Context
import androidx.room.Room
import androidx.room.withTransaction
import ai.oriveo.community.core.data.dao.StudioWorkDao
import ai.oriveo.community.core.data.database.OriveoDatabase
import ai.oriveo.community.core.data.entity.StudioRoundEntity
import ai.oriveo.community.core.data.entity.StudioRoundRefEntity
import ai.oriveo.community.core.data.entity.StudioVersionEntity
import ai.oriveo.community.core.data.entity.StudioWorkEntity
import java.nio.file.Files
import java.nio.file.Paths
import kotlinx.coroutines.runBlocking
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.boolean
import kotlinx.serialization.json.int
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.long
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment

/**
 * StudioWorkRepository card A: create / rename / favorite, partitioned list and detail, round insert, keep rules
 * and version numbers. Every case reads studio_data_model.v1 (aliases resolve through repository.ids).
 */
@RunWith(RobolectricTestRunner::class)
class StudioWorkRepositoryTest {

    private val context: Context get() = RuntimeEnvironment.getApplication()
    private var db: OriveoDatabase? = null
    private lateinit var repository: StudioWorkRepository
    private var partition = "uid-a"
    private var clock = NOW

    private val dao: StudioWorkDao get() = requireNotNull(db).studioWorkDao()

    private val dataModel: JsonObject by lazy {
        val shared = "shared"
        val dir = generateSequence(Paths.get("").toAbsolutePath().normalize()) { it.parent }
            .take(8)
            .map { it.resolve("$shared/studio-contracts") }
            .firstOrNull { Files.exists(it.resolve("studio_data_model.v1.json")) }
            ?: error("studio_data_model.v1.json not found")
        Json.parseToJsonElement(dir.resolve("studio_data_model.v1.json").toFile().readText()).jsonObject
    }
    private val fixtureRepository: JsonObject get() = dataModel.getValue("repository").jsonObject
    private val ids: Map<String, String> by lazy {
        fixtureRepository.getValue("ids").jsonObject.mapValues { it.value.jsonPrimitive.content }
    }

    @Before
    fun setUp() {
        openFresh()
    }

    @After
    fun tearDown() {
        db?.close()
    }

    private fun openFresh() {
        db?.close()
        val database = Room.inMemoryDatabaseBuilder(context, OriveoDatabase::class.java)
            .allowMainThreadQueries()
            .build()
        db = database
        partition = "uid-a"
        clock = NOW
        repository = StudioWorkRepository(
            dao = database.studioWorkDao(),
            currentPartition = { partition },
            now = { clock },
            runInTransaction = { block -> database.withTransaction { block() } },
        )
    }

    // ---- fixture helpers ----

    private fun id(alias: String): String = ids[alias] ?: alias

    private fun alias(id: String): String =
        ids.entries.firstOrNull { it.value.equals(id, ignoreCase = true) }?.key ?: id

    private fun JsonObject.str(key: String): String = getValue(key).jsonPrimitive.content

    private fun JsonObject.strOrNull(key: String): String? =
        get(key).let { if (it == null || it is JsonNull) null else (it as JsonPrimitive).content }

    private fun JsonObject.longOrNull(key: String): Long? =
        get(key).let { if (it == null || it is JsonNull) null else it.jsonPrimitive.long }

    private fun JsonObject.array(key: String): List<JsonObject> = getValue(key).jsonArray.map { it.jsonObject }

    private fun encodeIds(values: List<String>): String = JsonArray(values.map { JsonPrimitive(it) }).toString()

    private fun aliasList(element: JsonElement): List<String> = element.jsonArray.map { id(it.jsonPrimitive.content) }

    private fun seedWorks(name: String): List<JsonObject> =
        fixtureRepository.getValue("seeds").jsonObject.getValue(name).jsonObject.array("works")

    private suspend fun seed(name: String) {
        val seed = fixtureRepository.getValue("seeds").jsonObject.getValue(name).jsonObject
        seed.array("works").forEach { w ->
            dao.upsertWork(
                StudioWorkEntity(
                    id = id(w.str("id")),
                    title = w.str("title"),
                    currentVersionId = w.strOrNull("currentVersionId")?.let(::id),
                    source = w.str("source"),
                    chatConversationId = w.strOrNull("chatConversationId"),
                    chatMessageId = w.strOrNull("chatMessageId"),
                    favorite = w.getValue("favorite").jsonPrimitive.boolean,
                    selectedVersionIds = encodeIds(aliasList(w.getValue("selectedVersionIds"))),
                    deletedVersionIds = encodeIds(aliasList(w.getValue("deletedVersionIds"))),
                    createdAt = w.getValue("createdAt").jsonPrimitive.long,
                    updatedAt = w.getValue("updatedAt").jsonPrimitive.long,
                    deletedAt = w.longOrNull("deletedAt"),
                    revision = w.getValue("revision").jsonPrimitive.long,
                    baseRevision = w.getValue("baseRevision").jsonPrimitive.long,
                    accountPartition = w.str("accountPartition"),
                    syncState = w.str("syncState"),
                ),
            )
        }
        seed.array("rounds").forEach { r ->
            dao.upsertRound(
                roundRow(
                    id = id(r.str("id")),
                    workId = id(r.str("workId")),
                    index = r.getValue("index").jsonPrimitive.int,
                    baseVersionId = r.strOrNull("baseVersionId")?.let(::id),
                    status = r.str("status"),
                ),
            )
        }
        dao.insertVersions(
            seed.array("versions").map { v ->
                versionRow(
                    id = id(v.str("id")),
                    roundId = id(v.str("roundId")),
                    workId = id(v.str("workId")),
                    parentVersionId = v.strOrNull("parentVersionId")?.let(::id),
                    assetId = id(v.str("assetId")),
                    createdAt = v.getValue("createdAt").jsonPrimitive.long,
                    kept = v.getValue("kept").jsonPrimitive.boolean,
                )
            },
        )
        dao.upsertRefs(
            seed.array("refs").map { f ->
                StudioRoundRefEntity(
                    roundId = id(f.str("roundId")),
                    order = f.getValue("order").jsonPrimitive.int,
                    assetId = id(f.str("assetId")),
                    role = f.str("role"),
                )
            },
        )
    }

    @Suppress("LongParameterList")
    private fun roundRow(
        id: String,
        workId: String,
        index: Int,
        baseVersionId: String?,
        status: String,
        requested: Int = 1,
        delivered: Int = 1,
    ) = StudioRoundEntity(
        id = id,
        workId = workId,
        index = index,
        baseVersionId = baseVersionId,
        operation = if (baseVersionId == null) "generate" else "edit",
        prompt = "",
        composedPrompt = "",
        enhancedPrompt = null,
        presetIds = "[]",
        params = "{}",
        modelRef = null,
        status = status,
        errorKind = null,
        adjustments = "{}",
        nRequested = requested,
        nDelivered = delivered,
        costEstimateUsd = null,
        chargedUsd = null,
        fundingSource = "none",
        managedJobId = null,
        clientJobId = null,
        startedAt = 0,
        finishedAt = null,
    )

    @Suppress("LongParameterList")
    private fun versionRow(
        id: String,
        roundId: String,
        workId: String,
        parentVersionId: String?,
        assetId: String,
        createdAt: Long,
        kept: Boolean = false,
    ) = StudioVersionEntity(
        id = id,
        roundId = roundId,
        workId = workId,
        parentVersionId = parentVersionId,
        assetId = assetId,
        width = 1,
        height = 1,
        mime = "image/png",
        kept = kept,
        createdAt = createdAt,
    )

    // ---- versionCases (versionCasesHarness) ----

    @Test
    fun versionCases_matchFixture() = runBlocking {
        val cases = dataModel.array("versionCases")
        var checked = 0
        cases.forEach { case -> if (runVersionCase(case)) checked++ }
        assertTrue("versionCases must run", checked > 0)
    }

    /** Returns false for cases whose steps need deleteVersion. */
    @Suppress("CyclomaticComplexMethod", "LongMethod")
    private suspend fun runVersionCase(case: JsonObject): Boolean {
        val caseId = case.str("caseId")
        val steps = case.str("action").split(';')
        if (steps.any { it.startsWith("delete:") }) return false
        openFresh()
        val local = linkedMapOf<String, String>()
        fun v(alias: String): String = local.getOrPut(alias) {
            ids[alias] ?: "E%07X-0000-4000-8000-%012X".format(local.size + 1, local.size + 1)
        }
        fun aliasOf(id: String?): String? = id?.let { value ->
            local.entries.firstOrNull { it.value.equals(value, ignoreCase = true) }?.key ?: value
        }
        val workId = id("W")
        repository.createWork(id = workId, source = "studio", title = "")
        var index = 0
        var t = 1L
        fun roundId(i: Int) = "F%07X-0000-4000-8000-%012X".format(i, i)
        suspend fun singleRound(alias: String) {
            val rid = roundId(++index)
            assertTrue(
                "$caseId insert $alias",
                repository.insertRound(
                    roundRow(rid, workId, index, baseVersionId = null, status = "completed"),
                    listOf(versionRow(v(alias), rid, workId, null, "asset-$alias", t++)),
                    emptyList(),
                ),
            )
            repository.finishRound(workId, rid)
        }

        val round = case.getValue("round").jsonObject
        if (steps[0].startsWith("keep_order:")) {
            steps[0].removePrefix("keep_order:[").removeSuffix("]").split(',').forEach { singleRound(it.trim()) }
        } else {
            val previous = round["previous"]?.jsonPrimitive?.boolean == true
            if (previous) singleRound("P")
            val requested = round.getValue("n").jsonPrimitive.int
            val delivered = round.getValue("delivered").jsonPrimitive.int
            val status = when {
                delivered == requested -> "completed"
                delivered > 0 -> "partial"
                else -> "failed"
            }
            val rid = roundId(++index)
            val parent = if (previous) v("P") else null
            assertTrue(
                "$caseId insert round",
                repository.insertRound(
                    roundRow(rid, workId, index, parent, status, requested, delivered),
                    (1..delivered).map { versionRow(v("c$it"), rid, workId, parent, "asset-c$it", t++) },
                    emptyList(),
                ),
            )
            repository.finishRound(workId, rid)
            val actions = if (steps[0] == "finish") steps.drop(1) else steps
            actions.forEach { step ->
                step.split(',').forEach { part ->
                    val op = part.substringBefore(':')
                    val arg = part.substringAfter(':', "")
                    when (op) {
                        "pick" -> repository.pick(workId, v(arg))
                        "also" -> repository.alsoKeep(workId, v(arg))
                        "start_next_round" -> repository.resolvePendingPick(workId)
                        else -> error("$caseId unknown step $part")
                    }
                }
            }
        }

        val work = requireNotNull(repository.detail(workId)) { "$caseId detail" }.work
        val expect = case.getValue("expect").jsonObject
        expect["kept"]?.let { kept ->
            assertEquals(
                "$caseId kept",
                kept.jsonArray.map { it.jsonPrimitive.content },
                work.selectedVersionIds.mapNotNull(::aliasOf).filter { it.startsWith("c") },
            )
        }
        expect["current"]?.let {
            assertEquals("$caseId current", it.jsonPrimitive.content, aliasOf(work.currentVersionId))
        }
        expect["pendingPick"]?.let {
            assertEquals("$caseId pendingPick", it.jsonPrimitive.int, repository.pendingPickCount(workId))
        }
        expect["numbers"]?.jsonObject?.forEach { (alias, number) ->
            assertEquals("$caseId number $alias", number.jsonPrimitive.int, repository.versionNumber(workId, v(alias)))
        }
        expect["deletedVersionIds"]?.let { deleted ->
            assertEquals(
                "$caseId deletedVersionIds",
                deleted.jsonArray.map { it.jsonPrimitive.content },
                work.deletedVersionIds.mapNotNull(::aliasOf),
            )
        }
        return true
    }

    // ---- listCases ----

    @Test
    fun listCases_matchFixture() = runBlocking {
        val cases = fixtureRepository.array("listCases")
        assertTrue("listCases must not be empty", cases.isNotEmpty())
        cases.forEach { case ->
            val caseId = case.str("caseId")
            openFresh()
            seed(case.str("seed"))
            val parts = case.str("op").split(':')
            partition = parts[1]
            when (parts[0]) {
                "list" -> assertEquals(
                    caseId,
                    case.getValue("expect").jsonArray.map { it.jsonPrimitive.content },
                    repository.list().map { alias(it.id) },
                )
                "get" -> assertEquals(
                    caseId,
                    case.strOrNull("expect"),
                    repository.detail(id(parts[2]))?.let { alias(it.work.id) },
                )
                else -> error("$caseId unknown op ${parts[0]}")
            }
        }
    }

    // ---- create / rename / insert ----

    @Test
    fun createWork_defaults() = runBlocking {
        partition = "uid-a"
        val created = repository.createWork(
            id = null,
            source = "chat",
            title = "Window coffee",
            chatConversationId = "CONV-1",
            chatMessageId = "MSG-1",
        )
        assertTrue("upper-case UUID: ${created.id}", UPPER_UUID.matches(created.id))
        assertEquals(1L, created.revision)
        assertEquals(0L, created.baseRevision)
        assertEquals(StudioWorkRepository.SYNC_PENDING, created.syncState)
        assertEquals(NOW, created.createdAt)
        assertEquals(NOW, created.updatedAt)
        assertNull(created.deletedAt)
        assertNull(created.currentVersionId)
        assertFalse(created.favorite)
        assertEquals(emptyList<String>(), created.selectedVersionIds)
        assertEquals(emptyList<String>(), created.deletedVersionIds)
        assertEquals("uid-a", created.accountPartition)
        assertEquals("chat", created.source)
        assertEquals("CONV-1", created.chatConversationId)
        assertEquals("MSG-1", created.chatMessageId)
        val row = requireNotNull(dao.getWork(created.id))
        assertEquals(created.title, row.title)
        assertEquals(1L, row.revision)
        assertEquals(StudioWorkRepository.SYNC_PENDING, row.syncState)
        assertEquals(listOf(created.id), repository.list().map { it.id })
    }

    @Test
    fun createWork_existingIdNoRevive() = runBlocking {
        seed("list")
        val tombstone = seedWorks("list").first { it.longOrNull("deletedAt") != null }
        partition = tombstone.str("accountPartition")
        clock = NOW
        val before = requireNotNull(dao.getWork(id(tombstone.str("id"))))
        val returned = repository.createWork(
            id = before.id.lowercase(),
            source = "studio",
            title = "Revived",
        )
        assertEquals(before.id, returned.id)
        assertEquals(before.deletedAt, returned.deletedAt)
        assertEquals(before.revision, returned.revision)
        assertEquals(before.title, returned.title)
        assertEquals(before, dao.getWork(before.id))
        assertNull(repository.detail(before.id))
        assertFalse(repository.list().any { it.id.equals(before.id, ignoreCase = true) })
    }

    @Test
    fun rename_sameValueNoop() = runBlocking {
        seed("list")
        val live = seedWorks("list").first { it.longOrNull("deletedAt") == null }
        partition = live.str("accountPartition")
        val before = requireNotNull(dao.getWork(id(live.str("id"))))
        repository.rename(before.id, before.title)
        repository.setFavorite(before.id, before.favorite)
        assertEquals(before, dao.getWork(before.id))

        repository.rename(before.id, before.title + " 2")
        val after = requireNotNull(dao.getWork(before.id))
        assertEquals(before.title + " 2", after.title)
        assertEquals(before.revision + 1, after.revision)
        assertEquals(before.baseRevision, after.baseRevision)
        assertEquals(NOW, after.updatedAt)
        assertEquals(StudioWorkRepository.SYNC_PENDING, after.syncState)
    }

    @Test
    fun insertRound_rejectsTombstone() = runBlocking {
        seed("list")
        val tombstone = seedWorks("list").first { it.longOrNull("deletedAt") != null }
        partition = tombstone.str("accountPartition")
        val workId = id(tombstone.str("id"))
        val before = requireNotNull(dao.getWork(workId))
        val roundId = "F0000001-0000-4000-8000-000000000001"
        val versionId = "E0000001-0000-4000-8000-000000000001"
        val inserted = repository.insertRound(
            roundRow(roundId, workId, 1, baseVersionId = null, status = "completed"),
            listOf(versionRow(versionId, roundId, workId, null, "asset-new", 1)),
            listOf(StudioRoundRefEntity(roundId = roundId, order = 0, assetId = "asset-ref", role = "style")),
        )
        assertFalse(inserted)
        assertEquals(emptyList<StudioRoundEntity>(), dao.roundsOf(workId))
        assertEquals(emptyList<StudioVersionEntity>(), dao.versionsOf(workId))
        assertFalse(dao.referencedAssetIds().any { it == "asset-new" || it == "asset-ref" })
        assertEquals(before, dao.getWork(workId))

        val missing = "B000000F-0000-4000-8000-00000000000F"
        assertFalse(
            repository.insertRound(roundRow(roundId, missing, 1, null, "completed"), emptyList(), emptyList()),
        )
        assertEquals(emptyList<StudioRoundEntity>(), dao.roundsOf(missing))
    }

    private companion object {
        const val NOW = 9000L
        val UPPER_UUID = Regex("^[0-9A-F]{8}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{12}$")
    }
}
