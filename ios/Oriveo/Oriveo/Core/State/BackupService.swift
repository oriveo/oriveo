import Foundation
import CryptoKit
import ZIPFoundation
import UniformTypeIdentifiers
import SwiftUI


struct BackupDocument: FileDocument {
    static var readableContentTypes: [UTType] = [.oriveoBackup, .json]

    var data: Data

    init(data: Data) {
        self.data = data
    }

    init(configuration: ReadConfiguration) throws {
        data = configuration.file.regularFileContents ?? Data()
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}

// MARK: - BackupService

enum BackupService {
    nonisolated static let currentVersion = 1

    nonisolated struct ImportLimits: Equatable, Sendable {
        let maxInputBytes: Int
        let archiveBudget: ArchiveExtractionBudget
        let maxConversations: Int

        static func forPhysicalMemory(_ physicalMemory: UInt64) -> ImportLimits {
            let mib = 1024 * 1024
            let memoryBytes = min(physicalMemory, UInt64(Int.max))
            let inputBytes = min(max(Int(memoryBytes / 24), 128 * mib), 256 * mib)
            let expandedBytes = min(max(Int(memoryBytes / 16), 192 * mib), 512 * mib)
            let entryBytes = min(max(Int(memoryBytes / 48), 64 * mib), 128 * mib)
            return ImportLimits(
                maxInputBytes: inputBytes,
                archiveBudget: ArchiveExtractionBudget(
                    maxEntryBytes: entryBytes,
                    maxTotalBytes: expandedBytes,
                    maxEntries: 65_536
                ),
                maxConversations: 250_000
            )
        }

        static var currentDevice: ImportLimits {
            forPhysicalMemory(ProcessInfo.processInfo.physicalMemory)
        }
    }

    private struct ImageStoreReplacement {
        let targetDirectory: URL
        let backupDirectory: URL?
    }

    private struct BackupImageEntry {
        let filename: String
        let data: Data
    }

    private struct PreparedBackupPayload {
        let backupFile: BackupFile
        let imageEntries: [BackupImageEntry]
    }

    #if DEBUG
    @MainActor
    struct TestingHooks {
        var beforeReplaceAllCommit: (() async throws -> Void)?
    }

    @MainActor
    static var testingHooks = TestingHooks()

    @MainActor
    private static func currentBeforeReplaceAllCommitHook() -> (() async throws -> Void)? {
        testingHooks.beforeReplaceAllCommit
    }
    #endif


    static func exportBackup(
        providers: [Provider],
        conversations: [Conversation],
        folders: [Folder] = [],
        skills: [Skill] = [],
        preferences: AppPreference,
        lastUsedModelRef: LastUsedModelRef?,
        includeKeys: Bool,
        password: String?,
        allowEmpty: Bool = false,
        imagePartitionUID: String? = nil,
        notes: [Note] = [],
        noteFolders: [NoteFolder] = []
    ) async throws -> Data {
        let payload = try await prepareBackupPayload(
            providers: providers,
            conversations: conversations,
            folders: folders,
            skills: skills,
            preferences: preferences,
            lastUsedModelRef: lastUsedModelRef,
            includeKeys: includeKeys,
            password: password,
            allowEmpty: allowEmpty,
            imagePartitionUID: imagePartitionUID,
            notes: notes,
            noteFolders: noteFolders
        )
        let backupFile = payload.backupFile
        let imageEntries = payload.imageEntries

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        let backupJSON = try encoder.encode(backupFile)

        return try await Task.detached {
            guard let archive = Archive(accessMode: .create) else {
                throw BackupError.zipCreationFailed
            }
            try archive.addEntry(
                with: "data.json",
                type: .file,
                uncompressedSize: UInt32(backupJSON.count),
                provider: { (position: Int, size: Int) in
                    backupJSON[position..<(position + size)]
                }
            )
            for entry in imageEntries {
                try archive.addEntry(
                    with: "attachments/\(entry.filename)",
                    type: .file,
                    uncompressedSize: UInt32(entry.data.count),
                    provider: { (position: Int, size: Int) in
                        entry.data[position..<(position + size)]
                    }
                )
            }
            guard let zipData = archive.data else {
                throw BackupError.zipCreationFailed
            }
            return zipData
        }.value
    }

    nonisolated private struct BackupChunkManifest: Codable {
        struct Chunk: Codable {
            let filename: String
            let count: Int
        }
        let version: Int
        let totalConversations: Int
        let conversationChunks: [Chunk]
        let headerFilename: String
    }

    nonisolated private static let backupManifestFilename = "manifest.json"
    private static let backupHeaderFilename = "data.json"

