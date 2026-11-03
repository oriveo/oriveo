import Foundation
import Testing

/// Regression gate: test source may delete partitions only through `TestPartitionCleanup.remove` / `.clear`.
///
/// Calling `removeItem(AppSessionStore.userDir(for:))` directly, or synchronously calling `AppSessionStore.clearPartition` without waiting for in-flight AppState reads and writes
/// (send finalization, write queue, memory write-back, delete-ledger cleanup) to drain, leaves background reads hitting deleted database files; the log shows `[DiskIO] … dbFileExists=false`,
/// and `scripts/lib/ios-test-verdict.mjs` treats it with zero tolerance as red: all tests pass, but the verdict is still RED.
struct TestPartitionCleanupGateTests {
    private static let testsRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent() // Support
        .deletingLastPathComponent() // OriveoTests

    /// The only file allowed to delete a partition directly (the cleanup entry point itself and this gate's self-check samples).
    private static let allowed: Set<String> = ["TestPartitionCleanup.swift", "TestPartitionCleanupGateTests.swift"]

    /// One line in a source file that bypasses the shared cleanup (1-based line number plus original text). Comment lines do not count.
    static func offenses(in text: String) -> [(line: Int, text: String)] {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        // Alias: `let dir = AppSessionStore.userDir(for: uid)` (the next line is not an `.appendingPathComponent` continuation)
        var aliases: Set<String> = []
        let aliasRegex = try? NSRegularExpression(pattern: #"\b(?:let|var)\s+(\w+)\s*=\s*AppSessionStore\.userDir\(for:[^)]*\)\s*$"#)
        for (index, line) in lines.enumerated() {
            let range = NSRange(line.startIndex..., in: line)
            guard let match = aliasRegex?.firstMatch(in: line, range: range),
                  let name = Range(match.range(at: 1), in: line) else { continue }
            let next = index + 1 < lines.count ? lines[index + 1].trimmingCharacters(in: .whitespaces) : ""
            if !next.hasPrefix(".") { aliases.insert(String(line[name])) }
        }
        var found: [(Int, String)] = []
        for (index, line) in lines.enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.hasPrefix("//") else { continue }
            let code = line.components(separatedBy: "//").first ?? line
            let direct = code.contains("removeItem(") && code.contains("userDir(for:")
            let sync = code.contains("clearPartition(")
            let aliased = aliases.contains { code.contains("removeItem(at: \($0))") }
            if direct || sync || aliased { found.append((index + 1, trimmed)) }
        }
        return found
    }

    @Test("Scanner rule self-check: recognizes direct partition deletion, synchronous clearPartition and alias deletion; allows subpaths inside the partition and temp directories")
    func scannerRecognizesBypasses() {
        #expect(Self.offenses(in: "defer { try? FileManager.default.removeItem(at: AppSessionStore.userDir(for: uid)) }").count == 1)
        #expect(Self.offenses(in: "    try? fm.removeItem(at: AppSessionStore.userDir(for: testUID))").count == 1)
        #expect(Self.offenses(in: "        AppSessionStore.clearPartition(for: uid)").count == 1)
        #expect(Self.offenses(in: "let dir = AppSessionStore.userDir(for: uid)\ntry? FileManager.default.removeItem(at: dir)").count == 1)
        #expect(Self.offenses(in: "let dir = AppSessionStore.userDir(for: uid)\n    .appendingPathComponent(\"Images\")\ntry? FileManager.default.removeItem(at: dir)").isEmpty)
        #expect(Self.offenses(in: "defer { try? FileManager.default.removeItem(at: root) }").isEmpty)
        #expect(Self.offenses(in: "defer { await TestPartitionCleanup.remove(uid) }").isEmpty)
        #expect(Self.offenses(in: "    // do not AppSessionStore.clearPartition(for: uid)").isEmpty)
    }

    @Test("Test source must not bypass TestPartitionCleanup to delete partition directories directly or call clearPartition synchronously")
    func testsDeletePartitionsOnlyThroughSharedCleanup() throws {
        let enumerator = try #require(FileManager.default.enumerator(at: Self.testsRoot, includingPropertiesForKeys: nil))
        var scanned = 0
        var offenders: [String] = []
        for case let url as URL in enumerator where url.pathExtension == "swift" {
            scanned += 1
            guard !Self.allowed.contains(url.lastPathComponent) else { continue }
            let text = try String(contentsOf: url, encoding: .utf8)
            let relative = url.path.replacingOccurrences(of: Self.testsRoot.path + "/", with: "")
            for offense in Self.offenses(in: text) {
                offenders.append("\(relative):\(offense.line) \(offense.text)")
            }
        }
        // If #filePath resolution breaks, scanning 0 files would still "pass"; the guard must fail on its own.
        #expect(scanned >= 300, "only \(scanned) test source files scanned; #filePath resolution is probably broken")
        #expect(offenders.isEmpty, """
        Change it to `await TestPartitionCleanup.remove(uid)` inside the test case (use `.clear` if the Keychain must also be cleared and an empty partition rebuilt),
        `defer { await … }` requires the test case to be async:
        \(offenders.joined(separator: "\n"))
        """)
    }
}
