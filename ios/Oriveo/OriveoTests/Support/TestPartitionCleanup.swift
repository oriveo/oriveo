import Foundation
@testable import Oriveo

/// The single entry point for tests that delete a partition: wait for the AppStates bound to those partitions to drain
/// their in-flight reads and writes first, then close the database and remove the directory.
///
/// Removing the user directory directly lets background reads and writes (send-task wrap-up, write tails, the persist queue,
/// memory reconcile) hit the database file that was just deleted (SQLite disk I/O error), and a write resolved by uid
/// would even recreate the partition. A case's `defer` keeps only synchronous state restoration.
@MainActor
enum TestPartitionCleanup {
    static func remove(_ uids: String...) async {
        await remove(uids)
    }

    static func remove(_ uids: [String]) async {
        let targets = Set(uids)
        for state in AppState.liveInstancesForTesting(boundTo: targets) {
            await state.chatManager.waitForSendTasksForTesting()
            await state.drainPendingWrites()
        }
        DatabaseManager.shared.close()
        for uid in uids {
            try? FileManager.default.removeItem(at: AppSessionStore.userDir(for: uid))
        }
    }
}
