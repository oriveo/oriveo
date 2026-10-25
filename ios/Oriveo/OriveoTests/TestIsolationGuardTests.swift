import Foundation
import Testing
@testable import Oriveo

/// Fails when a test source schedules the shared metadata reset in an unawaited task:
///
///     defer { Task { await MetadataClient.shared.resetForTesting() } }
///
/// That shape returns immediately, so the reset lands inside whichever test runs next. The guard
/// scans the test sources instead of relying on someone spotting the pattern in review, because
/// the resulting failure surfaces in an unrelated file and only under some orderings.
///
/// It also checks that every test touching process-wide shared state carries `.sharedProcessState`.
@Suite("Test Isolation Guard Tests", .sharedProcessState)
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

    /// The counters are process-wide statics, and other cases also add to them through a ChatView mounted
    /// indirectly by AppRootView, so a case that reads a counter must count only its own conversation.
    @Test("Cases that read the ChatView / ChatMessageList body counters must scope the count to their conversation")
    func bodyCountReadersScopeToTheirConversation() throws {
        var readers = 0
        var offenders: [String] = []
        for url in try Self.swiftSourceFiles() where url.lastPathComponent != "TestIsolationGuardTests.swift" {
            let source = Self.strippingLineComments(try String(contentsOf: url, encoding: .utf8))
            for view in ["ChatView", "ChatMessageList"] where source.contains("\(view).bodyEvaluationCount") {
                readers += 1
                if !source.contains("\(view).resetBodyEvaluationCount(countingOnly:") {
                    offenders.append("\(url.lastPathComponent): \(view)")
                }
            }
        }
        // If nothing is found the lookup is broken and the guard is running empty
        #expect(readers >= 4, "Only found \(readers) counter reads; source lookup may be broken")
        #expect(offenders.isEmpty, "These cases read a body counter without resetBodyEvaluationCount(countingOnly:): \(offenders)")
    }

    @Test("Tests that touch process-wide shared state must carry .sharedProcessState")
    func sharedProcessStateTestsCarryTrait() throws {
        let sources = try Self.swiftSourceFiles().map { file in
            (name: file.lastPathComponent, source: try String(contentsOf: file, encoding: .utf8))
        }
        let report = Self.sharedProcessStateReport(for: sources)

        // Same as above: a hit count that collapses means the matching rule or #filePath lookup broke, so it cannot count as green
        #expect(
            report.scannedFiles >= 120,
            "Only found \(report.scannedFiles) test files touching process-wide shared state, which is far too few — the guard's matching rule or #filePath lookup broke"
        )
        #expect(
            report.offenders.isEmpty,
            """
            These tests touch process-wide shared state (\(Self.sharedProcessStatePattern)) without carrying .sharedProcessState:
            \(report.offenders.sorted().joined(separator: "\n"))

            Why: Swift Testing runs different suites in parallel within one process, and `.serialized` does not order \
            suites against each other. The MetadataClient shared snapshot and the view evaluation counters are \
            process-wide statics, so another suite can change them before your assertion runs.
            Fix: add .sharedProcessState to the suite's @Suite(...) (for cases in an extension, look at the @Suite at the declaration); \
            an XCTestCase should `await SharedProcessStateLock.shared.acquire()` in setUp and `release()` in tearDown.
            """
        )
    }

    /// Test files that write the metadata singleton (including `MetadataClient().loadForTesting`, which goes through
    /// replaceSharedState and changes the global) must carry `.sharedProcessState`: the exit restore hangs on the
    /// trait's unlock path, so a missing trait means neither mutual exclusion nor restore.
    /// Same criterion as `grep -rlE '^[^/]*(loadForTesting|…)\(' OriveoTests | grep -v Support/`.
    @Test("Test files that write the metadata singleton must carry .sharedProcessState")
    func metadataWritersCarrySharedProcessState() throws {
        let root = Self.testsSourceRoot.standardizedFileURL.path
        let files = try Self.swiftSourceFiles().map { file in
            (path: String(file.standardizedFileURL.path.dropFirst(root.count)),
             name: file.lastPathComponent,
             source: try String(contentsOf: file, encoding: .utf8))
        }
        let writerRegex = try NSRegularExpression(pattern: Self.metadataWriterLinePattern, options: .anchorsMatchLines)
        let writers = Set(files.filter { file in
            !file.path.contains("Support/")
                && writerRegex.firstMatch(
                    in: file.source, range: NSRange(location: 0, length: (file.source as NSString).length)
                ) != nil
        }.map(\.name))

        #expect(
            writers.count >= 90,
            "Only found \(writers.count) test files that write the metadata singleton, which is far too few — the matching rule or #filePath lookup broke"
        )
        let report = Self.sharedProcessStateReport(
            for: files.map { (name: $0.name, source: $0.source) }, forcedHits: writers
        )
        let offenders = report.offenders.filter { offender in
            writers.contains(where: { offender.hasPrefix("\($0):") })
        }
        #expect(
            offenders.isEmpty,
            """
            These test files write the metadata singleton without carrying .sharedProcessState:
            \(offenders.sorted().joined(separator: "\n"))

            Fix: add .sharedProcessState to the suite's @Suite(...) (for cases in an extension, look at the @Suite at the declaration).
            """
        )
    }

    /// Same criterion as the grep above: no `/` between the line start and the call (excludes comment lines).
    static let metadataWriterLinePattern =
        "^[^/\\n]*(loadForTesting|loadSplitForTesting|setRelayByModelForTesting|replaceStoredETagForTesting)\\("

    /// Trait exit restore: if the previous case loads and does not clear, the next case's sync* reads come back empty.
    /// Under `.serialized` they run in declaration order; cases from other suites squeezed in between are restored on exit
    /// the same way and do not change the conclusion.
    @Suite("The trait restores the metadata singleton on exit", .serialized, .sharedProcessState)
    struct MetadataExitReset {
        nonisolated(unsafe) static var loaderRan = false
        static let probeETag = "trait-exit-reset-probe"

        @Test("1. Load a fixture and exit without clearing")
        func loadsAndLeaves() async throws {
            await MetadataClient.shared.resetForTesting()
            try await MetadataClient.shared.loadForTesting(
                json: #"{"version": 1, "providers": {}}"#, metadataETag: Self.probeETag
            )
            #expect(MetadataClient.shared.syncMetadataETag() == Self.probeETag)
            #expect(MetadataClient.shared.syncMetadataSnapshotVersion() == 1)
            Self.loaderRan = true
        }

        @Test("2. The next case enters without clearing and reads an empty metadata singleton")
        func nextCaseSeesEmptySingleton() {
            #expect(Self.loaderRan, "1 must run before 2")
            #expect(MetadataClient.shared.syncMetadataETag() == nil)
            #expect(MetadataClient.shared.syncMetadataSnapshotVersion() == nil)
        }
    }

    // MARK: - Scanning implementation

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

    // MARK: - Process-wide shared state trait guard

    /// A hit counts as touching process-wide shared state: the MetadataClient shared snapshot, view evaluation
    /// counters, whole-page chat views (including root views that mount ChatView indirectly through AppRootView),
    /// and the global toast (assertions reading `current` must exclude other cases that pop toasts).
    /// MetadataClient counts only as a member call (`.shared` / static methods, lowercase after the dot) or the
    /// construction `MetadataClient(`; a pure type reference (a nested type such as `MetadataClient.CapabilityControl`,
    /// or a `: MetadataClient` annotation) does not touch the shared snapshot and does not count.
    static let sharedProcessStatePattern =
        "MetadataClient(?:\\.[a-z_]|\\s*\\()|bodyEvaluationCount|contentChangeCount|ChatView\\(|ChatMessageList\\(|AppRootView\\(|ToastManager\\.shared"
    private static let sharedProcessStateTraitToken = ".sharedProcessState"

    struct SharedProcessStateReport {
        var scannedFiles = 0
        var offenders: [String] = []
    }

    /// One `@Suite` / `@Test` attribute: `arguments` is the text inside the parentheses, nil when written bare (no parentheses).
    struct AttributeUse {
        let line: Int
        let arguments: String?
        /// Position after the attribute (UTF-16 offset), used to find the type declaration it decorates.
        let end: Int
    }

    /// `forcedHits`: counts a file as a hit by file name (ignoring `sharedProcessStatePattern`), so the writer guard reuses the same trait judgment.
    static func sharedProcessStateReport(
        for sources: [(name: String, source: String)],
        forcedHits: Set<String> = []
    ) -> SharedProcessStateReport {
        // First build "type name -> whether the @Suite at the declaration carries the trait" across all files, for extension files to look up
        var declaredSuites: [String: Bool] = [:]
        for file in sources {
            for (name, hasTrait) in suiteDeclarations(in: file.source) {
                declaredSuites[name] = (declaredSuites[name] ?? false) || hasTrait
            }
        }
        guard let hitRegex = try? NSRegularExpression(pattern: sharedProcessStatePattern) else {
            return SharedProcessStateReport(scannedFiles: 0, offenders: ["The guard regex is invalid"])
        }

        // Writes through a helper: a `static func` in another file writes the MetadataClient shared snapshot in its body,
        // so a file that calls it has no hit word of its own but still counts as a hit
        let helperCalls = sharedStateWriterHelperCalls(in: sources.map { strippingLineComments($0.source) })

        var report = SharedProcessStateReport()
        for file in sources {
            let scannable = strippingLineComments(file.source)
            let range = NSRange(location: 0, length: (scannable as NSString).length)
            let hitsDirectly = hitRegex.firstMatch(in: scannable, range: range) != nil
            guard forcedHits.contains(file.name) || hitsDirectly || helperCalls.contains(where: { callsHelper(scannable, $0) }) else { continue }
            report.scannedFiles += 1

            if scannable.range(of: "class\\s+\\w+\\s*:\\s*XCTest" + "Case\\b", options: .regularExpression) != nil {
                let acquires = scannable.contains("SharedProcessStateLock.shared.acquire(")
                let releases = scannable.contains("SharedProcessStateLock.shared.release()")
                if !(acquires && releases) {
                    report.offenders.append("\(file.name): XCTestCase does not acquire/release SharedProcessStateLock in setUp/tearDown")
                }
            }

            let suites = attributeUses(named: "Suite", in: file.source)
            for suite in suites where !carriesTrait(suite) {
                report.offenders.append("\(file.name):\(suite.line) @Suite is missing .sharedProcessState")
            }

            let tests = attributeUses(named: "Test", in: file.source)
            guard suites.isEmpty, !tests.isEmpty else { continue }
            // With no @Suite of its own: cases in an extension inherit the recursive trait of the @Suite at the declaration;
            // if the declaration does not carry it (or they are free functions), every @Test must carry it itself
            let extended = extendedTypeNames(in: scannable)
            let coveredByDeclaration = !extended.isEmpty && extended.allSatisfy { declaredSuites[$0] == true }
            if coveredByDeclaration { continue }
            for test in tests where !carriesTrait(test) {
                report.offenders.append("\(file.name):\(test.line) @Test is missing .sharedProcessState (and the @Suite at the declaration does not carry it)")
            }
        }
        return report
    }

    /// Call shapes that write the MetadataClient shared snapshot (reads do not count, so a read-only helper does not drag all its callers in).
    static let sharedStateWriterPattern =
        "MetadataClient\\.shared\\.(?:resetForTesting|loadForTesting|loadSplitForTesting|replaceStoredETagForTesting|forceRefresh)\\("

    /// The `static func`s whose body writes the shared snapshot, per file, returned as `TypeName.functionName` (type names are all the types the file declares / extends).
    static func sharedStateWriterHelperCalls(in sources: [String]) -> [String] {
        guard let funcRegex = try? NSRegularExpression(pattern: "static\\s+func\\s+([A-Za-z_][A-Za-z0-9_]*)"),
              let typeRegex = try? NSRegularExpression(
                  pattern: "(?<![A-Za-z0-9_])(?:struct|class|enum|actor|extension)\\s+([A-Za-z_][A-Za-z0-9_]*)"
              ),
              let writerRegex = try? NSRegularExpression(pattern: sharedStateWriterPattern) else { return [] }
        var calls: [String] = []
        for source in sources {
            let ns = source as NSString
            let all = NSRange(location: 0, length: ns.length)
            let types = typeRegex.matches(in: source, range: all).map { ns.substring(with: $0.range(at: 1)) }
            guard !types.isEmpty else { continue }
            for match in funcRegex.matches(in: source, range: all) {
                let name = ns.substring(with: match.range(at: 1))
                guard let body = braceBody(in: ns, from: match.range.location + match.range.length),
                      writerRegex.firstMatch(in: body, range: NSRange(location: 0, length: (body as NSString).length)) != nil
                else { continue }
                calls.append(contentsOf: types.map { "\($0).\(name)" })
            }
        }
        return calls
    }

    /// The text from the first `{` after `from` to its matching `}`; nil when they do not pair up.
    private static func braceBody(in ns: NSString, from: Int) -> String? {
        let open = UInt16(UInt8(ascii: "{")), close = UInt16(UInt8(ascii: "}"))
        var index = from
        while index < ns.length, ns.character(at: index) != open { index += 1 }
        let start = index
        var depth = 0
        while index < ns.length {
            let char = ns.character(at: index)
            if char == open { depth += 1 }
            if char == close {
                depth -= 1
                if depth == 0 { return ns.substring(with: NSRange(location: start, length: index - start + 1)) }
            }
            index += 1
        }
        return nil
    }

    private static func callsHelper(_ source: String, _ call: String) -> Bool {
        source.range(
            of: "(?<![A-Za-z0-9_])" + NSRegularExpression.escapedPattern(for: call) + "\\(",
            options: .regularExpression
        ) != nil
    }

    private static func carriesTrait(_ use: AttributeUse) -> Bool {
        use.arguments?.contains(sharedProcessStateTraitToken) ?? false
    }

    /// Finds `@Name` attributes at the start of a line (bare / with arguments / with arguments across lines), skipping string literals while pairing parentheses.
    static func attributeUses(named name: String, in source: String) -> [AttributeUse] {
        let ns = source as NSString
        guard let regex = try? NSRegularExpression(
            pattern: "^[ \\t]*@\(name)(?![A-Za-z0-9_])",
            options: [.anchorsMatchLines]
        ) else { return [] }
        let open = UInt16(UInt8(ascii: "(")), close = UInt16(UInt8(ascii: ")"))
        let quote = UInt16(UInt8(ascii: "\"")), backslash = UInt16(UInt8(ascii: "\\"))
        return regex.matches(in: source, range: NSRange(location: 0, length: ns.length)).map { match in
            let line = ns.substring(to: match.range.location).reduce(1) { $1 == "\n" ? $0 + 1 : $0 }
            let start = match.range.location + match.range.length
            guard start < ns.length, ns.character(at: start) == open else {
                return AttributeUse(line: line, arguments: nil, end: start)
            }
            var depth = 0
            var index = start
            while index < ns.length {
                let char = ns.character(at: index)
                if char == quote {
                    index += 1
                    while index < ns.length, ns.character(at: index) != quote {
                        if ns.character(at: index) == backslash { index += 1 }
                        index += 1
                    }
                } else if char == open {
                    depth += 1
                } else if char == close {
                    depth -= 1
                    if depth == 0 {
                        let arguments = ns.substring(with: NSRange(location: start + 1, length: index - start - 1))
                        return AttributeUse(line: line, arguments: arguments, end: index + 1)
                    }
                }
                index += 1
            }
            // Unbalanced parentheses: treat as no arguments, better to report it than to let it through
            return AttributeUse(line: line, arguments: nil, end: ns.length)
        }
    }

    /// The type declaration name between `@Suite(...)` and the first `{` -> whether that @Suite carries the trait.
    static func suiteDeclarations(in source: String) -> [(String, Bool)] {
        let ns = source as NSString
        guard let regex = try? NSRegularExpression(
            pattern: "(?<![A-Za-z0-9_])(?:struct|class|enum|actor)\\s+([A-Za-z_][A-Za-z0-9_]*)"
        ) else { return [] }
        return attributeUses(named: "Suite", in: source).compactMap { suite in
            let rest = ns.substring(from: suite.end)
            let head = rest.components(separatedBy: "{").first ?? rest
            let headNS = head as NSString
            guard let match = regex.firstMatch(in: head, range: NSRange(location: 0, length: headNS.length)) else {
                return nil
            }
            return (headNS.substring(with: match.range(at: 1)), carriesTrait(suite))
        }
    }

    static func extendedTypeNames(in source: String) -> [String] {
        let ns = source as NSString
        guard let regex = try? NSRegularExpression(
            pattern: "^[ \\t]*(?:@[A-Za-z]+[ \\t]+)*extension[ \\t]+([A-Za-z_][A-Za-z0-9_]*)",
            options: [.anchorsMatchLines]
        ) else { return [] }
        return regex.matches(in: source, range: NSRange(location: 0, length: ns.length)).map {
            ns.substring(with: $0.range(at: 1))
        }
    }

    @Test("The shared-state detector recognises bare / with-arguments / multi-line @Suite, looks up extensions at the declaration, and checks XCTestCase lock handling")
    func sharedProcessStateDetectorRecognisesShapes() {
        // Samples are joined with \n in single-line strings so this file's source has no line-leading @Suite / extension / XCTestCase shapes for the guard to scan
        let hit = "await MetadataClient.shared.resetForTesting()"
        let suite = "@" + "Suite"
        let trait = ".sharedProcess" + "State"

        let bare = (name: "Bare.swift", source: "\(suite)\nstruct A {\n  func f() async { \(hit) }\n}\n")
        let withArgs = (name: "Args.swift", source: "\(suite)(\"a (b)\", .serialized)\nstruct B { func f() async { \(hit) } }\n")
        let multiLine = (name: "Multi.swift", source: "\(suite)(\n    \"c\",\n    .serialized\n)\nstruct C { func f() async { \(hit) } }\n")
        let report = Self.sharedProcessStateReport(for: [bare, withArgs, multiLine])
        #expect(report.scannedFiles == 3)
        #expect(report.offenders.sorted() == [
            "Args.swift:1 @Suite is missing .sharedProcessState",
            "Bare.swift:1 @Suite is missing .sharedProcessState",
            "Multi.swift:1 @Suite is missing .sharedProcessState",
        ])

        let fixed = [
            (name: "Args.swift", source: "\(suite)(\"a (b)\", .serialized, \(trait))\nstruct B { func f() async { \(hit) } }\n"),
            (name: "Multi.swift", source: "\(suite)(\n    \"c\",\n    .serialized,\n    \(trait)\n)\nstruct C { func f() async { \(hit) } }\n"),
        ]
        #expect(Self.sharedProcessStateReport(for: fixed).offenders.isEmpty)

        // extension: a trait at the declaration covers it; if the declaration does not carry it, check each @Test
        let testAttr = "@" + "Test"
        let ext = (name: "D+Ext.swift", source: "ext" + "ension D {\n    \(testAttr)(\"x\")\n    func g() async { \(hit) }\n}\n")
        let declWith = (name: "D.swift", source: "\(suite)(\"d\", \(trait))\n@MainActor\nstruct D {}\n")
        let declWithout = (name: "D.swift", source: "\(suite)(\"d\")\n@MainActor\nstruct D {}\n")
        #expect(Self.sharedProcessStateReport(for: [ext, declWith]).offenders.isEmpty)
        #expect(Self.sharedProcessStateReport(for: [ext, declWithout]).offenders == [
            "D+Ext.swift:2 @Test is missing .sharedProcessState (and the @Suite at the declaration does not carry it)",
        ])
        let extTagged = (name: "D+Ext.swift", source: "ext" + "ension D {\n    \(testAttr)(\"x\", \(trait))\n    func g() async { \(hit) }\n}\n")
        #expect(Self.sharedProcessStateReport(for: [extTagged, declWithout]).offenders.isEmpty)

        // XCTestCase: must acquire/release the lock in setUp/tearDown
        let xcBase = "final class E: XC" + "TestCase {\n    func testA() async { \(hit) }\n"
        let xcBare = (name: "E.swift", source: xcBase + "}\n")
        let xcLocked = (name: "E.swift", source: xcBase
            + "    override func setUp() async throws { await SharedProcessStateLock.shared.acquire() }\n"
            + "    override func tearDown() async throws { await SharedProcessStateLock.shared.release() }\n}\n")
        #expect(Self.sharedProcessStateReport(for: [xcBare]).offenders.count == 1)
        #expect(Self.sharedProcessStateReport(for: [xcLocked]).offenders.isEmpty)

        // Files that do not hit shared state are not scanned; hit words in comments do not count
        let unrelated = (name: "F.swift", source: "\(suite)\nstruct F {}\n// MetadataClient\n")
        #expect(Self.sharedProcessStateReport(for: [unrelated]).scannedFiles == 0)

        // Pure type references (nested types / type annotations) do not count as hits; member calls and construction still do
        let typeOnly = (name: "G.swift", source: "\(suite)\nstruct G {\n  let c: MetadataClient.CapabilityControl? = nil\n  func f(_ m: MetadataClient) {}\n}\n")
        #expect(Self.sharedProcessStateReport(for: [typeOnly]).scannedFiles == 0)
        let constructs = (name: "H.swift", source: "\(suite)\nstruct H { let m = MetadataClient() }\n")
        #expect(Self.sharedProcessStateReport(for: [constructs]).offenders == ["H.swift:1 @Suite is missing .sharedProcessState"])
    }

    @Test("A file that writes the shared snapshot through a helper also counts as a hit: the caller never mentions MetadataClient")
    func sharedProcessStateDetectorFollowsWriterHelpers() {
        let suite = "@" + "Suite"
        let trait = ".sharedProcess" + "State"
        let writer = "await MetadataClient.shared.loadForTesting(json: j)"
        let helper = (name: "H.swift", source: "\(suite)(\"h\", \(trait))\nstruct H {\n    static func load() async { \(writer) }\n}\n")
        let caller = (name: "C.swift", source: "\(suite)(\"c\")\nstruct C {\n    func f() async { await H.load() }\n}\n")
        let report = Self.sharedProcessStateReport(for: [helper, caller])
        #expect(report.scannedFiles == 2)
        #expect(report.offenders == ["C.swift:1 @Suite is missing .sharedProcessState"])

        // A read-only helper does not drag its callers in
        let reader = (name: "R.swift", source: "\(suite)(\"r\", \(trait))\nstruct R {\n    static func cat() -> Int { MetadataClient.syncCount() }\n}\n")
        let readerCaller = (name: "RC.swift", source: "\(suite)(\"rc\")\nstruct RC {\n    func f() { _ = R.cat() }\n}\n")
        #expect(Self.sharedProcessStateReport(for: [reader, readerCaller]).offenders.isEmpty)
    }

    @Test("Write gate decision: non-cases pass, a case without the trait is recorded as a failure and passes, a non-holder is dropped, the holder passes")
    func sharedWriteGateDecision() {
        #expect(SharedProcessStateLock.writeDecision(origin: nil, holder: "a", isHeld: false) == .allow)
        #expect(SharedProcessStateLock.writeDecision(origin: nil, holder: nil, isHeld: true) == .allow)
        #expect(SharedProcessStateLock.writeDecision(origin: "a", holder: "a", isHeld: false) == .allowRecordingMissingTrait)
        #expect(SharedProcessStateLock.writeDecision(origin: "a", holder: "b", isHeld: true) == .drop)
        #expect(SharedProcessStateLock.writeDecision(origin: "a", holder: nil, isHeld: true) == .drop)
        #expect(SharedProcessStateLock.writeDecision(origin: "a", holder: "a", isHeld: true) == .allow)
    }

    @Test("The write gate is installed and lets the lock-holding case itself through")
    func sharedWriteGateInstalledAndAllowsHolder() throws {
        let gate = try #require(MetadataClient.debugSharedWriteGate)
        #expect(gate("probe"))
        #expect(SharedProcessStateLock.currentHolder == Test.current.map { String(describing: $0.id) })
    }

    @Test("A dropped write does not advance the evidence revision")
    @MainActor
    func droppedWriteDoesNotAdvanceEvidenceRevision() async throws {
        await MetadataClient.shared.resetForTesting()
        let installed = MetadataClient.debugSharedWriteGate
        // Simulate a leaked write from a non-holder: the gate drops every entry of this adopt
        MetadataClient.debugSharedWriteGate = { _ in false }
        let before = CapabilityEvidenceObservationBridge.shared.contentRevision
        do {
            try await MetadataClient.shared.loadForTesting(json: #"{"version":1,"providers":{}}"#)
        } catch {
            MetadataClient.debugSharedWriteGate = installed
            throw error
        }
        MetadataClient.debugSharedWriteGate = installed
        #expect(CapabilityEvidenceObservationBridge.shared.contentRevision == before)

        await MetadataClient.shared.resetForTesting()
    }

    @Test("The bootstrap is drained before unlock: an initialize() triggered by a stray Task while the lock is held finishes on the unlock path")
    func releaseDrainsMetadataBootstrap() async {
        await MetadataClient.shared.resetForTesting()
        // Simulate an initialize() started by a view's .task that does not end with the case
        let leaked = Task { await MetadataClient.shared.initialize() }
        var sawPending = false
        for _ in 0..<1_000 where !sawPending {
            sawPending = await MetadataClient.shared.hasPendingBackgroundWorkForTesting
            if !sawPending { await Task.yield() }
        }
        #expect(sawPending, "The stray initialize() should be in flight before draining, otherwise this case cannot measure the drain")

        // This is the drain path release() takes before unlocking
        let drained = await SharedProcessStateTrait.drainMetadataBackgroundWork()
        #expect(drained)
        #expect(await MetadataClient.shared.hasPendingBackgroundWorkForTesting == false)

        await leaked.value
        await MetadataClient.shared.resetForTesting()
    }
}
