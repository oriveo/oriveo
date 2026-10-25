import Foundation
import Testing
@testable import Oriveo

/// Voice page family screenshots read the shared manifest `shared/test-fixtures/shots/voice.v1.json`: the set of page names matches this app's page-name table;
/// the eleven pages of read aloud / main button / home / voice bar can be built from the manifest; the status of the six voice bar pages maps through production to the DisplayState of the same name;
/// the state of the four dictation pages goes through the production DictationPresentation to a recording bar / busy state / card;
/// the catalog of the four settings pages comes from the shared catalog contract through the production decoder, and the conversation engine row shows the manifest's realtime model through the production settings model.
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
        #expect(staged.count == 11)
        for (shot, page) in staged {
            #expect(page.messages.map(\.text) == manifest.conversation.map(\.text), "\(shot.rawValue)")
            #expect(page.messages.last?.role == .assistant, "\(shot.rawValue)")
        }
        #expect(staged[.voiceReadAloudIdle]?.readAloud == .idle)
        #expect(staged[.voiceReadAloudSpeaking]?.readAloud == .speaking)
        #expect(staged[.voiceComposerButton]?.surface == .composer)
        #expect(staged[.voiceHome]?.surface == .home)
        #expect(staged[.voiceHomeDraft]?.surface == .home)
    }

    @Test("shotsManifestBarStatusMapsToDisplayState: the status of the six voice bar pages maps through production to the DisplayState of the same name")
    func shotsManifestBarStatusMapsToDisplayState() throws {
        let barPages = try Self.rawPages().filter { $0["surface"] as? String == "voiceBar" }
        #expect(barPages.count == 6)
        for raw in barPages {
            let name = try #require(raw["name"] as? String)
            let status = try #require(raw["status"] as? String)
            let shot = try #require(Shots.Shot(rawValue: name))
            let staged = try Shots.stage(shot, manifestData: Shots.manifestData())
            #expect(staged.status?.rawValue == status, "\(name)")
            #expect(staged.barDisplayState?.rawValue == status, "\(name)")
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

        // Recording: the timer takes the manifest's elapsedSec=12 and goes through the production mapping to the recording bar.
        let recording = try #require(staged[.voiceDictationRecording]?.dictationState(now: now))
        #expect(recording == .recording(startedAt: now.addingTimeInterval(-12)))
        #expect(DictationPresentation.inputRow(for: recording, engineInfo: nil) == .recording(startedAt: now.addingTimeInterval(-12)))
        #expect(DictationPresentation.card(for: recording, savedDuration: nil) == nil)
        // The level bars take the manifest's dictationLevels (the same values on every platform) and attach only to the recording page.
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
        let failedCard = try #require(DictationPresentation.card(for: failed, savedDuration: nil))
        #expect(failedCard.title == L10n.tr("Transcription failed", table: .voice))
        #expect(failedCard.subtitle == L10n.tr("Connection unavailable. Recording saved", table: .voice))
        #expect(failedCard.secondary == .discard)
        #expect(failedCard.primary == .checkConnection)

        // Interrupted: the interrupted-recording card.
        let interrupted = try #require(staged[.voiceDictationInterrupted]?.dictationState(now: now))
        #expect(interrupted == .interrupted)
        let interruptedCard = try #require(DictationPresentation.card(for: interrupted, savedDuration: nil))
        #expect(interruptedCard.title == L10n.tr("Recording interrupted", table: .voice))
        #expect(interruptedCard.primary == .transcribeRecording)
    }

    private static let settingsShots: [Shots.Shot] = [.voiceSettings, .voiceEngineSheet, .voiceRealtimeRow, .voiceRealtimeNotice]

    @Test("shotsSettingsFourPagesStage: the four settings pages are built from the manifest, and the catalog comes from voice_catalog_contract.v2.json through the production decoder")
    func shotsSettingsFourPagesStage() throws {
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
            #expect(settings.realtime == Shots.DictationEngine(provider: "openAI", model: "gpt-realtime-2.1"))
            staged[shot] = settings
        }
        #expect(staged[.voiceSettings]?.sheetDirection == nil)
        #expect(staged[.voiceEngineSheet]?.sheetDirection == .stt)
        #expect(staged[.voiceRealtimeRow]?.scrollTo == .realtimeEngine)
        #expect(staged[.voiceRealtimeRow]?.realtimeNotice == .acknowledged)
        #expect(staged[.voiceRealtimeNotice]?.sheetDirection == .realtime)
        #expect(staged[.voiceRealtimeNotice]?.disclosure == .openAI)
        #expect(staged[.voiceEngineSheet]?.disclosure == nil)
    }

    @Test("shotsRealtimeRowShowsChosenModel: after injection the production settings model's conversation engine row shows gpt-realtime-2.1 with no disclosure, the dictation engine is OpenAI, and the sheet ticks gpt-transcribe")
    func shotsRealtimeRowShowsChosenModel() async throws {
        let appState = AppState(seedDemoData: true)
        let row = try #require(try Shots.stage(.voiceRealtimeRow, manifestData: Shots.manifestData()).settings)
        let injection = row.injection(seedProviders: appState.providers)
        #expect(injection.providers.map(\.kind) == [.openAI, .groq])
        #expect(injection.scrollToRealtimeEngine)
        #expect(injection.openEngineSheet == nil)
        defer { VoiceSettingsModel.shotsInjection = nil }
        VoiceSettingsModel.shotsInjection = injection
        let model = VoiceSettingsModel(providers: { [] })
        await model.load()
        #expect(model.realtimeEngine == VoiceSettingsModel.realtimeRow(for: .cloud(VoiceCloudEngine(
            providerKind: .openAI,
            connectionID: injection.providers[0].id.uuidString,
            model: "gpt-realtime-2.1"
        ))))
        #expect(model.realtimeEngine.subtitle.contains("gpt-realtime-2.1"))
        #expect(model.realtimeNotice == nil)
        #expect(model.dictationEngine.title == ProviderKind.openAI.displayName)
        #expect(model.dictationNotice == nil)
        let sheet = model.engineSheetModel(for: .stt)
        #expect(sheet.rows.first { $0.isSelected }?.id.hasSuffix("|gpt-transcribe") == true)

        // The voiceSettings page does not write a conversation engine choice: the row follows the current model.
        let settingsPage = try #require(try Shots.stage(.voiceSettings, manifestData: Shots.manifestData()).settings)
        VoiceSettingsModel.shotsInjection = settingsPage.injection(seedProviders: appState.providers)
        let settingsModel = VoiceSettingsModel(providers: { [] })
        await settingsModel.load()
        #expect(settingsModel.realtimeEngine == VoiceSettingsModel.realtimeRow(for: .system))
        #expect(settingsModel.realtimeEngine.subtitle == L10n.tr("Follow Current Model", table: .voice))
        #expect(settingsModel.dictationEngine.title == ProviderKind.openAI.displayName)

        let sheetPage = try #require(try Shots.stage(.voiceEngineSheet, manifestData: Shots.manifestData()).settings)
        #expect(sheetPage.injection(seedProviders: appState.providers).openEngineSheet == .stt)
    }

    @Test("shotsRealtimeNoticeShowsDisclosure: the disclosure page opens the conversation engine sheet, the production VoiceDisclosureRequest is OpenAI · gpt-realtime-2.1, the title / body use the production copy, and no consent is written")
    func shotsRealtimeNoticeShowsDisclosure() async throws {
        let appState = AppState(seedDemoData: true)
        let page = try #require(try Shots.stage(.voiceRealtimeNotice, manifestData: Shots.manifestData()).settings)
        let injection = page.injection(seedProviders: appState.providers)
        #expect(injection.openEngineSheet == .realtime)
        let engine = try #require(injection.disclosure)
        #expect(engine.providerKind == .openAI)
        #expect(engine.model == "gpt-realtime-2.1")
        defer { VoiceSettingsModel.shotsInjection = nil }
        VoiceSettingsModel.shotsInjection = injection
        let model = VoiceSettingsModel(providers: { [] })
        await model.load()
        // The conversation engine is still being chosen: the row still follows the current model.
        #expect(model.realtimeEngine == VoiceSettingsModel.realtimeRow(for: .system))
        let flow = VoiceEngineSheetFlow(model: model.engineSheetModel(for: .realtime))
        flow.showDisclosureForShots(engine)
        let request = try #require(flow.disclosure)
        #expect(request.direction == .realtime)
        #expect(request.engine.providerKind == .openAI)
        #expect(VoiceDisclosureSheet.title(provider: request.engine.providerKind, direction: request.direction)
            == L10n.format(L10n.tr("Use %1$@ for Voice Conversations?", table: .voice), ProviderKind.openAI.displayName))
        #expect(VoiceDisclosureSheet.message(provider: request.engine.providerKind, direction: request.direction)
            .contains(ProviderKind.openAI.displayName))
        #expect(!injection.settings.disclosures.hasAccepted(.openAI, direction: .realtime))
    }
}
