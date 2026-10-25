import Foundation
import Testing
@testable import Oriveo

/// VoiceEngineSettings defaults, store/load round trips, and fallback rewriting.
@Suite("Voice engine settings")
struct VoiceEngineSettingsTests {

    private static func makeDefaults() -> (UserDefaults, String) {
        let suiteName = "VoiceEngineSettingsTests-\(UUID().uuidString)"
        return (UserDefaults(suiteName: suiteName)!, suiteName)
    }

    private static func catalog(sttModel: String, ttsModel: String) -> VoiceCatalog {
        VoiceCatalogDecoder.decode([
            "providers": [
                "openAI": [
                    "stt": [[
                        "model": sttModel,
                        "transport": "openai_transcriptions",
                        "path": "/v1/audio/transcriptions",
                        "maxBytes": 25_000_000,
                        "maxDurationSec": 600,
                    ]],
                    "tts": [[
                        "model": ttsModel,
                        "transport": "openai_speech",
                        "path": "/v1/audio/speech",
                        "outputFormat": "mp3",
                        "maxChars": 4096,
                        "voices": [["id": "alloy"], ["id": "nova", "isDefault": true]],
                    ]],
                ],
            ],
        ] as [String: Any])
    }

    @Test("Defaults to system")
    func defaultsToSystem() {
        let (defaults, suiteName) = Self.makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let settings = VoiceEngineSettings(defaults: defaults)

        #expect(settings.selection(for: .stt) == .system)
        #expect(settings.selection(for: .tts) == .system)
        #expect(settings.recognitionLanguage == nil)
        #expect(settings.speechRate == 1.0)
    }

    @Test("Store and load round trip")
    func roundTrip() {
        let (defaults, suiteName) = Self.makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let stt = VoiceCloudEngine(providerKind: .openAI, connectionID: "c1", model: "stt-m")
        let tts = VoiceCloudEngine(providerKind: .grok, connectionID: "c2", model: "tts-m", voice: "nova")

        let writer = VoiceEngineSettings(defaults: defaults)
        writer.setSelection(.cloud(stt), for: .stt)
        writer.setSelection(.cloud(tts), for: .tts)
        writer.recognitionLanguage = "zh-Hans"
        writer.speechRate = 1.25

        // A new instance reads back from the same UserDefaults.
        let reader = VoiceEngineSettings(defaults: defaults)
        #expect(reader.selection(for: .stt) == .cloud(stt))
        #expect(reader.selection(for: .tts) == .cloud(tts))
        #expect(reader.recognitionLanguage == "zh-Hans")
        #expect(reader.speechRate == 1.25)

        // The two directions are independent; clearing the recognition language returns to automatic.
        reader.setSelection(.system, for: .stt)
        reader.recognitionLanguage = nil
        #expect(writer.selection(for: .stt) == .system)
        #expect(writer.selection(for: .tts) == .cloud(tts))
        #expect(writer.recognitionLanguage == nil)
    }

    @Test("Conversation engine: key voice.engine.realtime, stores the voice, and is independent of dictation / read-aloud")
    func realtimeSelectionRoundTrip() throws {
        let (defaults, suiteName) = Self.makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let engine = VoiceCloudEngine(providerKind: .gemini, connectionID: "g", model: "gemini-live", voice: "Kore")

        let writer = VoiceEngineSettings(defaults: defaults)
        #expect(writer.selection(for: .realtime) == .system)
        writer.setSelection(.cloud(engine), for: .realtime)

        #expect(defaults.data(forKey: "voice.engine.realtime") != nil)
        #expect(defaults.data(forKey: "voice.engine.stt") == nil)
        #expect(defaults.data(forKey: "voice.engine.tts") == nil)
        let reader = VoiceEngineSettings(defaults: defaults)
        #expect(reader.selection(for: .realtime) == .cloud(engine))
        #expect(reader.selection(for: .stt) == .system)

        // The pending fallback notice is likewise recorded per the realtime direction.
        reader.apply(.system(fallback: .keyMissing), for: .realtime, site: .use)
        #expect(reader.selection(for: .realtime) == .system)
        #expect(defaults.string(forKey: "voice.engine.pendingNotice.settings.realtime") == "key_missing")
        #expect(reader.takePendingNotice(site: .settings, direction: .realtime) == .keyMissing)
    }

