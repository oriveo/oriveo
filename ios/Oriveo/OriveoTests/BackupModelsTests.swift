import Testing
import Foundation
@testable import Oriveo


@Suite("BackupModels")
struct BackupModelsTests {


    private func makeProvider(
        kind: ProviderKind = .openAI,
        apiKey: String = "sk-test-key",
        models: [AIModel] = [],
        catalogModels: [AIModel] = []
    ) -> Provider {
        Provider(
            id: UUID(),
            kind: kind,
            status: .connected,
            models: models,
            catalogModels: catalogModels,
            lastCheckedAt: Date(),
            apiKey: apiKey,
            apiKeyPreview: "sk-...key",
            lastError: "some error",
            baseURLText: kind.defaultBaseURLText,
            customName: kind == .relay ? "My Relay" : nil
        )
    }

    private func makeModel(id: String = "model-1", name: String = "GPT-4o") -> AIModel {
        AIModel(
            id: id,
            name: name,
            capabilities: [.text, .image],
            reasoningModeAvailable: false,
            isAvailable: true,
            isDefault: false,
            priceTier: "$$"
        )
    }

    private func makeMessage(
        text: String = "Hello",
        role: ChatRole = .user,
        createdAt: Date? = Date()
    ) -> ChatMessage {
        ChatMessage(
            id: UUID(),
            role: role,
            text: text,
            providerKind: .openAI,
            providerName: "OpenAI",
            modelName: "GPT-4o",
            state: .delivered,
            createdAt: createdAt
        )
    }

    private func makeConversation(
        title: String = "Test Chat",
        hasCustomTitle: Bool = true,
        messageCount: Int = 3,
        isDraft: Bool = false
    ) -> Conversation {
        let msgs = (0..<messageCount).map { i in
            makeMessage(
                text: "Message \(i)",
                role: i % 2 == 0 ? .user : .assistant,
                createdAt: Date(timeIntervalSinceNow: Double(i) * 60)
            )
        }
        var conv = Conversation(
            id: UUID(),
            title: title,
            providerID: UUID(),
            providerKind: .openAI,
            modelID: "gpt-4o",
            previewText: msgs.last?.text ?? "",
            isDraft: isDraft,
            messages: msgs
        )
        conv.hasCustomTitle = hasCustomTitle
        return conv
    }


    @Test("Provider Field Cleaning")
    func providerFieldCleaning() {
        let provider = makeProvider(apiKey: "sk-secret-key")
        let backup = BackupProvider(from: provider)

        #expect(backup.id == provider.id)
        #expect(backup.kind == provider.kind)
        #expect(backup.baseURLText == provider.baseURLText)
        #expect(backup.customName == provider.customName)
        #expect(backup.models.count == provider.models.count)
        #expect(backup.catalogModels.count == provider.catalogModels.count)

    }

    @Test("Provider To Provider Conversion")
    func providerToProviderConversion() {
        let provider = makeProvider(kind: .anthropic)
        let backup = BackupProvider(from: provider)
        let restored = backup.toProvider()

        #expect(restored.id == provider.id)
        #expect(restored.kind == .anthropic)
        #expect(restored.apiKey.isEmpty)
        #expect(restored.apiKeyPreview.isEmpty)
        if case .issue = restored.status {} else {
            Issue.record("Restored Provider status should be .issue")
        }
    }

    @Test("Relay Backup Provider Preserves Relay Config")
    func relayBackupProviderPreservesRelayConfig() {
        var provider = makeProvider(kind: .relay, models: [makeModel()], catalogModels: [makeModel()])
        provider.relayKind = .codexStyle
        provider.relayRequested = RelayRequestedConfig(
            transport: .openaiResponses,
            authMode: .bearer,
            modelID: "gpt-5.4",
            reasoningEffort: .xhigh,
            serviceTier: "fast",
            stream: true,
            disableResponseStorage: true,
            headers: [RelayKeyValue(key: "x-test", value: "1")],
            queryParams: [RelayKeyValue(key: "api-version", value: "2026-04-23")]
        )
        let backup = BackupProvider(from: provider)
        let restored = backup.toProvider()

        #expect(backup.relayKind == .codexStyle)
        #expect(backup.relayRequested?.transport == .openaiResponses)
        #expect(backup.relayRequested?.modelID == "gpt-5.4")
        #expect(backup.relayRequested?.headers == nil)
        #expect(backup.relayRequested?.queryParams == nil)
        #expect(restored.relayKind == .codexStyle)
        #expect(restored.relayRequested?.transport == .openaiResponses)
        #expect(restored.relayRequested?.modelID == "gpt-5.4")
        #expect(restored.relayRequested?.headers == nil)
        #expect(restored.relayRequested?.queryParams == nil)
    }