    private static func prepareBackupPayload(
        providers: [Provider],
        conversations: [Conversation],
        folders: [Folder] = [],
        skills: [Skill] = [],
        preferences: AppPreference,
        lastUsedModelRef: LastUsedModelRef?,
        includeKeys: Bool,
        password: String?,
        allowEmpty: Bool,
        imagePartitionUID: String?,
        notes: [Note] = [],
        noteFolders: [NoteFolder] = []
    ) async throws -> PreparedBackupPayload {
        let backupProviders = providers.map { BackupProvider(from: $0) }

        let backupConversations = conversations
            .filter { !$0.isDraft || !$0.messages.isEmpty }
            .map { BackupConversation(from: $0) }
        let backupSkills = skills.map(sanitizeSkillForBackup)
        let backupNotes = notes.map { BackupNote(from: $0) }
        let backupNoteFolders = noteFolders.map { BackupNoteFolder(from: $0) }

        guard allowEmpty || !backupProviders.isEmpty || !backupConversations.isEmpty
            || !backupSkills.isEmpty || !backupNotes.isEmpty else {
            throw BackupError.noDataToExport
        }

        let backupPrefs = BackupPreferences(
            theme: preferences.theme.rawValue,
            language: preferences.language.rawValue,
            memoryText: preferences.memoryText.isEmpty ? nil : preferences.memoryText,
            memoryAntiForgetEnabled: preferences.memoryAntiForgetEnabled ? true : nil,
            memoryAntiForgetText: preferences.memoryAntiForgetText.isEmpty ? nil : preferences.memoryAntiForgetText,
            memoryUpdatedAt: preferences.memoryUpdatedAt.map { ISO8601DateFormatter().string(from: $0) }
        )

        let backupFolders = folders.isEmpty ? nil : folders.map { BackupFolder(from: $0) }
        let backupData = BackupData(
            providers: backupProviders,
            conversations: backupConversations,
            skills: backupSkills.isEmpty ? nil : backupSkills,
            preferences: backupPrefs,
            lastUsedModelRef: lastUsedModelRef,
            folders: backupFolders,
            notes: backupNotes.isEmpty ? nil : backupNotes,
            noteFolders: backupNoteFolders.isEmpty ? nil : backupNoteFolders
        )

        let dataJSON = try CanonicalJSON.encode(backupData)
        let checksum = CanonicalJSON.checksum(of: dataJSON)

        var attachmentChecksums: [String: String] = [:]
        var imageEntries: [BackupImageEntry] = []

        for conv in backupConversations {
            for msg in conv.messages {
                guard let atts = msg.attachments else { continue }
                for att in atts where att.kind == .image {
                    guard let lid = att.localImageID else { continue }
                    let ext = fileExtension(for: att.mimeType)

                    if let imgData = ImageStore.loadImageData(for: lid, partitionUID: imagePartitionUID) {
                        let filename = "\(att.id).\(ext)"
                        imageEntries.append(BackupImageEntry(filename: filename, data: imgData))
                        attachmentChecksums[filename] = CanonicalJSON.checksum(of: imgData)
                    }

                    if let thumbData = ImageStore.loadThumbnailData(for: lid, partitionUID: imagePartitionUID) {
                        let thumbFilename = "\(att.id).thumb.\(ext)"
                        imageEntries.append(BackupImageEntry(filename: thumbFilename, data: thumbData))
                        attachmentChecksums[thumbFilename] = CanonicalJSON.checksum(of: thumbData)
                    }
                }
            }
        }

        var encryptedKeys: String?
        if includeKeys, let password, !password.isEmpty {
            let keyEntries = providers.compactMap { provider -> BackupKeyEntry? in
                guard !provider.apiKey.isEmpty else { return nil }
                return BackupKeyEntry(
                    providerID: provider.id,
                    apiKey: provider.apiKey,
                    apiKeyPreview: provider.apiKeyPreview
                )
            }
            if !keyEntries.isEmpty {
                let payload = BackupKeysPayload(keys: keyEntries)
                let payloadData = try JSONEncoder().encode(payload)
                let encrypted = try BackupCrypto.encrypt(payloadData, password: password)
                encryptedKeys = encrypted.base64EncodedString()
            }
        }

        let appVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
        let backupFile = BackupFile(
            version: currentVersion,
            createdAt: ISO8601DateFormatter().string(from: Date()),
            appVersion: appVersion,
            platform: "iOS",
            checksum: checksum,
            containsKeys: encryptedKeys != nil,
            data: backupData,
            attachmentChecksums: attachmentChecksums.isEmpty ? nil : attachmentChecksums,
            encryptedKeys: encryptedKeys
        )
        return PreparedBackupPayload(backupFile: backupFile, imageEntries: imageEntries)
    }


    nonisolated static func loadImportData(at url: URL, limits: ImportLimits = .currentDevice) throws -> Data {
        do {
            return try BoundedFileReader.data(at: url, maxBytes: limits.maxInputBytes)
        } catch BoundedFileReadError.tooLarge {
            throw BackupError.resourceLimitExceeded
        } catch BoundedFileReadError.notRegularFile {
            throw BackupError.unrecognizedFormat
        }
    }

    nonisolated static func parseBackup(
        from data: Data,
        limits: ImportLimits = .currentDevice
    ) throws -> (backupFile: BackupFile, images: [String: Data]) {
        guard data.count <= limits.maxInputBytes else {
            throw BackupError.resourceLimitExceeded
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let rawValue = try container.decode(String.self)
            if let date = ISO8601Parser.date(from: rawValue) {
                return date
            }
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Expected date string to be ISO8601-formatted."
            )
        }

