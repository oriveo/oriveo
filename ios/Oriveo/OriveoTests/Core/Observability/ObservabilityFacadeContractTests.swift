import Foundation
import Testing
@testable import Oriveo

/// G2 facade exclusivity + G3 diagnostic registration (plan section 5).
///
/// - G2: nothing outside `Core/Observability/` and App entry initialization may touch the SDK directly (`import Sentry*` / `SentrySDK.`).
///   Reports that bypass the facade skip redaction and carry unregistered fingerprints, and the SDK cannot be swapped out as one block (13 direct call sites).
/// - G3: the `captureMessage` title must be a literal registered in the fixture `diagnostics.issue` (the `DiagnosticIssue` registry matches the fixture entry by entry),
///   metric names emitted by the facade must be in the fixture `metrics`. A new diagnostic that opens an issue carelessly, or interpolates variables into a title, fails here.
@Suite("ObservabilityFacadeContract")
struct ObservabilityFacadeContractTests {
    /// Files outside the facade directory that may use the SDK directly, and why.
    private static let sdkAllowlist: [String: String] = [
        "OriveoApp.swift": "App entry: reading SDK options from startup config before SentrySDK.start is part of initialization itself",
    ]

    private static let sdkPatterns = ["import Sentry", "import SentrySwiftUI", "SentrySDK."]

    private func appSources() throws -> [(relative: String, text: String)] {
        let root = TelemetryContractFixture.appSourceRoot
        let enumerator = try #require(FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil))
        var result: [(String, String)] = []
        for case let url as URL in enumerator where url.pathExtension == "swift" {
            let relative = String(url.path.dropFirst(root.path.count + 1))
            result.append((relative, try String(contentsOf: url, encoding: .utf8)))
        }
        #expect(result.count > 100, "source directory not read: \(root.path)")
        return result
    }

    /// Code lines with whole-line comments removed.
    private func codeLines(_ text: String) -> [(number: Int, line: String)] {
        text.components(separatedBy: "\n").enumerated().compactMap { index, line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.hasPrefix("//"), !trimmed.hasPrefix("///"), !trimmed.hasPrefix("*") else { return nil }
            return (index + 1, line)
        }
    }

    @Test("G2: no direct SDK calls outside the facade directory and the entry point")
    func sdkOnlyInsideFacade() throws {
        var violations: [String] = []
        for (relative, text) in try appSources() {
            if relative.hasPrefix("Core/Observability/") { continue }
            let fileName = (relative as NSString).lastPathComponent
            if Self.sdkAllowlist[fileName] != nil { continue }
            for (number, line) in codeLines(text) where Self.sdkPatterns.contains(where: { line.contains($0) }) {
                violations.append("\(relative):\(number): \(line.trimmingCharacters(in: .whitespaces))")
            }
        }
        #expect(violations.isEmpty, "SDK used directly outside the facade; route it through SentryReporter / Observability.sink:\n\(violations.joined(separator: "\n"))")
    }

    private func fixtureIssues() throws -> [[String: Any]] {
        let fixture = try TelemetryContractFixture.load()
        let diagnostics = try #require(fixture["diagnostics"] as? [String: Any])
        let issues = try #require(diagnostics["issue"] as? [[String: Any]])
        return issues.filter { ($0["platforms"] as? [String])?.contains("ios") == true }
    }

    @Test("G3: DiagnosticIssue matches the fixture diagnostics.issue (iOS) entry by entry")
    func registryMatchesFixture() throws {
        let issues = try fixtureIssues()
        let byName = Dictionary(uniqueKeysWithValues: issues.compactMap { entry in
            (entry["name"] as? String).map { ($0, entry) }
        })
        #expect(Set(byName.keys) == Set(DiagnosticIssue.allCases.map(\.rawValue)))
        for issue in DiagnosticIssue.allCases {
            guard let entry = byName[issue.rawValue] else { continue }
            #expect(entry["level"] as? String == issue.level.rawValue, "\(issue.rawValue) level")
            #expect(entry["module"] as? String == issue.module, "\(issue.rawValue) module")
            #expect(entry["fingerprint"] as? [String] == issue.fingerprintTemplate, "\(issue.rawValue) fingerprint")
        }
    }

