import Foundation
import Testing
@testable import Oriveo

/// The 9 keys of p3-copy.v1.json land verbatim in Voice.xcstrings through settingsKeyMap.ios (16 locales, manual).
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
        #expect(keys.count == 9)
        for (id, spec) in keys {
            let values = try #require(spec["values"] as? [String: String], "\(id)")
            let key = try #require(iosMap[id], "\(id) has no iOS key")
            let entry = try #require(strings[key], "missing \(id)")
            #expect(entry["extractionState"] as? String == "manual", "\(id)")
            let localizations = try #require(entry["localizations"] as? [String: [String: [String: String]]], "\(id)")
            #expect(Set(localizations.keys) == Set(locales), "\(id)")
            for locale in locales {
                #expect(localizations[locale]?["stringUnit"]?["value"] == values[locale], "\(id) \(locale)")
            }
        }
    }

    @Test("The disclosure body fills the provider name in three places with one argument")
    func disclosureBodyRepeatsProvider() {
        let body = VoiceDisclosureSheet.message(provider: .openAI, direction: .realtime)
        #expect(body.components(separatedBy: "OpenAI").count - 1 == 3)
        #expect(!body.contains("%"))
    }
}