        if data.count >= 2, data[0] == 0x50, data[1] == 0x4B {
            guard let archive = Archive(data: data, accessMode: .read) else {
                throw BackupError.zipExtractionFailed
            }
            do {
                try BoundedArchiveReader.validateDeclaredEntries(in: archive, budget: limits.archiveBudget)
            } catch is BoundedArchiveError {
                throw BackupError.resourceLimitExceeded
            }
            var reader = BoundedArchiveReader(budget: limits.archiveBudget)

            if let manifestEntry = archive[backupManifestFilename] {
                let manifestData = try boundedData(from: archive, entry: manifestEntry, reader: &reader)
                let manifest = try decoder.decode(BackupChunkManifest.self, from: manifestData)
                guard manifest.totalConversations >= 0,
                      manifest.totalConversations <= limits.maxConversations,
                      manifest.conversationChunks.count <= limits.archiveBudget.maxEntries,
                      manifest.conversationChunks.allSatisfy({ $0.count >= 0 }) else {
                    throw BackupError.resourceLimitExceeded
                }

                guard let headerEntry = archive[manifest.headerFilename] else {
                    throw BackupError.jsonParseFailed
                }
                let headerData = try boundedData(from: archive, entry: headerEntry, reader: &reader)
                let headerBackupFile = try decoder.decode(BackupFile.self, from: headerData)

                var allConvs: [BackupConversation] = []
                var declaredConversationCount = 0
                for chunkDesc in manifest.conversationChunks {
                    let (nextCount, overflow) = declaredConversationCount.addingReportingOverflow(chunkDesc.count)
                    guard !overflow, nextCount <= manifest.totalConversations else {
                        throw BackupError.jsonParseFailed
                    }
                    declaredConversationCount = nextCount
                    guard let chunkEntry = archive[chunkDesc.filename] else {
                        throw BackupError.jsonParseFailed
                    }
                    let chunkData = try boundedData(from: archive, entry: chunkEntry, reader: &reader)
                    let chunk = try decoder.decode([BackupConversation].self, from: chunkData)
                    guard chunk.count == chunkDesc.count else {
                        throw BackupError.jsonParseFailed
                    }
                    allConvs.append(contentsOf: chunk)
                }
                guard declaredConversationCount == manifest.totalConversations,
                      allConvs.count == manifest.totalConversations else {
                    throw BackupError.jsonParseFailed
                }

                let fullData = BackupData(
                    providers: headerBackupFile.data.providers,
                    conversations: allConvs,
                    skills: headerBackupFile.data.skills,
                    preferences: headerBackupFile.data.preferences,
                    lastUsedModelRef: headerBackupFile.data.lastUsedModelRef,
                    folders: headerBackupFile.data.folders,
                    notes: headerBackupFile.data.notes,
                    noteFolders: headerBackupFile.data.noteFolders
                )
                let fullBackupFile = BackupFile(
                    version: headerBackupFile.version,
                    createdAt: headerBackupFile.createdAt,
                    appVersion: headerBackupFile.appVersion,
                    platform: headerBackupFile.platform,
                    checksum: headerBackupFile.checksum,
                    containsKeys: headerBackupFile.containsKeys,
                    data: fullData,
                    attachmentChecksums: headerBackupFile.attachmentChecksums,
                    encryptedKeys: headerBackupFile.encryptedKeys
                )

                var images: [String: Data] = [:]
                for entry in archive {
                    guard entry.path.hasPrefix("attachments/"),
                          entry.type == .file else { continue }
                    let filename = String(entry.path.dropFirst("attachments/".count))
                    guard !filename.isEmpty else { continue }
                    let fileData = try boundedData(from: archive, entry: entry, reader: &reader)
                    images[filename] = fileData
                }
                return (fullBackupFile, images)
            }

            guard let dataEntry = archive["data.json"] else {
                throw BackupError.jsonParseFailed
            }
            let jsonData = try boundedData(from: archive, entry: dataEntry, reader: &reader)
            let backupFile = try decoder.decode(BackupFile.self, from: jsonData)

            var images: [String: Data] = [:]
            for entry in archive {
                guard entry.path.hasPrefix("attachments/"),
                      entry.type == .file else { continue }
                let filename = String(entry.path.dropFirst("attachments/".count))
                guard !filename.isEmpty else { continue }
                let fileData = try boundedData(from: archive, entry: entry, reader: &reader)
                images[filename] = fileData
            }

            return (backupFile, images)

        } else if data.count >= 1, data[0] == 0x7B {
            guard data.count <= limits.archiveBudget.maxEntryBytes else {
                throw BackupError.resourceLimitExceeded
            }
            let backupFile = try decoder.decode(BackupFile.self, from: data)
            guard backupFile.data.conversations.count <= limits.maxConversations else {
                throw BackupError.resourceLimitExceeded
            }
            return (backupFile, [:])

        } else {
            throw BackupError.unrecognizedFormat
        }
    }

    nonisolated private static func boundedData(
        from archive: Archive,
        entry: Entry,
        reader: inout BoundedArchiveReader
    ) throws -> Data {
        do {
            return try reader.data(from: archive, entry: entry)
        } catch is BoundedArchiveError {
            throw BackupError.resourceLimitExceeded
        }
    }


    nonisolated static func previewImport(
        backupFile: BackupFile,
        localConversations: [Conversation],
        localProviders: [Provider]
    ) -> ImportPreview {
        let localConvIDs = Set(localConversations.map(\.id))
        let localProviderIDs = Set(localProviders.map(\.id))

        let existingConvs = backupFile.data.conversations.filter { localConvIDs.contains($0.id) }.count
        let existingProvs = backupFile.data.providers.filter { localProviderIDs.contains($0.id) }.count

        let totalMessages = backupFile.data.conversations.reduce(0) { $0 + $1.messages.count }
        let totalImages = backupFile.data.conversations.reduce(0) { total, conv in
            total + conv.messages.reduce(0) { $0 + ($1.attachments?.filter { $0.kind == .image }.count ?? 0) }
        }

        return ImportPreview(
            backupCreatedAt: backupFile.createdAt,
            backupPlatform: backupFile.platform,
            backupAppVersion: backupFile.appVersion,
            containsKeys: backupFile.containsKeys,
            totalConversations: backupFile.data.conversations.count,
            existingConversations: existingConvs,
            totalProviders: backupFile.data.providers.count,
            existingProviders: existingProvs,
            totalMessages: totalMessages,
            totalImages: totalImages
        )
    }


