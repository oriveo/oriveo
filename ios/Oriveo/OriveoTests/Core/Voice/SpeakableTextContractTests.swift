import Foundation
import Testing
@testable import Oriveo

/// Checks the production SpeakableText against the three case groups in shared/voice-contracts/speakable-text.v1.json,
/// and that the output for every code point prefix (final=false) is a prefix of the full final=true output.
@Suite("Speakable text contract")
struct SpeakableTextContractTests {

    // MARK: Fixture

    private static func fixture() throws -> [String: Any] {
        var cursor = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        while cursor.path != "/" {
            let candidate = cursor.appendingPathComponent("shared/voice-contracts/speakable-text.v1.json")
            if FileManager.default.fileExists(atPath: candidate.path) {
                return try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: candidate)) as? [String: Any])
            }
            cursor.deleteLastPathComponent()
        }
        throw CocoaError(.fileNoSuchFile)
    }

    private static func cases(_ group: String) throws -> [[String: Any]] {
        try #require(try fixture()[group] as? [[String: Any]])
    }

    private static func expectedSegments(_ raw: Any?) throws -> [SpeakableSegment] {
        let items = try #require(raw as? [[String: Any]])
        return try items.map { item in
            switch item["kind"] as? String {
            case "sentence":
                return .sentence(try #require(item["text"] as? String))
            case "placeholder":
                let name = try #require(item["placeholder"] as? String)
                return .placeholder(try #require(SpeakablePlaceholder(rawValue: name)))
            default:
                throw CocoaError(.coderInvalidValue)
            }
        }
    }

    private static func describe(_ segments: [SpeakableSegment]) -> String {
        segments.map { segment in
            switch segment {
            case .sentence(let text): return "s(\(text))"
            case .placeholder(let kind): return "p(\(kind.rawValue))"
            }
        }.joined(separator: " | ")
    }

    // MARK: Cases

    @Test("cases and streamingCases match case by case")
    func segmentCasesMatchFixture() throws {
        let all = try Self.cases("cases") + Self.cases("streamingCases")
        #expect(all.count >= 30, "Too few fixture cases: \(all.count)")
        for item in all {
            let id = item["id"] as? String ?? "?"
            let input = try #require(item["input"] as? [String: Any])
            let text = try #require(input["text"] as? String)
            let final = try #require(input["final"] as? Bool)
            let expected = try Self.expectedSegments(item["expected"])
            let actual = SpeakableText.segments(text: text, final: final)
            #expect(actual == expected, "\(id)\nactual: \(Self.describe(actual))\nexpected: \(Self.describe(expected))")
        }
    }

    @Test("placeholderLocaleCases match case by case")
    func placeholderLocaleCasesMatchFixture() throws {
        let all = try Self.cases("placeholderLocaleCases")
        #expect(!all.isEmpty)
        for item in all {
            let id = item["id"] as? String ?? "?"
            let input = try #require(item["input"] as? [String: Any])
            let expected = try #require(item["expected"] as? String)
            let actual = SpeakableText.placeholderLocale(
                reading: input["readingLanguage"] as? String,
                ui: input["uiLocale"] as? String
            )
            #expect(actual == expected, "\(id): actual \(actual), expected \(expected)")
        }
    }

    @Test("Streaming output for every code point prefix is a prefix of the final output")
    func everyCodePointPrefixIsStable() throws {
        let all = try Self.cases("cases") + Self.cases("streamingCases")
        for item in all {
            let id = item["id"] as? String ?? "?"
            let input = try #require(item["input"] as? [String: Any])
            let text = try #require(input["text"] as? String)
            let full = SpeakableText.segments(text: text, final: true)
            let scalars = Array(text.unicodeScalars)
            var firstFailure: String?
            for length in 0...scalars.count {
                var view = String.UnicodeScalarView()
                view.append(contentsOf: scalars[0..<length])
                let partial = SpeakableText.segments(text: String(view), final: false)
                if partial.count > full.count || Array(full.prefix(partial.count)) != partial {
                    firstFailure = "prefix length \(length): \(Self.describe(partial))\nfinal: \(Self.describe(full))"
                    break
                }
            }
            #expect(firstFailure == nil, "\(id) \(firstFailure ?? "")")
        }
    }
}
