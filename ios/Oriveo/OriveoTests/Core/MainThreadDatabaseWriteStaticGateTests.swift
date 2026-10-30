import Foundation
import Testing
@testable import Oriveo

/// Static half of the main-thread database write gate.
///
/// `MainThreadDatabaseWriteGuard` (runtime, DEBUG) fails an assertion when a method listed in
/// `MainThreadDatabaseWriteAllowlist.known` writes synchronously on the main thread. That only works if `known` lists
/// every method that calls a synchronous GRDB write directly, so this suite scans the app sources and requires the
/// registry to match them exactly. A new synchronous write method fails here until it is added to `known` (which makes
/// the runtime gate cover it); a removed one fails until it is dropped. It also rejects blocking waits on a persist /
/// write queue (`xxxPersistQueue.sync`): a main-thread `dispatch_sync` onto a serial queue that is busy with a
/// whole-table write waits for the write lock just the same.
@Suite("Main-thread database write gate: static registry")
struct MainThreadDatabaseWriteStaticGateTests {
    private static let appRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent() // Core
        .deletingLastPathComponent() // OriveoTests
        .deletingLastPathComponent() // Oriveo (project directory)
        .appendingPathComponent("Oriveo", isDirectory: true)

    /// The gate's own files mention the write APIs by name.
    private static let selfFiles: Set<String> = ["MainThreadDatabaseWriteAllowlist.swift", "MainThreadDatabaseWriteGuard.swift"]