    nonisolated static func validateChecksum(_ backupFile: BackupFile) -> Bool {
        guard let dataJSON = try? CanonicalJSON.encode(backupFile.data) else { return false }
        let computed = CanonicalJSON.checksum(of: dataJSON)
        return computed == backupFile.checksum
    }

    nonisolated static func validateAttachmentChecksums(
        expected: [String: String],
        images: [String: Data]
    ) -> [String] {
        var corrupted: [String] = []
        for (filename, expectedHash) in expected {
            guard let data = images[filename] else {
                corrupted.append(filename)
                continue
            }
            let computed = CanonicalJSON.checksum(of: data)
            if computed != expectedHash {
                corrupted.append(filename)
            }
        }
        return corrupted
    }


    static func executeImport(
        backupFile: BackupFile,
        images: [String: Data],
        mode: ImportMode,
        password: String?,
        appState: AppState
    ) async throws -> ImportResult {
        var result = ImportResult()
        let partitionUID = await MainActor.run { appState.sessionPartitionUID }

        var restoredKeys: [UUID: (apiKey: String, preview: String)] = [:]
        if backupFile.containsKeys, let encStr = backupFile.encryptedKeys, let password, !password.isEmpty {
            guard let encData = Data(base64Encoded: encStr) else {
                throw BackupError.invalidEncryptedData
            }
            let decrypted = try BackupCrypto.decrypt(encData, password: password)
            let payload = try JSONDecoder().decode(BackupKeysPayload.self, from: decrypted)
            for entry in payload.keys {
                restoredKeys[entry.providerID] = (entry.apiKey, entry.apiKeyPreview)
            }
        }

        switch mode {
        case .importNewOnly:
            result = await importNewOnly(
                backupFile: backupFile,
                images: images,
                restoredKeys: restoredKeys,
                partitionUID: partitionUID,
                appState: appState
            )
        case .merge:
            result = await importMerge(
                backupFile: backupFile,
                images: images,
                restoredKeys: restoredKeys,
                partitionUID: partitionUID,
                appState: appState
            )
        case .replaceAll:
            result = try await importReplaceAll(
                backupFile: backupFile,
                images: images,
                restoredKeys: restoredKeys,
                partitionUID: partitionUID,
                appState: appState
            )
        }


        if let prefs = backupFile.data.preferences {
            if let theme = ThemeOption(rawValue: prefs.theme) {
                await MainActor.run {
                    appState.preferences.theme = theme
                    appState.preferences.themeSetByUser = true
                }
                result.restoredPreferences = true
            }
            if AppLanguagePreferencePolicy.shouldApplySyncedLanguage(
                storedPreference: AppPreferencesStore.savedLanguage
            ), let language = LanguageOption(rawValue: prefs.language) {
                await MainActor.run { appState.preferences.language = language }
                result.restoredPreferences = true
            }
            if let memoryText = prefs.memoryText {
                await MainActor.run {
                    appState.preferences.memoryText = String(memoryText.prefix(2000))
                }
                result.restoredPreferences = true
            }
            if let antiForgetEnabled = prefs.memoryAntiForgetEnabled {
                await MainActor.run {
                    appState.preferences.memoryAntiForgetEnabled = antiForgetEnabled
                }
            }
            if let antiForgetText = prefs.memoryAntiForgetText {
                await MainActor.run {
                    appState.preferences.memoryAntiForgetText = String(antiForgetText.prefix(200))
                }
            }
            if let updatedAtStr = prefs.memoryUpdatedAt {
                let parsed = ISO8601Parser.date(from: updatedAtStr)
                await MainActor.run {
                    appState.preferences.memoryUpdatedAt = parsed
                }
            }
            if result.restoredPreferences {
                await MainActor.run {
                    AppPreferencesStore.save(appState.preferences)
                }
            }
        }

        if let ref = backupFile.data.lastUsedModelRef {
            await MainActor.run { appState.lastUsedModelRef = ref }
            result.restoredLastUsedModel = true
        }

        await reconcileOfficialProvidersAfterImport(appState: appState)

        return result
    }

    @MainActor
    private static func reconcileOfficialProvidersAfterImport(appState: AppState) async {
        let officialIndexes = appState.providers.enumerated().compactMap { index, provider -> Int? in
            provider.kind == .relay ? nil : index
        }
        guard !officialIndexes.isEmpty else { return }

        await MetadataClient.shared.forceRefresh()

        for index in officialIndexes {
            var provider = appState.providers[index]
            let resolvedCatalog = ProviderCatalogResolver.resolve(provider: provider)
            let catalogModels = resolvedCatalog.catalog.map(\.model)
            let legacyCatalogModels = provider.catalogModels

            provider.catalogModels = []
            if !catalogModels.isEmpty {
                provider.models = ModelResolver.makeEnabledModels(
                    from: provider.models,
                    catalogModels: catalogModels,
                    providerKind: provider.kind,
                    legacyCatalogModels: legacyCatalogModels,
                    repairLegacyAutoEnabledAll: true
                )
            }
            provider = ModelResolver.synchronizeDefaultSelection(
                in: provider,
                preferredModelID: provider.defaultModel?.id
            )

            let postResolveCatalog = ProviderCatalogResolver.resolve(provider: provider)
            provider.models = ManualRetainedPruningPolicy.apply(
                provider: provider,
                resolvedCatalog: postResolveCatalog
            )
            ManualRetainedPruningPolicy.recordActivation(
                provider: provider,
                count: postResolveCatalog.enabledModels.filter(\.isManual).count
            )

            provider.cachedAvailableModelCount = ProviderCatalogResolver.resolve(provider: provider).availableModelCount
            appState.providers[index] = provider
        }
    }


