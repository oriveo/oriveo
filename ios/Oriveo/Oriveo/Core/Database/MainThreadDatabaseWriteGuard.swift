#if DEBUG
import Foundation
import GRDB

/// Runtime gate against synchronous database writes on the main thread (installed only in DEBUG / test builds).
///
/// A synchronous write on the main thread queues behind the GRDB writer: while a long transaction such as a whole-table
/// write holds the write lock, the main thread waits with it for seconds. A trace on every write connection keys each
/// write transaction started on the main thread (BEGIN, or a single statement outside a transaction) by the method that
/// calls the synchronous GRDB write directly:
/// - the key is main-thread debt (`MainThreadDatabaseWriteAllowlist.mainThreadDebt`) → allowed;
/// - the key is a known synchronous write method outside the debt (fixed or newly registered) → `violationHandler`
///   (an assertion failure by default);
/// - the direct caller is test code (a unit test calling a store's synchronous API) → allowed; unrecognized keys are
///   logged once.
/// `MainThreadDatabaseWriteStaticGateTests` scans the app sources and fails when a new synchronous write method is not
/// registered in `MainThreadDatabaseWriteAllowlist.known`.
nonisolated enum MainThreadDatabaseWriteGuard {
    enum Verdict: Equatable {
        /// Main-thread debt: allowed; the first hit per (key, call chain) logs one `[MAIN-THREAD-DB-WRITE-DEBT]` line for auditing.
        case debt(key: String, callers: [String])
        case exemptTestCaller
        case unknown(String?)
        case violation(key: String, caller: String?)
    }

    /// Tests swap this to capture violations instead of crashing.
    nonisolated(unsafe) static var violationHandler: (String) -> Void = { message in
        assertionFailure(message)
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var reportedUnknown = Set<String>()
    nonisolated(unsafe) private static var reportedDebt = Set<String>()
    nonisolated(unsafe) private static var symbolCache: [UInt: String] = [:]
    /// Symbolication is slow (dladdr scans a large debug image linearly per frame): the main thread only captures return
    /// addresses and the verdict runs on this serial queue, so the path under test is not slowed down.
    private static let queue = DispatchQueue(label: "MainThreadDatabaseWriteGuard", qos: .utility)

    /// No verdict while the test process opens a database for the first time on the main thread
    /// (`DatabaseManager.allowsMainThreadFirstOpen`): that is the test host's synchronous entry point, not a production path;
    /// production never opens a database on the main thread (a dedicated test with the switch off locks that in).
    /// Read and written only on the main thread.
    nonisolated(unsafe) private static var testHarnessOpenDepth = 0

    static func exemptingTestHarnessOpen<T>(_ body: () throws -> T) rethrows -> T {
        testHarnessOpenDepth += 1
        defer { testHarnessOpenDepth -= 1 }
        return try body()
    }

    static func install(on db: Database) {
        guard !db.configuration.readonly else { return }
        db.trace(options: .statement) { [unowned db] event in
            guard Thread.isMainThread, testHarnessOpenDepth == 0, case let .statement(statement) = event else { return }
            // A write transaction is judged once, at BEGIN; statements outside a transaction are judged one by one.
            guard statement.sql.hasPrefix("BEGIN") || !db.isInsideTransaction else { return }
            let addresses = Thread.callStackReturnAddresses.map(\.uintValue)
            queue.async { check(addresses: addresses) }
        }
    }

    /// Waits for queued verdicts to finish (for tests).
    static func drain() {
        queue.sync {}
    }

    private static func check(addresses: [UInt]) {
        switch classify(frames: addresses.map { frame(fromDemangled: demangle(symbolName(at: $0))) }) {
        case .exemptTestCaller:
            return
        case let .debt(key, callers):
            let line = "\(key) <- \(callers.joined(separator: " <- "))"
            lock.lock()
            let isNew = reportedDebt.insert(line).inserted
            lock.unlock()
            if isNew { print("[MAIN-THREAD-DB-WRITE-DEBT] \(line)") }
        case let .unknown(key):
            let label = key ?? "?"
            lock.lock()
            let isNew = reportedUnknown.insert(label).inserted
            lock.unlock()
            if isNew {
                let chain = unknownCallers.isEmpty ? "" : " <- " + unknownCallers.joined(separator: " <- ")
                print("[MainThreadDatabaseWriteGuard] synchronous main-thread database write (unregistered call site): \(label)\(chain)")
            }
        case let .violation(key, caller):
            violationHandler(
                "Synchronous database write on the main thread: \(key) (caller \(caller ?? "?")). A long transaction may hold "
                    + "the write lock and the main thread would hang with it; use `try await writer.write` or move it to the background."
            )
        }
    }

    // MARK: - Stack frame parsing (pure functions, testable)

    struct Frame: Equatable {
        /// Owning module (GRDB / Oriveo / OriveoTests / Swift…); nil for thunks and C frames.
        var module: String?
        /// `Type.method` (a closure belongs to the method that defines it); nil when unrecognized.
        var owner: String?
        /// A GRDB write entry point (`SerializedDatabase.sync`, `writeWithoutTransaction`, `DatabaseWriter.write`…).
        var isWriteEntry: Bool
    }

    /// Pure forwarding write wrappers: skipped when taking the key, which lands on the method that really starts the write.
    static let forwardingWrappers: Set<String> = ["ConversationStore.write"]
    /// Pure forwarding layers that resolve a store per partition: skipped when collecting the call chain, so the direct caller
    /// is whoever really started the write (a test calling the bridge directly is a test caller). Besides its own writes,
    /// ConversationStore also triggers the sidecar cleanup (`RecipeContinuationStore.purgeOrphans`), skipped the same way.
    static let forwardingCallerTypes: Set<Substring> = [
        "ConversationRuntimeBridge", "ConversationStore", "MemoryItemRepository", "MemoryItemWriter",
    ]

    /// Call chain of the latest `.unknown(key)` verdict (read and written only on the verdict queue, so the log can name callers).
    nonisolated(unsafe) private static var unknownCallers: [String] = []

    static func classify(frames: [Frame]) -> Verdict {
        unknownCallers = []
        guard let entry = frames.firstIndex(where: \.isWriteEntry) else { return .unknown(nil) }
        var index = entry + 1
        var key: String?
        var keyType: Substring?
        while index < frames.count {
            let frame = frames[index]
            index += 1
            guard frame.module == "Oriveo" || frame.module == "OriveoTests" else { continue }
            if frame.module == "OriveoTests" { return .exemptTestCaller }
            guard let owner = frame.owner else { return .unknown(nil) }
            if forwardingWrappers.contains(owner) { continue }
            key = owner
            keyType = owner.split(separator: ".").first
            break
        }
        guard let key else { return .unknown(nil) }
        // Call chain: skip forwarding inside the same type and take up to 3 outer app frames. A direct caller in test code is a
        // unit test calling a store's synchronous API, not an app path.
        var callers: [String] = []
        while index < frames.count, callers.count < 3 {
            let frame = frames[index]
            index += 1
            guard frame.module == "Oriveo" || frame.module == "OriveoTests" else { continue }
            if frame.module == "OriveoTests" {
                if callers.isEmpty { return .exemptTestCaller }
                break
            }
            guard let owner = frame.owner else { continue }
            // `xxxForTesting` is an entry point for tests (called only by tests): seeing it in the chain means a test caller.
            if owner.hasSuffix("ForTesting") { return .exemptTestCaller }
            let ownerType = owner.split(separator: ".").first
            if callers.isEmpty, ownerType == keyType || ownerType.map(forwardingCallerTypes.contains) == true { continue }
            if callers.last != owner { callers.append(owner) }
        }
        // Unregistered methods are judged by the call chain too: a direct test caller is exempt (returned above); an app path
        // logs once with its call chain.
        guard MainThreadDatabaseWriteAllowlist.known.contains(key) else {
            unknownCallers = callers
            return .unknown(key)
        }
        if MainThreadDatabaseWriteAllowlist.mainThreadDebt.contains(key) { return .debt(key: key, callers: callers) }
        return .violation(key: key, caller: callers.first)
    }

    static func frame(fromDemangled name: String) -> Frame {
        // A resumed async function fragment looks like "(1) await resume partial function for OriveoTests.X.y() async throws -> ()":
        // take the definition after "partial function for ", otherwise the frame has no module and an async test body calling
        // a synchronous API directly would be treated as an app path with caller "?".
        var name = name
        if let range = name.range(of: "partial function for ", options: .backwards) {
            name = String(name[range.upperBound...])
        }
        let thunkPrefixes = ["reabstraction thunk", "thunk for", "merged ", "outlined ", "objectdestroy", "@objc "]
        if thunkPrefixes.contains(where: name.hasPrefix) {
            return Frame(module: nil, owner: nil, isWriteEntry: false)
        }
        // Closures and protocol witnesses look like "closure #1 (...) in Oriveo.X.y(...)": take the defining context after the
        // last " in ". "(extension in GRDB):" itself contains " in ", so replace it first.
        let normalized = name.replacingOccurrences(of: "(extension in ", with: "(extension@")
        var context = Substring(normalized)
        if let range = normalized.range(of: " in ", options: .backwards) { context = normalized[range.upperBound...] }
        for prefix in ["static ", "partial apply for ", "dispatch thunk of ", "protocol witness for "] where context.hasPrefix(prefix) {
            context = context.dropFirst(prefix.count)
        }
        var extensionModule: String?
        if context.hasPrefix("(extension@"), let close = context.firstIndex(of: ")") {
            extensionModule = String(context[context.index(context.startIndex, offsetBy: 11)..<close])
            context = context[context.index(after: close)...].drop(while: { $0 == ":" })
        }
        let pathEnd = context.firstIndex(where: { $0 == "(" || $0 == " " }) ?? context.endIndex
        let path = stripGenerics(String(context[..<pathEnd]))
        let components = path.split(separator: ".").map(String.init)
        guard let first = components.first, !first.isEmpty, first.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" })
        else { return Frame(module: nil, owner: nil, isWriteEntry: false) }
        let module = extensionModule ?? first
        let hasCall = pathEnd < context.endIndex && context[pathEnd] == "("
        var owner: String?
        if hasCall, components.count >= 2 {
            var method = components[components.count - 1]
            if method == "__allocating_init" { method = "init" }
            owner = components.count >= 3 ? "\(components[components.count - 2]).\(method)" : method
        }
        let writeEntryMarkers = [
            "SerializedDatabase.sync", "writeWithoutTransaction", "DatabaseWriter.write", "DatabaseQueue.inDatabase",
            "DatabaseQueue.write", "DatabasePool.init", "DatabaseQueue.init", "DatabaseMigrator.migrate",
        ]
        let isWriteEntry = first == "GRDB" && writeEntryMarkers.contains(where: { path.contains($0) })
        return Frame(module: module, owner: owner, isWriteEntry: isWriteEntry)
    }

    private static func stripGenerics(_ path: String) -> String {
        var result = ""
        var depth = 0
        for character in path {
            if character == "<" { depth += 1; continue }
            if character == ">" { depth = max(0, depth - 1); continue }
            if depth == 0 { result.append(character) }
        }
        return result
    }

    /// Return address → symbol name (cached per address; called only on the verdict queue).
    private static func symbolName(at address: UInt) -> String {
        if let cached = symbolCache[address] { return cached }
        var info = Dl_info()
        var name = ""
        if let pointer = UnsafeRawPointer(bitPattern: address), dladdr(pointer, &info) != 0, let symbol = info.dli_sname {
            name = String(cString: symbol)
        }
        symbolCache[address] = name
        return name
    }

    private typealias SwiftDemangle = @convention(c) (
        UnsafePointer<CChar>?, Int, UnsafeMutablePointer<CChar>?, UnsafeMutablePointer<Int>?, UInt32
    ) -> UnsafeMutablePointer<CChar>?

    nonisolated(unsafe) private static let swiftDemangle: SwiftDemangle? = {
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "swift_demangle") else { return nil }
        return unsafeBitCast(symbol, to: SwiftDemangle.self)
    }()

    static func demangle(_ symbol: String) -> String {
        guard let swiftDemangle else { return symbol }
        return symbol.withCString { pointer in
            guard let demangled = swiftDemangle(pointer, strlen(pointer), nil, nil, 0) else { return symbol }
            defer { free(demangled) }
            return String(cString: demangled)
        }
    }
}
#endif
