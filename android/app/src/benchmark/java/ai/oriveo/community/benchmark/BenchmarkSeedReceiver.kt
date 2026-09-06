package ai.oriveo.community.benchmark

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.os.Binder
import android.os.Process
import android.util.Log
import ai.oriveo.community.core.app.AppPreferenceKeys
import ai.oriveo.community.core.app.AppPreferencesRepository
import ai.oriveo.community.core.data.database.LOCAL_PARTITION_ID
import ai.oriveo.community.core.data.EntityMapper.toEntity
import ai.oriveo.community.core.data.dao.ConversationDao
import ai.oriveo.community.core.data.dao.MessageDao
import ai.oriveo.community.core.data.dao.PreferenceDao
import ai.oriveo.community.core.data.dao.ProviderDao
import ai.oriveo.community.core.model.AIModel
import ai.oriveo.community.core.model.ChatMessage
import ai.oriveo.community.core.model.ChatMessageState
import ai.oriveo.community.core.model.ChatRole
import ai.oriveo.community.core.model.Conversation
import ai.oriveo.community.core.model.ModelCapability
import ai.oriveo.community.core.model.Provider
import ai.oriveo.community.core.model.ProviderConnectionState
import ai.oriveo.community.core.model.ProviderKind
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.launch
import org.koin.core.context.GlobalContext

class BenchmarkSeedReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action != ACTION_SEED_BENCHMARK_DATA) return

        val callingUid = Binder.getCallingUid()
        if (!isShellOrAppUid(callingUid)) {
            Log.w(TAG, "Ignoring seed broadcast from uid=$callingUid")
            return
        }

        val pendingResult = goAsync()
        CoroutineScope(SupervisorJob() + Dispatchers.IO).launch {
            try {
                Log.i(TAG, "Received seed broadcast")
                BenchmarkDataSeeder.seed()
                Log.i(TAG, "Seed broadcast finished")
            } catch (t: Throwable) {
                Log.e(TAG, "Seed broadcast failed", t)
            } finally {
                pendingResult.finish()
            }
        }
    }

    private fun isShellOrAppUid(callingUid: Int): Boolean {
        return callingUid == SHELL_UID ||
            callingUid == Process.SYSTEM_UID ||
            callingUid == Process.myUid()
    }

    companion object {
        const val ACTION_SEED_BENCHMARK_DATA = "ai.oriveo.community.action.SEED_BENCHMARK_DATA"
        private const val SHELL_UID = 2000
        private const val TAG = "BenchmarkSeed"
    }
}

private object BenchmarkDataSeeder {
    private const val ACCOUNT_ID = LOCAL_PARTITION_ID
    private const val PROVIDER_ID = "7B2A9C8A-4017-4FD0-8E1D-0BC90BFC7D6D"
    private const val RELAY_PROVIDER_ID = "benchmark-local-relay"
    private const val TARGET_CONVERSATION_ID = "C9FBA7B8-F541-4929-AD47-C4272CC764D9"
    private const val TARGET_CONVERSATION_TITLE = "Rendering cost on the chat screen"
    private const val MODEL_ID = "gpt-4.1-mini"
    private const val MODEL_NAME = "GPT-4.1 mini"

    private val benchmarkModel = AIModel(
        id = MODEL_ID,
        name = MODEL_NAME,
        capabilities = listOf(
            ModelCapability.Text,
            ModelCapability.Reasoning,
            ModelCapability.Image,
            ModelCapability.File,
        ),
        isDefault = true,
        isRecommended = true,
        priceTier = "$",
        summary = "128K context",
        contextLength = 128_000,
    )

