package ai.oriveo.community

import android.app.Application
import androidx.compose.foundation.ComposeFoundationFlags
import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.lifecycle.ProcessLifecycleOwner
import ai.oriveo.community.core.app.AppLanguageManager
import ai.oriveo.community.core.app.AppPreferencesRepository
import ai.oriveo.community.core.data.database.DatabaseHealthProbe
import ai.oriveo.community.core.data.remote.MetadataClient
import ai.oriveo.community.core.data.remote.MetadataRefreshEventBus
import ai.oriveo.community.core.data.repository.SkillRepository
import ai.oriveo.community.core.model.LanguageOption
import ai.oriveo.community.core.performance.DebugMainThreadDiagnostics
import ai.oriveo.community.core.provider.GenerationParameterDiagnosticStore
import ai.oriveo.community.core.provider.ModelControlRejectionCache
import ai.oriveo.community.core.provider.ToolCallMemoryStore
import ai.oriveo.community.core.security.SecureKeyStore
import ai.oriveo.community.core.streaming.StreamingLifecycleObserver
import ai.oriveo.community.di.appModule
import com.tom_roush.pdfbox.android.PDFBoxResourceLoader
import io.ktor.client.HttpClient
import kotlinx.coroutines.CoroutineExceptionHandler
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.launch
import org.koin.android.ext.koin.androidContext
import org.koin.core.context.startKoin

/**
 * Process entry point. Wires the dependency graph, then warms the caches that the
 * first screen reads so the home list does not render empty on a cold start.
 */
class OriveoApplication : Application() {

    @Volatile
    private var databaseHealthProbe: DatabaseHealthProbe? = null

    private val appScopeExceptionHandler = CoroutineExceptionHandler { _, error ->
        if (databaseHealthProbe?.recordEscapedFailure(error) == true) return@CoroutineExceptionHandler
        Thread.currentThread().let { thread ->
            thread.uncaughtExceptionHandler?.uncaughtException(thread, error)
        }
    }

    private val appScope = CoroutineScope(SupervisorJob() + Dispatchers.IO + appScopeExceptionHandler)

    @OptIn(ExperimentalFoundationApi::class)
    override fun onCreate() {
        super.onCreate()
        GenerationParameterDiagnosticStore.configure(this)
        ModelControlRejectionCache.configure(this)
        appScope.launch { ModelControlRejectionCache.prewarm() }
        ComposeFoundationFlags.isNewContextMenuEnabled = false
        PDFBoxResourceLoader.init(applicationContext)
        ai.oriveo.community.core.performance.PageTrace.begin("AppLaunch")
        if (BuildConfig.DEBUG) {
            DebugMainThreadDiagnostics.install()
        }

        val koinApp = startKoin {
            androidContext(this@OriveoApplication)
            modules(appModule)
        }
        MetadataClient.instance = koinApp.koin.get()
        val databaseHealthProbe = koinApp.koin.get<DatabaseHealthProbe>()
        this.databaseHealthProbe = databaseHealthProbe
        appScope.launch { databaseHealthProbe.awaitHealthy() }

        val languageValue = getSharedPreferences("oriveo_prefs", MODE_PRIVATE)
            .getString("app_language", null)
        val language = AppPreferencesRepository.parseLanguagePreference(languageValue)
            ?: LanguageOption.System
        AppLanguageManager.apply(language)

        appScope.launch { koinApp.koin.get<SecureKeyStore>().prewarm() }
        appScope.launch { koinApp.koin.get<SkillRepository>().prewarm() }

        appScope.launch { koinApp.koin.get<ToolCallMemoryStore>().prewarm() }

        val eventBus = koinApp.koin.get<MetadataRefreshEventBus>()
        appScope.launch {
            MetadataClient.refreshEvents.collect { event ->
                eventBus.dispatch(event)
            }
        }
        appScope.launch {
            if (!databaseHealthProbe.awaitHealthy()) return@launch
            MetadataClient.initialize(this@OriveoApplication)
            koinApp.koin.get<ai.oriveo.community.core.data.repository.ProviderRepository>().refreshProviderMetadata()
        }
        appScope.launch {
            if (!databaseHealthProbe.awaitHealthy()) return@launch
            koinApp.koin.get<ai.oriveo.community.core.data.repair.MessageAttachmentRepairTask>().runIfNeeded()
        }
        ProcessLifecycleOwner.get().lifecycle.addObserver(
            koinApp.koin.get<StreamingLifecycleObserver>(),
        )
    }
}
