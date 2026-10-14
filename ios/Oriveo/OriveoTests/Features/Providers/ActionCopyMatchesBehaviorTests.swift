import Foundation
import Testing
@testable import Oriveo

/// A button's title must say what it does. The local compute "context too long" recovery button said "Retry", but
/// tapping it only clears the error and moves focus to the model field; it does not retry.
@Suite("Button titles match their actions")
struct ActionCopyMatchesBehaviorTests {
    @Test("Recoveries without a landing point show no button, and the rest map to their real action instead of Retry")
    func shortenContextRecoveryTitleMatchesItsAction() throws {
        // The local page no longer has a model slot: "choose another model" recoveries (no model / context too long)
        // have nowhere to land, so only the error is shown with no button, and it must never fall back to a button
        // that says "Retry" without retrying. The other recovery actions each have a landing point.
        #expect(LocalRecoveryButton(.chooseModel) == nil)
        #expect(LocalRecoveryButton(.shortenContext) == nil)
        #expect(LocalRecoveryButton(.editAddress) == .editAddress)
        #expect(LocalRecoveryButton(.chooseEngine) == .chooseEngine)
        #expect(LocalRecoveryButton(.openSettings) == .openSettings)
        for action: LocalConnectionRecoveryAction in [.waitAndRetry, .startEngine, .freeMemory] {
            #expect(LocalRecoveryButton(action) == .retry)
        }
        let source = try ProductionSource.read("Features/Providers/LocalComputeSetupView.swift")
        #expect(!source.contains("accessibilityFocus = .model"))
        #expect(!source.contains("local_compute_recovery_choose_model_button"))
        #expect(!source.contains("local_compute_recovery_shorten_context_button"))
    }

    /// The arms of the switch in a function: `case .a, .b: <expression>` or `case .a:` followed by a block on the
    /// next lines. Returns each case pattern mapped to its arm (whitespace collapsed).
    private static func switchArms(in source: String, function signature: String) throws -> [String: String] {
        let start = try #require(source.range(of: signature), "\(signature) not found")
        let body = source[start.upperBound...]
        let end = body.range(of: "\n    }\n")?.lowerBound ?? body.endIndex
        var arms: [String: String] = [:]
        var currentPatterns: [String] = []
        var currentBody: [String] = []
        func flush() {
            let text = currentBody.joined(separator: " ").trimmingCharacters(in: .whitespaces)
            for pattern in currentPatterns { arms[pattern] = text }
            currentPatterns = []
            currentBody = []
        }
        for rawLine in body[..<end].split(separator: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("case "), let colon = line.firstIndex(of: ":") {
                flush()
                currentPatterns = line[line.index(line.startIndex, offsetBy: 5)..<colon]
                    .split(separator: ",")
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                let tail = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
                if !tail.isEmpty { currentBody.append(tail) }
            } else if !currentPatterns.isEmpty, line != "}", !line.hasPrefix("switch ") {
                currentBody.append(line)
            }
        }
        flush()
        return arms
    }
}
