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
        )
    }

    single {
        val db = get<OriveoDatabase>()
        ConversationRepository(
            conversationDao = get(),
            messageDao = get(),
            runInTransaction = { block -> db.withTransaction { block() } },
            continuationDao = get(),
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