    private static func importNewOnly(
        backupFile: BackupFile,
        images: [String: Data],
        restoredKeys: [UUID: (apiKey: String, preview: String)],
        partitionUID: String,
        appState: AppState
    ) async -> ImportResult {
        var result = ImportResult()
        var localConvIDs = Set(appState.conversations.map(\.id))
        let localProviderIDs = Set(appState.providers.map(\.id))
        let originalUserSkills = await MainActor.run { appState.skillManager.userSkills }
        var nextUserSkills = originalUserSkills
        var localSkillIDs = Set(nextUserSkills.map(\.id))

        for bp in backupFile.data.providers {
            if localProviderIDs.contains(bp.id) {
                result.skippedProviders += 1
                continue
            }
            var newProvider = bp.toProvider()
            if let keys = restoredKeys[bp.id] {
                newProvider.apiKey = keys.apiKey
                newProvider.apiKeyPreview = keys.preview
                newProvider.status = .issue("Connection has not been verified.")
                newProvider.lastCheckedAt = nil
                newProvider.lastError = "Connection has not been verified."
                result.restoredKeys += 1
            }
            newProvider.cachedAvailableModelCount = ProviderCatalogResolver.resolve(provider: newProvider).availableModelCount
            await MainActor.run {
                appState.providers.append(newProvider)
            }
            result.newProviders += 1
        }

        for bc in backupFile.data.conversations {
            if localConvIDs.contains(bc.id) {
                result.skippedConversations += 1
                continue
            }
            let conv = bc.toConversation()
            restoreImages(for: conv, from: images, partitionUID: partitionUID, result: &result)
            await MainActor.run {
                appState.upsertConversationProjection(conv)
            }
            localConvIDs.insert(conv.id)
            result.newConversations += 1
        }

        if let backupFolders = backupFile.data.folders {
            let localFolderIDs = Set(appState.folders.map(\.id))
            for bf in backupFolders {
                if !localFolderIDs.contains(bf.id) {
                    await MainActor.run { appState.folders.append(bf.toFolder()) }
                }
            }
        }

        if backupFile.data.notes != nil || backupFile.data.noteFolders != nil {
            let importedNotes = (backupFile.data.notes ?? []).map { $0.toNote() }
            let importedNoteFolders = (backupFile.data.noteFolders ?? []).map { $0.toNoteFolder() }
            await MainActor.run {
                appState.noteManager.importNotes(importedNotes, folders: importedNoteFolders, mode: .importNewOnly)
            }
        }

        for backupSkill in backupFile.data.skills ?? [] {
            if localSkillIDs.contains(backupSkill.id) {
                result.skippedSkills += 1
                continue
            }

            let restoredSkill = restoreSkillFromBackup(backupSkill)
            nextUserSkills.append(restoredSkill.skill)
            localSkillIDs.insert(restoredSkill.skill.id)
            result.newSkills += 1
            if restoredSkill.requiresKnowledgeReupload {
                result.skillsRequiringKnowledgeReupload += 1
            }
        }

        if nextUserSkills != originalUserSkills {
            await MainActor.run {
                appState.skillManager.replaceUserSkills(nextUserSkills)
            }
        }

        return result
    }


