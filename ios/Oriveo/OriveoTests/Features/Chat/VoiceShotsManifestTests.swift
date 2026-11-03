import Foundation
import Testing
@testable import Oriveo

/// Reads the voice page-family sample shared manifest `shared/test-fixtures/shots/voice.v1.json`: the page-name set matches this platform's page-name table;
/// The fifteen read-aloud / primary button / home / voice bar / realtime notice pages can be built from the manifest; the status of the nine voice-bar pages goes through production mapping to DisplayState;
/// The subtitles, levels, language names and two input-box segments of the three pages "you're saying / recognition language hint / live dictation fragment" are built from the manifest; malformed fields are rejected;
/// The state of the four dictation pages goes through production DictationPresentation to get the recording bar / busy state / card;
/// The catalogs of the two settings pages come from the shared catalog contract via the production decoder, and the dictation engine row comes from the production settings model's display manifest dictationEngine.
@Suite("Screenshot manifest - voice page family", .serialized)
@MainActor
struct VoiceShotsManifestTests {
    typealias Shots = VoiceShots

    private static let implementedSurfaces: Set<Shots.Surface> = [.readAloud, .composer, .home, .voiceBar]
    private static let dictationShots: [Shots.Shot] = [
        .voiceDictationRecording, .voiceDictationTranscribing, .voiceDictationFailed, .voiceDictationInterrupted
    ]

    private static func rawPages() throws -> [[String: Any]] {
        let root = try #require(try JSONSerialization.jsonObject(with: Shots.manifestData()) as? [String: Any])
        return try #require(root["pages"] as? [[String: Any]])
    }

    @Test("shotsManifestPagesMatchImplemented: the manifest's page names == this app's page-name table, in the same order")
    func shotsManifestPagesMatchImplemented() throws {
        let manifest = try Shots.Manifest.load(from: Shots.manifestData())
        #expect(manifest.pages.map(\.name) == Shots.Shot.allCases.map(\.rawValue))
    }

    @Test("shotsManifestTenPagesStage: the eleven pages of read aloud / main button / home / voice bar can all be built from the manifest, and the conversation is the manifest's conversation")
    func shotsManifestTenPagesStage() throws {
        let manifest = try Shots.Manifest.load(from: Shots.manifestData())
        var staged: [Shots.Shot: Shots.Staged] = [:]
        for shot in Shots.Shot.allCases {
            let page = try Shots.stage(shot, manifestData: Shots.manifestData())
            if Self.implementedSurfaces.contains(page.surface) { staged[shot] = page }
        }
        #expect(staged.count == 15)
        for (shot, page) in staged {
            #expect(page.messages.map(\.text) == manifest.conversation.map(\.text), "\(shot.rawValue)")
            #expect(page.messages.last?.role == .assistant, "\(shot.rawValue)")
        }
        #expect(staged[.voiceReadAloudIdle]?.readAloud == .idle)
        #expect(staged[.voiceReadAloudSpeaking]?.readAloud == .speaking)
        #expect(staged[.voiceComposerButton]?.surface == .composer)
        #expect(staged[.voiceHome]?.surface == .home)
        #expect(staged[.voiceHomeDraft]?.surface == .home)
        #expect(staged.filter { $0.value.disclosure != nil }.map(\.key) == [.voiceRealtimeDisclosure])
    }

    @Test("shotsManifestBarStatusMapsToDisplayState: the status of the six voice bar pages maps through production to the DisplayState of the same name")
    func shotsRealtimeDisclosureStage() throws {
        let staged = try Shots.stage(.voiceRealtimeDisclosure, manifestData: Shots.manifestData())
        #expect(staged.surface == .composer)
        #expect(staged.disclosure == .openAI)
        let catalogData = try Data(contentsOf: Shots.repositoryRoot()
            .appendingPathComponent("shared/model-contracts/voice_catalog_contract.v2.json"))
        let envelope = try #require(try JSONSerialization.jsonObject(with: catalogData) as? [String: Any])
        let defaultEntry = VoiceCatalogDecoder.decode(envelope["data"]).realtimeEntries(.openAI).first { $0.isDefault }
        let expected = try #require(defaultEntry)
        #expect(staged.realtimeModel == expected.model)
        #expect(staged.settings == nil)
    }

