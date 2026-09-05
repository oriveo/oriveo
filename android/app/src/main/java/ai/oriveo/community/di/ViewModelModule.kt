package ai.oriveo.community.di

import ai.oriveo.community.core.app.AppViewModel
import ai.oriveo.community.feature.backup.BackupViewModel
import ai.oriveo.community.feature.chat.ChatViewModel
import ai.oriveo.community.feature.home.HomeViewModel
import ai.oriveo.community.feature.notes.NoteDetailViewModel
import ai.oriveo.community.feature.notes.NotesViewModel
import ai.oriveo.community.feature.onboarding.OnboardingViewModel
import ai.oriveo.community.feature.providers.ProvidersViewModel
import ai.oriveo.community.feature.providers.SubscriptionAuthorizationViewModel
import ai.oriveo.community.feature.providers.detail.ProviderDetailViewModel
import ai.oriveo.community.feature.providers.manual.ManualModelEntryViewModel
import ai.oriveo.community.feature.providers.relay.RelaySetupViewModel
import ai.oriveo.community.feature.providers.local.LocalComputeSetupViewModel
import ai.oriveo.community.feature.providers.setup.ProviderSetupViewModel
import ai.oriveo.community.feature.settings.MemoryViewModel
import ai.oriveo.community.feature.settings.SettingsViewModel
import ai.oriveo.community.core.model.GenerationParameterSettingsStore
import ai.oriveo.community.core.model.GenerationParameterPresetStore
import kotlinx.coroutines.Dispatchers
import org.koin.core.qualifier.named
import org.koin.core.module.dsl.viewModel
import org.koin.core.module.dsl.viewModelOf
import org.koin.dsl.module
import org.koin.android.ext.koin.androidContext

val viewModelModule = module {
    viewModel { SubscriptionAuthorizationViewModel(httpClient = get(), savedState = get()) }
    viewModel {
        AppViewModel(
            appPreferencesRepository = get(),
            providerRepository = get(),
            globalSnackbarManager = get(),
            skillRepository = get(),
            databaseHealthProbe = get(),
        )
    }
    viewModelOf(::OnboardingViewModel)
    viewModel {
        ProviderSetupViewModel(
            context = get(),
            providerRepository = get(),
            appPreferencesRepository = get(),
            globalSnackbarManager = get(),
        )
    }
    viewModel {
        ChatViewModel(
            savedStateHandle = get(),
            context = get(),
            appPreferencesRepository = get(),
            providerRepository = get(),
            conversationRepository = get(),
            noteRepository = get(),
            chatStreamingManager = get(),
            skillRepository = get(),
            attachmentProcessor = get(),
            globalSnackbarManager = get(),
            applicationScope = get(named("applicationScope")),
        )
    }
    viewModel {
        HomeViewModel(
            appPreferencesRepository = get(),
            providerRepository = get(),
            conversationRepository = get(),
            folderRepository = get(),
            noteRepository = get(),
            globalSnackbarManager = get(),
            skillRepository = get(),
            chatStreamingManager = get(),
            ioDispatcher = Dispatchers.IO,
            generationParameterSettingsStore = GenerationParameterSettingsStore.from(androidContext()),
            capabilityPreferenceStore = ai.oriveo.community.core.model.CapabilityPreferenceStore.from(androidContext()),
            localCustomFragmentStore = ai.oriveo.community.core.model.LocalCapabilityCustomFragmentStore.from(androidContext()),
        )
    }
    viewModel {
        NotesViewModel(
            noteRepository = get(),
            globalSnackbarManager = get(),
            appPreferencesRepository = get(),
        )
    }
    viewModel {
        NoteDetailViewModel(
            savedStateHandle = get(),
            noteRepository = get(),
            providerRepository = get(),
            appPreferencesRepository = get(),
            globalSnackbarManager = get(),
        )
    }
    viewModel {
        ProvidersViewModel(
            providerRepository = get(),
            conversationRepository = get(),
            metadataRefreshEventBus = get(),
            providerBalanceRepository = get(),
            generationParameterSettingsStore = GenerationParameterSettingsStore.from(androidContext()),
            capabilityPreferenceStore = ai.oriveo.community.core.model.CapabilityPreferenceStore.from(androidContext()),
            localCustomFragmentStore = ai.oriveo.community.core.model.LocalCapabilityCustomFragmentStore.from(androidContext()),
            generationParameterPresetStore = GenerationParameterPresetStore.from(androidContext()),
        )
    }
    viewModel {
        ProviderDetailViewModel(
            savedStateHandle = get(),
            providerRepository = get(),
            appPreferencesRepository = get(),
            metadataRefreshEventBus = get(),
            applicationScope = get(named("applicationScope")),
            globalSnackbarManager = get(),
            providerBalanceRepository = get(),
            generationParameterSettingsStore = GenerationParameterSettingsStore.from(androidContext()),
            capabilityPreferenceStore = ai.oriveo.community.core.model.CapabilityPreferenceStore.from(androidContext()),
            localCustomFragmentStore = ai.oriveo.community.core.model.LocalCapabilityCustomFragmentStore.from(androidContext()),
            generationParameterPresetStore = GenerationParameterPresetStore.from(androidContext()),
        )
    }
    viewModelOf(::SettingsViewModel)
    viewModelOf(::MemoryViewModel)
    viewModel { BackupViewModel(get(), get(), androidContext().cacheDir, Dispatchers.IO) }
    viewModelOf(::ManualModelEntryViewModel)
    viewModelOf(::RelaySetupViewModel)
    viewModelOf(::LocalComputeSetupViewModel)
}