    private static func importMerge(
        backupFile: BackupFile,
        images: [String: Data],
        restoredKeys: [UUID: (apiKey: String, preview: String)],
        partitionUID: String,
        appState: AppState
    ) async -> ImportResult {
        var result = ImportResult()
        let originalUserSkills = await MainActor.run { appState.skillManager.userSkills }
        var nextUserSkills = originalUserSkills

        for bp in backupFile.data.providers {
            let matchIndex = appState.providers.firstIndex(where: { $0.id == bp.id })

            if let idx = matchIndex {
                await MainActor.run {
                    var existing = appState.providers[idx]
                    let existingModelIDs = Set(existing.models.map(\.id))
                    for model in bp.models where !existingModelIDs.contains(model.id) {
                        existing.models.append(model)
                    }
                    if bp.kind == .relay {
                        let existingCatalogIDs = Set(existing.catalogModels.map(\.id))
                        for model in bp.catalogModels where !existingCatalogIDs.contains(model.id) {
                            existing.catalogModels.append(model)
                        }
                    }
                    if let customName = bp.customName {
                        existing.customName = customName
                    }
                    if bp.kind == .relay {
                        existing.baseURLText = bp.baseURLText
                        existing.relayRequested = bp.relayRequested
                    }
                    if existing.apiKey.isEmpty, let keys = restoredKeys[bp.id] {
                        existing.apiKey = keys.apiKey
                        existing.apiKeyPreview = keys.preview
                        existing.status = .issue("Connection has not been verified.")
                        existing.lastCheckedAt = nil
                        existing.lastError = "Connection has not been verified."
                        result.restoredKeys += 1
                    }
                    existing.cachedAvailableModelCount = ProviderCatalogResolver.resolve(provider: existing).availableModelCount
                    appState.providers[idx] = existing
                }
                result.skippedProviders += 1
            } else {
                var newProvider = bp.toProvider()
                if let keys = restoredKeys[bp.id] {
                    newProvider.apiKey = keys.apiKey
                    newProvider.apiKeyPreview = keys.preview
                    newProvider.status = .issue("Connection has not been verified.")
                    newProvider.lastCheckedAt = nil
                    newProvider.lastError = "Connection has not been verified."
                    result.restoredKeys += 1
                }
                newProvider.cachedAvailableModelCount = ProviderCatalogResolver.resolve(provider: newProvider).availableModelCount
                await MainActor.run {
                    appState.providers.append(newProvider)
                }
                result.newProviders += 1
            }
        }

        for bc in backupFile.data.conversations {
            if let localIdx = appState.conversations.firstIndex(where: { $0.id == bc.id }) {
                let local = appState.conversations[localIdx]
                let localMessages = (try? appState.conversationRuntimeBridge.fetchConversationProjection(
                    id: bc.id,
                    uid: partitionUID
                ))?.messages ?? local.messages
                let merged = mergeMessages(local: localMessages, backup: bc.messages)
                let mergedUpdatedAt = max(local.updatedAt, bc.updatedAt)

                restoreImages(for: bc.toConversation(), from: images, partitionUID: partitionUID, result: &result)

                await MainActor.run {
                    var updated = appState.conversations[localIdx]
                    updated.messages = merged
                    updated.updatedAt = mergedUpdatedAt
                    if bc.updatedAt > local.updatedAt {
                        updated.title = bc.title
                        updated.hasCustomTitle = bc.hasCustomTitle
                        updated.previewText = bc.previewText
                        updated.estimatedCost = bc.estimatedCost
                        updated.folderID = bc.folderID
                    }
                    appState.upsertConversationProjection(updated)
                }
                result.mergedConversations += 1
            } else {
                let conv = bc.toConversation()
                restoreImages(for: conv, from: images, partitionUID: partitionUID, result: &result)
                await MainActor.run {
                    appState.upsertConversationProjection(conv)
                }
                result.newConversations += 1
            }
        }

        if let backupFolders = backupFile.data.folders {
            await MainActor.run {
                for bf in backupFolders {
                    if let localIdx = appState.folders.firstIndex(where: { $0.id == bf.id }) {
                        let local = appState.folders[localIdx]
                        if bf.updatedAt > local.updatedAt {
                            appState.folders[localIdx] = bf.toFolder()
                        }
                    } else {
                        appState.folders.append(bf.toFolder())
                    }
                }
            }
        }

        if backupFile.data.notes != nil || backupFile.data.noteFolders != nil {
            let importedNotes = (backupFile.data.notes ?? []).map { $0.toNote() }
            let importedNoteFolders = (backupFile.data.noteFolders ?? []).map { $0.toNoteFolder() }
            await MainActor.run {
                appState.noteManager.importNotes(importedNotes, folders: importedNoteFolders, mode: .merge)
            }
        }

        for backupSkill in backupFile.data.skills ?? [] {
            if let localIndex = nextUserSkills.firstIndex(where: { $0.id == backupSkill.id }) {
                let localSkill = nextUserSkills[localIndex]
                if backupSkill.updatedAt >= localSkill.updatedAt {
                    let restoredSkill = restoreSkillFromBackup(backupSkill)
                    nextUserSkills[localIndex] = restoredSkill.skill
                    result.mergedSkills += 1
                    if restoredSkill.requiresKnowledgeReupload {
                        result.skillsRequiringKnowledgeReupload += 1
                    }
                } else {
                    result.skippedSkills += 1
                }
            } else {
                let restoredSkill = restoreSkillFromBackup(backupSkill)
                nextUserSkills.append(restoredSkill.skill)
                result.newSkills += 1
                if restoredSkill.requiresKnowledgeReupload {
                    result.skillsRequiringKnowledgeReupload += 1
                }
            }
        }

        if nextUserSkills != originalUserSkills {
            await MainActor.run {
                appState.skillManager.replaceUserSkills(nextUserSkills)
            }
        }

        return result
    }