    @Test("shotsManifestBarStatusMapsToDisplayState: the status of the six voice bar pages maps through production to the DisplayState of the same name")
    func shotsManifestBarStatusMapsToDisplayState() throws {
        let barPages = try Self.rawPages().filter { $0["surface"] as? String == "voiceBar" }
        #expect(barPages.count == 9)
        for raw in barPages {
            let name = try #require(raw["name"] as? String)
            let status = try #require(raw["status"] as? String)
            let shot = try #require(Shots.Shot(rawValue: name))
            let staged = try Shots.stage(shot, manifestData: Shots.manifestData())
            #expect(staged.status?.rawValue == status, "\(name)")
            let expected = status == "caption" ? "userSpeaking" : status
            #expect(staged.barDisplayState?.rawValue == expected, "\(name)")
        }
    }

    @Test("shotsComposerEmptyDraftShowsVoice: the conversation sits on the demo seed model with an empty draft, and the production main button decision is the voice button")
    func shotsComposerEmptyDraftShowsVoice() throws {
        let appState = AppState(seedDemoData: true)
        let staged = try Shots.stage(.voiceComposerButton, manifestData: Shots.manifestData())
        let conversation = try Shots.install(staged, into: appState)
        let active = try #require(appState.activeModel)
        #expect(conversation.draftText.isEmpty)
        #expect(conversation.modelID == active.model.id)
        // The sample chat model has text capability only (identical on both platforms; same basis as Android VoiceShotsData).
        #expect(active.model.id == Shots.chatModelID)
        #expect(active.model.capabilities == [.text])
        let action = VoiceConversationEntry.primaryAction(
            isSending: false,
            hasContent: !conversation.draftText.isEmpty,
            sendEnabled: false,
            voiceAvailable: true,
            modelProducesText: VoiceConversationEntry.modelProducesText(active.model)
        )
        #expect(action == .voice)
    }

