import Foundation
import Testing
@testable import Oriveo

/// Model identifiers wrap only after "-", "_", or "/": the display string inserts U+200B after separators, while screen readers and copy use the raw id (same test case names as Android).
@Suite("Model identifier breaks")
struct ModelIdentifierBreaksTests {

    private static let zwsp = "\u{200B}"

    @Test("Inserts one zero-width space after each separator and leaves other characters unchanged")
    func modelIdBreaksAtSeparators() {
        let z = Self.zwsp
        #expect(
            ModelIdentifierBreaks.displayTitle("gemini-3.8-live-extended-thinking")
                == "gemini-\(z)3.8-\(z)live-\(z)extended-\(z)thinking"
        )
        #expect(ModelIdentifierBreaks.displayTitle("a_b/c") == "a_\(z)b/\(z)c")
        #expect(ModelIdentifierBreaks.displayTitle("GPT 5.4") == "GPT 5.4")
        #expect(ModelIdentifierBreaks.displayTitle("") == "")
    }

    @Test("Removing zero-width spaces from the display string yields the raw id; the four model rows display via displayTitle and use the raw id for the accessibility label")
    func accessibilityUsesRawId() throws {
        let raw = "gemini-3.8-live-extended-thinking"
        #expect(ModelIdentifierBreaks.displayTitle(raw).replacingOccurrences(of: Self.zwsp, with: "") == raw)

        let rows: [(file: String, from: String, to: String, raw: String)] = [
            ("Home/HomeModelPickerSheet.swift", "private struct ModelPickerRow: View", "rowMetadata", "title"),
            ("Home/HomeModelPickerSheet.swift", "private struct ModelPickerRealtimeRow", "Realtime voice", "model"),
            ("Settings/VoiceSettingsView.swift", "private func realtimeRow", "row.subtitle", "row.model"),
            ("Providers/ProviderRealtimeModelsSection.swift", "struct ProviderRealtimeModelRow", "Realtime voice", "model"),
        ]
        for row in rows {
            let source = try Self.featureSource(row.file)
            let start = try #require(source.range(of: row.from), "\(row.file): \(row.from)")
            let end = try #require(source.range(of: row.to, range: start.upperBound..<source.endIndex), "\(row.file): \(row.to)")
            let slice = source[start.upperBound..<end.lowerBound]
            #expect(slice.contains("Text(ModelIdentifierBreaks.displayTitle(\(row.raw)))"), "\(row.file)")
            #expect(slice.contains(".accessibilityLabel(\(row.raw))"), "\(row.file)")
        }
    }

    private static func featureSource(_ relativePath: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let url = root.appendingPathComponent("Oriveo/Features/\(relativePath)")
        return try String(contentsOf: url, encoding: .utf8)
    }
}