    private static func importReplaceAll(
        backupFile: BackupFile,
        images: [String: Data],
        restoredKeys: [UUID: (apiKey: String, preview: String)],
        partitionUID: String,
        appState: AppState
    ) async throws -> ImportResult {
        var result = ImportResult()

        try await MainActor.run {
            try ensureSessionStillBound(appState, partitionUID: partitionUID)
        }

        var importedProviders: [Provider] = []
        importedProviders.reserveCapacity(backupFile.data.providers.count)
        for bp in backupFile.data.providers {
            var newProvider = bp.toProvider()
            if let keys = restoredKeys[bp.id] {
                newProvider.apiKey = keys.apiKey
                newProvider.apiKeyPreview = keys.preview
                newProvider.status = .issue("Connection has not been verified.")
                newProvider.lastCheckedAt = nil
                newProvider.lastError = "Connection has not been verified."
                result.restoredKeys += 1
            }
            importedProviders.append(newProvider)
            result.newProviders += 1
        }

        var importedConversations: [Conversation] = []
        importedConversations.reserveCapacity(backupFile.data.conversations.count)
        for bc in backupFile.data.conversations {
            let conv = bc.toConversation()
            importedConversations.append(conv)
            result.newConversations += 1
        }

        let importedFolders = backupFile.data.folders?.map { $0.toFolder() } ?? []
        let importedNotes = backupFile.data.notes?.map { $0.toNote() } ?? []
        let importedNoteFolders = backupFile.data.noteFolders?.map { $0.toNoteFolder() } ?? []
        var importedSkills: [Skill] = []
        importedSkills.reserveCapacity(backupFile.data.skills?.count ?? 0)
        for backupSkill in backupFile.data.skills ?? [] {
            let restoredSkill = restoreSkillFromBackup(backupSkill)
            importedSkills.append(restoredSkill.skill)
            result.newSkills += 1
            if restoredSkill.requiresKnowledgeReupload {
                result.skillsRequiringKnowledgeReupload += 1
            }
        }
        let stagedImagesDirectory = try stageImportedImages(
            for: importedConversations,
            from: images,
            partitionUID: partitionUID,
            result: &result
        )
        let replacement = try beginImageStoreReplacement(
            with: stagedImagesDirectory,
            partitionUID: partitionUID
        )

        do {
            #if DEBUG
            if let hook = await currentBeforeReplaceAllCommitHook() {
                try await hook()
            }
            #endif

            try await MainActor.run {
                try ensureSessionStillBound(appState, partitionUID: partitionUID)
                try appState.replaceConversationProjectionOrThrow(
                    importedConversations,
                    persistedUID: partitionUID
                )
                try commitReplaceAllProviders(
                    importedProviders,
                    partitionUID: partitionUID,
                    appState: appState
                )
                appState.folders = importedFolders
                appState.noteManager.importNotes(importedNotes, folders: importedNoteFolders, mode: .replaceAll)
                appState.skillManager.replaceUserSkills(importedSkills)
                appState.persistSessionNow(for: partitionUID)
            }
        } catch {
            rollbackImageStoreReplacement(replacement)
            throw error
        }

        finalizeImageStoreReplacement(replacement)

        return result
    }

    @MainActor
    static func commitReplaceAllProviders(
        _ providers: [Provider],
        partitionUID: String,
        appState: AppState
    ) throws {
        try ensureSessionStillBound(appState, partitionUID: partitionUID)
        appState.providers = providers
    }


    static func mergeMessages(local: [ChatMessage], backup: [ChatMessage]) -> [ChatMessage] {
        func ensureCreatedAt(_ messages: [ChatMessage]) -> [ChatMessage] {
            messages.enumerated().map { i, msg in
                guard msg.createdAt == nil else { return msg }
                var fixed = msg
                fixed.createdAt = Date(timeIntervalSince1970: TimeInterval(i) * 0.001)
                return fixed
            }
        }

        return ChatMessage.mergeByIdAndCreatedAt(ensureCreatedAt(local), ensureCreatedAt(backup))
    }


    private static func attachmentEntryData(
        from images: [String: Data],
        attachment: Attachment,
        localImageID: String,
        suffix: String
    ) -> Data? {
        var extensions = [fileExtension(for: attachment.mimeType)]
        if !extensions.contains("jpg") { extensions.append("jpg") }

        for name in ["\(attachment.id)", localImageID] {
            for ext in extensions {
                if let data = images["\(name)\(suffix).\(ext)"] { return data }
            }
        }
        return nil
    }

    private static func restoreImages(
        for conversation: Conversation,
        from images: [String: Data],
        partitionUID: String,
        result: inout ImportResult
    ) {
        for msg in conversation.messages {
            guard let atts = msg.attachments else { continue }
            for att in atts where att.kind == .image {
                guard let lid = att.localImageID else { continue }

                if let imgData = attachmentEntryData(from: images, attachment: att, localImageID: lid, suffix: "") {
                    ImageStore.save(imageData: imgData, for: lid, partitionUID: partitionUID)
                    result.restoredImages += 1
                } else {
                    result.skippedImages += 1
                }

                if let thumbData = attachmentEntryData(from: images, attachment: att, localImageID: lid, suffix: ".thumb") {
                    ImageStore.saveThumbnail(imageData: thumbData, for: lid, partitionUID: partitionUID)
                }
            }
        }
    }


