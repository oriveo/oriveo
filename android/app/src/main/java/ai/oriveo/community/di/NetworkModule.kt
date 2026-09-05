package ai.oriveo.community.di

import ai.oriveo.community.BuildConfig
import ai.oriveo.community.core.data.remote.MetadataClient
import ai.oriveo.community.core.data.remote.MetadataRefreshEventBus
import ai.oriveo.community.core.network.NativeUserAgent
import io.ktor.client.HttpClient
import io.ktor.client.engine.okhttp.OkHttp
import io.ktor.client.plugins.contentnegotiation.ContentNegotiation
import io.ktor.client.plugins.logging.LogLevel
import io.ktor.client.plugins.logging.Logging
import io.ktor.serialization.kotlinx.json.json
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.serialization.json.Json
import org.koin.android.ext.koin.androidContext
import org.koin.core.qualifier.named
import org.koin.dsl.module
import java.util.concurrent.TimeUnit

val networkModule = module {
    single {
        Json {
            ignoreUnknownKeys = true
            isLenient = true
            encodeDefaults = true
            coerceInputValues = true
        }
    }

    single {
        HttpClient(OkHttp) {
            install(ContentNegotiation) {
                json(get<Json>())
            }
            if (BuildConfig.DEBUG) {
                install(Logging) {
                    level = LogLevel.INFO
                    sanitizeHeader { header ->
                        val lower = header.lowercase()
                        lower == "authorization" ||
                            lower == "x-api-key" ||
                            lower == "x-goog-api-key" ||
                            lower == "api-key" ||
                            lower.contains("token") ||
                            lower.contains("secret") ||
                            lower.contains("key")
                    }
                }
            }
            engine {
                config {
                    retryOnConnectionFailure(true)
                    connectTimeout(20, TimeUnit.SECONDS)
                    readTimeout(180, TimeUnit.SECONDS)
                    writeTimeout(60, TimeUnit.SECONDS)
                    addInterceptor { chain ->
                        val request = chain.request().newBuilder()
                            .header("User-Agent", NativeUserAgent.current())
                            .build()
                        chain.proceed(request)
                    }
                }
            }
        }
    }

    single { MetadataRefreshEventBus() }
    single { MetadataClient(androidContext(), metadataCacheDao = get()) }

    single<CoroutineScope>(named("applicationScope")) {
        CoroutineScope(SupervisorJob() + Dispatchers.Default)
    }
}
