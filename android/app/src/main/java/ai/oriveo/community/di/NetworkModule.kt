package ai.oriveo.community.di

import ai.oriveo.community.BuildConfig
import ai.oriveo.community.core.data.remote.HttpUrlConnectionMetadataSplitTransport
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
import io.ktor.client.engine.KTOR_DEFAULT_USER_AGENT
import io.ktor.http.HttpHeaders

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
                    addInterceptor(nativeUserAgentInterceptor())
                }
            }
        }
    }

    single { MetadataRefreshEventBus() }
    single {
        MetadataClient(
            androidContext(),
            metadataCacheDao = get(),
            metadataSplitTransport = HttpUrlConnectionMetadataSplitTransport(),
        )
    }

    single<CoroutineScope>(named("applicationScope")) {
        CoroutineScope(SupervisorJob() + Dispatchers.Default)
    }
}

/**
 * Writes [NativeUserAgent] only for requests that have no UA or carry only the Ktor engine default UA ([KTOR_DEFAULT_USER_AGENT]).
 * A UA explicitly set by the caller (Relay customUserAgent, Codex identity UA) must go out unchanged and must not be overridden here.
 */
// KTOR_DEFAULT_USER_AGENT is marked InternalAPI; use it directly instead of copying the literal, so this follows when Ktor changes the default.
@OptIn(io.ktor.utils.io.InternalAPI::class)
internal fun nativeUserAgentInterceptor(
    nativeUserAgent: () -> String = NativeUserAgent::current,
): okhttp3.Interceptor = okhttp3.Interceptor { chain ->
    val request = chain.request()
    val existing = request.header(HttpHeaders.UserAgent)
    if (existing.isNullOrBlank() || existing == KTOR_DEFAULT_USER_AGENT) {
        chain.proceed(request.newBuilder().header(HttpHeaders.UserAgent, nativeUserAgent()).build())
    } else {
        chain.proceed(request)
    }
}
