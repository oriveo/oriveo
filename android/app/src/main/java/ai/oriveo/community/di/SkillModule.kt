package ai.oriveo.community.di

import ai.oriveo.community.core.data.repository.SkillCatalogPrefsStore
import ai.oriveo.community.core.data.repository.SkillRepository
import ai.oriveo.community.feature.skills.SkillViewModel
import org.koin.android.ext.koin.androidContext
import org.koin.core.module.dsl.viewModel
import org.koin.dsl.module

val skillModule = module {
    single { SkillCatalogPrefsStore(context = androidContext()) }
    single {
        SkillRepository(
            dao = get(),
            catalogStore = get(),
        )
    }
    viewModel {
        SkillViewModel(
            skillRepository = get(),
            providerRepository = get(),
            conversationRepository = get(),
            appPreferencesRepository = get(),
            globalSnackbarManager = get(),
            capabilityPreferenceStore = ai.oriveo.community.core.model.CapabilityPreferenceStore.from(androidContext()),
        )
    }
}
