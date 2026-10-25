import AVFoundation
import Foundation
import Testing
@testable import Oriveo

/// The voice settings page presentation model: engine rows, dictation footer, recognition language, fallback notices, and the read-aloud group.
@MainActor
@Suite("Voice settings model")
struct VoiceSettingsModelTests {

    private static let fallbackNotice = "The selected engine is no longer available. Switched back to System."
    private static let realtimeFallbackNotice = "Switched back to Follow Current Model."

    private static func makeDefaults() -> (UserDefaults, String) {
        let suiteName = "VoiceSettingsModelTests-\(UUID().uuidString)"
        return (UserDefaults(suiteName: suiteName)!, suiteName)
    }

    private static let catalog: VoiceCatalog = VoiceCatalogDecoder.decode([
        "providers": [
            "openAI": [
                "stt": [[
                    "model": "gpt-4o-transcribe",
                    "transport": "openai_transcriptions",
                    "path": "/v1/audio/transcriptions",
                    "maxBytes": 25_000_000,
                    "maxDurationSec": 600,
                ]],
                "tts": [[
                    "model": "gpt-4o-mini-tts",
                    "transport": "openai_speech",
                    "path": "/v1/audio/speech",
                    "outputFormat": "mp3",
                    "maxChars": 4096,
                    "voices": [["id": "alloy", "isDefault": true]],
                ]],
            ],
        ],
    ] as [String: Any])

    private static let usableID = UUID(uuidString: "00000000-0000-0000-0000-0000000000C1")!
    private static let otherID = UUID(uuidString: "00000000-0000-0000-0000-0000000000C2")!
    private static let c1 = usableID.uuidString
    private static let c2 = otherID.uuidString
    private static let usable = TestFactories.makeProvider(id: usableID, kind: .openAI)
    private static let sttEngine = VoiceCloudEngine(providerKind: .openAI, connectionID: c1, model: "gpt-4o-transcribe")
    private static let ttsEngine = VoiceCloudEngine(
        providerKind: .openAI, connectionID: c1, model: "gpt-4o-mini-tts", voice: "alloy"
    )

    private static func model(
        _ settings: VoiceEngineSettings,
        state: VoiceCatalogState = .available(catalog),
        providers: [Provider] = [usable],
        voiceQuality: AVSpeechSynthesisVoiceQuality? = .enhanced
    ) -> VoiceSettingsModel {
        VoiceSettingsModel(
            settings: settings,
            refreshCatalog: { state },
            providers: { providers },
            interfaceLanguage: { "en" },
            systemVoiceQuality: { _ in voiceQuality }
        )
    }

    /// For the read-aloud group: one entry with a speedRange and two voices, plus one entry without a speedRange.
    private static let readAloudCatalog: VoiceCatalog = VoiceCatalogDecoder.decode([
        "providers": [
            "openAI": [
                "tts": [
                    [
                        "model": "gpt-4o-mini-tts",
                        "transport": "openai_speech",
                        "path": "/v1/audio/speech",
                        "outputFormat": "mp3",
                        "maxChars": 4096,
                        "speedRange": ["min": 0.25, "max": 4.0],
                        "voices": [["id": "alloy"], ["id": "echo", "isDefault": true]],
                    ],
                    [
                        "model": "tts-1",
                        "transport": "openai_speech",
                        "path": "/v1/audio/speech",
                        "outputFormat": "mp3",
                        "maxChars": 4096,
                        "voices": [["id": "nova", "isDefault": true]],
                    ],
                ],
            ],
        ],
    ] as [String: Any])

    private static let speedFooter = "This engine doesn't support speed control."
    private static let downloadHint =
        "For a more natural voice, download an Enhanced or Premium voice in Settings > Accessibility > Spoken Content > Voices."
    private static let readAloudFooter =
        "Read aloud skips thinking and code. If the cloud voice is unavailable, the system voice takes over. Voice conversations speak with this voice and speed too."