    @Test("When resolve returns persist=system, the selection is rewritten to system")
    func resolvePersistsSystemOnFallback() {
        let (defaults, suiteName) = Self.makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let settings = VoiceEngineSettings(defaults: defaults)
        let connections = [VoiceConnection(id: "c1", providerKind: .openAI, authMode: .apiKey, hasKey: true)]
        let catalog = Self.catalog(sttModel: "stt-m", ttsModel: "tts-m")

        // The entry is still there: the selection is kept; when the voice is not in the catalog the effective voice is the default one, but storage is not changed.
        let tts = VoiceCloudEngine(providerKind: .openAI, connectionID: "c1", model: "tts-m", voice: "gone")
        settings.setSelection(.cloud(tts), for: .tts)
        let kept = settings.resolve(direction: .tts, catalog: catalog, connections: connections, site: .use)
        #expect(kept.persist == .keep)
        #expect(kept == .cloud(VoiceCloudEngine(providerKind: .openAI, connectionID: "c1", model: "tts-m", voice: "nova")))
        #expect(settings.selection(for: .tts) == .cloud(tts))

        // The entry is removed: fall back and rewrite to system, leaving the other direction alone.
        let stt = VoiceCloudEngine(providerKind: .openAI, connectionID: "c1", model: "removed")
        settings.setSelection(.cloud(stt), for: .stt)
        let fallback = settings.resolve(direction: .stt, catalog: catalog, connections: connections, site: .use)
        #expect(fallback == .system(fallback: .entryRemoved))
        #expect(fallback.persist == .system)
        #expect(settings.selection(for: .stt) == .system)
        #expect(settings.selection(for: .tts) == .cloud(tts))

        // The connection is gone: rewritten likewise.
        settings.setSelection(.cloud(tts), for: .tts)
        let missing = settings.resolve(direction: .tts, catalog: catalog, connections: [], site: .use)
        #expect(missing == .system(fallback: .connectionMissing))
        #expect(settings.selection(for: .tts) == .system)
    }

    @Test("Pending fallback notice: none stays at the site that found it, one is left for the other site, it is cleared once taken, and the two directions are independent")
    func fallbackLeavesOnePendingNoticeForTheOtherSite() {
        let (defaults, suiteName) = Self.makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let settings = VoiceEngineSettings(defaults: defaults)
        let connections = [VoiceConnection(id: "c1", providerKind: .openAI, authMode: .apiKey, hasKey: true)]
        let catalog = Self.catalog(sttModel: "stt-m", ttsModel: "tts-m")

        // The use site finds the stt entry withdrawn: the settings site gets one notice and the use site gets none.
        settings.setSelection(.cloud(VoiceCloudEngine(providerKind: .openAI, connectionID: "c1", model: "removed")), for: .stt)
        let used = settings.resolve(direction: .stt, catalog: catalog, connections: connections, site: .use)
        #expect(used == .system(fallback: .entryRemoved))
        #expect(settings.takePendingNotice(site: .use, direction: .stt) == nil)
        // The other direction is unaffected.
        #expect(settings.takePendingNotice(site: .settings, direction: .tts) == nil)
        // A new instance reads it from the same UserDefaults; it is cleared once taken.
        let reader = VoiceEngineSettings(defaults: defaults)
        #expect(reader.takePendingNotice(site: .settings, direction: .stt) == .entryRemoved)
        #expect(reader.takePendingNotice(site: .settings, direction: .stt) == nil)

        // The settings site finds the tts connection gone: the use site gets one notice and the settings site gets none; nothing is left over for stt.
        settings.setSelection(.cloud(VoiceCloudEngine(providerKind: .openAI, connectionID: "c1", model: "tts-m", voice: "nova")), for: .tts)
        settings.resolve(direction: .tts, catalog: catalog, connections: [], site: .settings)
        #expect(settings.takePendingNotice(site: .settings, direction: .tts) == nil)
        #expect(settings.takePendingNotice(site: .use, direction: .stt) == nil)
        #expect(settings.takePendingNotice(site: .settings, direction: .stt) == nil)
        #expect(settings.takePendingNotice(site: .use, direction: .tts) == .connectionMissing)
        #expect(settings.takePendingNotice(site: .use, direction: .tts) == nil)
    }

    @Test("A resolution without a notice (kept / already system) leaves no pending notice")
    func resolutionWithoutNoticeLeavesNothingPending() {
        let (defaults, suiteName) = Self.makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let settings = VoiceEngineSettings(defaults: defaults)
        let connections = [VoiceConnection(id: "c1", providerKind: .openAI, authMode: .apiKey, hasKey: true)]
        let catalog = Self.catalog(sttModel: "stt-m", ttsModel: "tts-m")

        settings.setSelection(.cloud(VoiceCloudEngine(providerKind: .openAI, connectionID: "c1", model: "stt-m")), for: .stt)
        let kept = settings.resolve(direction: .stt, catalog: catalog, connections: connections, site: .use)
        #expect(kept.notice == false)
        let system = settings.resolve(direction: .tts, catalog: catalog, connections: connections, site: .settings)
        #expect(system == .system(fallback: nil))
        for site in [VoiceNoticeSite.settings, .use] {
            for direction in VoiceDirection.allCases {
                #expect(settings.takePendingNotice(site: site, direction: direction) == nil)
            }
        }
    }
}
