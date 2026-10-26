package ai.oriveo.community.feature.providers

import android.content.Context
import androidx.room.Room
import ai.oriveo.community.core.data.database.OriveoDatabase
import ai.oriveo.community.core.data.entity.ConversationEntity
import ai.oriveo.community.core.data.entity.MessageEntity
import ai.oriveo.community.core.data.repository.conversation.billedMessageCountByProvider
import ai.oriveo.community.core.model.CostFormatter
import ai.oriveo.community.core.model.Provider
import ai.oriveo.community.core.model.ProviderConnectionState
import ai.oriveo.community.core.model.ProviderKind
import ai.oriveo.community.core.provider.CostSource
import ai.oriveo.community.core.usage.CostParts
import ai.oriveo.community.core.util.normalizeUuid
import java.io.File
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.runBlocking
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.doubleOrNull
import kotlinx.serialization.json.int
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment

/**
 * Runs each case of the shared fixture `shared/test-fixtures/provider-catalog/provider-spotlight.v1.json`:
 * the fixture messages are written into an in-memory Room database, the billed-message counts and USD
 * amounts come from the production SQL, and those feed the production selector [computeSpotlightProviders].
 */
@RunWith(RobolectricTestRunner::class)
class ProviderSpotlightContractTest {

    private val context: Context get() = RuntimeEnvironment.getApplication()
    private lateinit var db: OriveoDatabase

    @Before
    fun setUp() {
        db = Room.inMemoryDatabaseBuilder(context, OriveoDatabase::class.java)
            .allowMainThreadQueries()
            .build()
    }

    @After
    fun tearDown() {
        db.close()
    }

    // -- Fixture --

    private val fixture: JsonObject by lazy {
        var dir: File? = File(System.getProperty("user.dir") ?: ".").absoluteFile
        while (dir != null) {
            val candidate = File(dir, "shared/test-fixtures/provider-catalog/provider-spotlight.v1.json")
            if (candidate.exists()) return@lazy Json.parseToJsonElement(candidate.readText()).jsonObject
            dir = dir.parentFile
        }
        throw IllegalStateException("provider-spotlight.v1.json not found")
    }

    private val cases: List<JsonObject> by lazy { fixture["cases"]!!.jsonArray.map { it.jsonObject } }

    private fun case(id: String): JsonObject = cases.first { it["id"]!!.jsonPrimitive.content == id }

    private fun JsonObject.str(key: String): String? = (this[key] as? JsonPrimitive)?.content

    // Fixture source upstream / localEstimate / unknown -> the CostSource name that gets stored
    private fun costSourceName(raw: String?): String = when (raw) {
        "upstream" -> CostSource.UPSTREAM.name
        "localEstimate" -> CostSource.LOCAL_ESTIMATE.name
        else -> CostSource.UNKNOWN.name
    }

    private fun providerOf(raw: JsonObject): Provider = Provider(
        id = normalizeUuid(raw.str("id")!!),
        // Fixture kinds are cross-platform camelCase (deepSeek etc.); match the enum name case-insensitively
        kind = ProviderKind.entries.first { it.name.equals(raw.str("kind"), ignoreCase = true) },
        apiKey = "sk-fixture",
        status = when (raw.str("status")) {
            "connected" -> ProviderConnectionState.Connected
            "syncing" -> ProviderConnectionState.Syncing
            else -> ProviderConnectionState.Issue("fixture")
        },
    )

