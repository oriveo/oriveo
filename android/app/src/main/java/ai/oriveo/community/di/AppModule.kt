package ai.oriveo.community.di

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
}
