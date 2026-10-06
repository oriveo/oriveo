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
    /// This switch only covers command-line builds; the next test covers builds from the IDE.
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

    /// Turning compiler extraction off does not stop Xcode: a build from the IDE still runs
    /// "Sync Localizations", using Xcode's own source scanner instead. (A command-line
    /// `xcodebuild` does not sync, so a check that only builds from the command line never sees it.)
    /// The sync does two things to a catalog: it changes or removes entries that are not `manual`,
    /// and it adds every literal it finds that the catalog does not have, as an empty entry. The
    /// scanner has no type information, so it writes a `%lld` key as `%@`; what it produces must
    /// not be committed as is.
    /// The catalogs therefore stay at the fixed point of that sync: every entry is `manual`, and
    /// literals that need no translation ("--", product names, `Text("\(n)%")`) are registered as
    /// `manual` with `shouldTranslate` false, which leaves Xcode nothing to add.
    @Test("catalogs sit at the fixed point of Xcode's sync: all manual, untranslated entries marked as such")
    func catalogsSitAtTheSyncFixedPoint() throws {
        let catalogs = try FileManager.default.contentsOfDirectory(at: catalogsRoot, includingPropertiesForKeys: nil)
            // InfoPlist entries come from Info.plist, not from Swift string extraction.
            .filter { $0.pathExtension == "xcstrings" && $0.lastPathComponent != "InfoPlist.xcstrings" }

        var residue: [String] = []
        for url in catalogs {
            let root = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
            let strings = root?["strings"] as? [String: [String: Any]] ?? [:]
            for (key, entry) in strings {
                let state = entry["extractionState"] as? String
                if state != "manual" {
                    residue.append("\(url.lastPathComponent): \"\(key)\" is \(state ?? "automatically extracted"), not manual")
                }
                let untranslated = (entry["localizations"] as? [String: Any] ?? [:]).isEmpty
                if untranslated, entry["shouldTranslate"] as? Bool != false {
                    residue.append("\(url.lastPathComponent): \"\(key)\" has no localizations and is not marked as not translated")
                }
            }
        }
        #expect(
            residue.isEmpty,
            """
            These entries were written by Xcode's sync after an IDE build; do not commit them as they are. \
            For a string that is translated, add the localizations and set extractionState to manual. \
            For one that is not, make the entry { "extractionState": "manual", "shouldTranslate": false }, \
            or use Text(verbatim:) and delete the entry. Keep the file in Xcode's serialization: \(residue.sorted().prefix(20))
            """
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