    @Test("G3: fingerprint templates fill values by tag, and missing ones fill as unknown")
    func fingerprintTemplateFilledFromTags() {
        #expect(DiagnosticIssue.backupConvergeDegraded.fingerprint(tags: ["stage": "providers_pull"])
            == ["backup.converge_degraded", "providers_pull"])
        #expect(DiagnosticIssue.backupConvergeDegraded.fingerprint(tags: [:]) == ["backup.converge_degraded", "unknown"])
        #expect(DiagnosticIssue.syncClockSkew.fingerprint(tags: ["x": "y"]) == ["sync.clock_skew"])
    }

    @Test("G3: every captureMessage title is a registered literal")
    func captureMessageTitlesRegistered() throws {
        let registered = Set(DiagnosticIssue.allCases.map(\.rawValue))
        let call = try NSRegularExpression(pattern: #"captureMessage\(\s*(\S)"#)
        let literal = try NSRegularExpression(pattern: #"captureMessage\(\s*"((?:[^"\\]|\\.)*)""#)
        var problems: [String] = []
        var seen = 0
        for (relative, text) in try appSources() {
            let code = codeLines(text).map(\.line).joined(separator: "\n")
            let range = NSRange(code.startIndex..., in: code)
            for match in call.matches(in: code, range: range) {
                // Skip the definition itself (`static func captureMessage(_ message: …`).
                guard let callRange = Range(match.range, in: code), !code[..<callRange.lowerBound].hasSuffix("func ") else { continue }
                if (code as NSString).substring(with: match.range(at: 1)) != "\"" {
                    problems.append("\(relative): title is not a literal (\(code[callRange]))")
                }
            }
            for match in literal.matches(in: code, range: range) {
                seen += 1
                let title = (code as NSString).substring(with: match.range(at: 1))
                if title.contains("\\(") {
                    problems.append("\(relative): title interpolates a variable: \(title)")
                } else if !registered.contains(title) {
                    problems.append("\(relative): title \"\(title)\" is not registered in fixture diagnostics.issue")
                }
            }
        }
        #expect(seen >= 4, "no captureMessage call found; the scan rule may be broken")
        #expect(problems.isEmpty, "\n\(problems.joined(separator: "\n"))")
    }

    @Test("G3: every metric name emitted by the facade is in the fixture metrics")
    func metricNamesRegistered() throws {
        let fixture = try TelemetryContractFixture.load()
        let metrics = try #require(fixture["metrics"] as? [[String: Any]])
        let registered = Set(metrics.filter { ($0["platforms"] as? [String])?.contains("ios") == true }
            .compactMap { $0["name"] as? String })
        let pattern = try NSRegularExpression(pattern: #"\.(?:count|distribution)\(\s*"([^"]+)""#)
        var unregistered: [String] = []
        var seen: Set<String> = []
        for (relative, text) in try appSources() {
            let code = codeLines(text).map(\.line).joined(separator: "\n")
            for match in pattern.matches(in: code, range: NSRange(code.startIndex..., in: code)) {
                let name = (code as NSString).substring(with: match.range(at: 1))
                seen.insert(name)
                if !registered.contains(name) { unregistered.append("\(relative): \(name)") }
            }
        }
        // The ledger's two distributions are emitted with constants (see DatabaseWriteLedger.metrics(for:)); DatabaseWriteLedgerTests covers their values.
        for constant in [DatabaseWriteLedger.mainThreadWriteMetric, DatabaseWriteLedger.longWriteMetric] {
            seen.insert(constant)
            #expect(registered.contains(constant), "\(constant)")
        }
        #expect(unregistered.isEmpty, "\n\(unregistered.joined(separator: "\n"))")
        // Reverse check: the fixture registers iOS metrics, but production source emits none of them, so they are dead metrics.
        #expect(registered.subtracting(seen).isEmpty, "registered in the fixture but never emitted in production: \(registered.subtracting(seen).sorted())")
    }
}
