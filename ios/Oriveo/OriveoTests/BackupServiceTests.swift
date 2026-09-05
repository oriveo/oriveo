import Foundation
import GRDB
import Testing
import ZIPFoundation
@testable import Oriveo


@Suite("BackupService", .serialized)
struct BackupServiceTests {

    @Test("Relay Backup Excludes Portable Credentials")
    func relayBackupExcludesPortableCredentials() {
        var provider = TestFactories.makeProvider(
            kind: .relay,
            apiKey: "primary-secret",
            baseURLText: "https://relay.example.com/v1?api_key=base-secret#fragment"
        )
        provider.relayRequested = RelayRequestedConfig(
            transport: .openaiResponses,
            authMode: .bearer,
            headers: [RelayKeyValue(key: "X-Second-Key", value: "header-secret")],
            queryParams: [RelayKeyValue(key: "api_key", value: "query-secret")],
            resolvedAPIBaseURL: "https://relay.example.com/v1?token=resolved-secret#fragment"
        )

        let backup = BackupProvider(from: provider)
        #expect(backup.baseURLText == "https://relay.example.com/v1")
        #expect(backup.relayRequested?.headers == nil)
        #expect(backup.relayRequested?.queryParams == nil)
        #expect(backup.relayRequested?.resolvedAPIBaseURL == "https://relay.example.com/v1")
    }


    private enum ImportReplaceAllTestError: Error, Equatable {
        case injectedCommitFailure
    }

    @MainActor
    private static var retainedStates: [AppState] = []

    @MainActor
    private func makeAppState(
        seedDemoData: Bool = false,
        sessionUID: String? = nil
    ) -> AppState {
        let state = AppState(seedDemoData: seedDemoData, sessionUID: sessionUID)
        Self.retainedStates.append(state)
        return state
    }

    @MainActor
    private func cleanupAppState(_ state: AppState, removing uids: [String]) {
        state.flushConversationPersistQueue()
        DatabaseManager.shared.close()
        for uid in uids {
            try? FileManager.default.removeItem(at: AppSessionStore.userDir(for: uid))
        }
    }

    private func makeMessage(
        id: UUID = UUID(),
        text: String = "Hello",
        role: ChatRole = .user,
        createdAt: Date? = Date()
    ) -> ChatMessage {
        ChatMessage(
            id: id,
            role: role,
            text: text,
            providerKind: .openAI,
            providerName: "OpenAI",
            modelName: "GPT-4o",
            state: .delivered,
            createdAt: createdAt
        )
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

    private func makeSkill(
        id: UUID = UUID(),
        updatedAt: Date = Date(),
        knowledgeBase: SkillKnowledgeBase? = nil
    ) -> Skill {
        Skill(
            id: id,
            name: "Backup Skill",
            description: "Restored from backup",
            icon: "✨",
            color: "#8B5CF6",
            systemPrompt: "Use grounded knowledge.",
            knowledgeFiles: [],
            knowledgeBase: knowledgeBase,
            useMemory: true,
            isPinned: false,
            pinOrder: 0,
            source: .user,
            sortOrder: 0,
            usageCount: 0,
            updatedAt: updatedAt
        )
    }


    @Test("Merge Subset")
    func mergeSubset() {
        let m1 = makeMessage(text: "M1", createdAt: Date(timeIntervalSince1970: 1000))
        let m2 = makeMessage(text: "M2", createdAt: Date(timeIntervalSince1970: 2000))
        let m3 = makeMessage(text: "M3", createdAt: Date(timeIntervalSince1970: 3000))
        let m4 = makeMessage(text: "M4", createdAt: Date(timeIntervalSince1970: 4000))
        let m5 = makeMessage(text: "M5", createdAt: Date(timeIntervalSince1970: 5000))

        let local = [m1, m2, m3, m4, m5]
        let backup = [m1, m2, m3]

        let merged = BackupService.mergeMessages(local: local, backup: backup)

        #expect(merged.count == 5)
        #expect(merged.map(\.id) == [m1.id, m2.id, m3.id, m4.id, m5.id])
    }

    @Test("Merge Disjoint")
    func mergeDisjoint() {
        let m1 = makeMessage(text: "M1", createdAt: Date(timeIntervalSince1970: 1000))
        let m2 = makeMessage(text: "M2", createdAt: Date(timeIntervalSince1970: 2000))
        let m3 = makeMessage(text: "M3", createdAt: Date(timeIntervalSince1970: 3000))
        let m4 = makeMessage(text: "M4", createdAt: Date(timeIntervalSince1970: 4000))
        let m5 = makeMessage(text: "M5", createdAt: Date(timeIntervalSince1970: 5000))
        let m6 = makeMessage(text: "M6", createdAt: Date(timeIntervalSince1970: 6000))
        let m7 = makeMessage(text: "M7", createdAt: Date(timeIntervalSince1970: 7000))

        let local = [m6, m7]
        let backup = [m1, m2, m3, m4, m5]

        let merged = BackupService.mergeMessages(local: local, backup: backup)

        #expect(merged.count == 7)
        #expect(merged[0].id == m1.id)
        #expect(merged[4].id == m5.id)
        #expect(merged[5].id == m6.id)
        #expect(merged[6].id == m7.id)
    }

    @Test("Merge Overlapping")
    func mergeOverlapping() {
        let m1 = makeMessage(text: "M1", createdAt: Date(timeIntervalSince1970: 1000))
        let m2 = makeMessage(text: "M2", createdAt: Date(timeIntervalSince1970: 2000))
        let m3 = makeMessage(text: "M3", createdAt: Date(timeIntervalSince1970: 3000))
        let m4 = makeMessage(text: "M4", createdAt: Date(timeIntervalSince1970: 4000))
        let m5 = makeMessage(text: "M5", createdAt: Date(timeIntervalSince1970: 5000))

        let local = [m1, m3, m5]
        let backup = [m1, m2, m3, m4]

        let merged = BackupService.mergeMessages(local: local, backup: backup)

        #expect(merged.count == 5)
        #expect(merged.map(\.text) == ["M1", "M2", "M3", "M4", "M5"])
    }

    @Test("Merge Empty Local")
    func mergeEmptyLocal() {
        let m1 = makeMessage(text: "M1", createdAt: Date(timeIntervalSince1970: 1000))
        let m2 = makeMessage(text: "M2", createdAt: Date(timeIntervalSince1970: 2000))

        let merged = BackupService.mergeMessages(local: [], backup: [m1, m2])

        #expect(merged.count == 2)
    }

    @Test("Merge Empty Backup")
    func mergeEmptyBackup() {
        let m1 = makeMessage(text: "M1", createdAt: Date(timeIntervalSince1970: 1000))

        let merged = BackupService.mergeMessages(local: [m1], backup: [])

        #expect(merged.count == 1)
    }

    @Test("Merge Both Empty")
    func mergeBothEmpty() {
        let merged = BackupService.mergeMessages(local: [], backup: [])

        #expect(merged.isEmpty)
    }

    @Test("Merge Nil Created At")
    func mergeNilCreatedAt() {
        let m1 = makeMessage(text: "M1", createdAt: nil)
        let m2 = makeMessage(text: "M2", createdAt: nil)
        let m3 = makeMessage(text: "M3", createdAt: Date(timeIntervalSince1970: 1000))

        let merged = BackupService.mergeMessages(local: [m1, m2], backup: [m3])

        #expect(merged.count == 3)
        #expect(merged.last?.id == m3.id)
    }

    @Test("Merge Same Timestamp Tie Break")
    func mergeSameTimestampTieBreak() {
        let fixedTime = Date(timeIntervalSince1970: 5000)
        let m1 = makeMessage(text: "M1", createdAt: fixedTime)
        let m2 = makeMessage(text: "M2", createdAt: fixedTime)

        let merged = BackupService.mergeMessages(local: [m1], backup: [m2])

        #expect(merged.count == 2)
        let firstID = merged[0].id.uuidString
        let secondID = merged[1].id.uuidString
        #expect(firstID < secondID)
    }


    @Test("Parse ZIPFormat")
    func parseZIPFormat() throws {
        let backupData = BackupData(
            providers: [],
            conversations: [],
            preferences: BackupPreferences(theme: "system", language: "english"),
            lastUsedModelRef: nil
        )
        let dataJSON = try CanonicalJSON.encode(backupData)
        let checksum = CanonicalJSON.checksum(of: dataJSON)

        let backupFile = BackupFile(
            version: 1,
            createdAt: "2026-03-18T10:00:00Z",
            appVersion: "1.0",
            platform: "iOS",
            checksum: checksum,
            containsKeys: false,
            data: backupData,
            attachmentChecksums: nil,
            encryptedKeys: nil
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        let jsonData = try encoder.encode(backupFile)

        guard let archive = Archive(accessMode: .create) else {
            Issue.record("Unable to create ZIP archive")
            return
        }
        try archive.addEntry(
            with: "data.json",
            type: .file,
            uncompressedSize: UInt32(jsonData.count),
            provider: { (position: Int, size: Int) in
                jsonData[position..<(position + size)]
            }
        )
        guard let zipData = archive.data else {
            Issue.record("Unable to get ZIP data")
            return
        }

        #expect(zipData[0] == 0x50)
        #expect(zipData[1] == 0x4B)

        let (parsed, images) = try BackupService.parseBackup(from: zipData)
        #expect(parsed.version == 1)
        #expect(parsed.platform == "iOS")
        #expect(images.isEmpty)
    }

    @Test("Parse JSONFormat")
    func parseJSONFormat() throws {
        let backupData = BackupData(
            providers: [],
            conversations: [],
            preferences: BackupPreferences(theme: "system", language: "english"),
            lastUsedModelRef: nil
        )
        let dataJSON = try CanonicalJSON.encode(backupData)

        let backupFile = BackupFile(
            version: 1,
            createdAt: "2026-03-18T10:00:00Z",
            appVersion: "1.0",
            platform: "Web",
            checksum: CanonicalJSON.checksum(of: dataJSON),
            containsKeys: false,
            data: backupData,
            attachmentChecksums: nil,
            encryptedKeys: nil
        )

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let jsonData = try encoder.encode(backupFile)

        let (parsed, images) = try BackupService.parseBackup(from: jsonData)
        #expect(parsed.platform == "Web")
        #expect(images.isEmpty)
    }

    @Test("Export Backup Includes Folders And Folder Relations")
    func exportBackupIncludesFoldersAndFolderRelations() async throws {
        let provider = TestFactories.makeProvider()
        let folder = TestFactories.makeFolder(name: "Work", sortOrder: 1000)
        let conversation = TestFactories.makeConversation(
            title: "Folder Chat",
            providerID: provider.id,
            folderID: folder.id
        )

        let exported = try await BackupService.exportBackup(
            providers: [provider],
            conversations: [conversation],
            folders: [folder],
            preferences: AppPreference(theme: .system, language: .english),
            lastUsedModelRef: nil,
            includeKeys: false,
            password: nil
        )

        let (parsed, _) = try BackupService.parseBackup(from: exported)
        #expect(parsed.data.folders?.count == 1)
        #expect(parsed.data.folders?.first?.id == folder.id)
        #expect(parsed.data.folders?.first?.name == "Work")
        #expect(parsed.data.conversations.count == 1)
        #expect(parsed.data.conversations.first?.folderID == folder.id)
    }

    @Test("Parse Unrecognized Format")
    func parseUnrecognizedFormat() {
        let randomData = Data([0xFF, 0xD8, 0xFF, 0xE0])

        #expect(throws: BackupError.self) {
            _ = try BackupService.parseBackup(from: randomData)
        }
    }

    @Test("Parse Empty Data")
    func parseEmptyData() {
        #expect(throws: BackupError.self) {
            _ = try BackupService.parseBackup(from: Data())
        }
    }

