package ai.oriveo.community.di

import ai.oriveo.community.core.reachability.ServiceReachabilityMonitor
import org.koin.android.ext.koin.androidContext
import org.koin.dsl.module

val reachabilityModule = module {
    single { ServiceReachabilityMonitor(androidContext()) }
}
