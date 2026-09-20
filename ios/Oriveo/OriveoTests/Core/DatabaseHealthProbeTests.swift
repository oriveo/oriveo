import Foundation
import GRDB
import Testing
@testable import Oriveo

/// The device running out of storage is no longer silent.
@Suite("Local database health", .serialized)
@MainActor
struct DatabaseHealthProbeTests {

    /// One of the real shapes a full disk takes on the GRDB side.
    private var sqliteFullError: Error {
        DatabaseError(resultCode: ResultCode(rawValue: 13), message: "database or disk is full")
    }

    @Test("No room left → blocked as storageFull")
    func storageFullBlocks() {
        let probe = DatabaseHealthProbe(availableBytes: { 1024 })

        #expect(probe.recordFailure(sqliteFullError))

        #expect(probe.health == .blocked(.storageFull))
    }

    /// Room to spare and still failing is a local fault. Telling the user their device is full
    /// would be false, and would leave them with nothing to do about it.
    @Test("Space to spare → blocked as a local fault")
    func genuineFailureBlocksAsUnavailable() {
        let probe = DatabaseHealthProbe(availableBytes: { 8 * 1024 * 1024 * 1024 })

        #expect(probe.recordFailure(sqliteFullError))

        #expect(probe.health == .blocked(.unavailable))
    }

    @Test("Recovering after a block returns to healthy")
    func recoveryMarksHealthy() {
        let probe = DatabaseHealthProbe(availableBytes: { 0 })

        probe.recordFailure(sqliteFullError)
        probe.recordSuccess()

        #expect(probe.health == .healthy)
    }

    /// The probe only claims storage access failures. Anything else goes back to the caller
    /// untouched, and is never mistaken for a storage block.
    @Test("A non-storage failure is not claimed")
    func nonStorageFailureIsNotSwallowed() {
        let probe = DatabaseHealthProbe(availableBytes: { 0 })

        let decodingError = DecodingError.dataCorrupted(
            .init(codingPath: [], debugDescription: "not storage related")
        )

        #expect(probe.recordFailure(decodingError) == false)
        #expect(probe.health == .unknown)
    }
}

/// The cold-start read really does drive the three states.
///
/// The suite above tests the verdict with injected errors. This one shapes nothing: the database
/// file is genuinely broken, the error genuinely comes out of `DatabaseManager.openIfNeeded`, and
/// the state is genuinely flipped by `AppState.loadSession`.
@Suite("Cold start drives database health", .serialized)
@MainActor
struct DatabaseHealthFromLoadSessionTests {

    @Test("A readable database is healthy")
    func healthyDatabaseMarksHealthy() throws {
        let uid = "db-health-ok-\(UUID().uuidString)"
        defer {
            DatabaseManager.shared.close()
            try? FileManager.default.removeItem(at: AppSessionStore.userDir(for: uid))
        }
        DatabaseManager.shared.close()

        let state = AppState(sessionUID: uid)

        #expect(state.databaseHealthProbe.health == .healthy)
    }

    /// A broken database on a disk with room is a local fault, not "your device is full".
    @Test("A corrupt database blocks as a local fault")
    func corruptDatabaseBlocks() throws {
        let uid = "db-health-corrupt-\(UUID().uuidString)"
        defer {
            DatabaseManager.shared.close()
            try? FileManager.default.removeItem(at: AppSessionStore.userDir(for: uid))
        }
        DatabaseManager.shared.close()

        _ = AppState(sessionUID: uid)
        DatabaseManager.shared.close()
        try Data("not-a-valid-sqlite".utf8).write(
            to: AppSessionStore.databasePath(for: uid),
            options: .atomic
        )

        let relaunched = AppState(sessionUID: uid)

        #expect(relaunched.databaseHealthProbe.health == .blocked(.unavailable))
    }
}

/// The soft failure: the database opens but writes fail.
@Suite("Degraded local writes", .serialized)
@MainActor
struct StorageWriteHealthTests {

    private var outOfSpaceWriteError: Error {
        let underlying = NSError(domain: NSPOSIXErrorDomain, code: 28, userInfo: [
            NSLocalizedDescriptionKey: "No space left on device",
        ])
        return NSError(domain: NSCocoaErrorDomain, code: 640, userInfo: [
            NSUnderlyingErrorKey: underlying,
        ])
    }

    @Test("A write that failed on device storage degrades")
    func outOfSpaceWriteDegrades() async {
        StorageWriteHealthSignal.resetForTesting()
        StorageWriteHealth.shared.markRecovered()

        StorageWriteHealthSignal.recordFailure(outOfSpaceWriteError, availableBytes: 1024)
        await Task.yield()

        #expect(StorageWriteHealth.shared.isDegraded)
    }

    /// A write that failed with space to spare is a local fault. The banner says the device is out
    /// of space, so showing it here would be untrue, and the user could do nothing about it.
    @Test("A write that failed with space to spare shows no banner")
    func genuineWriteFailureDoesNotDegrade() async {
        StorageWriteHealthSignal.resetForTesting()
        StorageWriteHealth.shared.markRecovered()

        StorageWriteHealthSignal.recordFailure(
            outOfSpaceWriteError,
            availableBytes: 8 * 1024 * 1024 * 1024
        )
        await Task.yield()

        #expect(!StorageWriteHealth.shared.isDegraded)
    }

    @Test("A non-storage failure shows no banner")
    func nonStorageFailureDoesNotDegrade() async {
        StorageWriteHealthSignal.resetForTesting()
        StorageWriteHealth.shared.markRecovered()

        StorageWriteHealthSignal.recordFailure(
            DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "unrelated")),
            availableBytes: 0
        )
        await Task.yield()

        #expect(!StorageWriteHealth.shared.isDegraded)
    }

    /// One successful write takes the banner away. Without this it would stay until the next cold
    /// start, stating a passing condition as a permanent one.
    @Test("The next successful write clears the banner")
    func successClearsBanner() async {
        StorageWriteHealthSignal.resetForTesting()
        StorageWriteHealth.shared.markRecovered()

        StorageWriteHealthSignal.recordFailure(outOfSpaceWriteError, availableBytes: 0)
        await Task.yield()
        #expect(StorageWriteHealth.shared.isDegraded)

        StorageWriteHealthSignal.recordSuccess()
        await Task.yield()

        #expect(!StorageWriteHealth.shared.isDegraded)
    }
}
