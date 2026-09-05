import Foundation

nonisolated final class NoteRuntimeBridge: @unchecked Sendable {
    typealias SoftDeleteNoteFolderHandler = @Sendable (_ uid: String, _ id: UUID, _ deletedAt: Date, _ updatedAt: Date) throws -> [UUID]

    private let databaseManager: DatabaseManager
    private let softDeleteNoteFolderHandler: SoftDeleteNoteFolderHandler?

    init() {
        self.databaseManager = .shared
        self.softDeleteNoteFolderHandler = nil
    }

    init(databaseManager: DatabaseManager, softDeleteNoteFolderHandler: SoftDeleteNoteFolderHandler? = nil) {
        self.databaseManager = databaseManager
        self.softDeleteNoteFolderHandler = softDeleteNoteFolderHandler
    }

    init(softDeleteNoteFolderHandler: @escaping SoftDeleteNoteFolderHandler) {
        self.databaseManager = .shared
        self.softDeleteNoteFolderHandler = softDeleteNoteFolderHandler
    }

    func makeStore(for uid: String) throws -> NoteStore {
        let pool = try databaseManager.openIfNeeded(for: uid)
        return NoteStore(dbPool: pool)
    }

    func softDeleteNoteFolder(for uid: String, id: UUID, deletedAt: Date, updatedAt: Date) throws -> [UUID] {
        if let softDeleteNoteFolderHandler {
            return try softDeleteNoteFolderHandler(uid, id, deletedAt, updatedAt)
        }
        return try makeStore(for: uid).softDeleteNoteFolder(id: id, deletedAt: deletedAt, updatedAt: updatedAt)
    }
}