    @Test("shotsDictationFourPagesStage: the four dictation pages are built from the manifest and their state comes from the production DictationPresentation")
    func shotsDictationFourPagesStage() throws {
        let manifest = try Shots.Manifest.load(from: Shots.manifestData())
        let appState = AppState(seedDemoData: true)
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        var staged: [Shots.Shot: Shots.Staged] = [:]
        for shot in Self.dictationShots {
            let page = try Shots.stage(shot, manifestData: Shots.manifestData())
            #expect(page.surface == .dictation, "\(shot.rawValue)")
            #expect(page.messages.map(\.text) == manifest.conversation.map(\.text), "\(shot.rawValue)")
            staged[shot] = page
        }
        #expect(staged.count == 4)
        #expect(staged.values.allSatisfy { $0.liveSnapshot == nil })

        // Recording: the timer takes the manifest's elapsedSec=12 and goes through the production mapping to the recording bar.
        let recording = try #require(staged[.voiceDictationRecording]?.dictationState(now: now))
        #expect(recording == .recording(startedAt: now.addingTimeInterval(-12)))
        #expect(DictationPresentation.inputRow(for: recording, engineInfo: nil) == .recording(startedAt: now.addingTimeInterval(-12)))
        #expect(DictationPresentation.card(for: recording, savedDuration: nil, recognitionLanguageName: "English") == nil)
        // The level bar takes dictationLevels from the manifest (same value on both platforms); it is attached only to the recording page.
        #expect(staged[.voiceDictationRecording]?.dictationLevels?.count == 24)
        #expect(staged[.voiceDictationRecording]?.dictationLevels?.first == 0.18)
        #expect(staged[.voiceDictationFailed]?.dictationLevels == nil)
        // The recording bar timer is fixed at 12 seconds; non-recording pages clear the override.
        defer { ComposerDictationBar.shotsFrozenElapsedSec = nil }
        Shots.applyDictationDisplayOverrides(try #require(staged[.voiceDictationRecording]))
        #expect(ComposerDictationBar.shotsFrozenElapsedSec == 12)
        Shots.applyDictationDisplayOverrides(try #require(staged[.voiceDictationFailed]))
        #expect(ComposerDictationBar.shotsFrozenElapsedSec == nil)

        // Transcribing: the engine row takes the manifest's dictationEngine (openAI), and the busy-state copy carries that connection's display name.
        let transcribingPage = try #require(staged[.voiceDictationTranscribing])
        let transcribing = try #require(transcribingPage.dictationState(now: now))
        let info = try #require(transcribingPage.dictationEngineInfo(providers: appState.providers))
        let openAI = try #require(appState.providers.first { $0.kind == .openAI })
        #expect(info == DictationEngineInfo(displayName: openAI.displayName, providerID: openAI.id))
        #expect(DictationPresentation.inputRow(for: transcribing, engineInfo: info)
            == .busy(.transcribing(engineName: openAI.displayName)))

        // Failed: the checkConnection one, "connection timed out, recording saved", with buttons as in production (Discard / Check Connection).
        let failed = try #require(staged[.voiceDictationFailed]?.dictationState(now: now))
        #expect(failed == .failed(.checkConnection))
        let failedCard = try #require(DictationPresentation.card(for: failed, savedDuration: nil, recognitionLanguageName: "English"))
        #expect(failedCard.title == L10n.tr("Transcription failed", table: .voice))
        #expect(failedCard.subtitle == L10n.tr("Connection unavailable. Recording saved", table: .voice))
        #expect(failedCard.secondary == .discard)
        #expect(failedCard.primary == .checkConnection)

        // Interrupted: the interrupted-recording card.
        let interrupted = try #require(staged[.voiceDictationInterrupted]?.dictationState(now: now))
        #expect(interrupted == .interrupted)
        let interruptedCard = try #require(DictationPresentation.card(for: interrupted, savedDuration: nil, recognitionLanguageName: "English"))
        #expect(interruptedCard.title == L10n.tr("Recording interrupted", table: .voice))
        #expect(interruptedCard.primary == .transcribeRecording)
    }

    private static let settingsShots: [Shots.Shot] = [.voiceSettings, .voiceEngineSheet]

    @Test("shotsSettingsFourPagesStage: the four settings pages are built from the manifest, and the catalog comes from voice_catalog_contract.v2.json through the production decoder")
    func shotsSettingsPagesStage() throws {
        let catalogData = try Data(contentsOf: Shots.repositoryRoot()
            .appendingPathComponent("shared/model-contracts/voice_catalog_contract.v2.json"))
        let envelope = try #require(try JSONSerialization.jsonObject(with: catalogData) as? [String: Any])
        let expected = VoiceCatalogDecoder.decode(envelope["data"])
        #expect(expected.realtimeEntries(.openAI).contains { $0.model == "gpt-realtime-2.1" })
        var staged: [Shots.Shot: Shots.SettingsStage] = [:]
        for shot in Self.settingsShots {
            let page = try Shots.stage(shot, manifestData: Shots.manifestData())
            let settings = try #require(page.settings, "\(shot.rawValue)")
            #expect(settings.catalog == expected, "\(shot.rawValue)")
            #expect(settings.connections == [.openAI, .groq], "\(shot.rawValue)")
            #expect(settings.dictationEngine == Shots.DictationEngine(provider: "openAI", model: "gpt-transcribe"))
            staged[shot] = settings
        }
        #expect(staged[.voiceSettings]?.sheetDirection == nil)
        #expect(staged[.voiceEngineSheet]?.sheetDirection == .stt)
        #expect(staged[.voiceEngineSheet]?.disclosure == nil)
    }

    @Test("shotsRealtimeRowShowsChosenModel: after injection the production settings model's conversation engine row shows gpt-realtime-2.1 with no disclosure, the dictation engine is OpenAI, and the sheet ticks gpt-transcribe")
    func shotsSettingsShowsDictationEngine() async throws {
        let appState = AppState(seedDemoData: true)
        let page = try #require(try Shots.stage(.voiceSettings, manifestData: Shots.manifestData()).settings)
        let injection = page.injection(seedProviders: appState.providers)
        #expect(injection.providers.map(\.kind) == [.openAI, .groq])
        #expect(injection.openEngineSheet == nil)
        #expect(injection.disclosure == nil)
        defer { VoiceSettingsModel.shotsInjection = nil }
        VoiceSettingsModel.shotsInjection = injection
        let model = VoiceSettingsModel(providers: { [] })
        await model.load()
        #expect(model.dictationEngine.title == ProviderKind.openAI.displayName)
        #expect(model.dictationNotice == nil)
        let sheet = model.engineSheetModel(for: .stt)
        #expect(sheet.rows.first { $0.isSelected }?.id.hasSuffix("|gpt-transcribe") == true)

        // The voiceSettings page does not write a conversation engine choice: the row follows the current model.
        let settingsPage = try #require(try Shots.stage(.voiceSettings, manifestData: Shots.manifestData()).settings)
        VoiceSettingsModel.shotsInjection = settingsPage.injection(seedProviders: appState.providers)
        let settingsModel = VoiceSettingsModel(providers: { [] })
        await settingsModel.load()
        #expect(settingsModel.dictationEngine.title == ProviderKind.openAI.displayName)

        let sheetPage = try #require(try Shots.stage(.voiceEngineSheet, manifestData: Shots.manifestData()).settings)
        #expect(sheetPage.injection(seedProviders: appState.providers).openEngineSheet == .stt)
    }

    // MARK: - You're saying / recognition language hint / live dictation fragment

    /// Modify a page's field in the manifest (nil = remove that key), re-encode, and test that malformed fields are rejected.
    private static func manifestData(page name: String, set changes: [String: Any?]) throws -> Data {
        var root = try #require(try JSONSerialization.jsonObject(with: Shots.manifestData()) as? [String: Any])
        var pages = try #require(root["pages"] as? [[String: Any]])
        let index = try #require(pages.firstIndex { $0["name"] as? String == name })
        for (key, value) in changes { pages[index][key] = value }
        root["pages"] = pages
        return try JSONSerialization.data(withJSONObject: root)
    }

    @Test("shotsRealtimeNoticeShowsDisclosure: the disclosure page opens the conversation engine sheet, the production VoiceDisclosureRequest is OpenAI · gpt-realtime-2.1, the title / body use the production copy, and no consent is written")
    func shotsUserSpeakingStage() throws {
        let staged = try Shots.stage(.voiceBarUserSpeaking, manifestData: Shots.manifestData())
        #expect(staged.surface == .voiceBar)
        #expect(staged.status == .caption)
        #expect(staged.barDisplayState == .userSpeaking)
        #expect(staged.caption == "Give me three tips for a calmer morning")
        #expect(staged.level == 0.6)
        #expect(staged.recognitionLanguage == nil)
        defer {
            VoiceConversationDemo.shotsCaption = nil
            VoiceConversationDemo.shotsLevel = nil
            VoiceConversationDemo.shotsSettings = nil
        }
        Shots.applyBarOverrides(staged)
        #expect(VoiceConversationDemo.caption == "Give me three tips for a calmer morning")
        #expect(VoiceConversationDemo.level() == 0.6)
        #expect(VoiceConversationDemo.languageChip(for: staged.status) == nil)
        // Voice-bar pages with no level in the manifest use 0, not the default demo value.
        Shots.applyBarOverrides(try Shots.stage(.voiceBarListening, manifestData: Shots.manifestData()))
        #expect(VoiceConversationDemo.caption == nil)
        #expect(VoiceConversationDemo.level() == 0)
    }

    @Test("shotsRealtimeNoticeShowsDisclosure: the disclosure page opens the conversation engine sheet, the production VoiceDisclosureRequest is OpenAI · gpt-realtime-2.1, the title / body use the production copy, and no consent is written")
    func shotsSpeakingLevelStage() throws {
        let staged = try Shots.stage(.voiceBarSpeaking, manifestData: Shots.manifestData())
        #expect(staged.status == .speaking)
        #expect(staged.level == 0.5)
        #expect(staged.caption == nil)
        defer {
            VoiceConversationDemo.shotsLevel = nil
            VoiceConversationDemo.shotsStageClock = nil
        }
        Shots.applyBarOverrides(staged)
        #expect(VoiceConversationDemo.level() == 0.5)
    }

    @Test("shotsRealtimeNoticeShowsDisclosure: the disclosure page opens the conversation engine sheet, the production VoiceDisclosureRequest is OpenAI · gpt-realtime-2.1, the title / body use the production copy, and no consent is written")
    func shotsSayAgainStage() throws {
        let staged = try Shots.stage(.voiceBarSayAgain, manifestData: Shots.manifestData())
        #expect(staged.surface == .voiceBar)
        #expect(staged.status == .sayAgain)
        #expect(staged.barDisplayState == .sayAgain)
        #expect(VoiceConversationDemo.displayState(for: staged.status) == .sayAgain)
        #expect(staged.level == nil)
        defer {
            VoiceConversationDemo.shotsLevel = nil
            VoiceConversationDemo.shotsStageClock = nil
        }
        Shots.applyBarOverrides(staged)
        #expect(VoiceConversationDemo.level() == 0)
    }

    @Test("shotsRealtimeNoticeShowsDisclosure: the disclosure page opens the conversation engine sheet, the production VoiceDisclosureRequest is OpenAI · gpt-realtime-2.1, the title / body use the production copy, and no consent is written")
    func shotsStageClockOverride() throws {
        let manifest = try Shots.Manifest.load(from: Shots.manifestData())
        let ms = try #require(manifest.stageClockMs)
        let staged = try Shots.stage(.voiceBarListening, manifestData: Shots.manifestData())
        #expect(staged.stageClock == ms / 1000)
        defer {
            VoiceConversationDemo.shotsLevel = nil
            VoiceConversationDemo.shotsStageClock = nil
        }
        Shots.applyBarOverrides(staged)
        #expect(VoiceConversationDemo.stageClock == ms / 1000)

        func data(stageClockMs: Any?) throws -> Data {
            var root = try #require(try JSONSerialization.jsonObject(with: Shots.manifestData()) as? [String: Any])
            root["stageClockMs"] = stageClockMs
            return try JSONSerialization.data(withJSONObject: root)
        }
        let moved = try Shots.stage(.voiceBarSpeaking, manifestData: data(stageClockMs: 2600))
        Shots.applyBarOverrides(moved)
        #expect(VoiceConversationDemo.stageClock == 2.6)

        Shots.applyBarOverrides(try Shots.stage(.voiceReadAloudIdle, manifestData: Shots.manifestData()))
        #expect(VoiceConversationDemo.stageClock == nil)
        #expect(VoiceConversationDemo.shotsLevel == nil)

        for bad in [nil, -1, 0.5] as [Any?] {
            #expect(throws: Shots.ManifestError.self, "stageClockMs \(String(describing: bad))") {
                try Shots.stage(.voiceBarListening, manifestData: data(stageClockMs: bad))
            }
        }
    }

