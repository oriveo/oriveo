package ai.oriveo.community.di

import ai.oriveo.community.core.voice.AndroidReadAloudEnvironment
import ai.oriveo.community.core.voice.ReadAloudController
import ai.oriveo.community.core.voice.SystemSpeechEngine
import org.koin.android.ext.koin.androidContext
import org.koin.dsl.module

/** Global Koin modules. */
val appModule = module {
    includes(
        databaseModule,
        networkModule,
        securityModule,
        reachabilityModule,
        providerModule,
        repositoryModule,
        skillModule,
        viewModelModule,
    )
    single {
        ReadAloudController(
            engine = SystemSpeechEngine(androidContext()),
            environment = AndroidReadAloudEnvironment(androidContext(), get()),
        )
    }
}
