import Foundation
import Testing
@testable import Oriveo

/// A button's title must say what it does. The local compute "context too long" recovery button said "Retry", but
/// tapping it only clears the error and moves focus to the model field; it does not retry.
@Suite("Button titles match their actions")
struct ActionCopyMatchesBehaviorTests {
    @Test("The context-too-long recovery button does the same as choosing a model and says so, not Retry")
    func shortenContextRecoveryTitleMatchesItsAction() throws {
        let source = try ProductionSource.read("Features/Providers/LocalComputeSetupView.swift")
        let titles = try Self.switchArms(in: source, function: "private func recoveryTitle(for action: LocalConnectionRecoveryAction)")
        let actions = try Self.switchArms(in: source, function: "private func performRecovery(_ action: LocalConnectionRecoveryAction)")

        // Action side: shortenContext and chooseModel do the same thing (clear the error, focus the model field)
        #expect(actions[".shortenContext"] != nil)
        #expect(actions[".shortenContext"] == actions[".chooseModel"])
        // The title follows the action
        let title = try #require(titles[".shortenContext"], "recoveryTitle has no .shortenContext")
        #expect(title == titles[".chooseModel"], "the shortenContext title is \(title), which does not match what it does (choose a model)")
        #expect(!title.contains("\"Retry\""))
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