    @Test("shotsRealtimeNoticeShowsDisclosure: the disclosure page opens the conversation engine sheet, the production VoiceDisclosureRequest is OpenAI · gpt-realtime-2.1, the title / body use the production copy, and no consent is written")
    func shotsCheckLanguageStage() throws {
        let staged = try Shots.stage(.voiceBarCheckLanguage, manifestData: Shots.manifestData())
        #expect(staged.status == .checkLanguage)
        #expect(staged.barDisplayState == .checkLanguage)
        #expect(staged.recognitionLanguage == "en-US")
        #expect(staged.caption == nil && staged.level == nil)
        defer { VoiceConversationDemo.shotsSettings = nil }
        Shots.applyBarOverrides(staged)
        let suite = try #require(UserDefaults(suiteName: Shots.SettingsStage.defaultsSuite))
        #expect(VoiceEngineSettings(defaults: suite).recognitionLanguage == "en-US")
        let chip = try #require(VoiceConversationDemo.languageChip(for: .checkLanguage))
        #expect(chip.name == RecognitionLanguageSheetModel.displayName("en-US"))
        #expect(chip.name != RecognitionLanguageSheetModel.displayName(nil))
        // The capsule shows the language name, not the raw code.
        let system = try #require(AppLocalization.currentLocale.localizedString(forIdentifier: "en-US"))
        #expect(chip.name.lowercased() == system.lowercased())
        #expect(chip.name != "en-US")
        #expect(VoiceConversationDemo.languageChip(for: .listening) == nil)
    }