    suspend fun seed() {
        val koin = GlobalContext.get()
        val appPreferencesRepository = koin.get<AppPreferencesRepository>()
        val preferenceDao = koin.get<PreferenceDao>()
        val providerDao = koin.get<ProviderDao>()
        val conversationDao = koin.get<ConversationDao>()
        val messageDao = koin.get<MessageDao>()

        Log.i("BenchmarkSeed", "Seeding benchmark fixture data")
        conversationDao.deleteByAccount(ACCOUNT_ID)
        providerDao.deleteByAccount(ACCOUNT_ID)

        val now = System.currentTimeMillis()
        val provider = Provider(
            id = PROVIDER_ID,
            kind = ProviderKind.OpenAI,
            status = ProviderConnectionState.Connected,
            models = listOf(benchmarkModel),
            catalogModels = listOf(benchmarkModel),
            apiKeyPreview = "sk-••••bench",
            updatedAt = now,
        )
        val finalized = ai.oriveo.community.core.provider.prepareProviderForUpsert(provider)
        providerDao.upsert(finalized.toEntity(ACCOUNT_ID))
        providerDao.upsert(largeCatalogBenchmarkProvider(now).toEntity(ACCOUNT_ID))

        sampleConversations(now).forEach { seededConversation ->
            conversationDao.upsert(seededConversation.conversation.toEntity(ACCOUNT_ID))
            seededConversation.messages.forEachIndexed { index, message ->
                messageDao.upsert(message.toEntity(ACCOUNT_ID, seededConversation.conversation.id, index))
            }
        }

        appPreferencesRepository.completeOnboarding()
        appPreferencesRepository.setLastUsedModel(PROVIDER_ID, MODEL_ID)

        Log.i(
            "BenchmarkSeed",
            "Seed complete providers=${providerDao.countByAccount(ACCOUNT_ID)} " +
                "conversations=${conversationDao.countByAccount(ACCOUNT_ID)} " +
                "onboarding=${preferenceDao.get(AppPreferenceKeys.ONBOARDING_COMPLETED)} " +
                "account=$ACCOUNT_ID",
        )
    }

    /** A relay holding 32 models across four vendors, so the picker has a real catalog to render. */
    private fun largeCatalogBenchmarkProvider(now: Long): Provider {
        val vendors = listOf(
            "openai" to "OpenAI",
            "anthropic" to "Anthropic",
            "google" to "Google Gemini",
            "deepseek" to "DeepSeek",
        )
        val models = List(32) { index ->
            val (groupKey, groupName) = vendors[index % vendors.size]
            AIModel(
                id = "benchmark-model-$index",
                name = "$groupName Benchmark Model $index",
                capabilities = listOf(
                    ModelCapability.Text,
                    ModelCapability.Image,
                    ModelCapability.File,
                    ModelCapability.NativePdf,
                ),
                groupKey = groupKey,
                groupName = groupName,
                promptPrice = 0.000005,
                completionPrice = 0.000025,
                priceTier = "\$5 / 1M input · \$25 / 1M output · \$0.5 / 1M cache-read",
            )
        }
        return Provider(
            id = RELAY_PROVIDER_ID,
            // Uses a Relay container to reproduce the same multi-vendor, large-catalog rendering
            // load, so the benchmark doesn't depend on network access or a signed-in state.
            kind = ProviderKind.Relay,
            status = ProviderConnectionState.Connected,
            models = models,
            catalogModels = models,
            customName = "Local Relay",
            cachedAvailableModelCount = models.size,
            updatedAt = now,
        )
    }

