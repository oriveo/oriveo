import Foundation
import GRDB
import Testing
@testable import Oriveo

@Suite("BackupService Hook", .serialized)
struct BackupServiceHookTests {
    private enum HookTestError: Error, Equatable {
        case injectedCommitFailure
    }

    private func makeBackupFile(
        data: BackupData,
        platform: String = "iOS"
    ) throws -> BackupFile {
        let dataJSON = try CanonicalJSON.encode(data)
        return BackupFile(
            version: 1,
            createdAt: "2026-03-18T10:00:00Z",
            appVersion: "1.0",
            platform: platform,
            checksum: CanonicalJSON.checksum(of: dataJSON),
            containsKeys: false,
            data: data,
            attachmentChecksums: nil,
            encryptedKeys: nil
        )
    }

    private func makeStore(uid: String) throws -> ConversationStore {
        let dbPool = try DatabasePool(
            path: AppSessionStore.databasePath(for: uid).path,
            configuration: DatabaseSchema.makeConfiguration()
        )
        let attachmentFileStore = AttachmentFileStore(
            rootDirectory: AppSessionStore.userDir(for: uid)
                .appendingPathComponent("Files", isDirectory: true)
        )
        try DatabaseSchema.makeMigrator(attachmentFileStore: attachmentFileStore).migrate(dbPool)
        return ConversationStore(
            dbPool: dbPool,
            attachmentFileStore: attachmentFileStore
        )
    }

    @Test("replaceAll runs the pre-commit hook and rolls back on failure")
    @MainActor
    func replaceAllExecutesPreCommitHook() async throws {
        let targetUID = "backup-hook-\(UUID().uuidString)"
        let existingLocalImageID = "existing-\(UUID().uuidString)"
        let existingImageData = Data("existing-image".utf8)
        let targetImageURL = AppSessionStore.userDir(for: targetUID)
            .appendingPathComponent("Images", isDirectory: true)
            .appendingPathComponent("\(existingLocalImageID).img")

        let provider = TestFactories.makeProvider(kind: .openAI)
        let importedLocalImageID = "imported-\(UUID().uuidString)"
        let importedAttachment = TestFactories.makeImageAttachment(
            fileName: "hook.png",
            mimeType: "image/png",
            localImageID: importedLocalImageID
        )
        let importedMessage = TestFactories.makeMessage(
            role: .assistant,
            text: "hook image",
            attachments: [importedAttachment]
        )
        let importedConversation = TestFactories.makeConversation(
            title: "Hook Chat",
            providerID: provider.id,
            messages: [importedMessage]
        )
        let backupData = BackupData(
            providers: [BackupProvider(from: provider)],
            conversations: [BackupConversation(from: importedConversation)],
            preferences: BackupPreferences(theme: "system", language: "english"),
            lastUsedModelRef: nil
        )
        let backupFile = try makeBackupFile(data: backupData)
        let imageKey = "\(importedAttachment.id).png"
        let thumbnailKey = "\(importedAttachment.id).thumb.png"

        defer {
            BackupService.testingHooks = .init()
            DatabaseManager.shared.close()
            try? FileManager.default.removeItem(at: AppSessionStore.userDir(for: targetUID))
        }

        DatabaseManager.shared.close()

        let appState = AppState(sessionUID: targetUID)
        var hookInvoked = false
        ImageStore.save(imageData: existingImageData, for: existingLocalImageID, partitionUID: targetUID)
        BackupService.testingHooks.beforeReplaceAllCommit = {
            await MainActor.run {
                hookInvoked = true
            }
            throw HookTestError.injectedCommitFailure
        }

        do {
            _ = try await BackupService.executeImport(
                backupFile: backupFile,
                images: [imageKey: Data("imported-image".utf8), thumbnailKey: Data("imported-thumb".utf8)],
                mode: .replaceAll,
                password: nil,
                appState: appState
            )
            Issue.record("replaceAll should abort after a hook injection failure")
        } catch let error as HookTestError {
            #expect(error == .injectedCommitFailure)
        }

        let restoredData = try Data(contentsOf: targetImageURL)
        let store = try makeStore(uid: targetUID)

        #expect(hookInvoked == true)
        #expect(restoredData == existingImageData)
        #expect(try store.fetchConversationThread(id: importedConversation.id) == nil)
    }
}
