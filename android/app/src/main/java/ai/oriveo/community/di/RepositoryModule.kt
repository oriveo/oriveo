package ai.oriveo.community.di

import android.content.Context
import androidx.room.withTransaction
import ai.oriveo.community.core.app.AppPreferencesRepository
import ai.oriveo.community.core.app.GlobalSnackbarManager
import ai.oriveo.community.core.data.database.OriveoDatabase

import ai.oriveo.community.core.data.backup.BackupService
import ai.oriveo.community.core.data.backup.ConversationExporter
import ai.oriveo.community.core.data.repository.ChatRepository
import ai.oriveo.community.core.data.repository.ConversationRepository
import ai.oriveo.community.core.data.repository.FolderRepository
import ai.oriveo.community.core.data.repository.ProviderRepository
import kotlinx.coroutines.CoroutineScope
import org.koin.android.ext.koin.androidContext
import org.koin.core.qualifier.named
import org.koin.dsl.module

val repositoryModule = module {
    single {
        val db = get<OriveoDatabase>()
        AppPreferencesRepository(
            preferenceDao = get(),
            runInTransaction = { block -> db.withTransaction { block() } },
            appContext = get(),
        )
    }
    single { GlobalSnackbarManager() }

    single {
        val db = get<OriveoDatabase>()
        ProviderRepository(
            dao = get(),
            conversationDao = get(),
            secureKeyStore = get(),
            openRouterService = get(),
            openAIService = get(),
            deepSeekService = get(),
            grokService = get(),
            anthropicService = get(),
            geminiService = get(),
            groqService = get(),
            togetherService = get(),
            fireworksService = get(),
            miniMaxService = get(),
            zhipuService = get(),
            qwenService = get(),
            moonshotService = get(),
            mistralService = get(),
            siliconFlowService = get(),
            relayService = get(),
            metadataRefreshEventBus = get(),
            httpClient = get(),
            runInTransaction = { block -> db.withTransaction { block() } },
            capabilityPreferenceStore = ai.oriveo.community.core.model.CapabilityPreferenceStore.from(androidContext()),
            localCapabilityCustomFragmentStore = ai.oriveo.community.core.model.LocalCapabilityCustomFragmentStore.from(androidContext()),
            toolCallMemoryStore = get(),
            preferenceDao = get(),
        )
    }

    single {
        val db = get<OriveoDatabase>()
        ConversationRepository(
            conversationDao = get(),
            messageDao = get(),
            runInTransaction = { block -> db.withTransaction { block() } },
            continuationDao = get(),
            searchIndexer = get(),
        )
    }

    single {
        FolderRepository(
            folderDao = get(),
            conversationDao = get(),
        )
    }

    single {
        ai.oriveo.community.core.data.repository.NoteRepository(
            noteDao = get(),
            noteFolderDao = get(),
        )
    }

    single { ai.oriveo.community.core.provider.MessageContinuationStore(get(), get()) }
    single {
        ai.oriveo.community.core.provider.ToolCallMemoryStore(
            prefsProvider = {
                androidContext().getSharedPreferences(
                    ai.oriveo.community.core.provider.ToolCallMemoryStore.PREFS_NAME,
                    Context.MODE_PRIVATE,
                )
            },
            json = get(),
        )
    }

    single {
        ChatRepository(
            conversationRepository = get(),
            providerRepository = get(),
            attachmentStore = get(),
            continuationStore = get(),
            continuationAccountId = { ai.oriveo.community.core.data.database.LOCAL_PARTITION_ID },
            toolCallMemoryStore = get(),
            mcpChatToolRunner = get(),
        )
    }

    // ── Remote MCP servers ──────────────────────────────────

    single {
        ai.oriveo.community.core.mcp.McpServerStore(
            dao = get(),
            credentials = get(),
            grants = get(),
        )
    }
    // "Allow for the rest of this conversation". The chat send path reads it, and the storage
    // layer revokes from it when a permission, a tool or a server changes, so the whole app must
    // share this one instance.
    single { ai.oriveo.community.core.mcp.McpConversationGrants() }
    single { ai.oriveo.community.core.mcp.McpConfirmationCoordinator() }
    // Wires remote MCP into the chat send path. The confirmation gate is the chat screen's
    // confirmation dialog: without the user's consent no `tools/call` is sent.
    single {
        ai.oriveo.community.core.mcp.McpChatToolRunner(
            httpClient = get(),
            json = get(),
            store = get(),
            credentialStore = get(),
            grants = get(),
            // Read on every send, so limits from a refreshed catalog apply without a restart.
            runtimeConfig = { ai.oriveo.community.core.data.remote.MetadataClient.mcpRuntimeConfig() },
            // Shared with the add flow and the management screens: token refreshes are serialized
            // per authorizer instance, and two instances refreshing on their own would spend a
            // rotating refresh token twice.
            authorizer = get(),
            mcpTransport = { get<ai.oriveo.community.core.mcp.McpRawTransport>() },
            writeScope = get(named("applicationScope")),
        ).also { runner ->
            runner.confirmationGate = get<ai.oriveo.community.core.mcp.McpConfirmationCoordinator>()
            // "Re-authorize" in the chat screen (tool panel, step blocks) goes through the same
            // entry point as the management screens. Resolved lazily: it is only needed once the
            // user taps it, not while the chat loop is being assembled.
            runner.reauthorizer = ai.oriveo.community.core.mcp.McpReauthorizer { serverId ->
                get<ai.oriveo.community.core.mcp.McpReauthorizationCoordinator>().reauthorize(serverId)
            }
        }
    }

    // Operations on a stored server (re-read tools, confirm changes, re-authorize, remove) and
    // the coordination of the re-authorization dialog.
    single {
        val transport = get<ai.oriveo.community.core.mcp.McpRawTransport>()
        ai.oriveo.community.core.mcp.McpServerActions(
            store = get(),
            credentialStore = get(),
            runtimeConfig = { ai.oriveo.community.core.data.remote.MetadataClient.mcpRuntimeConfig() },
            authorizer = get(),
            makeClient = { endpoint, config -> ai.oriveo.community.core.mcp.McpClient(endpoint, config, transport) },
        )
    }
    single {
        ai.oriveo.community.core.mcp.McpReauthorizationCoordinator(
            actions = get(),
            store = get(),
        )
    }

    // Browser sign-in: Custom Tabs opens the authorization page, and the redirect comes back
    // through a trampoline activity into the router.
    single { ai.oriveo.community.core.mcp.McpOAuthCallbackRouter() }
    single { ai.oriveo.community.core.mcp.McpAuthorizationPageLauncher(androidContext()) }
    single<ai.oriveo.community.core.mcp.McpBrowserSession> {
        ai.oriveo.community.core.mcp.McpAppBrowserSession(
            router = get(),
            openPage = get<ai.oriveo.community.core.mcp.McpAuthorizationPageLauncher>()::open,
        )
    }
    single<ai.oriveo.community.core.mcp.McpRawTransport> { ai.oriveo.community.core.mcp.KtorMcpRawTransport() }
    single {
        ai.oriveo.community.core.mcp.McpAuthorizer(
            transport = ai.oriveo.community.core.mcp.McpHttpAuthTransport(get<ai.oriveo.community.core.mcp.McpRawTransport>()),
            browser = get(),
            credentialStore = get(),
        )
    }
    // The add flow reads the limits afresh for every addition.
    factory {
        val config = ai.oriveo.community.core.data.remote.MetadataClient.mcpRuntimeConfig()
        val transport = get<ai.oriveo.community.core.mcp.McpRawTransport>()
        ai.oriveo.community.core.mcp.McpAddCoordinator(
            probe = ai.oriveo.community.core.mcp.McpAddProbe(
                authorizer = get(),
                credentialStore = get(),
                makeClient = { endpoint -> ai.oriveo.community.core.mcp.McpClient(endpoint, config, transport) },
                runtimeConfig = config,
            ),
            store = get(),
            credentialStore = get(),
            runtimeConfig = config,
        )
    }

    single {
        ai.oriveo.community.core.streaming.ChatStreamingManager(
            chatRepository = get(),
        )
    }

    single {
        ai.oriveo.community.core.streaming.StreamingLifecycleObserver(
            chatStreamingManager = get(),
        )
    }

    single {
        val db = get<OriveoDatabase>()
        BackupService(
            providerDao = get(),
            conversationDao = get(),
            messageDao = get(),
            folderDao = get(),
            skillDao = get(),
            noteDao = get(),
            noteFolderDao = get(),
            json = get(),
            secureKeyStore = get(),
            attachmentStore = get(),
            preferenceDao = get(),
            runInTransaction = { block -> db.withTransaction { block() } },
        )
    }

    single {
        ConversationExporter(
            conversationDao = get(),
            messageDao = get(),
        )
    }

    single {
        ai.oriveo.community.core.data.repair.MessageAttachmentRepairTask(
            messageDao = get(),
            preferenceDao = get(),
            attachmentStore = get(),
        )
    }
}