    private fun sampleConversations(now: Long): List<SeededConversation> = listOf(
        SeededConversation(
            conversation = Conversation(
                id = "3A2D0A11-4C1E-4A8B-90A6-1B93E76B6C11",
                title = "Plan for today",
                hasCustomTitle = true,
                providerID = PROVIDER_ID,
                providerKind = ProviderKind.OpenAI,
                modelID = MODEL_ID,
                previewText = "Fix the home and chat screen frame times first, then add a regression run.",
                createdAt = now - 3_600_000,
                updatedAt = now - 1_000,
            ),
            messages = listOf(
                userMessage(
                    id = "F6D572AE-A8D0-4B11-9A0D-06AEF27C3A31",
                    text = "What should we start with today?",
                    createdAt = now - 3_600_000,
                ),
                assistantMessage(
                    id = "E0F4D86B-0637-4B0F-BD10-3B2A89F1A212",
                    text = "Fix the home and chat screen frame times first, then add a regression run.",
                    createdAt = now - 3_599_000,
                ),
            ),
        ),
        SeededConversation(
            conversation = Conversation(
                id = TARGET_CONVERSATION_ID,
                title = TARGET_CONVERSATION_TITLE,
                hasCustomTitle = true,
                providerID = PROVIDER_ID,
                providerKind = ProviderKind.OpenAI,
                modelID = MODEL_ID,
                previewText = "Splitting this into causes, risks and a fix order.",
                createdAt = now - 7_200_000,
                updatedAt = now - 2_000,
            ),
            messages = listOf(
                userMessage(
                    id = "A2E4B80D-E89A-4A77-A0E0-FDDB43B5C871",
                    text = TARGET_CONVERSATION_TITLE,
                    createdAt = now - 7_200_000,
                ),
                assistantMessage(
                    id = "CB11A76E-3A34-4FA1-AB20-9D817BDB784F",
                    text = """
                        Splitting this into causes and a fix order.

                        ## Where the time goes
                        1. The home screen's first composition is doing too much work.
                        2. Markdown parsing and highlighting run on the main thread.
                        3. Returning to a conversation stacks another listener and scroll state.

                        ```kotlin
                        if (route == "home" && targetConversation == TARGET) {
                            openConversation()
                            renderMarkdownOffMainThread()
                        }
                        ```

                        ## Fix order
                        - Cut the shadow, canvas and blur cost on the home cards first.
                        - Then move Markdown work off the main thread entirely.
                        - Finally pin the result with a repeatable benchmark.
                    """.trimIndent(),
                    createdAt = now - 7_199_000,
                ),
            ),
        ),
        SeededConversation(
            conversation = Conversation(
                id = "779FFB85-43A2-4372-B947-EFA7A2A640FA",
                title = "Spend alerts",
                hasCustomTitle = true,
                providerID = PROVIDER_ID,
                providerKind = ProviderKind.OpenAI,
                modelID = MODEL_ID,
                previewText = "Warn once when the month is close to its threshold.",
                createdAt = now - 10_800_000,
                updatedAt = now - 3_000,
            ),
            messages = listOf(
                userMessage(
                    id = "7780D0C4-268B-4D8A-A5B0-C2E465264B81",
                    text = "What is a sensible way to warn about spend?",
                    createdAt = now - 10_800_000,
                ),
                assistantMessage(
                    id = "D45C46A2-D28A-45DE-8723-4B817B1ED485",
                    text = "One threshold for the month and one per provider, so the home screen interrupts rarely.",
                    createdAt = now - 10_799_000,
                ),
            ),
        ),
        SeededConversation(
            conversation = Conversation(
                id = "D0D11A6D-7F0F-4892-AB53-809C40657BF6",
                title = "Choosing a provider",
                hasCustomTitle = true,
                providerID = PROVIDER_ID,
                providerKind = ProviderKind.OpenAI,
                modelID = MODEL_ID,
                previewText = "Keep only recently used models on the home screen.",
                createdAt = now - 14_400_000,
                updatedAt = now - 4_000,
            ),
            messages = listOf(
                userMessage(
                    id = "B6AD4D48-2BA8-4B48-93C9-95A0B90D25F5",
                    text = "How many providers should the home screen show?",
                    createdAt = now - 14_400_000,
                ),
                assistantMessage(
                    id = "3A5604F9-ED6C-4D81-B808-29BEE9CF4F4A",
                    text = "Show the last one used and put the rest behind the switcher.",
                    createdAt = now - 14_399_000,
                ),
            ),
        ),
        SeededConversation(
            conversation = Conversation(
                id = "41DAF3AA-601C-402F-B0DA-A2F53F88528D",
                title = "Attachments",
                hasCustomTitle = true,
                providerID = PROVIDER_ID,
                providerKind = ProviderKind.OpenAI,
                modelID = MODEL_ID,
                previewText = "Store the bytes out of line and keep only a pointer on the message.",
                createdAt = now - 18_000_000,
                updatedAt = now - 5_000,
            ),
            messages = listOf(
                userMessage(
                    id = "5F74A8FE-9439-4661-9E5B-BAB64218C9CB",
                    text = "Where should large attachments be stored?",
                    createdAt = now - 18_000_000,
                ),
                assistantMessage(
                    id = "E91B3D94-E0CF-47FD-9BB2-54B6E7605761",
                    text = "Keep the bytes in the attachment store and only the metadata on the message.",
                    createdAt = now - 17_999_000,
                ),
            ),
        ),
    )

    private fun userMessage(
        id: String,
        text: String,
        createdAt: Long,
    ) = ChatMessage(
        id = id,
        role = ChatRole.User,
        text = text,
        providerID = PROVIDER_ID,
        providerKind = ProviderKind.OpenAI,
        providerName = ProviderKind.OpenAI.displayName,
        modelID = MODEL_ID,
        modelName = MODEL_NAME,
        state = ChatMessageState.Delivered,
        createdAt = createdAt,
    )

    private fun assistantMessage(
        id: String,
        text: String,
        createdAt: Long,
    ) = ChatMessage(
        id = id,
        role = ChatRole.Assistant,
        text = text,
        providerID = PROVIDER_ID,
        providerKind = ProviderKind.OpenAI,
        providerName = ProviderKind.OpenAI.displayName,
        modelID = MODEL_ID,
        modelName = MODEL_NAME,
        state = ChatMessageState.Delivered,
        createdAt = createdAt,
    )

    private data class SeededConversation(
        val conversation: Conversation,
        val messages: List<ChatMessage>,
    )
}