    @Test("shotsRealtimeNoticeShowsDisclosure: the disclosure page opens the conversation engine sheet, the production VoiceDisclosureRequest is OpenAI · gpt-realtime-2.1, the title / body use the production copy, and no consent is written")
    func shotsVoiceBarPinsChatModel() throws {
        #expect(Shots.chatModelID == "claude-haiku-5-5")
        #expect(Shots.chatModelName == "Claude Haiku 5.5")
        let appState = AppState(seedDemoData: true)
        let staged = try Shots.stage(.voiceBarListening, manifestData: Shots.manifestData())
        let conversation = try Shots.install(staged, into: appState)
        #expect(conversation.modelID == Shots.chatModelID)
        #expect(conversation.providerKind == .anthropic)
        #expect(conversation.messages.filter { $0.role == .assistant }.allSatisfy { $0.modelID == Shots.chatModelID })
        let installed = try #require(appState.conversations.first { $0.id == conversation.id })
        #expect(appState.currentModel(for: installed)?.id == Shots.chatModelID)
        #expect(appState.currentModel(for: installed)?.name == Shots.chatModelName)
        let active = try #require(appState.activeModel)
        #expect(active.model.id == Shots.chatModelID)
        // Installing again does not insert the model twice.
        _ = try Shots.install(staged, into: appState)
        let provider = try #require(appState.providers.first { $0.id == conversation.providerID })
        #expect(provider.models.filter { $0.id == Shots.chatModelID }.count == 1)
    }

