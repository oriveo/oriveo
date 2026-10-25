import Foundation
import Testing
@testable import Oriveo

/// The production VoiceCatalogDecoder matches the decodeCases in shared/voice-contracts/engine-resolution.v2.json.
/// Catalog "base" = the data object of shared/model-contracts/voice_catalog_contract.v2.json (the server handler's output).
@Suite("Voice catalog contract")
struct VoiceCatalogContractTests {

    // MARK: Fixtures

    static func fixture(_ relativePath: String) throws -> [String: Any] {
        var cursor = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        while cursor.path != "/" {
            let candidate = cursor.appendingPathComponent(relativePath)
            if FileManager.default.fileExists(atPath: candidate.path) {
                return try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: candidate)) as? [String: Any])
            }
            cursor.deleteLastPathComponent()
        }
        throw CocoaError(.fileNoSuchFile)
    }

    static func cases(_ group: String) throws -> [[String: Any]] {
        try #require(try fixture("shared/voice-contracts/engine-resolution.v2.json")[group] as? [[String: Any]])
    }

    static func baseCatalogData() throws -> [String: Any] {
        try #require(try fixture("shared/model-contracts/voice_catalog_contract.v2.json")["data"] as? [String: Any])
    }

    /// The catalog in a case: the string "base" is replaced by the base catalog, anything else is an inline document.
    static func catalogDocument(_ raw: Any?) throws -> Any? {
        if let name = raw as? String {
            #expect(name == "base", "Unknown catalog reference: \(name)")
            return try baseCatalogData()
        }
        return raw
    }

    static func describe(_ value: Any) -> String {
        guard JSONSerialization.isValidJSONObject(value),
              let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]) else {
            return String(describing: value)
        }
        return String(decoding: data, as: UTF8.self)
    }

    /// Renders the decoded result using the fixture's expected keys, for value comparison (not JSON text comparison).
    private static func render(_ catalog: VoiceCatalog) -> [String: Any] {
        var providers: [String: Any] = [:]
        for (kind, entries) in catalog.providers {
            providers[kind.rawValue] = [
                "stt": entries.stt.map(render),
                "tts": entries.tts.map(render),
            ]
        }
        return ["providers": providers]
    }

    private static func render(_ entry: VoiceSTTEntry) -> [String: Any] {
        var out: [String: Any] = [
            "model": entry.model,
            "transport": entry.transport.rawValue,
            "path": entry.path,
            "maxBytes": entry.maxBytes,
            "maxDurationSec": entry.maxDurationSec,
            "isDefault": entry.isDefault,
        ]
        if let languageField = entry.languageField { out["languageField"] = languageField }
        return out
    }

    private static func render(_ entry: VoiceTTSEntry) -> [String: Any] {
        var out: [String: Any] = [
            "model": entry.model,
            "transport": entry.transport.rawValue,
            "path": entry.path,
            "outputFormat": entry.outputFormat,
            "maxChars": entry.maxChars,
            "voices": entry.voices.map { ["id": $0.id, "isDefault": $0.isDefault] as [String: Any] },
            "isDefault": entry.isDefault,
        ]
        if let range = entry.speedRange { out["speedRange"] = ["min": range.min, "max": range.max] }
        return out
    }

    /// In realtimeDecodeCases, each provider's expected has only the realtime key.
    private static func renderRealtime(_ catalog: VoiceCatalog) -> [String: Any] {
        var providers: [String: Any] = [:]
        for (kind, entries) in catalog.providers {
            providers[kind.rawValue] = ["realtime": entries.realtime.map(render)]
        }
        return ["providers": providers]
    }

    private static func render(_ entry: VoiceRealtimeEntry) -> [String: Any] {
        var out: [String: Any] = [
            "model": entry.model,
            "transport": entry.transport.rawValue,
            "path": entry.path,
            "contextWindow": entry.contextWindow,
            "voices": entry.voices.map { ["id": $0.id, "isDefault": $0.isDefault] as [String: Any] },
            "isDefault": entry.isDefault,
        ]
        if let maxSessionSec = entry.maxSessionSec { out["maxSessionSec"] = maxSessionSec }
        if let model = entry.inputTranscriptionModel { out["inputTranscriptionModel"] = model }
        return out
    }

    // MARK: Cases

    @Test("The ProviderKind enum equals the fixture's knownProviderKinds item by item (so clients do not only recognize the providers that currently have voice)")
    func clientProviderKindsEqualFixture() throws {
        let constants = try #require(try Self.fixture("shared/voice-contracts/engine-resolution.v2.json")["constants"] as? [String: Any])
        let want = try #require(constants["knownProviderKinds"] as? [String])
        #expect(ProviderKind.allCases.map(\.rawValue).sorted() == want.sorted())
    }

    @Test("decodeCases all match")
    func decodeCasesMatchFixture() throws {
        let all = try Self.cases("decodeCases")
        #expect(all.count >= 6, "Too few fixture cases: \(all.count)")
        for item in all {
            let id = item["id"] as? String ?? "?"
            let input = try #require(item["input"] as? [String: Any], "\(id) is missing input")
            let expected = try #require(item["expected"] as? [String: Any], "\(id) is missing expected")
            let decoded = VoiceCatalogDecoder.decode(try Self.catalogDocument(input["catalog"]))
            let rendered = Self.render(decoded)
            #expect(
                NSDictionary(dictionary: rendered).isEqual(to: expected),
                "\(id)\nactual \(Self.describe(rendered))\nexpected \(Self.describe(expected))"
            )
        }
    }

    @Test("realtimeDecodeCases all match")
    func realtimeDecodeCasesMatchFixture() throws {
        let all = try Self.cases("realtimeDecodeCases")
        #expect(all.count >= 7, "Too few fixture cases: \(all.count)")
        for item in all {
            let id = item["id"] as? String ?? "?"
            let input = try #require(item["input"] as? [String: Any], "\(id) is missing input")
            let expected = try #require(item["expected"] as? [String: Any], "\(id) is missing expected")
            let decoded = VoiceCatalogDecoder.decode(try Self.catalogDocument(input["catalog"]))
            let rendered = Self.renderRealtime(decoded)
            #expect(
                NSDictionary(dictionary: rendered).isEqual(to: expected),
                "\(id)\nactual \(Self.describe(rendered))\nexpected \(Self.describe(expected))"
            )
        }
    }

    @Test("Base catalog: the bytes entry and the object entry agree, and revision and schemaVersion are kept")
    func baseCatalogBytesMatchObject() throws {
        let data = try Self.baseCatalogData()
        let fromObject = VoiceCatalogDecoder.decode(data)
        let fromBytes = try #require(VoiceCatalogDecoder.decode(jsonData: JSONSerialization.data(withJSONObject: data)))
        #expect(fromBytes == fromObject)
        #expect(fromObject.revision == data["revision"] as? String)
        #expect(fromObject.schemaVersion == 2)
        // SenseVoice is listed only after a real request confirmed it accepts m4a.
        #expect(fromObject.sttEntries(.siliconFlow).map(\.model) == ["FunAudioLLM/SenseVoiceSmall"])
        #expect(VoiceCatalogDecoder.decode(jsonData: Data("not json".utf8)) == nil)
    }
}