    @Test("The system row is System / built into the device, free; the dictation footer is the system variant")
    func systemRows() async {
        let (defaults, suiteName) = Self.makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let model = Self.model(VoiceEngineSettings(defaults: defaults))
        await model.load()

        let expected = VoiceEngineRow(
            title: L10n.tr("System", table: .voice),
            subtitle: L10n.tr("Built into your device, free", table: .voice),
            isCloud: false
        )
        #expect(model.dictationEngine == expected)
        #expect(model.readAloudEngine == expected)
        #expect(model.dictationFooter == L10n.tr(
            "System dictation may be processed by Apple. If transcription fails, the recording stays on this device for up to 7 days. Voice conversations listen with this engine too.",
            table: .voice
        ))
        #expect(model.dictationNotice == nil)
        #expect(model.readAloudNotice == nil)
    }

    @Test("A cloud row is provider name / model · billed to your connection; the dictation footer is the cloud variant")
    func cloudRows() async {
        let (defaults, suiteName) = Self.makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let settings = VoiceEngineSettings(defaults: defaults)
        settings.setSelection(.cloud(Self.sttEngine), for: .stt)
        settings.setSelection(.cloud(Self.ttsEngine), for: .tts)
        let model = Self.model(settings)
        await model.load()

        let format = L10n.tr("%@ · Billed to your connection", table: .voice)
        #expect(model.dictationEngine.title == "OpenAI")
        #expect(model.dictationEngine.subtitle == L10n.format(format, "gpt-4o-transcribe"))
        #expect(model.dictationEngine.isCloud)
        #expect(model.readAloudEngine.title == "OpenAI")
        #expect(model.readAloudEngine.subtitle == L10n.format(format, "gpt-4o-mini-tts"))
        #expect(model.dictationFooter == L10n.tr(
            "Recordings are sent only to the provider you choose. If transcription fails, the recording stays on this device for up to 7 days. Voice conversations listen with this engine too.",
            table: .voice
        ))
        #expect(model.dictationNotice == nil)
        #expect(model.readAloudNotice == nil)
        #expect(settings.selection(for: .stt) == .cloud(Self.sttEngine))
    }

    @Test("Recognition languages are Automatic plus the app's 16 languages by their own names")
    func recognitionLanguages() async {
        let (defaults, suiteName) = Self.makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let settings = VoiceEngineSettings(defaults: defaults)
        let model = Self.model(settings)
        await model.load()

        let options = model.recognitionLanguageOptions
        #expect(options.count == 17)
        #expect(options.first == VoiceRecognitionLanguageOption(code: nil, title: L10n.tr("Automatic", table: .voice)))
        #expect(options.map(\.code).dropFirst() == [
            "en", "zh-Hans", "zh-Hant", "ja", "ko", "es", "fr", "de",
            "pt-BR", "ar", "hi", "id", "vi", "th", "tr", "ru",
        ])
        #expect(options.contains(VoiceRecognitionLanguageOption(code: "zh-Hans", title: "\u{7B80}\u{4F53}\u{4E2D}\u{6587}")))
        #expect(options.contains(VoiceRecognitionLanguageOption(code: "ja", title: "\u{65E5}\u{672C}\u{8A9E}")))
        #expect(options.contains(VoiceRecognitionLanguageOption(code: "ru", title: "Русский")))
        #expect(model.recognitionLanguageTitle == L10n.tr("Automatic", table: .voice))

        model.setRecognitionLanguage("ja")
        #expect(settings.recognitionLanguage == "ja")
        #expect(model.recognitionLanguageTitle == "\u{65E5}\u{672C}\u{8A9E}")
        model.setRecognitionLanguage(nil)
        #expect(settings.recognitionLanguage == nil)
    }

    @Test("An invalid connection on entering the page is rewritten to System, with a notice shown once under that direction's engine row")
    func fallbackOnEnter() async {
        let (defaults, suiteName) = Self.makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let settings = VoiceEngineSettings(defaults: defaults)
        settings.setSelection(.cloud(Self.sttEngine), for: .stt)
        // Only the dictation connection is invalid: tts is selected on a connection that is still usable.
        let ttsOnOther = VoiceCloudEngine(providerKind: .openAI, connectionID: Self.c2, model: "gpt-4o-mini-tts", voice: "alloy")
        settings.setSelection(.cloud(ttsOnOther), for: .tts)
        let other = TestFactories.makeProvider(id: Self.otherID, kind: .openAI)
        let model = Self.model(settings, providers: [other])
        await model.load()

        #expect(settings.selection(for: .stt) == .system)
        #expect(model.dictationEngine.isCloud == false)
        #expect(model.dictationEngine.title == L10n.tr("System", table: .voice))
        #expect(model.dictationNotice == L10n.tr(Self.fallbackNotice, table: .voice))
        #expect(model.readAloudNotice == nil)
        #expect(model.readAloudEngine.isCloud)
        // The use site left one pending notice.
        #expect(settings.takePendingNotice(site: .use, direction: .stt) == .connectionMissing)

        await model.load()
        #expect(model.dictationNotice == nil)
    }

    @Test("A pending notice left by the use site is shown once on the settings page as well")
    func pendingNoticeFromUseSite() async {
        let (defaults, suiteName) = Self.makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let settings = VoiceEngineSettings(defaults: defaults)
        settings.setSelection(.cloud(Self.ttsEngine), for: .tts)
        // The use site notices the fallback first: it rewrites to System and leaves a pending notice for the settings page.
        settings.resolve(direction: .tts, catalog: Self.catalog, connections: [], site: .use)
        #expect(settings.selection(for: .tts) == .system)

        let model = Self.model(settings)
        await model.load()
        #expect(model.readAloudNotice == L10n.tr(Self.fallbackNotice, table: .voice))
        #expect(model.dictationNotice == nil)
        #expect(model.readAloudEngine.isCloud == false)

        await model.load()
        #expect(model.readAloudNotice == nil)
    }

    @Test("The stored cloud selection is not rewritten while the catalog is unavailable")
    func noCatalogKeepsSelection() async {
        let (defaults, suiteName) = Self.makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let settings = VoiceEngineSettings(defaults: defaults)
        settings.setSelection(.cloud(Self.sttEngine), for: .stt)
        let model = Self.model(settings, state: .loadFailed, providers: [])
        await model.load()

        #expect(model.catalogState == .loadFailed)
        #expect(settings.selection(for: .stt) == .cloud(Self.sttEngine))
        #expect(model.dictationEngine.isCloud)
        #expect(model.dictationNotice == nil)
    }

    // MARK: - Voice conversation group

    private static let realtimeCatalog: VoiceCatalog = VoiceCatalogDecoder.decode([
        "providers": [
            "openAI": [
                "realtime": [[
                    "model": "gpt-realtime",
                    "transport": "openai_realtime",
                    "path": "/v1/realtime",
                    "contextWindow": 128_000,
                    "voices": [["id": "marin", "isDefault": true]],
                    "inputTranscriptionModel": "gpt-4o-mini-transcribe",
                ]],
            ],
        ],
    ] as [String: Any])
    private static let realtimeEngine = VoiceCloudEngine(
        providerKind: .openAI, connectionID: c1, model: "gpt-realtime", voice: "marin"
    )

    @Test("Conversation engine row: title Conversation Engine, subtitle Follow Current Model or provider name · model; plus the group footer")
    func realtimeRow() async {
        let (defaults, suiteName) = Self.makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let settings = VoiceEngineSettings(defaults: defaults)
        let model = Self.model(settings, state: .available(Self.realtimeCatalog))
        await model.load()

        #expect(model.realtimeEngine == VoiceEngineRow(
            title: "Conversation Engine",
            subtitle: "Follow Current Model",
            isCloud: false
        ))
        #expect(model.realtimeNotice == nil)
        #expect(model.realtimeFooter
            == "A realtime model hears you and answers directly, so replies come faster, but this chat's model isn't used.")
        #expect(VoiceSettingsModel.realtimeGroupTitle == "Voice Conversation")

        settings.setSelection(.cloud(Self.realtimeEngine), for: .realtime)
        model.reloadLocalSettings()
        #expect(model.realtimeEngine == VoiceEngineRow(
            title: "Conversation Engine",
            subtitle: "OpenAI · gpt-realtime",
            isCloud: true,
            providerKind: .openAI
        ))
    }

    @Test("An invalid conversation engine connection on entering the page is rewritten to Follow Current Model with a notice once (dedicated fallback copy)")
    func realtimeFallbackNotice() async {
        let (defaults, suiteName) = Self.makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let settings = VoiceEngineSettings(defaults: defaults)
        settings.setSelection(.cloud(Self.realtimeEngine), for: .realtime)
        let model = Self.model(settings, state: .available(Self.realtimeCatalog), providers: [])
        await model.load()

        #expect(settings.selection(for: .realtime) == .system)
        #expect(model.realtimeEngine.subtitle == "Follow Current Model")
        #expect(model.realtimeNotice == L10n.tr(Self.realtimeFallbackNotice, table: .voice))
        #expect(model.dictationNotice == nil)
        #expect(model.readAloudNotice == nil)

        await model.load()
        #expect(model.realtimeNotice == nil)
    }

    // MARK: - Read-aloud group

    @Test("Voice rows appear only for cloud read-aloud; they list the entry's voices capitalized, check the current voice, and choosing one writes into the tts selection")
    func voiceRows() async {
        let (defaults, suiteName) = Self.makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let settings = VoiceEngineSettings(defaults: defaults)
        let system = Self.model(settings, state: .available(Self.readAloudCatalog))
        await system.load()
        #expect(system.voiceRows.isEmpty)

        // No stored voice: the entry's fallback voice is checked (echo, the isDefault one).
        let engine = VoiceCloudEngine(providerKind: .openAI, connectionID: Self.c1, model: "gpt-4o-mini-tts")
        settings.setSelection(.cloud(engine), for: .tts)
        let model = Self.model(settings, state: .available(Self.readAloudCatalog))
        await model.load()
        #expect(model.voiceRowsTitle == L10n.tr("Speaking Voice", table: .voice))
        #expect(model.voiceRows == [
            VoiceSpeakingVoiceRow(id: "alloy", title: "Alloy", isSelected: false),
            VoiceSpeakingVoiceRow(id: "echo", title: "Echo", isSelected: true),
        ])

        model.selectVoice("alloy")
        let expected = VoiceCloudEngine(providerKind: .openAI, connectionID: Self.c1, model: "gpt-4o-mini-tts", voice: "alloy")
        #expect(settings.selection(for: .tts) == .cloud(expected))
        #expect(model.voiceRows.map(\.isSelected) == [true, false])
        #expect(model.readAloudEngine.isCloud)
        // The dictation direction is unaffected.
        #expect(settings.selection(for: .stt) == .system)
    }

    @Test("Speed spans 0.5…2 in 0.1 steps and shows 1.0×; the system engine is adjustable and writes to the shared speed")
    func systemSpeed() async {
        let (defaults, suiteName) = Self.makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let settings = VoiceEngineSettings(defaults: defaults)
        let model = Self.model(settings)
        await model.load()

        #expect(model.speedTitle == L10n.tr("Speed", table: .voice))
        #expect(model.speedRange == 0.5...2.0)
        #expect(model.speedStep == 0.1)
        #expect(model.speedText == "1.0×")
        #expect(model.speedEnabled)
        #expect(model.speedFooter == nil)

        model.setSpeechRate(1.5)
        #expect(settings.speechRate == 1.5)
        #expect(model.speedText == "1.5×")
        model.setSpeechRate(3)
        #expect(settings.speechRate == 2.0)
        model.setSpeechRate(0.74)
        #expect(settings.speechRate == 0.7)
    }

    @Test("A cloud entry without speedRange is not adjustable and shows a footer; with speedRange it is adjustable")
    func cloudSpeed() async {
        let (defaults, suiteName) = Self.makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let settings = VoiceEngineSettings(defaults: defaults)
        settings.setSelection(
            .cloud(VoiceCloudEngine(providerKind: .openAI, connectionID: Self.c1, model: "tts-1", voice: "nova")),
            for: .tts
        )
        let model = Self.model(settings, state: .available(Self.readAloudCatalog))
        await model.load()
        #expect(model.speedEnabled == false)
        #expect(model.speedFooter == L10n.tr(Self.speedFooter, table: .voice))

        settings.setSelection(
            .cloud(VoiceCloudEngine(providerKind: .openAI, connectionID: Self.c1, model: "gpt-4o-mini-tts", voice: "alloy")),
            for: .tts
        )
        await model.load()
        #expect(model.speedEnabled)
        #expect(model.speedFooter == nil)
    }

    @Test("System read-aloud whose best voice for the interface language is only default quality shows the download-enhanced-voice hint")
    func downloadHint() async {
        let (defaults, suiteName) = Self.makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let settings = VoiceEngineSettings(defaults: defaults)

        var probed: [String] = []
        let model = VoiceSettingsModel(
            settings: settings,
            refreshCatalog: { .available(Self.catalog) },
            providers: { [Self.usable] },
            interfaceLanguage: { "ja" },
            systemVoiceQuality: { language in
                probed.append(language)
                return .default
            }
        )
        await model.load()
        #expect(probed.last == "ja")
        #expect(model.systemVoiceDownloadHint == L10n.tr(Self.downloadHint, table: .voice))

        for quality in [AVSpeechSynthesisVoiceQuality.enhanced, .premium] {
            let better = Self.model(settings, voiceQuality: quality)
            await better.load()
            #expect(better.systemVoiceDownloadHint == nil)
        }

        // Cloud read-aloud shows no hint.
        settings.setSelection(.cloud(Self.ttsEngine), for: .tts)
        let cloud = Self.model(settings, voiceQuality: .default)
        await cloud.load()
        #expect(cloud.systemVoiceDownloadHint == nil)
    }

    @Test("The read-aloud footer is always present")
    func readAloudFooter() async {
        let (defaults, suiteName) = Self.makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let settings = VoiceEngineSettings(defaults: defaults)
        let system = Self.model(settings)
        await system.load()
        #expect(system.readAloudFooter == L10n.tr(Self.readAloudFooter, table: .voice))

        settings.setSelection(.cloud(Self.ttsEngine), for: .tts)
        let cloud = Self.model(settings)
        await cloud.load()
        #expect(cloud.readAloudFooter == L10n.tr(Self.readAloudFooter, table: .voice))
    }

    // MARK: - View outputs

    @Test("A cloud engine row carries providerKind, and the system row has nil")
    func rowProviderKind() async {
        let (defaults, suiteName) = Self.makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let settings = VoiceEngineSettings(defaults: defaults)
        settings.setSelection(.cloud(Self.sttEngine), for: .stt)
        let model = Self.model(settings)
        await model.load()

        #expect(model.dictationEngine.providerKind == .openAI)
        #expect(model.readAloudEngine.providerKind == nil)
    }

    @Test("Catalog available: the sheet lists System plus cloud rows, and with several connections of one provider the subtitle carries Provider.displayName")
    func sheetAvailable() async {
        let (defaults, suiteName) = Self.makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let settings = VoiceEngineSettings(defaults: defaults)
        let work = TestFactories.makeProvider(id: Self.usableID, kind: .openAI, customName: "Work")
        let home = TestFactories.makeProvider(id: Self.otherID, kind: .openAI, customName: "Home")
        let model = Self.model(settings, providers: [work, home])
        await model.load()

        let sheet = model.engineSheetModel(for: .stt)
        #expect(sheet.direction == .stt)
        #expect(sheet.catalogState == .available(Self.catalog))
        #expect(sheet.rows.map(\.subtitle) == [
            L10n.tr("Built into your device, free", table: .voice),
            "gpt-4o-transcribe · Work",
            "gpt-4o-transcribe · Home",
        ])
        #expect(sheet.rows.first?.isSelected == true)
        #expect(sheet.footer == nil)
        #expect(model.engineSheetModel(for: .tts).rows.map(\.subtitle).last == "gpt-4o-mini-tts · Home")

        // The sheet writes to this model's settings.
        sheet.choose(sheet.rows[0])
        #expect(settings.selection(for: .stt) == .system)
    }

    @Test("Sheet connection rows keep the providers' original order (the Providers main list order in settings), are not re-sorted by kind across providers, and unusable connections are merely skipped")
    func sheetKeepsProviderListOrder() async {
        let (defaults, suiteName) = Self.makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let settings = VoiceEngineSettings(defaults: defaults)
        // Multi-provider catalog: add groq and gemini stt / tts entries next to openAI from Self.catalog,
        // so regressions such as "stable sort by kind" or "iterate catalog kinds first, then connections" become visible.
        func stt(_ model: String) -> [String: Any] {
            ["model": model, "transport": "openai_transcriptions", "path": "/v1/audio/transcriptions",
             "maxBytes": 25_000_000, "maxDurationSec": 600]
        }
        func tts(_ model: String) -> [String: Any] {
            ["model": model, "transport": "openai_speech", "path": "/v1/audio/speech",
             "outputFormat": "mp3", "maxChars": 4096, "voices": [["id": "alloy", "isDefault": true]]]
        }
        let catalog = VoiceCatalogDecoder.decode([
            "providers": [
                "openAI": ["stt": [stt("gpt-4o-transcribe")], "tts": [tts("gpt-4o-mini-tts")]],
                "groq": ["stt": [stt("whisper-large-v3")], "tts": [tts("playai-tts")]],
                "gemini": ["stt": [stt("gemini-stt")], "tts": [tts("gemini-tts")]],
            ],
        ] as [String: Any])
        // Connection order: openAI-A, groq, openAI-NoKey (no key, unusable), gemini, openAI-B; the ids are deliberately not in lexical order either.
        let openAIA = TestFactories.makeProvider(
            id: UUID(uuidString: "00000000-0000-0000-0000-0000000000F4")!, kind: .openAI, customName: "A"
        )
        let groq = TestFactories.makeProvider(
            id: UUID(uuidString: "00000000-0000-0000-0000-0000000000F1")!, kind: .groq
        )
        let noKey = TestFactories.makeProvider(
            id: UUID(uuidString: "00000000-0000-0000-0000-0000000000F0")!, kind: .openAI,
            apiKey: "", apiKeyPreview: "", customName: "NoKey"
        )
        let gemini = TestFactories.makeProvider(
            id: UUID(uuidString: "00000000-0000-0000-0000-0000000000F3")!, kind: .gemini
        )
        let openAIB = TestFactories.makeProvider(
            id: UUID(uuidString: "00000000-0000-0000-0000-0000000000F2")!, kind: .openAI, customName: "B"
        )
        let providers = [openAIA, groq, noKey, gemini, openAIB]
        // In production the providers closure is `appState?.providers ?? []` from VoiceSettingsView.init(appState:),
        // the same array in the same order as ForEach(appState.providers) in ProvidersView.allProvidersSection; this returns that same array.
        // The spotlight card (ProviderSpotlight.select) only picks the top one and never changes appState.providers, so the main list order is allProvidersSection's original order.
        let model = Self.model(settings, state: .available(catalog), providers: providers)
        await model.load()

        let expected = [openAIA, groq, gemini, openAIB].map(\.id.uuidString)
        for direction in [VoiceDirection.stt, .tts] {
            let rows = model.engineSheetModel(for: direction).rows
            #expect(rows.first?.option == .system)
            let connectionIDs = rows.dropFirst().compactMap { row -> String? in
                guard case .cloud(_, let connectionID, _, _) = row.option else { return nil }
                return connectionID
            }
            #expect(connectionIDs.count == rows.count - 1)
            #expect(connectionIDs == expected)
        }
    }

    @Test("Catalog 404 / load failure still yields a sheet: only the System row plus the matching footer")
    func sheetUnavailableAndFailed() async {
        let (defaults, suiteName) = Self.makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let settings = VoiceEngineSettings(defaults: defaults)

        let missing = Self.model(settings, state: .unavailable)
        await missing.load()
        let missingSheet = missing.engineSheetModel(for: .stt)
        #expect(missingSheet.catalogState == .unavailable)
        #expect(missingSheet.rows.map(\.option) == [.system])
        #expect(missingSheet.footer == L10n.tr("No cloud voice engines yet", table: .voice))

        let failed = Self.model(settings, state: .loadFailed)
        await failed.load()
        let failedSheet = failed.engineSheetModel(for: .tts)
        #expect(failedSheet.catalogState == .loadFailed)
        #expect(failedSheet.rows.map(\.option) == [.system])
        #expect(failedSheet.footer == L10n.tr("Cloud engines can't be loaded right now", table: .voice))
    }

    @Test("With the catalog undecided (page not entered) the sheet has only the System row and no footer; once the catalog arrives and connections are added, the same sheet refreshes")
    func sheetBeforeLoad() async {
        let (defaults, suiteName) = Self.makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        // A connection with no voice entries yet: with a catalog it produces the pending-provider footer, without a verdict it does not.
        let anthropic = TestFactories.makeProvider(kind: .anthropic)
        var providers = [Self.usable, anthropic]
        let model = VoiceSettingsModel(
            settings: VoiceEngineSettings(defaults: defaults),
            refreshCatalog: { .available(Self.catalog) },
            providers: { providers },
            interfaceLanguage: { "en" },
            systemVoiceQuality: { _ in .enhanced }
        )

        #expect(model.catalogState == nil)
        let sheet = model.engineSheetModel(for: .stt)
        #expect(sheet.rows.map(\.option) == [.system])
        #expect(sheet.footer == nil)

        // Catalog arrives: the open sheet picks up the cloud rows and the pending-provider footer.
        await model.load()
        #expect(sheet.catalogState == .available(Self.catalog))
        #expect(sheet.rows.map(\.subtitle) == [
            L10n.tr("Built into your device, free", table: .voice),
            "gpt-4o-transcribe",
        ])
        #expect(sheet.footer != nil)

        // A connection arrives late: a second connection of the same provider appears and the subtitle carries the connection name.
        let home = TestFactories.makeProvider(id: Self.otherID, kind: .openAI, customName: "Home")
        providers.append(home)
        #expect(sheet.rows.map(\.subtitle).last == "gpt-4o-transcribe · Home")
    }

    @Test("Preview parameters = current entry + its Provider + effective speed; nil when the entry or connection is missing")
    func previewRequest() async {
        let (defaults, suiteName) = Self.makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let settings = VoiceEngineSettings(defaults: defaults)
        settings.setSelection(
            .cloud(VoiceCloudEngine(providerKind: .openAI, connectionID: Self.c1, model: "gpt-4o-mini-tts", voice: "alloy")),
            for: .tts
        )
        settings.speechRate = 1.5
        var providers = [Self.usable]
        let model = VoiceSettingsModel(
            settings: settings,
            refreshCatalog: { .available(Self.readAloudCatalog) },
            providers: { providers },
            interfaceLanguage: { "en" },
            systemVoiceQuality: { _ in .enhanced }
        )
        await model.load()

        let request = model.previewRequest(voice: "echo")
        #expect(request?.entry.model == "gpt-4o-mini-tts")
        #expect(request?.provider.id == Self.usableID)
        #expect(request?.voice == "echo")
        #expect(request?.speed == 1.5)

        // An entry without speedRange gets an effective speed of 1.
        settings.setSelection(
            .cloud(VoiceCloudEngine(providerKind: .openAI, connectionID: Self.c1, model: "tts-1", voice: "nova")),
            for: .tts
        )
        await model.load()
        #expect(model.previewRequest(voice: "nova")?.speed == 1)

        // The connection is missing.
        providers = []
        #expect(model.previewRequest(voice: "nova") == nil)

        // System read-aloud.
        providers = [Self.usable]
        settings.setSelection(.system, for: .tts)
        model.reloadLocalSettings()
        #expect(model.previewRequest(voice: "nova") == nil)
    }

    @Test("Entry not found in the catalog gives nil preview parameters")
    func previewRequestWithoutEntry() async {
        let (defaults, suiteName) = Self.makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let settings = VoiceEngineSettings(defaults: defaults)
        settings.setSelection(.cloud(Self.ttsEngine), for: .tts)
        let model = Self.model(settings, state: .loadFailed)
        await model.load()

        #expect(model.readAloudEngine.isCloud)
        #expect(model.previewRequest(voice: "alloy") == nil)
    }

    @Test("Refreshing after the sheet closes only re-reads local settings and does not refetch the catalog")
    func reloadLocalSettingsSkipsCatalog() async {
        let (defaults, suiteName) = Self.makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let settings = VoiceEngineSettings(defaults: defaults)
        var refreshes = 0
        let model = VoiceSettingsModel(
            settings: settings,
            refreshCatalog: {
                refreshes += 1
                return .available(Self.catalog)
            },
            providers: { [Self.usable] },
            interfaceLanguage: { "en" },
            systemVoiceQuality: { _ in .enhanced }
        )
        await model.load()
        #expect(refreshes == 1)
        #expect(model.dictationEngine.isCloud == false)

        settings.setSelection(.cloud(Self.sttEngine), for: .stt)
        settings.setSelection(.cloud(Self.ttsEngine), for: .tts)
        settings.speechRate = 1.2
        model.reloadLocalSettings()

        #expect(refreshes == 1)
        #expect(model.catalogState == .available(Self.catalog))
        #expect(model.dictationEngine.isCloud)
        #expect(model.dictationEngine.providerKind == .openAI)
        #expect(model.readAloudSelection == .cloud(Self.ttsEngine))
        #expect(model.speechRate == 1.2)
    }
}
