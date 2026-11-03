import Foundation
import Testing
@testable import Oriveo

/// All current keys of p3-copy.v1.json are copied verbatim into Voice.xcstrings (16 locales, manual).
/// iOS source strings: use the mapped value when settingsKeyMap.ios has a mapping, otherwise the key's en original text.
@Suite("Voice settings P3 copy")
struct VoiceSettingsP3CopyTests {
    private static func repoFile(_ relative: String) throws -> URL {
        var cursor = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        while cursor.path != "/" {
            let candidate = cursor.appendingPathComponent(relative)
            if FileManager.default.fileExists(atPath: candidate.path) { return candidate }
            cursor.deleteLastPathComponent()
        }
        throw CocoaError(.fileNoSuchFile)
    }

    private static func json(_ url: URL) throws -> [String: Any] {
        try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
    }

    @Test("9 keys x 16 locales equal p3-copy.v1.json verbatim, extractionState = manual")
    func p3CopyInVoiceTable() throws {
        let copy = try Self.json(Self.repoFile("shared/voice-contracts/p3-copy.v1.json"))
        let table = try Self.json(Self.repoFile("ios/Oriveo/Oriveo/Voice.xcstrings"))
        let strings = try #require(table["strings"] as? [String: [String: Any]])
        let keys = try #require(copy["keys"] as? [String: [String: Any]])
        let locales = try #require(copy["locales"] as? [String])
        #expect(locales.count == 16)
        let iosMap = try #require((copy["settingsKeyMap"] as? [String: Any])?["ios"] as? [String: String])
        // 29 keys minus the 7 retired keys, plus the live-row subtitle, plus the live filter chip with count copy, plus the engine-switch status row, plus the three live-settings voice group keys, plus the "Loading model" screen-reader copy while the voice catalog loads
        #expect(keys.count == 29)
        for (id, spec) in keys {
            let values = try #require(spec["values"] as? [String: String], "\(id)")
            let key = try #require(iosMap[id] ?? values["en"], "\(id) has no iOS key")
            let entry = try #require(strings[key], "missing \(id)")
            #expect(entry["extractionState"] as? String == "manual", "\(id)")
            let localizations = try #require(entry["localizations"] as? [String: [String: [String: String]]], "\(id)")
            #expect(Set(localizations.keys) == Set(locales), "\(id)")
            for locale in locales {
                #expect(localizations[locale]?["stringUnit"]?["value"] == values[locale], "\(id) \(locale)")
            }
        }
    }

    /// The 7 iOS keys retired in the last round (equal to their old en original text): must not stay in Voice.xcstrings, and must not be referenced again.
    private static let retiredKeys = [
        "Voice Conversation",
        "Conversation Engine",
        "Follow Current Model",
        "Dictation → current model → read aloud",
        "A realtime model hears you and answers directly, so replies come faster, but this chat's model isn't used.",
        "Your conversation engine isn't available anymore, so this conversation uses the current model.",
        "Switched back to Follow Current Model.",
    ]

    @Test("The 7 retired keys are not in Voice.xcstrings and source no longer references them")
    func retiredVoiceCopyIsGone() throws {
        let table = try Self.json(Self.repoFile("ios/Oriveo/Oriveo/Voice.xcstrings"))
        let strings = try #require(table["strings"] as? [String: Any])
        for key in Self.retiredKeys {
            #expect(strings[key] == nil, "Voice.xcstrings still contains the retired key: \(key)")
        }
        let sources = try Self.repoFile("ios/Oriveo/Oriveo")
        var offenders: [String] = []
        let files = FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil)
        while let url = files?.nextObject() as? URL {
            guard url.pathExtension == "swift",
                  let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
            for key in Self.retiredKeys where text.contains("\"\(key)\"") {
                offenders.append("\(url.lastPathComponent): \(key)")
            }
        }
        #expect(offenders.isEmpty, "Source still references retired copy: \(offenders)")
    }

    @Test("The disclosure body fills the provider name in three places with one argument, verbatim equal to the p3-copy en text")
    func disclosureBodyRepeatsProvider() throws {
        let copy = try Self.json(Self.repoFile("shared/voice-contracts/p3-copy.v1.json"))
        let spec = try #require((copy["keys"] as? [String: [String: Any]])?["voice_realtime_disclosure_body"])
        let en = try #require((spec["values"] as? [String: String])?["en"])
        let body = VoiceDisclosureSheet.message(provider: .openAI, direction: .realtime)
        #expect(body == en.replacingOccurrences(of: "%1$@", with: "OpenAI"))
        #expect(body.components(separatedBy: "OpenAI").count - 1 == 3)
        #expect(!body.contains("%"))
    }
}