    private static func stageImportedImages(
        for conversations: [Conversation],
        from images: [String: Data],
        partitionUID: String,
        result: inout ImportResult
    ) throws -> URL {
        let stagedDirectory = AppSessionStore.userDir(for: partitionUID)
            .appendingPathComponent("Images-import-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: stagedDirectory, withIntermediateDirectories: true)

        do {
            for conversation in conversations {
                try stageImages(
                    for: conversation,
                    from: images,
                    into: stagedDirectory,
                    result: &result
                )
            }
            return stagedDirectory
        } catch {
            try? FileManager.default.removeItem(at: stagedDirectory)
            throw error
        }
    }

    private static func stageImages(
        for conversation: Conversation,
        from images: [String: Data],
        into directory: URL,
        result: inout ImportResult
    ) throws {
        for msg in conversation.messages {
            guard let atts = msg.attachments else { continue }
            for att in atts where att.kind == .image {
                guard let lid = att.localImageID else { continue }

                if let imgData = attachmentEntryData(from: images, attachment: att, localImageID: lid, suffix: "") {
                    try imgData.write(
                        to: directory.appendingPathComponent("\(lid).img"),
                        options: .atomic
                    )
                    result.restoredImages += 1
                } else {
                    result.skippedImages += 1
                }

                if let thumbData = attachmentEntryData(from: images, attachment: att, localImageID: lid, suffix: ".thumb") {
                    try thumbData.write(
                        to: directory.appendingPathComponent("\(lid).thumb"),
                        options: .atomic
                    )
                }
            }
        }
    }

    @MainActor
    private static func ensureSessionStillBound(_ appState: AppState, partitionUID: String) throws {
        guard appState.sessionPartitionUID == partitionUID else {
            throw BackupError.sessionChangedDuringImport
        }
    }

    private static func beginImageStoreReplacement(
        with stagedDirectory: URL,
        partitionUID: String
    ) throws -> ImageStoreReplacement {
        let fileManager = FileManager.default
        let targetDirectory = AppSessionStore.imagesDir(for: partitionUID)
        let backupDirectory = AppSessionStore.userDir(for: partitionUID)
            .appendingPathComponent("Images-pre-replace-backup-\(UUID().uuidString)", isDirectory: true)
        var replacement = ImageStoreReplacement(targetDirectory: targetDirectory, backupDirectory: nil)

        if fileManager.fileExists(atPath: targetDirectory.path) {
            try fileManager.moveItem(at: targetDirectory, to: backupDirectory)
            replacement = ImageStoreReplacement(targetDirectory: targetDirectory, backupDirectory: backupDirectory)
        }

        do {
            try fileManager.moveItem(at: stagedDirectory, to: targetDirectory)
            ImageStore.clearAllCaches()
            return replacement
        } catch {
            if fileManager.fileExists(atPath: targetDirectory.path) {
                try? fileManager.removeItem(at: targetDirectory)
            }
            if let backupDirectory = replacement.backupDirectory,
               fileManager.fileExists(atPath: backupDirectory.path) {
                try? fileManager.moveItem(at: backupDirectory, to: targetDirectory)
            }
            if fileManager.fileExists(atPath: stagedDirectory.path) {
                try? fileManager.removeItem(at: stagedDirectory)
            }
            throw error
        }
    }

    private static func finalizeImageStoreReplacement(_ replacement: ImageStoreReplacement) {
        if let backupDirectory = replacement.backupDirectory {
            try? FileManager.default.removeItem(at: backupDirectory)
        }
        ImageStore.clearAllCaches()
    }

    private static func rollbackImageStoreReplacement(_ replacement: ImageStoreReplacement) {
        let fileManager = FileManager.default
        if fileManager.fileExists(atPath: replacement.targetDirectory.path) {
            try? fileManager.removeItem(at: replacement.targetDirectory)
        }
        if let backupDirectory = replacement.backupDirectory,
           fileManager.fileExists(atPath: backupDirectory.path) {
            try? fileManager.moveItem(at: backupDirectory, to: replacement.targetDirectory)
        }
        ImageStore.clearAllCaches()
    }


    private static func fileExtension(for mimeType: String) -> String {
        let parts = mimeType.split(separator: "/")
        guard parts.count == 2 else { return "jpg" }
        let subtype = String(parts[1]).lowercased()
        switch subtype {
        case "png": return "png"
        case "gif": return "gif"
        case "webp": return "webp"
        case "heic", "heif": return "heic"
        default: return "jpg"
        }
    }

    private static func sanitizeSkillForBackup(_ skill: Skill) -> Skill {
        var sanitized = skill
        sanitized.knowledgeBase = sanitizeKnowledgeBaseForBackup(skill.knowledgeBase)
        return sanitized
    }

    private static func sanitizeKnowledgeBaseForBackup(_ knowledgeBase: SkillKnowledgeBase?) -> SkillKnowledgeBase? {
        guard let knowledgeBase else { return nil }

        return SkillKnowledgeBase(
            provider: knowledgeBase.provider,
            retrievalModel: knowledgeBase.retrievalModel,
            vectorStoreId: "",
            expiresAfterDays: knowledgeBase.expiresAfterDays,
            files: knowledgeBase.files.map { file in
                SkillKnowledgeBaseFile(
                    id: file.id,
                    name: file.name,
                    mimeType: file.mimeType,
                    sizeBytes: file.sizeBytes,
                    ingestionMode: file.ingestionMode,
                    extractedFrom: file.extractedFrom,
                    openAIFileId: nil,
                    status: .disabled,
                    errorCode: file.errorCode,
                    createdAt: file.createdAt,
                    updatedAt: file.updatedAt
                )
            },
            updatedAt: knowledgeBase.updatedAt
        )
    }

    private static func restoreSkillFromBackup(_ skill: Skill) -> (skill: Skill, requiresKnowledgeReupload: Bool) {
        let requiresKnowledgeReupload = !(skill.knowledgeBase?.files.isEmpty ?? true)
        var restored = skill
        restored.source = .user
        restored.knowledgeBase = nil
        return (restored, requiresKnowledgeReupload)
    }


    static func defaultFilename() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        return "Oriveo-Backup-\(formatter.string(from: Date())).oriveo"
    }
}


extension BackupProvider {
    func toProvider() -> Provider {
        let catalogForRestore: [AIModel]
        switch kind {
        case .relay:
            catalogForRestore = catalogModels
        default:
            catalogForRestore = []
        }

        return Provider(
            id: id,
            kind: kind,
            status: .issue(L10n.tr("Needs setup")),
            models: models,
            catalogModels: catalogForRestore,

            lastCheckedAt: nil,
            apiKey: "",
            apiKeyPreview: "",
            lastError: nil,
            baseURLText: baseURLText,
            customName: customName,
            relayRequested: relayRequested,
            relayKind: relayKind
        )
    }
}
