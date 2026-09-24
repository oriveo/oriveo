import Foundation
import Testing

/// In data-related strings, local means "on this device". Older translations used the geographic sense
/// ("area / region"): th "ข้อมูลท้องถิ่น" or "ในพื้นที่", vi "địa phương". Local time (th เวลาท้องถิ่น,
/// vi giờ địa phương) and local network (th เครือข่ายท้องถิ่น) really mean that and are allowed.
@Suite("local (on this device) in th / vi")
struct LocalMeaningLocalizationTests {
    private static let geographic = [
        "th": "(?<!เวลา|เครือข่าย)ท้องถิ่น|ในพื้นที่",
        "vi": "(?i)(?<!giờ )địa phương",
    ]

    @Test("th / vi do not render data on this device as a geographic place")
    func localIsNotAPlace() throws {
        let catalogs = try FileManager.default.contentsOfDirectory(at: catalogsRoot, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "xcstrings" }
        #expect(catalogs.count >= 10, "too few xcstrings tables found: \(catalogs.count)")

        var problems: [String] = []
        for url in catalogs {
            let root = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
            let strings = try #require(root["strings"] as? [String: Any])
            for (key, raw) in strings {
                let localizations = (raw as? [String: Any])?["localizations"] as? [String: Any] ?? [:]
                let english = value(localizations["en"]) ?? key
                guard english.range(of: "(?i)\\blocal\\b", options: .regularExpression) != nil else { continue }
                for (locale, pattern) in Self.geographic {
                    guard let text = value(localizations[locale]),
                          text.range(of: pattern, options: .regularExpression) != nil else { continue }
                    problems.append("\(url.deletingPathExtension().lastPathComponent) \(key) [\(locale)]: \(text)")
                }
            }
        }
        #expect(problems.isEmpty, "local translated in its geographic sense:\n\(problems.joined(separator: "\n"))")
    }

    private func value(_ localeEntry: Any?) -> String? {
        ((localeEntry as? [String: Any])?["stringUnit"] as? [String: Any])?["value"] as? String
    }

    private var catalogsRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Oriveo")
    }
}
