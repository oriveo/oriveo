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

    /// The app target does not let the compiler extract strings. With extraction on, every
    /// Xcode build writes back into the catalogs: literals that need no translation, such as
    /// `Text("· \(x)")`, are added as empty entries, and keys reached through `L10n.tr` are
    /// marked stale because the extractor cannot see through that wrapper. Keys here are
    /// registered by hand, so extraction only produces uncommitted churn.
    @Test("the project does not extract Swift strings or generate catalog symbols")
    func projectDoesNotExtractSwiftStrings() throws {
        let project = try String(
            contentsOf: catalogsRoot
                .deletingLastPathComponent()
                .appendingPathComponent("Oriveo.xcodeproj/project.pbxproj"),
            encoding: .utf8
        )
        #expect(project.contains("SWIFT_EMIT_LOC_STRINGS = NO;"))
        #expect(!project.contains("SWIFT_EMIT_LOC_STRINGS = YES;"))
        // Nothing uses the generated symbols; they only make the build fail when two keys
        // differ by case or trailing punctuation.
        #expect(!project.contains("STRING_CATALOG_GENERATE_SYMBOLS = YES;"))
    }

    /// Stale states and entries with no localizations can only come from Xcode's extraction sync.
    @Test("catalogs carry no stale or empty entries")
    func catalogsCarryNoExtractionResidue() throws {
        let catalogs = try FileManager.default.contentsOfDirectory(at: catalogsRoot, includingPropertiesForKeys: nil)
            // InfoPlist entries come from Info.plist, not from Swift string extraction.
            .filter { $0.pathExtension == "xcstrings" && $0.lastPathComponent != "InfoPlist.xcstrings" }

        var residue: [String] = []
        for url in catalogs {
            let root = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
            let strings = root?["strings"] as? [String: [String: Any]] ?? [:]
            for (key, entry) in strings {
                if entry["extractionState"] as? String == "stale" {
                    residue.append("\(url.lastPathComponent): \"\(key)\" is stale")
                }
                if (entry["localizations"] as? [String: Any] ?? [:]).isEmpty {
                    residue.append("\(url.lastPathComponent): \"\(key)\" has no localizations")
                }
            }
        }
        #expect(
            residue.isEmpty,
            "Set stale keys back to manual and delete empty entries; use Text(verbatim:) for literals that need no translation: \(residue.sorted().prefix(20))"
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
