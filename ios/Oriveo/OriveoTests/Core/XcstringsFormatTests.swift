import Foundation
import Testing

/// String catalogs must stay in Xcode's own serialization. A catalog written as `"key": value` (or with keys
/// in a different order) is rewritten in full by Xcode as soon as it touches one key, leaving a huge diff.
@Suite("xcstrings format")
struct XcstringsFormatTests {
    @Test("every xcstrings file matches Xcode's serialization byte for byte")
    func catalogsUseXcodeSerialization() throws {
        let catalogs = try FileManager.default.contentsOfDirectory(at: catalogsRoot, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "xcstrings" }
        #expect(catalogs.count >= 5, "too few xcstrings found: \(catalogs.count)")

        var drifted: [String] = []
        for url in catalogs {
            let raw = try Data(contentsOf: url)
            let object = try JSONSerialization.jsonObject(with: raw)
            let formatted = try JSONSerialization.data(
                withJSONObject: object,
                options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            )
            if formatted != raw { drifted.append(url.lastPathComponent) }
        }
        #expect(
            drifted.isEmpty,
            "not in Xcode format; from the ios directory run swift scripts/xcstrings-format.swift Oriveo/Oriveo/<file>: \(drifted.sorted())"
        )
    }

    private var catalogsRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Oriveo")
    }
}