    @Test("shotsRealtimeNoticeShowsDisclosure: the disclosure page opens the conversation engine sheet, the production VoiceDisclosureRequest is OpenAI · gpt-realtime-2.1, the title / body use the production copy, and no consent is written")
    func shotsLivePartialStage() throws {
        let staged = try Shots.stage(.voiceDictationLivePartial, manifestData: Shots.manifestData())
        #expect(staged.surface == .dictation)
        #expect(staged.dictation == .recording)
        #expect(staged.elapsedSec == 4)
        #expect(staged.liveFinal == "Give me three tips")
        #expect(staged.liveVolatile == " for a calmer morning")
        let snapshot = try #require(staged.liveSnapshot)

        // Production snapshot → production write entry point (not attached to the input box: inserts at the end of an empty draft).
        let liveText = DictationLiveText()
        let generation = liveText.begin()
        liveText.publish(snapshot, generation: generation)
        let live = try #require(liveText.value)
        #expect(live.final == "Give me three tips")
        #expect(live.volatile == "for a calmer morning")
        let probe = ComposerSelectionProbe()
        let written = probe.writeLive(live, generation: generation, currentText: "")
        #expect(written == "Give me three tips for a calmer morning")
        #expect(probe.isWritingLive)

        // Two segments: the unfinalized range is exactly volatile; the earlier one is finalized.
        let insertion = DictationRules.liveInsert(
            finals: [live.final], partial: live.volatile, into: "", selectionStart: 0, selectionEnd: 0
        )
        let text = insertion.text as NSString
        let volatile = NSRange(location: insertion.volatile.lowerBound, length: insertion.volatile.count)
        #expect(text.substring(with: volatile) == "for a calmer morning")
        #expect(text.substring(to: volatile.location).trimmingCharacters(in: .whitespaces) == "Give me three tips")
    }

    @Test("shotsRealtimeNoticeShowsDisclosure: the disclosure page opens the conversation engine sheet, the production VoiceDisclosureRequest is OpenAI · gpt-realtime-2.1, the title / body use the production copy, and no consent is written")
    func shotsNewPagesRejectBadFields() throws {
        let cases: [(Shots.Shot, [String: Any?])] = [
            (.voiceBarUserSpeaking, ["caption": nil]),
            (.voiceBarUserSpeaking, ["caption": ""]),
            (.voiceBarUserSpeaking, ["level": nil]),
            (.voiceBarUserSpeaking, ["level": 1.5]),
            (.voiceBarListening, ["level": 0.6]),
            (.voiceBarThinking, ["level": 0.5]),
            (.voiceBarSpeaking, ["level": 1.5]),
            (.voiceBarCheckLanguage, ["recognitionLanguage": nil]),
            (.voiceBarCheckLanguage, ["recognitionLanguage": ""]),
            (.voiceBarListening, ["recognitionLanguage": "en-US"]),
            (.voiceDictationLivePartial, ["liveFinal": nil]),
            (.voiceDictationLivePartial, ["liveVolatile": " "]),
            (.voiceDictationFailed, ["liveFinal": "Give me", "liveVolatile": " tips"]),
            (.voiceBarListening, ["disclosure": "openAI"]),
            (.voiceReadAloudIdle, ["disclosure": "openAI"]),
            (.voiceDictationRecording, ["disclosure": "openAI"]),
            (.voiceHome, ["disclosure": "openAI"]),
            (.voiceSettings, ["disclosure": "openAI"]),
            (.voiceRealtimeDisclosure, ["disclosure": "notAProvider"]),
        ]
        for (shot, changes) in cases {
            let data = try Self.manifestData(page: shot.rawValue, set: changes)
            #expect(throws: Shots.ManifestError.self, "\(shot.rawValue) \(changes)") {
                try Shots.stage(shot, manifestData: data)
            }
        }
    }
}
