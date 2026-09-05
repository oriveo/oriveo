import Foundation
import Testing

/// Fails when a test source schedules the shared metadata reset in an unawaited task:
///
///     defer { Task { await MetadataClient.shared.resetForTesting() } }
///
/// That shape returns immediately, so the reset lands inside whichever test runs next. The guard
/// scans the test sources instead of relying on someone spotting the pattern in review, because
/// the resulting failure surfaces in an unrelated file and only under some orderings.
@Suite("Test Isolation Guard Tests")
struct TestIsolationGuardTests {

    @Test("No Fire And Forget Reset For Testing")
    func noFireAndForgetResetForTesting() throws {
        let sources = try Self.swiftSourceFiles()

        #expect(
            sources.count >= 200,
            "Guard only scanned \(sources.count) test sources, which is far too few — #filePath resolution probably broke; fix the guard itself"
        )

        var offenders: [String] = []
        for file in sources {
            let source = try String(contentsOf: file, encoding: .utf8)
            let scannable = Self.strippingLineComments(source)
            for line in Self.fireAndForgetResetLines(in: scannable) {
                offenders.append("\(file.lastPathComponent):\(line)")
            }
        }

        #expect(
            offenders.isEmpty,
            """
            An unawaited `Task { … }` wrapping `MetadataClient.shared.resetForTesting()` was found at: \
            \(offenders.sorted().joined(separator: ", "))

            `resetForTesting()` clears process-wide state: the shared metadata snapshot, the stored \
            ETags, the cached UserDefaults keys and the persisted rows. Scheduled without being \
            awaited, the test returns first and the reset runs during a later test, wiping the \
            fixture that test had just installed. The failure then appears in an unrelated file and \
            only under some orderings, which is why it is worth a guard.

            Fix it by awaiting the reset: make the test `async` and call \
            `await MetadataClient.shared.resetForTesting()` at the end of the body, or from an \
            `async` teardown helper. A `defer` block cannot await, so the call has to move out of it.
            """
        )
    }


    private static var testsSourceRoot: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    }

    private static func swiftSourceFiles() throws -> [URL] {
        let root = testsSourceRoot
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey]
        ) else {
            return []
        }
        return enumerator
            .compactMap { $0 as? URL }
            .filter { $0.pathExtension == "swift" }
    }

    private static func strippingLineComments(_ source: String) -> String {
        source
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { line -> String in
                guard let commentStart = line.range(of: "//") else { return String(line) }
                return String(line[line.startIndex..<commentStart.lowerBound])
            }
            .joined(separator: "\n")
    }

    private static func fireAndForgetResetLines(in source: String) -> [Int] {
        let pattern = "(?<![A-Za-z0-9_])Task(?:\\.detached)?\\s*\\{[^{}]{0,400}resetForTesting"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators]) else {
            return []
        }
        let ns = source as NSString
        let matches = regex.matches(in: source, range: NSRange(location: 0, length: ns.length))
        return matches.map { match in
            let prefix = ns.substring(to: match.range.location)
            return prefix.reduce(1) { $1 == "\n" ? $0 + 1 : $0 }
        }
    }


    @Test("Detector Recognises Both Shapes")
    func detectorRecognisesBothShapes() {
        let taskOpen = "Task" + " {"
        let reset = "await MetadataClient.shared.resetForTesting()"

        let singleLine = "defer { \(taskOpen) \(reset) } }"
        #expect(Self.fireAndForgetResetLines(in: singleLine) == [1])

        let multiLine = """
        defer {
            \(taskOpen)
                \(reset)
            }
        }
        """
        #expect(Self.fireAndForgetResetLines(in: multiLine) == [2])

        #expect(Self.fireAndForgetResetLines(in: reset).isEmpty)
        #expect(Self.fireAndForgetResetLines(in: "\(taskOpen) await somethingElse() }").isEmpty)
        #expect(Self.fireAndForgetResetLines(in: "myTask { \(reset) }").isEmpty)
    }

    @Test("Detector Ignores Comments")
    func detectorIgnoresComments() {
        let commented = "// defer { " + "Task" + " { await MetadataClient.shared.resetForTesting() } }"
        #expect(Self.fireAndForgetResetLines(in: Self.strippingLineComments(commented)).isEmpty)
    }
}