    @Test("Conversation Preserves Custom Title")
    func conversationPreservesCustomTitle() {
        let conv = makeConversation(title: "My Custom Title", hasCustomTitle: true)
        let backup = BackupConversation(from: conv)
        let restored = backup.toConversation()

        #expect(restored.hasCustomTitle == true)
        #expect(restored.title == "My Custom Title")
    }

    @Test("Conversation Clears Draft")
    func conversationClearsDraft() {
        var conv = makeConversation()
        conv.draftText = "Some draft text"

        let backup = BackupConversation(from: conv)
        let restored = backup.toConversation()

        #expect(restored.draftText.isEmpty)
        #expect(restored.isDraft == false)
    }

    @Test("Conversation Preserves Messages")
    func conversationPreservesMessages() {
        let conv = makeConversation(messageCount: 5)
        let backup = BackupConversation(from: conv)
        let restored = backup.toConversation()

        #expect(restored.messages.count == 5)
        #expect(restored.estimatedCost == conv.estimatedCost)
        #expect(restored.previewText == conv.previewText)
        #expect(restored.providerID == conv.providerID)
        #expect(restored.modelID == conv.modelID)
    }

    @Test("Backup Folder Roundtrip")
    func backupFolderRoundtrip() throws {
        let createdAt = Date(timeIntervalSince1970: 1_710_000_000)
        let updatedAt = Date(timeIntervalSince1970: 1_710_123_456)
        let folder = Folder(
            id: UUID(),
            name: "Archive",
            sortOrder: 3000,
            createdAt: createdAt,
            updatedAt: updatedAt
        )

        let backup = BackupFolder(from: folder)
        let encoded = try TestFactories.jsonEncoder.encode(backup)
        let decoded = try TestFactories.jsonDecoder.decode(BackupFolder.self, from: encoded)

        #expect(decoded.id == folder.id)
        #expect(decoded.name == "Archive")
        #expect(decoded.sortOrder == 3000)
        #expect(decoded.createdAt == createdAt)
        #expect(decoded.updatedAt == updatedAt)

        let restored = decoded.toFolder()
        #expect(restored.id == folder.id)
        #expect(restored.name == folder.name)
        #expect(restored.sortOrder == folder.sortOrder)
        #expect(restored.createdAt == createdAt)
        #expect(restored.updatedAt == updatedAt)
    }

    // MARK: - CanonicalJSON

    @Test("Canonical JSONDeterministic")
    func canonicalJSONDeterministic() throws {
        let prefs = BackupPreferences(theme: "system", language: "english")
        let data1 = try CanonicalJSON.encode(prefs)
        let data2 = try CanonicalJSON.encode(prefs)

        #expect(data1 == data2)
        #expect(CanonicalJSON.checksum(of: data1) == CanonicalJSON.checksum(of: data2))
    }

    @Test("Checksum Format")
    func checksumFormat() {
        let data = Data("test data".utf8)
        let checksum = CanonicalJSON.checksum(of: data)

        #expect(checksum.hasPrefix("sha256:"))
        let hex = String(checksum.dropFirst("sha256:".count))
        #expect(hex.count == 64)
        #expect(hex.allSatisfy { $0.isHexDigit })
    }

    @Test("Different Data Different Checksum")
    func differentDataDifferentChecksum() {
        let checksum1 = CanonicalJSON.checksum(of: Data("data1".utf8))
        let checksum2 = CanonicalJSON.checksum(of: Data("data2".utf8))

        #expect(checksum1 != checksum2)
    }

    // MARK: - BackupFile Codable

    @Test("BackupFile JSON roundtrip")
    func backupFileRoundtrip() throws {
        let backupData = BackupData(
            providers: [],
            conversations: [],
            preferences: BackupPreferences(theme: "dark", language: "english"),
            lastUsedModelRef: nil
        )
        let dataJSON = try CanonicalJSON.encode(backupData)

        let original = BackupFile(
            version: 1,
            createdAt: "2026-03-18T10:00:00Z",
            appVersion: "1.0.0",
            platform: "iOS",
            checksum: CanonicalJSON.checksum(of: dataJSON),
            containsKeys: false,
            data: backupData,
            attachmentChecksums: nil,
            encryptedKeys: nil
        )

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let encoded = try encoder.encode(original)

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(BackupFile.self, from: encoded)

        #expect(decoded.version == original.version)
        #expect(decoded.createdAt == original.createdAt)
        #expect(decoded.platform == original.platform)
        #expect(decoded.checksum == original.checksum)
        #expect(decoded.containsKeys == false)
        #expect(decoded.encryptedKeys == nil)
    }

    // MARK: - ImportMode

    @Test("Import Mode Count")
    func importModeCount() {
        #expect(ImportMode.allCases.count == 3)
    }

    @Test("Import Mode Default")
    func importModeDefault() {
        #expect(ImportMode.importNewOnly.isDefault == true)
        #expect(ImportMode.merge.isDefault == false)
        #expect(ImportMode.replaceAll.isDefault == false)
    }
}
