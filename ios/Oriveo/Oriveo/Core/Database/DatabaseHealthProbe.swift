import Foundation

/// The three states of the local database. The UI only cares whether it is `.blocked`.
enum DatabaseHealth: Equatable {
    /// No verdict yet. The first frame stays here: it does not wait on the probe.
    case unknown
    case healthy
    case blocked(DatabaseBlockedReason)

    var blockedReason: DatabaseBlockedReason? {
        if case let .blocked(reason) = self { return reason }
        return nil
    }
}

/// Why the local data is unreachable. Decides which page is shown.
enum DatabaseBlockedReason: Equatable {
    /// The device is out of free space. The user can fix it → out-of-storage page.
    case storageFull
    /// It fails with space to spare (corruption, migration, permissions). The user cannot fix it.
    case unavailable
}

/// Tracks whether the local database can be read.
///
/// ## What it is for
///
/// When the database cannot be opened, `AppState.loadSession` quietly falls back to the recovery
/// snapshot and the app carries on into the main screen. The result is an app that works but keeps
/// nothing: messages sent, conversations created and settings changed are all gone at the next
/// launch, and the interface never says a word about it. The only hint was a wordless ⚠️ on the
/// chat screen.
///
/// ## The test
///
/// One line only: the read failed **and** free space is below `storageFullThresholdBytes` → out of
/// storage; otherwise it is a local fault. Deliberately not split by error code — see
/// `StorageFailureTriage.swift`: "disk full" surfaces as entirely different codes in GRDB, in WAL
/// and in the file layer, while one code can equally mean bad blocks or a read-only filesystem.
/// The only stable fact is how much room is left.
///
/// ## Why it observes instead of probing
///
/// A cold start reads the database through `AppState.loadSession`, and a failure there is caught.
/// So this observes that real read (`recordSuccess` / `recordFailure`) rather than running a query
/// of its own: no extra IO before the first frame, and the verdict is formed from the error the
/// production path actually produced.
@MainActor
@Observable
final class DatabaseHealthProbe {
    private(set) var health: DatabaseHealth = .unknown

    @ObservationIgnored private let availableBytes: @Sendable () -> Int64?

    init(availableBytes: @escaping @Sendable () -> Int64? = { availableStorageBytesForAppContainer() }) {
        self.availableBytes = availableBytes
    }

    /// The local database read succeeded.
    func recordSuccess() {
        health = .healthy
    }

    /// The local database read failed.
    ///
    /// - Returns: whether this was turned into a blocked state. false = the failure is not a
    ///   storage access failure, and the caller **must** handle it the way it did before.
    @discardableResult
    func recordFailure(_ error: Error) -> Bool {
        guard let verdict = triageStorageFailure(error, availableBytes: availableBytes()) else {
            return false
        }
        let reason: DatabaseBlockedReason = verdict.isLocalFault ? .unavailable : .storageFull
        let wasBlocked = health.blockedReason != nil
        health = .blocked(reason)
        // Only leave a trace on entering the blocked state: a full disk arrives from several
        // startup paths at once, and logging each one just floods.
        guard !wasBlocked else { return true }
        AppLog.error(error, module: "persistence", context: [
            "op": "openLocalDatabase",
            "freeBytesBucket": verdict.freeBytesBucket,
        ])
        return true
    }
}