    @Test("Every synchronous GRDB write method in the app is registered, and no stale entries remain")
    func registryMatchesAppSources() throws {
        let enumerator = try #require(FileManager.default.enumerator(at: Self.appRoot, includingPropertiesForKeys: nil))
        var scannedFiles = 0
        var hits: [String: [String]] = [:]
        var syncWaits: [String] = []
        for case let url as URL in enumerator where url.pathExtension == "swift" && !Self.selfFiles.contains(url.lastPathComponent) {
            scannedFiles += 1
            let result = Self.scan(try String(contentsOf: url, encoding: .utf8))
            for hit in result.hits { hits[hit.key, default: []].append("\(url.lastPathComponent):\(hit.line)") }
            syncWaits += result.syncWaits.map { "\(url.lastPathComponent):\($0.line) (\($0.owner): \($0.queue).sync)" }
        }
        // Scanning zero files would also "pass": fail loudly if #filePath stops resolving.
        #expect(scannedFiles >= 300, "Only \(scannedFiles) app sources scanned; #filePath resolution is probably broken")
        #expect(hits.count >= 40, "Only \(hits.count) synchronous write methods found; the scanner probably broke")

        let known = MainThreadDatabaseWriteAllowlist.known
        let unregistered = hits.keys.filter { !known.contains($0) }.sorted()
        #expect(
            unregistered.isEmpty,
            """
            New synchronous database write methods are not registered in MainThreadDatabaseWriteAllowlist.known: \
            \(unregistered.map { "\($0) (\(hits[$0]?.first ?? "?"))" }.joined(separator: ", ")). \
            Prefer `try await writer.write`; a method that must stay synchronous is registered there so the runtime gate \
            forbids it on the main thread.
            """
        )
        let stale = known.filter { hits[$0] == nil }.sorted()
        #expect(stale.isEmpty, "MainThreadDatabaseWriteAllowlist.known lists methods that no longer write synchronously: \(stale)")
        #expect(MainThreadDatabaseWriteAllowlist.mainThreadDebt.isEmpty, "Main-thread debt may only shrink, and it is empty")
        #expect(
            syncWaits.isEmpty,
            "Blocking waits on a persist / write queue (the main thread waits for the write lock with it): \(syncWaits). Enqueue asynchronously and await instead."
        )
    }

    @Test("The scanner keys writes by the enclosing Type.method and skips awaited calls, comments and strings")
    func scannerRecognizesWrites() {
        let source = """
        final class SampleStore {
            func save() throws {
                try dbPool.write { db in try db.execute(sql: "x") }
            }
            func saveAsync() async throws {
                try await dbPool.write { db in try db.execute(sql: "x") }
            }
            // try dbPool.write { _ in } is only a comment
            func describe() -> String { "try dbPool.write { }" }
            init(path: String) throws {
                pool = try DatabasePool(path: path)
            }
            func flush() {
                sessionPersistQueue.sync { }
            }
        }
        extension Outer.Nested {
            static func purge() throws {
                let ids = [1].map { $0 }
                try queue.inDatabase { db in _ = db }
            }
        }
        """
        let result = Self.scan(source)
        #expect(result.hits.map(\.key) == ["SampleStore.save", "SampleStore.init", "Nested.purge"])
        #expect(result.syncWaits.map(\.owner) == ["SampleStore.flush"])
    }

    // MARK: - Scanner

    private struct Scope {
        enum Kind { case type, function, other }
        var kind: Kind
        var name: String
    }

    /// Ways to start a synchronous GRDB write directly (an `await` earlier on the same line means the async variant).
    private static let triggers: [NSRegularExpression] = [
        #"\b(?:dbPool|pool|queue|dbQueue|writer|dbWriter|databaseWriter|database)\??\.(?:write|writeWithoutTransaction|barrierWriteWithoutTransaction|inDatabase|unsafeReentrantWrite)\s*[({]"#,
        #"\)\s*\.(?:write|writeWithoutTransaction|barrierWriteWithoutTransaction|inDatabase)\s*\{"#,
        #"\btry\s+write\s*[({]"#,
        #"\.migrate\(\s*(?:pool|dbPool|queue|dbQueue|writer|database)\b"#,
        #"\b(?:DatabasePool|DatabaseQueue)\s*\(\s*path:"#,
    ].map { try! NSRegularExpression(pattern: $0) }
    private static let syncWait = try! NSRegularExpression(pattern: #"\b(\w*(?:[Pp]ersist|[Ww]rite)\w*[Qq]ueue)\??\.sync\s*[({]"#)
    private static let awaitWord = try! NSRegularExpression(pattern: #"\bawait\b"#)
    private static let typeDecl = try! NSRegularExpression(pattern: #"\b(?:class|struct|enum|actor|extension|protocol)\s+([A-Za-z_][\w.]*)"#)
    private static let funcDecl = try! NSRegularExpression(pattern: #"\bfunc\s+([A-Za-z_]\w*)"#)
    private static let initDecl = try! NSRegularExpression(pattern: #"(?:^|[\s;}])(init|deinit)\b\s*[?!]?\s*[(<{]"#)

    private static func scan(_ source: String) -> (hits: [(key: String, line: Int)], syncWaits: [(owner: String, queue: String, line: Int)]) {
        let code = stripCode(source)
        // Snapshot the scope stack at every brace and look positions up by binary search.
        var events: [(position: Int, stack: [Scope])] = []
        var stack: [Scope] = []
        var header: [UInt8] = []
        for (position, byte) in code.enumerated() {
            switch byte {
            case UInt8(ascii: "{"):
                stack.append(scope(for: String(decoding: header, as: UTF8.self)))
                header = []
                events.append((position, stack))
            case UInt8(ascii: "}"):
                if !stack.isEmpty { stack.removeLast() }
                header = []
                events.append((position, stack))
            case UInt8(ascii: ";"):
                header = []
            default:
                header.append(byte)
            }
        }
        func scopes(at position: Int) -> [Scope] {
            var low = 0, high = events.count - 1
            var best: [Scope] = []
            while low <= high {
                let mid = (low + high) / 2
                if events[mid].position <= position { best = events[mid].stack; low = mid + 1 } else { high = mid - 1 }
            }
            return best
        }

        var hits: [(key: String, line: Int)] = []
        var waits: [(owner: String, queue: String, line: Int)] = []
        var offset = 0
        for (index, lineBytes) in code.split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: false).enumerated() {
            let text = String(decoding: lineBytes, as: UTF8.self)
            let range = NSRange(location: 0, length: (text as NSString).length)
            if let wait = syncWait.firstMatch(in: text, range: range) {
                let queue = (text as NSString).substring(with: wait.range(at: 1))
                waits.append((key(for: scopes(at: offset + wait.range.location)) ?? "?", queue, index + 1))
            }
            for trigger in triggers {
                guard let match = trigger.firstMatch(in: text, range: range) else { continue }
                let prefix = NSRange(location: 0, length: match.range.location)
                if awaitWord.firstMatch(in: text, range: prefix) != nil { continue }
                if let key = key(for: scopes(at: offset + match.range.location)) { hits.append((key, index + 1)) }
                break
            }
            offset += lineBytes.count + 1
        }
        return (hits, waits)
    }

    private static func scope(for header: String) -> Scope {
        let range = NSRange(location: 0, length: (header as NSString).length)
        if let match = funcDecl.firstMatch(in: header, range: range) {
            return Scope(kind: .function, name: (header as NSString).substring(with: match.range(at: 1)))
        }
        if let match = initDecl.firstMatch(in: header, range: range) {
            return Scope(kind: .function, name: (header as NSString).substring(with: match.range(at: 1)))
        }
        if let match = typeDecl.firstMatch(in: header, range: range) {
            // `let x = Foo.init { struct … }` style expressions are not declarations.
            let before = (header as NSString).substring(to: match.range.location)
            if !before.contains("=") && !before.contains("(") {
                return Scope(kind: .type, name: (header as NSString).substring(with: match.range(at: 1)))
            }
        }
        return Scope(kind: .other, name: "")
    }

    /// Innermost type name + the method under it (closures and local functions belong to the outer method, matching the
    /// key the runtime gate derives from stack frames).
    private static func key(for stack: [Scope]) -> String? {
        let typeIndex = stack.lastIndex { $0.kind == .type }
        let start = typeIndex.map { $0 + 1 } ?? 0
        guard let function = stack[start...].first(where: { $0.kind == .function }) else { return nil }
        let typeName = typeIndex.map { stack[$0].name.split(separator: ".").last.map(String.init) ?? "" } ?? ""
        return typeName.isEmpty ? function.name : "\(typeName).\(function.name)"
    }

    /// Blanks out comments and string contents (keeping newlines) so braces can be counted and code matched. Non-ASCII
    /// bytes become spaces too, so byte offsets equal UTF-16 offsets in the regex matches.
    private static func stripCode(_ source: String) -> [UInt8] {
        let src = Array(source.utf8)
        let count = src.count
        var out: [UInt8] = []
        out.reserveCapacity(count)
        let space = UInt8(ascii: " "), newline = UInt8(ascii: "\n"), slash = UInt8(ascii: "/"), star = UInt8(ascii: "*")
        let quote = UInt8(ascii: "\""), hash = UInt8(ascii: "#"), backslash = UInt8(ascii: "\\")
        func at(_ index: Int) -> UInt8? { index < count ? src[index] : nil }
        func starts(_ pattern: [UInt8], at index: Int) -> Bool {
            index + pattern.count <= count && Array(src[index..<index + pattern.count]) == pattern
        }
        var i = 0
        while i < count {
            let c = src[i]
            let next = at(i + 1)
            if c == slash, next == slash {
                while i < count, src[i] != newline { out.append(space); i += 1 }
                continue
            }
            if c == slash, next == star {
                var depth = 0
                while i < count {
                    if src[i] == slash, at(i + 1) == star { depth += 1; out += [space, space]; i += 2; continue }
                    if src[i] == star, at(i + 1) == slash {
                        depth -= 1; out += [space, space]; i += 2
                        if depth == 0 { break }
                        continue
                    }
                    out.append(src[i] == newline ? newline : space)
                    i += 1
                }
                continue
            }
            if c == quote || (c == hash && (next == quote || next == hash)) {
                var hashes = 0
                var j = i
                while j < count, src[j] == hash { hashes += 1; j += 1 }
                guard j < count, src[j] == quote else { out.append(c < 0x80 ? c : space); i += 1; continue }
                let multi = starts([quote, quote, quote], at: j)
                let opening = multi ? [quote, quote, quote] : [quote]
                let closing = opening + Array(repeating: hash, count: hashes)
                out += Array(repeating: space, count: j - i + opening.count)
                i = j + opening.count
                while i < count {
                    if hashes == 0, src[i] == backslash { out += [space, space]; i += 2; continue }
                    if starts(closing, at: i) { out += Array(repeating: space, count: closing.count); i += closing.count; break }
                    if !multi, src[i] == newline { break }
                    out.append(src[i] == newline ? newline : space)
                    i += 1
                }
                continue
            }
            out.append(c < 0x80 ? c : space)
            i += 1
        }
        return out
    }
}