    @Test("Backup Input Size Is Bounded")
    func backupInputSizeIsBounded() throws {
        let limits = makeImportLimits(input: 8, entry: 16, total: 32, entries: 4)
        #expect(throws: BackupError.self) {
            _ = try BackupService.parseBackup(from: Data(repeating: 0, count: 9), limits: limits)
        }

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("oversized-backup-\(UUID().uuidString)")
        try Data(repeating: 0x61, count: 9).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(throws: BackupError.self) {
            _ = try BackupService.loadImportData(at: url, limits: limits)
        }
    }

    @Test("Backup Archive Expansion Is Bounded")
    func backupArchiveExpansionIsBounded() throws {
        let zip = try makeZip(entries: [("data.json", Data(repeating: 0x61, count: 64))])
        let limits = makeImportLimits(input: zip.count + 1, entry: 32, total: 32, entries: 4)

        do {
            _ = try BackupService.parseBackup(from: zip, limits: limits)
            Issue.record("Expected resourceLimitExceeded")
        } catch let error as BackupError {
            guard case .resourceLimitExceeded = error else {
                Issue.record("Unexpected error: \(error)")
                return
            }
        }
    }

    @Test("Production Entry Cap Covers Large Image Libraries")
    func productionEntryCapCoversLargeImageLibraries() {
        let lowEnd = BackupService.ImportLimits.forPhysicalMemory(2 * 1024 * 1024 * 1024)
        let highEnd = BackupService.ImportLimits.forPhysicalMemory(8 * 1024 * 1024 * 1024)
        #expect(lowEnd.archiveBudget.maxEntries >= 65_536)
        #expect(highEnd.archiveBudget.maxEntries >= 65_536)
    }

    @Test("Chunk Manifest Rejects Untrusted Conversation Count")
    func chunkManifestRejectsUntrustedConversationCount() throws {
        let manifest = Data(#"{"version":1,"totalConversations":2147483647,"conversationChunks":[],"headerFilename":"data.json"}"#.utf8)
        let zip = try makeZip(entries: [("manifest.json", manifest)])
        let limits = makeImportLimits(input: zip.count + 1, entry: 1024, total: 2048, entries: 4)

        do {
            _ = try BackupService.parseBackup(from: zip, limits: limits)
            Issue.record("Expected resourceLimitExceeded")
        } catch let error as BackupError {
            guard case .resourceLimitExceeded = error else {
                Issue.record("Unexpected error: \(error)")
                return
            }
        }
    }


    @Test("Valid Checksum Passes")
    func validChecksumPasses() throws {
        let backupData = BackupData(
            providers: [],
            conversations: [],
            preferences: BackupPreferences(theme: "dark", language: "english"),
            lastUsedModelRef: nil
        )
        let dataJSON = try CanonicalJSON.encode(backupData)
        let checksum = CanonicalJSON.checksum(of: dataJSON)

        let backupFile = BackupFile(
            version: 1,
            createdAt: "2026-03-18T10:00:00Z",
            appVersion: "1.0",
            platform: "iOS",
            checksum: checksum,
            containsKeys: false,
            data: backupData,
            attachmentChecksums: nil,
            encryptedKeys: nil
        )

        #expect(BackupService.validateChecksum(backupFile) == true)
    }

    @Test("Invalid Checksum Fails")
    func invalidChecksumFails() throws {
        let backupData = BackupData(
            providers: [],
            conversations: [],
            preferences: BackupPreferences(theme: "dark", language: "english"),
            lastUsedModelRef: nil
        )

        let backupFile = BackupFile(
            version: 1,
            createdAt: "2026-03-18T10:00:00Z",
            appVersion: "1.0",
            platform: "iOS",
            checksum: "sha256:0000000000000000000000000000000000000000000000000000000000000000",
            containsKeys: false,
            data: backupData,
            attachmentChecksums: nil,
            encryptedKeys: nil
        )

        #expect(BackupService.validateChecksum(backupFile) == false)
    }


    @Test("Attachment Checksums All Match")
    func attachmentChecksumsAllMatch() {
        let imgData = Data("fake image data".utf8)
        let checksum = CanonicalJSON.checksum(of: imgData)

        let expected = ["photo.jpg": checksum]
        let images = ["photo.jpg": imgData]

        let corrupted = BackupService.validateAttachmentChecksums(
            expected: expected, images: images
        )
        #expect(corrupted.isEmpty)
    }

    @Test("Attachment Checksum Mismatch")
    func attachmentChecksumMismatch() {
        let expected = ["photo.jpg": "sha256:aaaa"]
        let images = ["photo.jpg": Data("modified data".utf8)]

        let corrupted = BackupService.validateAttachmentChecksums(
            expected: expected, images: images
        )
        #expect(corrupted == ["photo.jpg"])
    }

    @Test("Attachment Missing")
    func attachmentMissing() {
        let expected = ["photo.jpg": "sha256:aaaa"]
        let images: [String: Data] = [:]

        let corrupted = BackupService.validateAttachmentChecksums(
            expected: expected, images: images
        )
        #expect(corrupted == ["photo.jpg"])
    }


    @Test("Import Preview Stats")
    func importPreviewStats() throws {
        let convID = UUID()
        let providerID = UUID()
        let localConvs = [Conversation(
            id: convID, title: "Local Chat",
            providerID: providerID, providerKind: .openAI, modelID: "gpt-4o",
            previewText: "Hello", isDraft: false, messages: []
        )]
        let localProviders = [Provider(
            id: providerID, kind: .openAI, status: .connected,
            models: [], catalogModels: [],
            apiKey: "sk-test", apiKeyPreview: "sk-...st"
        )]

        let backupData = BackupData(
            providers: [
                BackupProvider(from: localProviders[0]),
                BackupProvider(from: Provider(
                    id: UUID(), kind: .anthropic, status: .connected,
                    models: [], catalogModels: [],
                    apiKey: "sk-ant", apiKeyPreview: "sk-...nt"
                ))
            ],
            conversations: [
                BackupConversation(from: localConvs[0]),
                BackupConversation(from: Conversation(
                    id: UUID(), title: "New Chat",
                    providerID: UUID(), providerKind: .anthropic, modelID: "claude-3",
                    previewText: "Hi", isDraft: false, messages: []
                ))
            ],
            preferences: BackupPreferences(theme: "system", language: "english"),
            lastUsedModelRef: nil
        )
        let dataJSON = try CanonicalJSON.encode(backupData)

        let backupFile = BackupFile(
            version: 1,
            createdAt: "2026-03-18T10:00:00Z",
            appVersion: "1.0",
            platform: "iOS",
            checksum: CanonicalJSON.checksum(of: dataJSON),
            containsKeys: false,
            data: backupData,
            attachmentChecksums: nil,
            encryptedKeys: nil
        )

        let preview = BackupService.previewImport(
            backupFile: backupFile,
            localConversations: localConvs,
            localProviders: localProviders
        )

        #expect(preview.totalConversations == 2)
        #expect(preview.existingConversations == 1)
        #expect(preview.totalProviders == 2)
        #expect(preview.existingProviders == 1)
        #expect(preview.containsKeys == false)
    }

    @Test("Import Preview Treats Same Kind Different Id Provider As New Instance")
    func importPreviewTreatsSameKindDifferentIdProviderAsNewInstance() throws {
        let localProvider = Provider(
            id: UUID(),
            kind: .openRouter,
            status: .connected,
            models: [],
            catalogModels: [],
            apiKey: "sk-local",
            apiKeyPreview: "sk-...al",
            customName: "OpenRouter"
        )
        let backupProvider = Provider(
            id: UUID(),
            kind: .openRouter,
            status: .connected,
            models: [],
            catalogModels: [],
            apiKey: "",
            apiKeyPreview: "",
            customName: "OpenRouter 2"
        )
        let backupData = BackupData(
            providers: [BackupProvider(from: backupProvider)],
            conversations: [],
            preferences: BackupPreferences(theme: "system", language: "english"),
            lastUsedModelRef: nil
        )
        let backupFile = try makeBackupFile(data: backupData)

        let preview = BackupService.previewImport(
            backupFile: backupFile,
            localConversations: [],
            localProviders: [localProvider]
        )

        #expect(preview.totalProviders == 1)
        #expect(preview.existingProviders == 0)
    }

    @Test("Import Restores Folders And Conversation folderID")
    @MainActor
    func importRestoresFoldersAndConversationRelation() async throws {
        let provider = TestFactories.makeProvider(kind: .openAI)
        let folder = TestFactories.makeFolder(name: "Imported Folder", sortOrder: 1000)
        let conversation = TestFactories.makeConversation(
            title: "Imported Chat",
            providerID: provider.id,
            folderID: folder.id
        )

        let backupData = BackupData(
            providers: [BackupProvider(from: provider)],
            conversations: [BackupConversation(from: conversation)],
            preferences: BackupPreferences(theme: "system", language: "english"),
            lastUsedModelRef: nil,
            folders: [BackupFolder(from: folder)]
        )
        let backupFile = try makeBackupFile(data: backupData)

        let appState = makeAppState(seedDemoData: true)
        appState.providers = []
        appState.conversations = []
        appState.folders = []

        let result = try await BackupService.executeImport(
            backupFile: backupFile,
            images: [:],
            mode: .replaceAll,
            password: nil,
            appState: appState
        )

        #expect(result.newProviders == 1)
        #expect(result.newConversations == 1)
        #expect(appState.folders.count == 1)
        #expect(appState.folders[0].id == folder.id)
        #expect(appState.conversations.count == 1)
        #expect(appState.conversations[0].folderID == folder.id)
    }

    @Test("Legacy Backup Without Folders Field Still Imports")
    @MainActor
    func importLegacyBackupWithoutFolders() async throws {
        let provider = TestFactories.makeProvider(kind: .openAI)
        let conversation = TestFactories.makeConversation(
            title: "Legacy Chat",
            providerID: provider.id,
            folderID: nil
        )

        let legacyData = BackupData(
            providers: [BackupProvider(from: provider)],
            conversations: [BackupConversation(from: conversation)],
            preferences: BackupPreferences(theme: "system", language: "english"),
            lastUsedModelRef: nil
        )
        let legacyFile = try makeBackupFile(data: legacyData)

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let rawJSON = try encoder.encode(legacyFile)
        let (parsed, _) = try BackupService.parseBackup(from: rawJSON)

        #expect(parsed.data.folders == nil)

        let appState = makeAppState(seedDemoData: true)
        appState.providers = []
        appState.conversations = []
        appState.folders = []

        let result = try await BackupService.executeImport(
            backupFile: parsed,
            images: [:],
            mode: .replaceAll,
            password: nil,
            appState: appState
        )

        #expect(result.newProviders == 1)
        #expect(result.newConversations == 1)
        #expect(appState.folders.isEmpty)
        #expect(appState.conversations.count == 1)
        #expect(appState.conversations[0].folderID == nil)
    }

    @Test("Export Includes Skills Manifest")
    func exportIncludesSkillsManifest() async throws {
        let skill = makeSkill(
            id: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!,
            knowledgeBase: SkillKnowledgeBase(
                provider: "openai",
                retrievalModel: "gpt-5.4-mini",
                vectorStoreId: "vs_live_123",
                expiresAfterDays: 90,
                files: [
                    SkillKnowledgeBaseFile(
                        id: "file-manifest-1",
                        name: "guide.pdf",
                        mimeType: "application/pdf",
                        sizeBytes: 2048,
                        ingestionMode: .nativeFile,
                        openAIFileId: "file-live-1",
                        status: .ready,
                        createdAt: Date(),
                        updatedAt: Date()
                    )
                ],
                updatedAt: Date()
            )
        )

        let exported = try await BackupService.exportBackup(
            providers: [],
            conversations: [],
            folders: [],
            skills: [skill],
            preferences: AppPreference(theme: .system, language: .english),
            lastUsedModelRef: nil,
            includeKeys: false,
            password: nil
        )

        let (parsed, _) = try BackupService.parseBackup(from: exported)
        let exportedSkill = try #require(parsed.data.skills?.first)
        #expect(exportedSkill.knowledgeBase?.vectorStoreId == "")
        #expect(exportedSkill.knowledgeBase?.files.first?.openAIFileId == nil)
        #expect(exportedSkill.knowledgeBase?.files.first?.status == .disabled)
    }

    @Test("Import Restores User Skills And Clears knowledgeBase With Reupload Prompt")
    @MainActor
    func importRestoresSkillsWithoutKnowledgeBase() async throws {
        let skill = makeSkill(
            id: UUID(uuidString: "22222222-2222-2222-2222-222222222222")!,
            knowledgeBase: SkillKnowledgeBase(
                provider: "openai",
                retrievalModel: "gpt-5.4-mini",
                vectorStoreId: "",
                expiresAfterDays: 90,
                files: [
                    SkillKnowledgeBaseFile(
                        id: "file-manifest-2",
                        name: "guide.pdf",
                        mimeType: "application/pdf",
                        sizeBytes: 2048,
                        ingestionMode: .nativeFile,
                        openAIFileId: nil,
                        status: .disabled,
                        createdAt: Date(),
                        updatedAt: Date()
                    )
                ],
                updatedAt: Date()
            )
        )
        let backupData = BackupData(
            providers: [],
            conversations: [],
            skills: [skill],
            preferences: BackupPreferences(theme: "system", language: "english"),
            lastUsedModelRef: nil
        )
        let backupFile = try makeBackupFile(data: backupData)

        let appState = makeAppState(seedDemoData: true)
        let result = try await BackupService.executeImport(
            backupFile: backupFile,
            images: [:],
            mode: .importNewOnly,
            password: nil,
            appState: appState
        )

        #expect(result.newSkills == 1)
        #expect(result.skillsRequiringKnowledgeReupload == 1)
        #expect(appState.skillManager.userSkills.count == 1)
        #expect(appState.skillManager.userSkills[0].knowledgeBase == nil)
    }

    @Test("Merge Import Overwrites Local Skill With Newer Backup And Prompts Knowledge Reupload")
    @MainActor
    func mergeImportUpdatesNewerSkillAndClearsKnowledgeBase() async throws {
        let skillID = UUID(uuidString: "33333333-3333-3333-3333-333333333333")!
        let localSkill = makeSkill(
            id: skillID,
            updatedAt: Date(timeIntervalSince1970: 1000),
            knowledgeBase: nil
        )
        let backupSkill = Skill(
            id: skillID,
            name: "Merged Backup Skill",
            description: "From backup",
            icon: "📚",
            color: "#3B82F6",
            systemPrompt: "Use the backup copy.",
            knowledgeFiles: [],
            knowledgeBase: SkillKnowledgeBase(
                provider: "openai",
                retrievalModel: "gpt-5.4-mini",
                vectorStoreId: "",
                expiresAfterDays: 90,
                files: [
                    SkillKnowledgeBaseFile(
                        id: "file-merge-1",
                        name: "merge.pdf",
                        mimeType: "application/pdf",
                        sizeBytes: 1024,
                        ingestionMode: .nativeFile,
                        openAIFileId: nil,
                        status: .disabled,
                        createdAt: Date(),
                        updatedAt: Date()
                    )
                ],
                updatedAt: Date()
            ),
            useMemory: false,
            isPinned: true,
            pinOrder: 2,
            source: .user,
            sortOrder: 5,
            usageCount: 8,
            updatedAt: Date(timeIntervalSince1970: 2000)
        )
        let backupData = BackupData(
            providers: [],
            conversations: [],
            skills: [backupSkill],
            preferences: BackupPreferences(theme: "system", language: "english"),
            lastUsedModelRef: nil
        )
        let backupFile = try makeBackupFile(data: backupData)

        let appState = makeAppState(seedDemoData: true)
        appState.skillManager.replaceUserSkills([localSkill])

        let result = try await BackupService.executeImport(
            backupFile: backupFile,
            images: [:],
            mode: .merge,
            password: nil,
            appState: appState
        )

        let restoredSkill = try #require(appState.skillManager.userSkills.first)
        #expect(result.mergedSkills == 1)
        #expect(result.skillsRequiringKnowledgeReupload == 1)
        #expect(restoredSkill.name == "Merged Backup Skill")
        #expect(restoredSkill.knowledgeBase == nil)
        #expect(restoredSkill.useMemory == false)
    }

    @Test("replaceAll Import Writes The Authoritative Store After Stopping Session Backwrite")
    @MainActor
    func replaceAllImportWritesToAuthoritativeStore() async throws {
        let uid = "backup-import-store-\(UUID().uuidString)"
        let provider = TestFactories.makeProvider(kind: .openAI)
        let conversation = TestFactories.makeConversation(
            title: "Imported Chat",
            providerID: provider.id,
            messages: [TestFactories.makeMessage(role: .user, text: "backup request", estimatedCost: 0.4)]
        )
        let backupData = BackupData(
            providers: [BackupProvider(from: provider)],
            conversations: [BackupConversation(from: conversation)],
            preferences: BackupPreferences(theme: "system", language: "english"),
            lastUsedModelRef: nil
        )
        let backupFile = try makeBackupFile(data: backupData)

        DatabaseManager.shared.close()

        let appState = makeAppState(sessionUID: uid)
        defer { cleanupAppState(appState, removing: [uid]) }

        appState.providers = []
        appState.conversations = []
        appState.folders = []

        let result = try await BackupService.executeImport(
            backupFile: backupFile,
            images: [:],
            mode: .replaceAll,
            password: nil,
            appState: appState
        )

        #expect(result.newProviders == 1)
        #expect(result.newConversations == 1)
        #expect(appState.conversations.count == 1)
        do {
            let store = try makeStore(uid: uid)
            let stored = try #require(try store.fetchConversationThread(id: conversation.id))
            #expect(stored.summary.previewText == "backup request")
            #expect(stored.messages.count == 1)
            #expect(stored.messages.first?.text == "backup request")
        }
    }

    @Test("replaceAll No Longer Auto-Creates A Hidden Temporary .oriveo Backup")
    @MainActor
    func replaceAllDoesNotCreateHiddenTemporaryBackupArchive() async throws {
        let uid = "backup-temp-archive-\(UUID().uuidString)"
        let existingProvider = TestFactories.makeProvider(kind: .anthropic)
        let existingFolder = TestFactories.makeFolder(name: "Existing Folder", sortOrder: 300)
        let existingConversation = TestFactories.makeConversation(
            title: "Existing Chat",
            providerID: existingProvider.id,
            messages: [TestFactories.makeMessage(role: .user, text: "preserve me", estimatedCost: 0.2)],
            folderID: existingFolder.id
        )
        let importedProvider = TestFactories.makeProvider(kind: .openAI)
        let importedConversation = TestFactories.makeConversation(
            title: "Imported Chat",
            providerID: importedProvider.id,
            messages: [TestFactories.makeMessage(role: .user, text: "replace me", estimatedCost: 0.4)]
        )
        let existingSkill = makeSkill(
            id: UUID(uuidString: "44444444-4444-4444-4444-444444444444")!,
            updatedAt: Date(timeIntervalSince1970: 1500),
            knowledgeBase: SkillKnowledgeBase(
                provider: "openai",
                retrievalModel: "gpt-5.4-mini",
                vectorStoreId: "vs_existing_live",
                expiresAfterDays: 90,
                files: [
                    SkillKnowledgeBaseFile(
                        id: "file-existing-1",
                        name: "existing.pdf",
                        mimeType: "application/pdf",
                        sizeBytes: 4096,
                        ingestionMode: .nativeFile,
                        openAIFileId: "file-live-existing",
                        status: .ready,
                        createdAt: Date(),
                        updatedAt: Date()
                    )
                ],
                updatedAt: Date()
            )
        )
        let importedSkill = makeSkill(
            id: UUID(uuidString: "55555555-5555-5555-5555-555555555555")!,
            updatedAt: Date(timeIntervalSince1970: 2500),
            knowledgeBase: SkillKnowledgeBase(
                provider: "openai",
                retrievalModel: "gpt-5.4-mini",
                vectorStoreId: "",
                expiresAfterDays: 90,
                files: [
                    SkillKnowledgeBaseFile(
                        id: "file-imported-1",
                        name: "imported.pdf",
                        mimeType: "application/pdf",
                        sizeBytes: 2048,
                        ingestionMode: .nativeFile,
                        openAIFileId: nil,
                        status: .disabled,
                        createdAt: Date(),
                        updatedAt: Date()
                    )
                ],
                updatedAt: Date()
            )
        )
        let backupData = BackupData(
            providers: [BackupProvider(from: importedProvider)],
            conversations: [BackupConversation(from: importedConversation)],
            skills: [importedSkill],
            preferences: BackupPreferences(theme: "dark", language: "english"),
            lastUsedModelRef: LastUsedModelRef(providerID: importedProvider.id, modelID: "gpt-4o")
        )
        let backupFile = try makeBackupFile(data: backupData)
        let tempDir = AppSessionStore.userDir(for: uid).appendingPathComponent("temp-backups", isDirectory: true)

        DatabaseManager.shared.close()

        let appState = makeAppState(sessionUID: uid)
        defer { cleanupAppState(appState, removing: [uid]) }

        appState.providers = [existingProvider]
        appState.conversations = [existingConversation]
        appState.folders = [existingFolder]
        appState.preferences.theme = .dark
        appState.preferences.language = .english
        appState.lastUsedModelRef = LastUsedModelRef(providerID: existingProvider.id, modelID: "claude-3-7-sonnet")
        appState.skillManager.replaceUserSkills([existingSkill])

        let result = try await BackupService.executeImport(
            backupFile: backupFile,
            images: [:],
            mode: .replaceAll,
            password: nil,
            appState: appState
        )

        let tempBackupExists = FileManager.default.fileExists(atPath: tempDir.path)
        let backupURLs = (try? FileManager.default.contentsOfDirectory(
            at: tempDir,
            includingPropertiesForKeys: nil
        ).filter { $0.pathExtension == "oriveo" }) ?? []

        #expect(tempBackupExists == false)
        #expect(backupURLs.isEmpty)
        #expect(result.newSkills == 1)
        #expect(result.skillsRequiringKnowledgeReupload == 1)
        #expect(appState.skillManager.userSkills.map(\.id) == [importedSkill.id])
        #expect(appState.skillManager.userSkills.first?.knowledgeBase == nil)
    }

    @Test("replaceAll Restores Images To The Bound Partition Not The activeUID Partition")
    @MainActor
    func replaceAllRestoresImagesIntoBoundPartition() async throws {
        let previousUID = AppSessionStore.activeUID
        let activeUID = "backup-active-\(UUID().uuidString)"
        let targetUID = "backup-images-target-\(UUID().uuidString)"
        let provider = TestFactories.makeProvider(kind: .openAI)
        let localImageID = "img-\(UUID().uuidString)"
        let attachment = TestFactories.makeImageAttachment(
            fileName: "attachment.png",
            mimeType: "image/png",
            localImageID: localImageID
        )
        let message = TestFactories.makeMessage(
            role: .assistant,
            text: "image reply",
            attachments: [attachment]
        )
        let conversation = TestFactories.makeConversation(
            title: "Imported Image Chat",
            providerID: provider.id,
            messages: [message]
        )
        let backupData = BackupData(
            providers: [BackupProvider(from: provider)],
            conversations: [BackupConversation(from: conversation)],
            preferences: BackupPreferences(theme: "system", language: "english"),
            lastUsedModelRef: nil
        )
        let backupFile = try makeBackupFile(data: backupData)
        let imageData = Data("image-data".utf8)
        let thumbnailData = Data("thumb-data".utf8)
        let imageKey = "\(attachment.id).png"
        let thumbnailKey = "\(attachment.id).thumb.png"
        let targetImageURL = AppSessionStore.userDir(for: targetUID)
            .appendingPathComponent("Images", isDirectory: true)
            .appendingPathComponent("\(localImageID).img")
        let activeImageURL = AppSessionStore.userDir(for: activeUID)
            .appendingPathComponent("Images", isDirectory: true)
            .appendingPathComponent("\(localImageID).img")

        DatabaseManager.shared.close()
        AppSessionStore.switchToUser(activeUID)

        let appState = makeAppState(sessionUID: targetUID)
        defer {
            appState.flushConversationPersistQueue()
            DatabaseManager.shared.close()
            AppSessionStore.switchToUser(previousUID)
            try? FileManager.default.removeItem(at: AppSessionStore.userDir(for: activeUID))
            try? FileManager.default.removeItem(at: AppSessionStore.userDir(for: targetUID))
        }

        appState.providers = []
        appState.conversations = []
        appState.folders = []

        _ = try await BackupService.executeImport(
            backupFile: backupFile,
            images: [imageKey: imageData, thumbnailKey: thumbnailData],
            mode: .replaceAll,
            password: nil,
            appState: appState
        )

        #expect(FileManager.default.fileExists(atPath: targetImageURL.path))
        #expect(FileManager.default.fileExists(atPath: activeImageURL.path) == false)
    }

    @Test("replaceAll Aborts When The Authoritative Store Read Fails Instead Of Silently Falling Back")
    @MainActor
    func replaceAllFailsLoudWhenAuthoritativeStoreIsUnreadable() async throws {
        let uid = "backup-fail-loud-\(UUID().uuidString)"
        let provider = TestFactories.makeProvider(kind: .openAI)
        let conversation = TestFactories.makeConversation(
            title: "Imported Chat",
            providerID: provider.id,
            messages: [TestFactories.makeMessage(role: .user, text: "import payload", estimatedCost: 0.2)]
        )
        let backupData = BackupData(
            providers: [BackupProvider(from: provider)],
            conversations: [BackupConversation(from: conversation)],
            preferences: BackupPreferences(theme: "system", language: "english"),
            lastUsedModelRef: nil
        )
        let backupFile = try makeBackupFile(data: backupData)

        DatabaseManager.shared.close()

        let appState = makeAppState(sessionUID: uid)
        defer { cleanupAppState(appState, removing: [uid]) }

        DatabaseManager.shared.close()
        try Data("not-a-valid-sqlite".utf8).write(
            to: AppSessionStore.databasePath(for: uid),
            options: .atomic
        )

        await #expect(throws: (any Error).self) {
            _ = try await BackupService.executeImport(
                backupFile: backupFile,
                images: [:],
                mode: .replaceAll,
                password: nil,
                appState: appState
            )
        }
    }

    @Test("replaceAll Aborts And Rolls Back Image Directories If The Session Rebinds During Import")
    @MainActor
    func replaceAllAbortsAndRollsBackImagesWhenSessionChangesDuringImport() async throws {
        let targetUID = "backup-session-target-\(UUID().uuidString)"
        let reboundUID = "backup-session-rebound-\(UUID().uuidString)"
        let existingLocalImageID = "existing-\(UUID().uuidString)"
        let existingImageData = Data("existing-image".utf8)
        let targetImageURL = AppSessionStore.userDir(for: targetUID)
            .appendingPathComponent("Images", isDirectory: true)
            .appendingPathComponent("\(existingLocalImageID).img")

        let provider = TestFactories.makeProvider(kind: .openAI)
        let importedLocalImageID = "imported-\(UUID().uuidString)"
        let importedAttachment = TestFactories.makeImageAttachment(
            fileName: "imported.png",
            mimeType: "image/png",
            localImageID: importedLocalImageID
        )
        let importedMessage = TestFactories.makeMessage(
            role: .assistant,
            text: "imported image",
            attachments: [importedAttachment]
        )
        let importedConversation = TestFactories.makeConversation(
            title: "Imported Chat",
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

        DatabaseManager.shared.close()

        let appState = makeAppState(sessionUID: targetUID)
        defer {
            BackupService.testingHooks = .init()
            cleanupAppState(appState, removing: [targetUID, reboundUID])
        }

        var hookInvoked = false
        ImageStore.save(imageData: existingImageData, for: existingLocalImageID, partitionUID: targetUID)
        BackupService.testingHooks.beforeReplaceAllCommit = {
            await MainActor.run {
                hookInvoked = true
                appState.loadSession(boundTo: reboundUID)
            }
        }

        do {
            _ = try await BackupService.executeImport(
                backupFile: backupFile,
                images: [imageKey: Data("imported-image".utf8), thumbnailKey: Data("imported-thumb".utf8)],
                mode: .replaceAll,
                password: nil,
                appState: appState
            )
            Issue.record("replaceAll should abort because the session rebound")
        } catch let error as BackupError {
            guard case .sessionChangedDuringImport = error else {
                Issue.record("Unexpected error type: \(error)")
                return
            }
        }

        let restoredData = try Data(contentsOf: targetImageURL)
        #expect(restoredData == existingImageData)
        do {
            let store = try makeStore(uid: targetUID)
            #expect(try store.fetchConversationThread(id: importedConversation.id) == nil)
        }
        #expect(hookInvoked == true)
        #expect(appState.sessionPartitionUID == reboundUID)
    }

    @Test("replaceAll Restores The Old Image Directory If Commit Fails After Images Switched")
    @MainActor
    func replaceAllRollsBackImagesWhenCommitFailsAfterReplacement() async throws {
        let targetUID = "backup-rollback-\(UUID().uuidString)"
        let existingLocalImageID = "existing-\(UUID().uuidString)"
        let existingImageData = Data("existing-image".utf8)
        let targetImageURL = AppSessionStore.userDir(for: targetUID)
            .appendingPathComponent("Images", isDirectory: true)
            .appendingPathComponent("\(existingLocalImageID).img")

        let provider = TestFactories.makeProvider(kind: .openAI)
        let importedLocalImageID = "imported-\(UUID().uuidString)"
        let importedAttachment = TestFactories.makeImageAttachment(
            fileName: "rollback.png",
            mimeType: "image/png",
            localImageID: importedLocalImageID
        )
        let importedMessage = TestFactories.makeMessage(
            role: .assistant,
            text: "rollback image",
            attachments: [importedAttachment]
        )
        let importedConversation = TestFactories.makeConversation(
            title: "Rollback Chat",
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

        DatabaseManager.shared.close()

        let appState = makeAppState(sessionUID: targetUID)
        defer {
            BackupService.testingHooks = .init()
            cleanupAppState(appState, removing: [targetUID])
        }

        var hookInvoked = false
        ImageStore.save(imageData: existingImageData, for: existingLocalImageID, partitionUID: targetUID)
        BackupService.testingHooks.beforeReplaceAllCommit = {
            await MainActor.run {
                hookInvoked = true
            }
            throw ImportReplaceAllTestError.injectedCommitFailure
        }

        do {
            _ = try await BackupService.executeImport(
                backupFile: backupFile,
                images: [imageKey: Data("imported-image".utf8), thumbnailKey: Data("imported-thumb".utf8)],
                mode: .replaceAll,
                password: nil,
                appState: appState
            )
            Issue.record("replaceAll should inject failure before commit")
        } catch let error as ImportReplaceAllTestError {
            #expect(error == .injectedCommitFailure)
        }

        let restoredData = try Data(contentsOf: targetImageURL)
        #expect(hookInvoked == true)
        #expect(restoredData == existingImageData)
        do {
            let store = try makeStore(uid: targetUID)
            #expect(try store.fetchConversationThread(id: importedConversation.id) == nil)
        }
    }


    @MainActor
    private func restoreImageFromArchive(
        namedByAttachmentID: Bool,
        mimeType: String = "image/jpeg",
        entryExtension: String = "jpg"
    ) async throws {
        let targetUID = "backup-naming-\(UUID().uuidString)"
        let localImageID = "imported-\(UUID().uuidString)"
        let attachment = TestFactories.makeImageAttachment(
            fileName: "photo.jpg",
            mimeType: mimeType,
            localImageID: localImageID
        )
        let provider = TestFactories.makeProvider(kind: .openAI)
        let conversation = TestFactories.makeConversation(
            title: "Imported Chat",
            providerID: provider.id,
            messages: [
                TestFactories.makeMessage(role: .assistant, text: "image", attachments: [attachment])
            ]
        )
        let backupData = BackupData(
            providers: [BackupProvider(from: provider)],
            conversations: [BackupConversation(from: conversation)],
            preferences: BackupPreferences(theme: "system", language: "english"),
            lastUsedModelRef: nil
        )
        let backupFile = try makeBackupFile(data: backupData)

        let entryName = namedByAttachmentID ? "\(attachment.id)" : localImageID
        let imageData = Data("image-bytes".utf8)
        let thumbData = Data("thumb-bytes".utf8)

        DatabaseManager.shared.close()
        let appState = makeAppState(sessionUID: targetUID)
        defer { cleanupAppState(appState, removing: [targetUID]) }

        let result = try await BackupService.executeImport(
            backupFile: backupFile,
            images: [
                "\(entryName).\(entryExtension)": imageData,
                "\(entryName).thumb.\(entryExtension)": thumbData
            ],
            mode: .importNewOnly,
            password: nil,
            appState: appState
        )

        #expect(result.restoredImages == 1)
        #expect(result.skippedImages == 0)
        #expect(ImageStore.loadImageData(for: localImageID, partitionUID: targetUID) == imageData)
        #expect(ImageStore.loadThumbnailData(for: localImageID, partitionUID: targetUID) == thumbData)
    }

    @Test("Restore iOS/Android-Style Archive (attachment.id Names) Recovers Images")
    @MainActor
    func restoresImagesNamedByAttachmentID() async throws {
        try await restoreImageFromArchive(namedByAttachmentID: true)
    }

    @Test("Restore Legacy Web Archive (localImageID Names) Still Recovers Images")
    @MainActor
    func restoresImagesNamedByLocalImageID() async throws {
        try await restoreImageFromArchive(namedByAttachmentID: false)
    }

    @Test("Restore Android/Web Archive: PNG Entries Written As .jpg Still Recover Images")
    @MainActor
    func restoresPNGAttachmentStoredWithJPGExtension() async throws {
        try await restoreImageFromArchive(
            namedByAttachmentID: true,
            mimeType: "image/png",
            entryExtension: "jpg"
        )
    }

    @Test("Restore iOS Archive: PNG Entries Named .png By mimeType Still Recover Images")
    @MainActor
    func restoresPNGAttachmentStoredWithPNGExtension() async throws {
        try await restoreImageFromArchive(
            namedByAttachmentID: true,
            mimeType: "image/png",
            entryExtension: "png"
        )
    }


    @Test("To Provider Strips Catalog Models For Official Provider")
    func toProviderStripsCatalogModelsForOfficialProvider() throws {
        let staleCatalog = [
            AIModel(
                id: "qwen3.5-plus-2026-01-01",
                name: "Old Qwen Snapshot",
                capabilities: [.text],
                reasoningModeAvailable: false,
                isAvailable: true,
                isDefault: true,
                priceTier: ""
            ),
            AIModel(
                id: "qwen-manual-legacy",
                name: "Legacy manual",
                capabilities: [.text],
                reasoningModeAvailable: false,
                isAvailable: true,
                isDefault: false,
                priceTier: ""
            ),
        ]
        let backupProvider = BackupProvider(
            from: Provider(
                id: UUID(),
                kind: .qwen,
                status: .connected,
                models: [staleCatalog[0]],
                catalogModels: staleCatalog,
                apiKey: "sk-qwen-old",
                apiKeyPreview: "sk-...old"
            )
        )

        let restored = backupProvider.toProvider()

        #expect(restored.catalogModels.isEmpty)
    }

    @Test("To Provider Preserves Relay Catalog Models")
    func toProviderPreservesRelayCatalogModels() throws {
        let relayModels = [
            AIModel(
                id: "relay-manual-custom-model",
                name: "custom-model",
                capabilities: [.text],
                reasoningModeAvailable: false,
                isAvailable: true,
                isDefault: true,
                priceTier: ""
            )
        ]
        let backupProvider = BackupProvider(
            from: Provider(
                id: UUID(),
                kind: .relay,
                status: .connected,
                models: relayModels,
                catalogModels: relayModels,
                apiKey: "sk-relay",
                apiKeyPreview: "sk-...ay",
                baseURLText: "https://relay.example.com/v1",
                customName: "Relay"
            )
        )

        let restored = backupProvider.toProvider()

        #expect(restored.catalogModels.count == 1)
        #expect(restored.catalogModels.first?.id == "relay-manual-custom-model")
        if case .issue = restored.status {
            #expect(restored.lastCheckedAt == nil)
        } else {
            Issue.record("Restored Relay must remain unverified until explicit generation verification")
        }
    }

    @Test("importNewOnly Of A Legacy Qwen Backup Leaves Official Provider catalogModels Empty")
    @MainActor
    func importNewOnlyClearsCatalogModelsForOfficialProvider() async throws {
        let stale = AIModel(
            id: "qwen3.5-plus-2026-01-01",
            name: "Old Qwen",
            capabilities: [.text],
            reasoningModeAvailable: false,
            isAvailable: true,
            isDefault: true,
            priceTier: ""
        )
        let backupProvider = Provider(
            id: UUID(),
            kind: .qwen,
            status: .connected,
            models: [stale],
            catalogModels: [stale],
            apiKey: "sk-qwen",
            apiKeyPreview: "sk-...en"
        )
        let backupData = BackupData(
            providers: [BackupProvider(from: backupProvider)],
            conversations: [],
            preferences: BackupPreferences(theme: "system", language: "english"),
            lastUsedModelRef: nil
        )
        let backupFile = try makeBackupFile(data: backupData)

        let appState = makeAppState(seedDemoData: true)
        appState.providers = []
        appState.conversations = []
        appState.folders = []

        let result = try await BackupService.executeImport(
            backupFile: backupFile,
            images: [:],
            mode: .importNewOnly,
            password: nil,
            appState: appState
        )

        #expect(result.newProviders == 1)
        let restored = try #require(appState.providers.first(where: { $0.kind == .qwen }))
        #expect(restored.catalogModels.isEmpty)
    }

    @Test("replaceAll Of A Legacy Official Provider Backup Does Not Rehydrate catalogModels")
    @MainActor
    func replaceAllClearsCatalogModelsForOfficialProvider() async throws {
        let uid = "backup-replace-catalog-\(UUID().uuidString)"
        let stale = AIModel(
            id: "glm-4-plus-old",
            name: "Old GLM",
            capabilities: [.text],
            reasoningModeAvailable: false,
            isAvailable: true,
            isDefault: true,
            priceTier: ""
        )
        let backupProvider = Provider(
            id: UUID(),
            kind: .zhipu,
            status: .connected,
            models: [stale],
            catalogModels: [stale],
            apiKey: "sk-zhipu",
            apiKeyPreview: "sk-...pu"
        )
        let backupData = BackupData(
            providers: [BackupProvider(from: backupProvider)],
            conversations: [],
            preferences: BackupPreferences(theme: "system", language: "english"),
            lastUsedModelRef: nil
        )
        let backupFile = try makeBackupFile(data: backupData)

        DatabaseManager.shared.close()

        let appState = makeAppState(sessionUID: uid)
        defer { cleanupAppState(appState, removing: [uid]) }

        appState.providers = []
        appState.conversations = []
        appState.folders = []

        _ = try await BackupService.executeImport(
            backupFile: backupFile,
            images: [:],
            mode: .replaceAll,
            password: nil,
            appState: appState
        )

        let restored = try #require(appState.providers.first(where: { $0.kind == .zhipu }))
        #expect(restored.catalogModels.isEmpty)
    }

    @Test("merge Of A Legacy Backup Does Not Rehydrate Local Official Provider catalogModels")
    @MainActor
    func mergeClearsCatalogModelsForOfficialProvider() async throws {
        let localProvider = Provider(
            id: UUID(),
            kind: .qwen,
            status: .connected,
            models: [AIModel(
                id: "qwen3.6-plus",
                name: "Qwen 3.6 Plus",
                capabilities: [.text],
                reasoningModeAvailable: false,
                isAvailable: true,
                isDefault: true,
                priceTier: ""
            )],
            catalogModels: [],
            apiKey: "sk-local-qwen",
            apiKeyPreview: "sk-...al"
        )

        let staleSnapshot = AIModel(
            id: "qwen3.5-plus-2026-01-01",
            name: "Old Qwen Snapshot",
            capabilities: [.text],
            reasoningModeAvailable: false,
            isAvailable: true,
            isDefault: false,
            priceTier: ""
        )
        let backupProvider = Provider(
            id: localProvider.id,
            kind: .qwen,
            status: .connected,
            models: [staleSnapshot],
            catalogModels: [staleSnapshot],
            apiKey: "sk-backup-qwen",
            apiKeyPreview: "sk-...up"
        )
        let backupData = BackupData(
            providers: [BackupProvider(from: backupProvider)],
            conversations: [],
            preferences: BackupPreferences(theme: "system", language: "english"),
            lastUsedModelRef: nil
        )
        let backupFile = try makeBackupFile(data: backupData)

        let appState = makeAppState(seedDemoData: true)
        appState.providers = [localProvider]
        appState.conversations = []
        appState.folders = []

        _ = try await BackupService.executeImport(
            backupFile: backupFile,
            images: [:],
            mode: .merge,
            password: nil,
            appState: appState
        )

        let restored = try #require(appState.providers.first(where: { $0.kind == .qwen }))
        #expect(
            restored.catalogModels.isEmpty,
            "merge path must clear official provider catalogModels (BackupService.swift:591 call site)"
        )
    }

    @Test("merge Import Of Same-id Relay Provider Rehydrates Non-Credential Relay Contract Config")
    @MainActor
    func mergeImportRestoresRelayConfigIntoExistingRelayProvider() async throws {
        let uid = "backup-merge-relay-config-\(UUID().uuidString)"

        let providerID = UUID()
        var existingProvider = TestFactories.makeProvider(
            id: providerID,
            kind: .relay,
            models: [
                TestFactories.makeModel(
                    id: "gpt-4o-mini",
                    name: "GPT-4o mini",
                    capabilities: [.text],
                    isDefault: true
                )
            ],
            catalogModels: [],
            apiKey: "",
            apiKeyPreview: "",
            baseURLText: "https://old-relay.example.com/v1",
            customName: "Old Relay"
        )
        existingProvider.relayRequested = RelayRequestedConfig(
            transport: .openaiChatCompletions,
            authMode: .bearer,
            modelID: "gpt-4o-mini",
            stream: true
        )

        var importedProvider = TestFactories.makeProvider(
            id: providerID,
            kind: .relay,
            models: [
                TestFactories.makeModel(
                    id: "gpt-5.4",
                    name: "GPT-5.4",
                    capabilities: [.text, .reasoning],
                    reasoningModeAvailable: true,
                    isDefault: true
                )
            ],
            catalogModels: [
                TestFactories.makeModel(
                    id: "gpt-5.4",
                    name: "GPT-5.4",
                    capabilities: [.text, .reasoning],
                    reasoningModeAvailable: true,
                    isDefault: true
                )
            ],
            apiKey: "",
            apiKeyPreview: "",
            baseURLText: "https://new-relay.example.com/v1",
            customName: "Imported Relay"
        )
        importedProvider.relayRequested = RelayRequestedConfig(
            transport: .openaiResponses,
            authMode: .bearer,
            modelID: "gpt-5.4",
            reasoningEffort: .xhigh,
            serviceTier: "priority",
            stream: false,
            disableResponseStorage: true,
            headers: [RelayKeyValue(key: "x-test-header", value: "1")],
            queryParams: [RelayKeyValue(key: "trace", value: "true")]
        )

        let backupData = BackupData(
            providers: [BackupProvider(from: importedProvider)],
            conversations: [],
            preferences: BackupPreferences(theme: "system", language: "english"),
            lastUsedModelRef: nil
        )
        let backupFile = try makeBackupFile(data: backupData)

        let appState = makeAppState(sessionUID: uid)
        defer { cleanupAppState(appState, removing: [uid]) }

        appState.providers = [existingProvider]
        appState.conversations = []
        appState.folders = []

        let result = try await BackupService.executeImport(
            backupFile: backupFile,
            images: [:],
            mode: .merge,
            password: nil,
            appState: appState
        )

        let restored = try #require(appState.providers.first(where: { $0.id == providerID }))

        #expect(result.skippedProviders == 1)
        #expect(restored.customName == "Imported Relay")
        #expect(restored.baseURLText == "https://new-relay.example.com/v1")
        #expect(restored.relayRequested == importedProvider.relayRequested?.credentialFreePortableCopy())
        #expect(restored.relayRequested?.headers == nil)
        #expect(restored.relayRequested?.queryParams == nil)
        #expect(restored.models.contains(where: { $0.id == "gpt-5.4" }))
        #expect(restored.catalogModels.contains(where: { $0.id == "gpt-5.4" }))
    }


    @Test("Default Filename Format")
    func defaultFilenameFormat() {
        let filename = BackupService.defaultFilename()

        #expect(filename.hasPrefix("Oriveo-Backup-"))
        #expect(filename.hasSuffix(".oriveo"))
        let dateStr = String(filename.dropFirst("Oriveo-Backup-".count).dropLast(".oriveo".count))
        #expect(dateStr.count == 10)
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

    private func makeImportLimits(
        input: Int,
        entry: Int,
        total: Int,
        entries: Int
    ) -> BackupService.ImportLimits {
        BackupService.ImportLimits(
            maxInputBytes: input,
            archiveBudget: ArchiveExtractionBudget(
                maxEntryBytes: entry,
                maxTotalBytes: total,
                maxEntries: entries
            ),
            maxConversations: 100
        )
    }

    private func makeZip(entries: [(String, Data)]) throws -> Data {
        let archive = try #require(Archive(accessMode: .create))
        for (path, data) in entries {
            try archive.addEntry(
                with: path,
                type: .file,
                uncompressedSize: UInt32(data.count),
                provider: { position, size in data[position..<(position + size)] }
            )
        }
        return try #require(archive.data)
    }


    @Test("Api Key Encrypt Decrypt Roundtrip")
    func apiKeyEncryptDecryptRoundtrip() throws {
        let providerID = UUID()
        let keyEntries = [
            BackupKeyEntry(
                providerID: providerID,
                apiKey: "sk-real-api-key-12345",
                apiKeyPreview: "sk-...345"
            )
        ]
        let payload = BackupKeysPayload(keys: keyEntries)
        let payloadData = try JSONEncoder().encode(payload)
        let password = "my-backup-password"

        let encrypted = try BackupCrypto.encrypt(payloadData, password: password)
        let encBase64 = encrypted.base64EncodedString()

        guard let encData = Data(base64Encoded: encBase64) else {
            Issue.record("Base64 decode failed")
            return
        }
        let decrypted = try BackupCrypto.decrypt(encData, password: password)
        let restored = try JSONDecoder().decode(BackupKeysPayload.self, from: decrypted)

        #expect(restored.keys.count == 1)
        #expect(restored.keys[0].providerID == providerID)
        #expect(restored.keys[0].apiKey == "sk-real-api-key-12345")
        #expect(restored.keys[0].apiKeyPreview == "sk-...345")
    }

    @Test("Api Key Wrong Password Fails")
    func apiKeyWrongPasswordFails() throws {
        let payload = BackupKeysPayload(keys: [
            BackupKeyEntry(providerID: UUID(), apiKey: "sk-key", apiKeyPreview: "sk-...y")
        ])
        let payloadData = try JSONEncoder().encode(payload)
        let encrypted = try BackupCrypto.encrypt(payloadData, password: "correct-pw")

        #expect(throws: (any Error).self) {
            _ = try BackupCrypto.decrypt(encrypted, password: "wrong-pw")
        }
    }

    @Test("replaceAll Restoring A Relay Key Must Return Unverified Not Fake-Connected")
    @MainActor
    func replaceAllRestoredRelayKeyIsUnverified() async throws {
        var relay = TestFactories.makeProvider(
            kind: .relay,
            status: .connected,
            apiKey: "",
            baseURLText: "https://relay.example.com/v1"
        )
        relay.relayRequested = RelayRequestedConfig(
            transport: .openaiChatCompletions,
            authMode: .bearer,
            modelID: "relay-model"
        )
        let backupData = BackupData(
            providers: [BackupProvider(from: relay)],
            conversations: [],
            preferences: BackupPreferences(theme: "system", language: "english"),
            lastUsedModelRef: nil
        )
        let key = "sk-restored-relay-key"
        let password = "restore-password"
        let encrypted = try BackupCrypto.encrypt(
            JSONEncoder().encode(BackupKeysPayload(keys: [
                BackupKeyEntry(providerID: relay.id, apiKey: key, apiKeyPreview: "sk-r…-key"),
            ])),
            password: password
        )
        let dataJSON = try CanonicalJSON.encode(backupData)
        let backupFile = BackupFile(
            version: 1,
            createdAt: "2026-08-08T00:00:00Z",
            appVersion: "1.0",
            platform: "iOS",
            checksum: CanonicalJSON.checksum(of: dataJSON),
            containsKeys: true,
            data: backupData,
            attachmentChecksums: nil,
            encryptedKeys: encrypted.base64EncodedString()
        )
        let state = makeAppState()
        state.providers = []

        _ = try await BackupService.executeImport(
            backupFile: backupFile,
            images: [:],
            mode: .replaceAll,
            password: password,
            appState: state
        )

        let restored = try #require(state.provider(for: relay.id))
        #expect(restored.apiKey == key)
        #expect(restored.status == .issue("Connection has not been verified."))
        #expect(restored.lastCheckedAt == nil)
        #expect(restored.lastError == "Connection has not been verified.")
    }

    @Test("Restored Key Write Points Are Fail Closed")
    func restoredKeyWritePointsAreFailClosed() throws {
        let testFile = URL(fileURLWithPath: #filePath)
        let sourceURL = testFile
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Oriveo/Core/State/BackupService.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)
        #expect(source.components(separatedBy: "status = .issue(\"Connection has not been verified.\")").count - 1 == 4)
        #expect(source.components(separatedBy: "lastCheckedAt = nil").count - 1 >= 4)
    }
}