    private fun runCase(id: String) = runBlocking {
        val raw = case(id)
        val providers = raw["providers"]!!.jsonArray.map { providerOf(it.jsonObject) }
        val dao = db.messageDao()
        providers.forEach { provider ->
            db.conversationDao().upsert(
                ConversationEntity(
                    id = "conv-${provider.id}",
                    title = "Spotlight",
                    hasCustomTitle = false,
                    providerID = provider.id,
                    providerKind = provider.kind.name,
                    modelID = "model",
                    previewText = "",
                    estimatedCost = 0.0,
                    isDraft = false,
                    draftText = "",
                    createdAt = MONTH_START,
                    updatedAt = MONTH_START,
                    accountId = ACCOUNT,
                ),
            )
        }
        raw["messages"]!!.jsonArray.map { it.jsonObject }.forEachIndexed { index, message ->
            val providerId = normalizeUuid(message.str("providerId")!!)
            val provider = providers.first { it.id == providerId }
            val nonUsd = message["nonUsdCost"]?.jsonObject
            dao.upsert(
                MessageEntity(
                    id = "msg-$index",
                    conversationId = "conv-$providerId",
                    role = "Assistant",
                    text = "reply",
                    providerID = providerId,
                    providerKind = provider.kind.name,
                    providerName = provider.kind.name,
                    modelName = "model",
                    estimatedCost = message["estimatedCost"]!!.jsonPrimitive.doubleOrNull ?: 0.0,
                    costSource = costSourceName(message.str("costSource")),
                    state = "Delivered",
                    errorTitle = null,
                    errorDetail = null,
                    attachmentsJson = null,
                    createdAt = MONTH_START + index,
                    sortOrder = index,
                    accountId = ACCOUNT,
                    nonUsdCostCurrency = nonUsd?.str("currencyCode"),
                    nonUsdCostAmount = nonUsd?.get("amount")?.jsonPrimitive?.doubleOrNull,
                    nonUsdCostSource = nonUsd?.let { costSourceName(it.str("costSource")) },
                ),
            )
        }

        val counts = billedMessageCountByProvider(
            dao.observeMonthlyBilledMessageCountByProvider(ACCOUNT, CostFormatter.COST_EPSILON, MONTH_START, MONTH_END).first(),
        )
        val usd = dao.getMonthlyCostByProviderKind(ACCOUNT, CostFormatter.COST_EPSILON, MONTH_START, MONTH_END)
            .groupBy { normalizeUuid(it.providerID) }
            .mapValues { (_, rows) -> CostParts.usdAmount(CostParts.split(rows.map { it.currencyCode to it.totalCost })) }

        val spotlight = computeSpotlightProviders(
            providers = providers,
            billedMessageCountByProvider = counts,
            monthlyUsdCostByProvider = usd,
        )

        val expected = raw["expect"]!!.jsonObject["spotlightProviderIds"]!!.jsonArray.map { normalizeUuid(it.jsonPrimitive.content) }
        assertEquals(id, expected, spotlight.map { it.id })
        assertEquals(fixture["spotlightCount"]!!.jsonObject["android"]!!.jsonPrimitive.int, spotlight.size)
    }

    @Test
    fun `fixture cases are all covered`() {
        assertEquals(
            setOf(
                "cny_only_provider_can_win",
                "message_count_beats_usd_amount",
                "tie_breaks_by_usd_then_status",
                "full_tie_keeps_list_order",
                "no_cost_falls_back_to_status",
                "unrecorded_messages_not_counted",
            ),
            cases.map { it["id"]!!.jsonPrimitive.content }.toSet(),
        )
    }

    @Test fun PROVIDER_SPOTLIGHT_cny_only_provider_can_win() = runCase("cny_only_provider_can_win")

    @Test fun PROVIDER_SPOTLIGHT_message_count_beats_usd_amount() = runCase("message_count_beats_usd_amount")

    @Test fun PROVIDER_SPOTLIGHT_tie_breaks_by_usd_then_status() = runCase("tie_breaks_by_usd_then_status")

    @Test fun PROVIDER_SPOTLIGHT_full_tie_keeps_list_order() = runCase("full_tie_keeps_list_order")

    @Test fun PROVIDER_SPOTLIGHT_no_cost_falls_back_to_status() = runCase("no_cost_falls_back_to_status")

    @Test fun PROVIDER_SPOTLIGHT_unrecorded_messages_not_counted() = runCase("unrecorded_messages_not_counted")

    private companion object {
        const val ACCOUNT = "account-1"
        // All fixture messages fall in the month: a half-open 2026-10-01 to 2026-11-01 UTC window
        const val MONTH_START = 1_790_812_800_000L
        const val MONTH_END = 1_793_491_200_000L
    }
}
