package ai.oriveo.community.di

import android.content.Context
import android.media.MediaRecorder
import ai.oriveo.community.BuildConfig
import ai.oriveo.community.R
import ai.oriveo.community.core.app.AppPreferencesRepository
import ai.oriveo.community.core.app.GlobalSnackbarManager
import ai.oriveo.community.core.data.repository.ProviderRepository
import ai.oriveo.community.core.storage.AppStoragePaths
import ai.oriveo.community.core.voice.AndroidAudioSessionCoordinator
import ai.oriveo.community.core.voice.AndroidDictationEnvironment
import ai.oriveo.community.core.voice.AndroidMicrophonePermission
import ai.oriveo.community.core.voice.AndroidReadAloudEnvironment
import ai.oriveo.community.core.voice.AndroidReadingLanguageDetector
import ai.oriveo.community.core.voice.AndroidSystemSTTBackend
import ai.oriveo.community.core.voice.AndroidSystemSTTSessionBackend
import ai.oriveo.community.core.voice.AndroidSystemTtsVoiceProbe
import ai.oriveo.community.core.voice.AudioRecordCapture
import ai.oriveo.community.core.voice.CloudReadAloudRules
import ai.oriveo.community.core.voice.DefaultDictationEngineFactory
import ai.oriveo.community.core.voice.DictationEngineFactory
import ai.oriveo.community.core.voice.DefaultReadAloudEngineFactory
import ai.oriveo.community.core.voice.DictationController
import ai.oriveo.community.core.voice.MediaCodecAacEncoder
import ai.oriveo.community.core.voice.ReadAloudController
import ai.oriveo.community.core.voice.ReadAloudEndReason
import ai.oriveo.community.core.voice.RecordingStore
import ai.oriveo.community.core.voice.SettingsReadAloudEngineSource
import ai.oriveo.community.core.voice.SettingsVoicePreviewEngineSource
import ai.oriveo.community.core.voice.SpeechAudioCache
import ai.oriveo.community.core.voice.SystemSTTEngine
import ai.oriveo.community.core.voice.SystemSTTRouter
import ai.oriveo.community.core.voice.SystemSpeechEngine
import ai.oriveo.community.core.voice.SystemTtsVoiceProbe
import ai.oriveo.community.core.voice.VoiceCatalogClient
import ai.oriveo.community.core.voice.VoiceEngineSettings
import ai.oriveo.community.core.voice.providerDisclosureCoRecorder
import ai.oriveo.community.core.voice.VoicePreviewController
import ai.oriveo.community.core.voice.asDictationCatalogSource
import ai.oriveo.community.core.voice.SpeakablePlaceholder
import ai.oriveo.community.core.voice.conversation.AndroidConversationAudio
import ai.oriveo.community.core.voice.conversation.CloudConversationTts
import ai.oriveo.community.core.voice.conversation.DictationConversationSttSource
import ai.oriveo.community.core.voice.conversation.ReadAloudConversationTtsSource
import ai.oriveo.community.core.voice.conversation.ServiceConversationForeground
import ai.oriveo.community.core.voice.conversation.SpeakerBargeInMemory
import ai.oriveo.community.core.voice.conversation.SpeechProbSource
import ai.oriveo.community.core.voice.conversation.SystemConversationTts
import ai.oriveo.community.core.voice.conversation.VoiceConversationController
import ai.oriveo.community.core.voice.conversation.VoiceConversationEnvironment
import ai.oriveo.community.core.voice.conversation.VoiceConversationEngine
import ai.oriveo.community.core.voice.conversation.VoicePrompt
import java.util.Locale
import io.ktor.client.HttpClient
import java.io.File
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.launch
import org.koin.android.ext.koin.androidContext
import org.koin.core.qualifier.named
import org.koin.dsl.bind
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
        val ctx = androidContext()
        val koin = getKoin()
        VoiceEngineSettings(
            onRealtimeDisclosureAccepted = providerDisclosureCoRecorder(
                preferences = { koin.getOrNull<AppPreferencesRepository>() },
                scope = get(named("applicationScope")),
            ),
        ) {
            ctx.getSharedPreferences(VoiceEngineSettings.PREFS_NAME, Context.MODE_PRIVATE)
        }
    }
    // Read-aloud, conversation and realtime conversation share one audio session coordinator (AudioManager operations are serialized onto its thread).
    single { AndroidAudioSessionCoordinator(androidContext()) }
    // Read-aloud and voice-preview playback share one synthesized-audio cache.
    single { SpeechAudioCache(File(AppStoragePaths.cacheDir(androidContext()), "voice-tts")) }
    single {
        val ctx = androidContext()
        val settings = get<VoiceEngineSettings>()
        val catalogClient = get<VoiceCatalogClient>()
        val appScope = get<CoroutineScope>(named("applicationScope"))
        val koin = getKoin()
        ReadAloudController(
            engineSource = SettingsReadAloudEngineSource(
                engines = DefaultReadAloudEngineFactory(
                    httpClient = get<HttpClient>(),
                    cache = get<SpeechAudioCache>(),
                    systemEngine = SystemSpeechEngine(ctx, speechRate = settings::speechRate),
                    speechRate = settings::speechRate,
                ),
                settings = settings,
                catalogState = { catalogClient.state.value },
                refreshCatalog = { appScope.launch { catalogClient.ensureFresh() } },
                providers = { get<ProviderRepository>().observeAll().first() },
            ),
            environment = AndroidReadAloudEnvironment(ctx, get(), get()),
            languageDetector = AndroidReadingLanguageDetector(ctx),
            showToast = get<GlobalSnackbarManager>()::show,
            beforeStart = { koin.get<VoicePreviewController>().stop() },
        )
    }
    single {
        val ctx = androidContext()
        val catalogClient = get<VoiceCatalogClient>()
        val environment = AndroidReadAloudEnvironment(ctx, get(), get())
        val koin = getKoin()
        VoicePreviewController(
            engineSource = SettingsVoicePreviewEngineSource(
                httpClient = get<HttpClient>(),
                cache = get<SpeechAudioCache>(),
                settings = get<VoiceEngineSettings>(),
                catalogState = { catalogClient.state.value },
                providers = { get<ProviderRepository>().observeAll().first() },
            ),
            environment = environment,
            sampleText = { environment.uiString(R.string.voice_preview_sample) },
            stopReadAloud = { koin.get<ReadAloudController>().stop(ReadAloudEndReason.USER_STOPPED) },
        )
    }
    single { AndroidMicrophonePermission(androidContext(), settings = get()) }
    single<SystemTtsVoiceProbe> { AndroidSystemTtsVoiceProbe(androidContext()) }
    single {
        VoiceCatalogClient(
            get(),
            BuildConfig.METADATA_BASE_URL,
            File(AppStoragePaths.filesDir(androidContext()), "voice"),
        )
    }
    // Warm the voice catalog at app start: read the cache cold in a background coroutine, then refresh if needed, so the main thread never builds the client.
    single(named("voiceCatalogWarmup"), createdAtStart = true) {
        val koin = getKoin()
        get<CoroutineScope>(named("applicationScope")).launch {
            val client = koin.get<VoiceCatalogClient>()
            client.loadCached()
            client.ensureFresh()
        }
    }
    // Dictation and voice conversation share one dictation engine factory.
    single<DictationEngineFactory> {
        val ctx = androidContext()
        val router = SystemSTTRouter(AndroidSystemSTTBackend(ctx))
        DefaultDictationEngineFactory(
            get<HttpClient>(),
            File(AppStoragePaths.cacheDir(ctx), "voice-upload"),
            SystemSTTEngine(AndroidSystemSTTSessionBackend(ctx), routeFor = router::route),
            router,
        )
    }
    single {
        val ctx = androidContext()
        DictationController(
            engines = get<DictationEngineFactory>(),
            settings = get<VoiceEngineSettings>(),
            catalog = get<VoiceCatalogClient>().asDictationCatalogSource(),
            providers = { get<ProviderRepository>().observeAll().first() },
            // Dictation uses the VOICE_RECOGNITION capture source; conversation and realtime still use the default MIC.
            capture = AudioRecordCapture(ctx, MediaRecorder.AudioSource.VOICE_RECOGNITION),
            store = RecordingStore.production(ctx),
            encoderFactory = { MediaCodecAacEncoder() },
            permission = get<AndroidMicrophonePermission>(),
            environment = AndroidDictationEnvironment(ctx, get(), get()),
        )
    }
    single {
        val ctx = androidContext()
        val settings = get<VoiceEngineSettings>()
        val catalogClient = get<VoiceCatalogClient>()
        val appScope = get<CoroutineScope>(named("applicationScope"))
        val readAloudEnvironment = AndroidReadAloudEnvironment(ctx, get(), get())
        val detector = AndroidReadingLanguageDetector(ctx)
        val dictationEnvironment = AndroidDictationEnvironment(ctx, get(), settings)
        val koin = getKoin()
        val localeFor: suspend (String) -> Locale = { text ->
            val uiLocale = readAloudEnvironment.uiLocale()
            val hypotheses = runCatching { detector.detect(text) }.getOrDefault(emptyList())
            val readingTag = CloudReadAloudRules.readingLanguage(hypotheses, uiLocale.toLanguageTag())
            if (readingTag == uiLocale.toLanguageTag()) uiLocale else Locale.forLanguageTag(readingTag)
        }
        val system = SystemConversationTts(
            ctx,
            speechRate = settings::speechRate,
            localeFor = localeFor,
            tempDir = File(AppStoragePaths.cacheDir(ctx), "voice-conversation-tts"),
        )
        VoiceConversationController(
            audio = AndroidConversationAudio(ctx, get(), File(AppStoragePaths.cacheDir(ctx), "voice-conversation")),
            sttSource = DictationConversationSttSource(
                engines = get<DictationEngineFactory>(),
                settings = settings,
                catalog = catalogClient.asDictationCatalogSource(),
                providers = { get<ProviderRepository>().observeAll().first() },
                language = dictationEnvironment::recognitionLanguage,
            ),
            ttsSource = ReadAloudConversationTtsSource(
                readAloud = SettingsReadAloudEngineSource(
                    engines = DefaultReadAloudEngineFactory(
                        httpClient = get<HttpClient>(),
                        cache = get<SpeechAudioCache>(),
                        systemEngine = SystemSpeechEngine(ctx, speechRate = settings::speechRate),
                        speechRate = settings::speechRate,
                    ),
                    settings = settings,
                    catalogState = { catalogClient.state.value },
                    refreshCatalog = { appScope.launch { catalogClient.ensureFresh() } },
                    providers = { get<ProviderRepository>().observeAll().first() },
                ),
                system = system,
                cloud = { engine -> CloudConversationTts(engine, localeFor) },
            ),
            foreground = ServiceConversationForeground(ctx),
            environment = object : VoiceConversationEnvironment {
                override fun stopReadAloud() = koin.get<ReadAloudController>().stop(ReadAloudEndReason.USER_STOPPED)
            },
            memory = SpeakerBargeInMemory({
                ctx.getSharedPreferences(SpeakerBargeInMemory.PREFS_NAME, Context.MODE_PRIVATE)
            }),
            prompt = { which ->
                readAloudEnvironment.uiString(
                    when (which) {
                        VoicePrompt.DidNotCatch -> R.string.voice_conversation_prompt_did_not_catch
                        VoicePrompt.ApprovalNeeded -> R.string.voice_conversation_prompt_approval_needed
                        VoicePrompt.SayAgain -> R.string.voice_conversation_prompt_say_again
                        VoicePrompt.CheckLanguage -> R.string.voice_conversation_prompt_check_language
                        VoicePrompt.EchoHint -> R.string.voice_conversation_prompt_echo_hint
                        is VoicePrompt.Placeholder -> when (which.kind) {
                            SpeakablePlaceholder.CODE -> R.string.voice_placeholder_code
                            SpeakablePlaceholder.TABLE -> R.string.voice_placeholder_table
                            SpeakablePlaceholder.MATH -> R.string.voice_placeholder_math
                        }
                    },
                )
            },
            speechProbs = SpeechProbSource.silero(ctx),
        )
    } bind VoiceConversationEngine::class
    // The chat page voice conversation on a cloud realtime model: no foreground service, closes in the background.
    single {
        val ctx = androidContext()
        val catalogClient = get<VoiceCatalogClient>()
        val conversations = get<ai.oriveo.community.core.data.repository.ConversationRepository>()
        val appScope = get<CoroutineScope>(named("applicationScope"))
        val audioSessions = get<AndroidAudioSessionCoordinator>()
        // Same target route the realtime audio selects on start; not the communication device (audio not started yet). Maintained on the coordinator thread from the output devices and their callbacks,
        // until then it defaults to the speaker.
        val outputRoute = java.util.concurrent.atomic.AtomicReference(
            ai.oriveo.community.core.voice.conversation.ConversationRoute.SPEAKER,
        )
        audioSessions.post {
            val ops = this
            val refresh = {
                outputRoute.set(
                    ai.oriveo.community.core.voice.conversation.routeForOutputs(
                        ops.devices(android.media.AudioManager.GET_DEVICES_OUTPUTS).map { it.type },
                    ),
                )
            }
            refresh()
            registerDeviceCallback(
                object : android.media.AudioDeviceCallback() {
                    override fun onAudioDevicesAdded(addedDevices: Array<out android.media.AudioDeviceInfo>?) = refresh()

                    override fun onAudioDevicesRemoved(removedDevices: Array<out android.media.AudioDeviceInfo>?) =
                        refresh()
                },
            )
        }
        ai.oriveo.community.feature.chat.voice.RealtimeVoiceSessionBuilder(
            settings = get<VoiceEngineSettings>(),
            catalog = {
                val source = catalogClient.asDictationCatalogSource()
                source.loadCached()
                    ?: (source.refresh() as? ai.oriveo.community.core.voice.VoiceCatalogState.Available)?.catalog
            },
            // A failed connect asks the server again: the cache may still list a model that was removed (model_gone).
            refreshedCatalog = {
                (catalogClient.asDictationCatalogSource().refresh() as? ai.oriveo.community.core.voice.VoiceCatalogState.Available)
                    ?.catalog
            },
            providers = { get<ProviderRepository>().observeAll().first() },
            conversation = { id -> conversations.getWithMessages(id) },
            sinkFor = { id, createHomeConversation, attribution ->
                ai.oriveo.community.feature.chat.voice.RepositoryRealtimeTranscriptSink(
                    conversations,
                    id,
                    attribution,
                    appScope,
                    createHomeConversation,
                )
            },
            outputRoute = outputRoute::get,
            audio = { ai.oriveo.community.core.voice.realtime.AndroidRealtimeAudio(ctx, audioSessions) },
            scope = CoroutineScope(kotlinx.coroutines.SupervisorJob() + kotlinx.coroutines.Dispatchers.Main.immediate),
            latestCheckpoint = get<ai.oriveo.community.core.data.repository.ContextCompactionCoordinator>()::latestValid,
            speechProbs = SpeechProbSource.silero(ctx),
            foreground = ServiceConversationForeground(ctx),
        )
    }
    // Hands one voice conversation from the home hero to the chat page it creates.
    single { ai.oriveo.community.feature.chat.voice.VoiceConversationSessions() }
}
