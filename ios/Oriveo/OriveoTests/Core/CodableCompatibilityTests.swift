import Testing
import Foundation
@testable import Oriveo


@Suite("Codable Compatibility Tests")
struct CodableCompatibilityTests {

    private let encoder = TestFactories.jsonEncoder
    private let decoder = TestFactories.jsonDecoder


    private func loadFixture(_ name: String) throws -> Data {
        let bundle = Bundle(for: BundleLocator.self)
        guard let url = bundle.url(forResource: name, withExtension: "json", subdirectory: nil)
                ?? bundle.url(forResource: name, withExtension: "json") else {
            let testDir = URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()  // Core/
                .deletingLastPathComponent()  // OriveoTests/
                .appendingPathComponent("Fixtures")
                .appendingPathComponent("\(name).json")
            return try Data(contentsOf: testDir)
        }
        return try Data(contentsOf: url)
    }


    @Suite("Provider Codable")
    struct ProviderCodableTests {
        private let encoder = TestFactories.jsonEncoder
        private let decoder = TestFactories.jsonDecoder

        @Test("Provider Full Roundtrip")
        func providerFullRoundtrip() throws {
            let original = TestFactories.makeProvider(
                id: UUID(uuidString: "550E8400-E29B-41D4-A716-446655440001")!,
                kind: .openAI,
                models: [
                    TestFactories.makeModel(id: "gpt-4o", name: "GPT-4o", capabilities: [.text, .image, .reasoning], isDefault: true),
                    TestFactories.makeModel(id: "gpt-4o-mini", name: "GPT-4o Mini", capabilities: [.text])
                ],
                apiKey: "sk-test-key-abc123",
                apiKeyPreview: "sk-...c123",
                baseURLText: "api.openai.com/v1",
                updatedAt: Date(timeIntervalSince1970: 1710500000)
            )

            let data = try encoder.encode(original)
            let encoded = String(data: data, encoding: .utf8) ?? ""
            #expect(!encoded.contains("sk-test-key-abc123"))
            let object = try #require(
                try JSONSerialization.jsonObject(with: data) as? [String: Any]
            )
            #expect(object["apiKey"] == nil)

            let decoded = try decoder.decode(Provider.self, from: data)

            #expect(decoded.id == original.id)
            #expect(decoded.kind == original.kind)
            #expect(decoded.apiKey == "")
            #expect(decoded.apiKeyPreview == original.apiKeyPreview)
            #expect(decoded.baseURLText == original.baseURLText)
            #expect(decoded.models.count == original.models.count)
            #expect(decoded.models[0].id == "gpt-4o")
            #expect(decoded.models[0].capabilities.contains(.reasoning))
            #expect(decoded.models[1].id == "gpt-4o-mini")
            #expect(abs(decoded.updatedAt.timeIntervalSince(original.updatedAt)) < 1.0)
        }

        @Test("Provider Legacy APIKey Decodes For Migration")
        func providerLegacyAPIKeyDecodesForMigration() throws {
            let json = """
            {
                "id": "550E8400-E29B-41D4-A716-446655440009",
                "kind": "openAI",
                "status": {"kind": "connected"},
                "models": [],
                "catalogModels": [],
                "apiKey": "sk-legacy-secret",
                "apiKeyPreview": "sk-...ret"
            }
            """
            let provider = try decoder.decode(Provider.self, from: Data(json.utf8))

            #expect(provider.apiKey == "sk-legacy-secret")
            #expect(provider.apiKeyPreview == "sk-...ret")
        }

        @Test("Provider Legacy No Updated At")
        func providerLegacyNoUpdatedAt() throws {
            let json = """
            {
                "id": "550E8400-E29B-41D4-A716-446655440002",
                "kind": "anthropic",
                "status": {"kind": "connected"},
                "models": [],
                "catalogModels": [],
                "apiKey": "sk-ant-test",
                "apiKeyPreview": "sk-ant-...st"
            }
            """
            let data = json.data(using: .utf8)!
            let provider = try decoder.decode(Provider.self, from: data)

            #expect(provider.updatedAt == .distantPast)
            #expect(provider.kind == .anthropic)
        }

        @Test("Provider Optional Fields Missing")
        func providerOptionalFieldsMissing() throws {
            let json = """
            {
                "id": "550E8400-E29B-41D4-A716-446655440005",
                "kind": "openRouter",
                "status": {"kind": "syncing"},
                "models": [],
                "apiKey": "sk-or-test",
                "apiKeyPreview": "sk-or-...st"
            }
            """
            let data = json.data(using: .utf8)!
            let provider = try decoder.decode(Provider.self, from: data)

            #expect(provider.catalogModels.isEmpty)
            #expect(provider.lastCheckedAt == nil)
            #expect(provider.lastError == nil)
            #expect(provider.baseURLText == nil)
            #expect(provider.customName == nil)
        }

        @Test("Relay Provider Custom Name")
        func relayProviderCustomName() throws {
            let original = TestFactories.makeProvider(kind: .relay, customName: "My Corporate Relay")

            let data = try encoder.encode(original)
            let decoded = try decoder.decode(Provider.self, from: data)

            #expect(decoded.kind == .relay)
            #expect(decoded.customName == "My Corporate Relay")
        }
    }


    @Suite("Conversation Codable")
    struct ConversationCodableTests {
        private let encoder = TestFactories.jsonEncoder
        private let decoder = TestFactories.jsonDecoder

        @Test("Conversation Full Roundtrip")
        func conversationFullRoundtrip() throws {
            let msg1 = TestFactories.makeMessage(
                id: UUID(uuidString: "770E8400-E29B-41D4-A716-446655440001")!,
                role: .user,
                text: "How do I use async/await?",
                createdAt: Date(timeIntervalSince1970: 1710500000)
            )
            let msg2 = TestFactories.makeMessage(
                id: UUID(uuidString: "770E8400-E29B-41D4-A716-446655440002")!,
                role: .assistant,
                text: "Here's how to use async/await...",
                estimatedCost: 0.0015,
                createdAt: Date(timeIntervalSince1970: 1710500005)
            )

            let original = TestFactories.makeConversation(
                id: UUID(uuidString: "660E8400-E29B-41D4-A716-446655440001")!,
                title: "Swift Help",
                hasCustomTitle: true,
                modelID: "gpt-4o",
                estimatedCost: 0.0025,
                messages: [msg1, msg2],
                createdAt: Date(timeIntervalSince1970: 1710500000),
                updatedAt: Date(timeIntervalSince1970: 1710500005)
            )

            let data = try encoder.encode(original)
            let decoded = try decoder.decode(Conversation.self, from: data)

            #expect(decoded.id == original.id)
            #expect(decoded.title == "Swift Help")
            #expect(decoded.hasCustomTitle == true)
            #expect(decoded.modelID == "gpt-4o")
            #expect(decoded.messages.count == 2)
            #expect(decoded.messages[0].role == .user)
            #expect(decoded.messages[1].role == .assistant)
            #expect(abs(decoded.estimatedCost - 0.0025) < 0.0001)
            #expect(decoded.draftText == "")
        }

        @Test("Conversation Legacy Cost Text")
        func conversationLegacyCostText() throws {
            let json = """
            {
                "id": "660E8400-E29B-41D4-A716-446655440002",
                "title": "Old format",
                "providerID": "550E8400-E29B-41D4-A716-446655440001",
                "providerKind": "openAI",
                "modelID": "gpt-4o",
                "useMemory": true,
                "previewText": "test",
                "estimatedCostText": "~$0.05",
                "isDraft": false,
                "messages": []
            }
            """
            let data = json.data(using: .utf8)!
            let conv = try decoder.decode(Conversation.self, from: data)

            #expect(abs(conv.estimatedCost - 0.05) < 0.001, "estimatedCostText '~$0.05' → 0.05")
        }

        @Test("Conversation No Cost Fields")
        func conversationNoCostFields() throws {
            let json = """
            {
                "id": "660E8400-E29B-41D4-A716-446655440003",
                "title": "No cost",
                "providerID": "550E8400-E29B-41D4-A716-446655440001",
                "providerKind": "openAI",
                "modelID": "gpt-4o",
                "useMemory": true,
                "previewText": "",
                "isDraft": false,
                "messages": []
            }
            """
            let data = json.data(using: .utf8)!
            let conv = try decoder.decode(Conversation.self, from: data)

            #expect(conv.estimatedCost == 0)
        }

        @Test("Conversation Default Has Custom Title")
        func conversationDefaultHasCustomTitle() throws {
            let json = """
            {
                "id": "660E8400-E29B-41D4-A716-446655440004",
                "title": "Auto title",
                "providerID": "550E8400-E29B-41D4-A716-446655440001",
                "providerKind": "openAI",
                "modelID": "gpt-4o",
                "useMemory": true,
                "previewText": "",
                "isDraft": false,
                "messages": []
            }
            """
            let data = json.data(using: .utf8)!
            let conv = try decoder.decode(Conversation.self, from: data)

            #expect(conv.hasCustomTitle == false)
        }

        @Test("Conversation Default Draft Text")
        func conversationDefaultDraftText() throws {
            let json = """
            {
                "id": "660E8400-E29B-41D4-A716-446655440005",
                "title": "No draft",
                "providerID": "550E8400-E29B-41D4-A716-446655440001",
                "providerKind": "openAI",
                "modelID": "gpt-4o",
                "useMemory": true,
                "previewText": "",
                "isDraft": false,
                "messages": []
            }
            """
            let data = json.data(using: .utf8)!
            let conv = try decoder.decode(Conversation.self, from: data)

            #expect(conv.draftText == "")
        }

    }


    @Suite("ChatMessage Codable")
    struct ChatMessageCodableTests {
        private let encoder = TestFactories.jsonEncoder
        private let decoder = TestFactories.jsonDecoder

        @Test("Message Full Roundtrip")
        func messageFullRoundtrip() throws {
            let original = TestFactories.makeMessage(
                role: .assistant,
                text: "Hello there!",
                providerKind: .anthropic,
                modelName: "Claude 4",
                estimatedCost: 0.002,
                state: .delivered,
                createdAt: Date(timeIntervalSince1970: 1710500000)
            )

            let data = try encoder.encode(original)
            let decoded = try decoder.decode(ChatMessage.self, from: data)

            #expect(decoded.id == original.id)
            #expect(decoded.role == .assistant)
            #expect(decoded.text == "Hello there!")
            #expect(decoded.providerKind == .anthropic)
            #expect(decoded.providerName == "Anthropic")
            #expect(decoded.modelName == "Claude 4")
            #expect(abs(decoded.estimatedCost - 0.002) < 0.0001)
            #expect(decoded.state == .delivered)
        }

        @Test("Message Legacy Cost Text")
        func messageLegacyCostText() throws {
            let json = """
            {
                "id": "770E8400-E29B-41D4-A716-446655440010",
                "role": "user",
                "text": "test",
                "providerKind": "openAI",
                "providerName": "OpenAI",
                "modelName": "GPT-4o",
                "estimatedCostText": "~$0.0012",
                "state": "delivered"
            }
            """
            let data = json.data(using: .utf8)!
            let msg = try decoder.decode(ChatMessage.self, from: data)

            #expect(abs(msg.estimatedCost - 0.0012) < 0.0001)
        }

        @Test("Message With Attachments Roundtrip")
        func messageWithAttachmentsRoundtrip() throws {
            let imgAtt = TestFactories.makeImageAttachment(
                thumbnailBase64: "thumb-data-base64"
            )
            let fileAtt = TestFactories.makeFileAttachment(
                fileName: "data.csv",
                mimeType: "text/csv",
                base64Data: "Y3N2LGRhdGE="
            )

            let original = TestFactories.makeMessage(
                text: "Check these files",
                attachments: [imgAtt, fileAtt]
            )

            let data = try encoder.encode(original)
            let decoded = try decoder.decode(ChatMessage.self, from: data)

            #expect(decoded.attachments?.count == 2)

            let decodedImg = decoded.attachments?.first(where: { $0.kind == .image })
            #expect(decodedImg?.fileName == "photo.jpg")
            #expect(decodedImg?.thumbnailBase64 == "thumb-data-base64")
            #expect(decodedImg?.base64Data == nil)

            let decodedFile = decoded.attachments?.first(where: { $0.kind == .file })
            #expect(decodedFile?.fileName == "data.csv")
            #expect(decodedFile?.mimeType == "text/csv")
            #expect(decodedFile?.base64Data == "Y3N2LGRhdGE=")
        }

        @Test("Message No Attachments")
        func messageNoAttachments() throws {
            let original = TestFactories.makeMessage(attachments: nil)

            let data = try encoder.encode(original)
            let decoded = try decoder.decode(ChatMessage.self, from: data)

            #expect(decoded.attachments == nil)
        }

        @Test("Message Legacy No Created At")
        func messageLegacyNoCreatedAt() throws {
            let json = """
            {
                "id": "770E8400-E29B-41D4-A716-446655440011",
                "role": "assistant",
                "text": "old message",
                "providerKind": "openAI",
                "providerName": "OpenAI",
                "modelName": "GPT-4",
                "estimatedCost": 0.001,
                "state": "delivered"
            }
            """
            let data = json.data(using: .utf8)!
            let msg = try decoder.decode(ChatMessage.self, from: data)

            #expect(msg.createdAt == nil)
        }

        @Test("Message All States Roundtrip")
        func messageAllStatesRoundtrip() throws {
            let states: [ChatMessageState] = [.delivered, .generating, .interrupted, .failed]
            for state in states {
                let msg = TestFactories.makeMessage(state: state)
                let data = try encoder.encode(msg)
                let decoded = try decoder.decode(ChatMessage.self, from: data)
                #expect(decoded.state == state)
            }
        }
    }


    @Suite("Attachment Codable")
    struct AttachmentCodableTests {
        private let encoder = TestFactories.jsonEncoder
        private let decoder = TestFactories.jsonDecoder

        @Test("Image Attachment Skips Base64 Data")
        func imageAttachmentSkipsBase64Data() throws {
            let att = Attachment(
                id: UUID(),
                kind: .image,
                fileName: "photo.jpg",
                mimeType: "image/jpeg",
                base64Data: "should-be-skipped",
                localImageID: "img-001",
                thumbnailBase64: "thumb-data"
            )

            let data = try encoder.encode(att)
            let json = String(data: data, encoding: .utf8)!

            #expect(!json.contains("should-be-skipped"))

            let decoded = try decoder.decode(Attachment.self, from: data)
            #expect(decoded.kind == .image)
            #expect(decoded.base64Data == nil)
            #expect(decoded.localImageID == "img-001")
            #expect(decoded.thumbnailBase64 == "thumb-data")
        }

        @Test("File Attachment Preserves Base64 Data")
        func fileAttachmentPreservesBase64Data() throws {
            let att = Attachment(
                id: UUID(),
                kind: .file,
                fileName: "doc.pdf",
                mimeType: "application/pdf",
                base64Data: "JVBERi0xLjQ="
            )

            let data = try encoder.encode(att)
            let decoded = try decoder.decode(Attachment.self, from: data)

            #expect(decoded.kind == .file)
            #expect(decoded.base64Data == "JVBERi0xLjQ=")
            #expect(decoded.fileName == "doc.pdf")
        }

        @Test("Attachment Minimal Fields")
        func attachmentMinimalFields() throws {
            let att = Attachment(
                id: UUID(),
                kind: .file,
                fileName: "minimal.txt",
                mimeType: "text/plain"
            )

            let data = try encoder.encode(att)
            let decoded = try decoder.decode(Attachment.self, from: data)

            #expect(decoded.fileName == "minimal.txt")
            #expect(decoded.base64Data == nil)
            #expect(decoded.localImageID == nil)
            #expect(decoded.thumbnailBase64 == nil)
        }
    }


    @Test("Provider Kind Raw Value Stability")
    func providerKindRawValueStability() {
        #expect(ProviderKind.openAI.rawValue == "openAI")
        #expect(ProviderKind.anthropic.rawValue == "anthropic")
        #expect(ProviderKind.gemini.rawValue == "gemini")
        #expect(ProviderKind.deepseek.rawValue == "deepseek")
        #expect(ProviderKind.grok.rawValue == "grok")
        #expect(ProviderKind.openRouter.rawValue == "openRouter")
        #expect(ProviderKind.groq.rawValue == "groq")
        #expect(ProviderKind.together.rawValue == "together")
        #expect(ProviderKind.fireworks.rawValue == "fireworks")
        #expect(ProviderKind.miniMax.rawValue == "miniMax")
        #expect(ProviderKind.zhipu.rawValue == "zhipu")
        #expect(ProviderKind.qwen.rawValue == "qwen")
        #expect(ProviderKind.mistral.rawValue == "mistral")
        #expect(ProviderKind.siliconFlow.rawValue == "siliconFlow")
        #expect(ProviderKind.moonshot.rawValue == "moonshot")
        #expect(ProviderKind.relay.rawValue == "relay")
    }

    @Test("Provider Kind All Cases Count")
    func providerKindAllCasesCount() {
        #expect(ProviderKind.allCases.count == 16)
    }


    @Test("Model Capability Raw Value Stability")
    func modelCapabilityRawValueStability() {
        #expect(ModelCapability.reasoning.rawValue == "reasoning")
        #expect(ModelCapability.text.rawValue == "text")
        #expect(ModelCapability.image.rawValue == "image")
        #expect(ModelCapability.file.rawValue == "file")
        #expect(ModelCapability.web.rawValue == "web")
        #expect(ModelCapability.imageGen.rawValue == "imageGeneration")
    }

    // MARK: - Capability forward compatibility

    @Test("Model Capability Forward Compatibility")
    func modelCapabilityForwardCompatibility() throws {
        let json = #"""
        {
          "id": "future-model",
          "name": "Future Model",
          "capabilities": ["text", "audio", "image", "video-gen-xyz"],
          "reasoningModeAvailable": false,
          "isAvailable": true,
          "isDefault": false,
          "priceTier": "premium"
        }
        """#.data(using: .utf8)!

        let decoded = try TestFactories.jsonDecoder.decode(AIModel.self, from: json)

        #expect(decoded.capabilities == [.text, .image])
        #expect(decoded.id == "future-model")
    }

    @Test("Badge Order Forward Compatibility")
    func badgeOrderForwardCompatibility() throws {
        let json = #"""
        {
          "id": "future-model",
          "name": "Future Model",
          "capabilities": ["text"],
          "reasoningModeAvailable": false,
          "isAvailable": true,
          "isDefault": false,
          "priceTier": "premium",
          "badgeOrder": ["audio", "text", "video-gen-xyz", "reasoning"]
        }
        """#.data(using: .utf8)!

        let decoded = try TestFactories.jsonDecoder.decode(AIModel.self, from: json)

        #expect(decoded.badgeOrder == [.text, .reasoning])
    }


    @Suite("ProviderConnectionState Codable")
    struct ConnectionStateCodableTests {
        private let encoder = TestFactories.jsonEncoder
        private let decoder = TestFactories.jsonDecoder

        @Test("Connected Roundtrip")
        func connectedRoundtrip() throws {
            let state = ProviderConnectionState.connected
            let data = try encoder.encode(state)
            let decoded = try decoder.decode(ProviderConnectionState.self, from: data)
            #expect(decoded == .connected)
        }

        @Test("Syncing Roundtrip")
        func syncingRoundtrip() throws {
            let state = ProviderConnectionState.syncing
            let data = try encoder.encode(state)
            let decoded = try decoder.decode(ProviderConnectionState.self, from: data)
            #expect(decoded == .syncing)
        }

        @Test("Issue Roundtrip")
        func issueRoundtrip() throws {
            let state = ProviderConnectionState.issue("API Key expired")
            let data = try encoder.encode(state)
            let decoded = try decoder.decode(ProviderConnectionState.self, from: data)

            if case .issue(let msg) = decoded {
                #expect(msg == "API Key expired")
            } else {
                #expect(Bool(false))
            }
        }
    }


    @Suite("CostFormatter")
    struct CostFormatterTests {
        @Test("Format Zero")
        func formatZero() {
            #expect(CostFormatter.format(0) == "")
        }

        @Test("Format Negative")
        func formatNegative() {
            #expect(CostFormatter.format(-1) == "")
        }

        @Test("Format Small Value")
        func formatSmallValue() {
            let result = CostFormatter.format(0.0015)
            #expect(result == "$0.0015")
        }

        @Test("Format Normal Value")
        func formatNormalValue() {
            let result = CostFormatter.format(0.05)
            #expect(result == "$0.05")
        }

        @Test("parse: '~$0.05' → 0.05")
        func parseNormalText() {
            #expect(abs(CostFormatter.parse("~$0.05") - 0.05) < 0.0001)
        }

        @Test("parse: '~$0.0012' → 0.0012")
        func parseSmallText() {
            #expect(abs(CostFormatter.parse("~$0.0012") - 0.0012) < 0.00001)
        }

        @Test("Format Tiny Value")
        func formatTinyValue() {
            #expect(CostFormatter.format(0.00005) == "$0.00005")
            #expect(CostFormatter.format(0.00009999) == "$0.00010")
        }

        @Test("Format Epsilon Boundary")
        func formatEpsilonBoundary() {
            #expect(CostFormatter.format(0.00001) == "")
            #expect(CostFormatter.format(0.000009) == "")
        }

        @Test("Format Non Finite")
        func formatNonFinite() {
            #expect(CostFormatter.format(Double.nan) == "")
            #expect(CostFormatter.format(Double.infinity) == "")
            #expect(CostFormatter.format(-Double.infinity) == "")
        }

        @Test("Format Large Value")
        func formatLargeValue() {
            #expect(CostFormatter.format(12.34) == "$12.34")
            #expect(CostFormatter.format(100.0) == "$100.00")
            #expect(CostFormatter.format(1.999) == "$2.00")
        }

        @Test("parse: '~<$0.0001' → 0.0001")
        func parseTinyText() {
            #expect(abs(CostFormatter.parse("~<$0.0001") - 0.0001) < 0.00001)
        }

        @Test("Parse Invalid Text")
        func parseInvalidText() {
            #expect(CostFormatter.parse("invalid") == 0)
            #expect(CostFormatter.parse("") == 0)
        }
    }

    // MARK: - 9. AppSessionSnapshot roundtrip

    @Test("Session Snapshot Roundtrip")
    func sessionSnapshotRoundtrip() throws {
        let provider = TestFactories.makeProvider(kind: .anthropic, apiKey: "sk-ant-test")
        let msg = TestFactories.makeMessage(text: "Hi", providerKind: .anthropic)
        let conv = TestFactories.makeConversation(
            providerID: provider.id,
            modelID: "claude-4",
            messages: [msg]
        )

        let original = TestFactories.makeSnapshot(
            selectedTab: .providers,
            hasCompletedOnboarding: true,
            providers: [provider],
            conversations: [conv],
            lastUsedModelRef: LastUsedModelRef(providerID: provider.id, modelID: "claude-4")
        )

        let data = try encoder.encode(original)
        let decoded = try decoder.decode(AppSessionSnapshot.self, from: data)

        #expect(decoded.selectedTab == .providers)
        #expect(decoded.hasCompletedOnboarding == true)
        #expect(decoded.providers.count == 1)
        #expect(decoded.providers[0].kind == .anthropic)
        #expect(decoded.conversations == nil)
        #expect(decoded.lastUsedModelRef?.modelID == "claude-4")
    }

    @Test("Session Snapshot Legacy Decode")
    func sessionSnapshotLegacyDecode() throws {
        let json = """
        {
            "selectedTab": "providers",
            "hasCompletedOnboarding": true,
            "providers": [],
            "conversations": [
                {
                    "id": "660E8400-E29B-41D4-A716-446655440001",
                    "title": "Legacy Chat",
                    "providerID": "550E8400-E29B-41D4-A716-446655440001",
                    "providerKind": "anthropic",
                    "modelID": "claude-4",
                    "useMemory": true,
                    "previewText": "Hi",
                    "estimatedCost": 0,
                    "isDraft": false,
                    "messages": [
                        {
                            "id": "770E8400-E29B-41D4-A716-446655440001",
                            "role": "user",
                            "text": "Hi",
                            "providerKind": "anthropic",
                            "providerName": "Anthropic",
                            "modelName": "Claude",
                            "estimatedCost": 0,
                            "state": "delivered"
                        }
                    ]
                }
            ]
        }
        """

        let decoded = try decoder.decode(AppSessionSnapshot.self, from: Data(json.utf8))
        #expect((decoded.conversations ?? []).count == 1)
        #expect(decoded.conversations?.first?.messages.count == 1)
    }


    @Test("Chat Role Raw Value Stability")
    func chatRoleRawValueStability() {
        #expect(ChatRole.user.rawValue == "user")
        #expect(ChatRole.assistant.rawValue == "assistant")
    }

    @Test("Chat Message State Raw Value Stability")
    func chatMessageStateRawValueStability() {
        #expect(ChatMessageState.delivered.rawValue == "delivered")
        #expect(ChatMessageState.generating.rawValue == "generating")
        #expect(ChatMessageState.interrupted.rawValue == "interrupted")
        #expect(ChatMessageState.failed.rawValue == "failed")
    }

    @Test("Attachment Kind Raw Value Stability")
    func attachmentKindRawValueStability() {
        #expect(AttachmentKind.image.rawValue == "image")
        #expect(AttachmentKind.file.rawValue == "file")
    }

    @Test("App Tab Raw Value Stability")
    func appTabRawValueStability() {
        #expect(AppTab.home.rawValue == "home")
        #expect(AppTab.providers.rawValue == "providers")
        #expect(AppTab.settings.rawValue == "settings")
    }

    @Test("Reasoning Mode Raw Value Stability")
    func reasoningModeRawValueStability() {
        #expect(ReasoningMode.automatic.rawValue == "automatic")
        #expect(ReasoningMode.fast.rawValue == "fast")
        #expect(ReasoningMode.balanced.rawValue == "balanced")
        #expect(ReasoningMode.deep.rawValue == "deep")
        #expect(ReasoningMode.max.rawValue == "max")
    }

    @Test("Theme Option Raw Value Stability")
    func themeOptionRawValueStability() {
        #expect(ThemeOption.system.rawValue == "system")
        #expect(ThemeOption.light.rawValue == "light")
        #expect(ThemeOption.dark.rawValue == "dark")
    }


    @Test("Ai Model Full Roundtrip")
    func aiModelFullRoundtrip() throws {
        let model = AIModel(
            id: "gpt-4o-2026-03",
            name: "GPT-4o (March 2026)",
            capabilities: [.text, .image, .reasoning, .file, .web],
            reasoningModeAvailable: true,
            isAvailable: true,
            isDefault: true,
            priceTier: "premium",
            summary: "Latest GPT-4o model",
            groupKey: "gpt-4o",
            groupName: "GPT-4o Family",
            createdAt: 1710500000,
            promptPrice: 0.000005,
            completionPrice: 0.000015
        )

        let data = try encoder.encode(model)
        let decoded = try decoder.decode(AIModel.self, from: data)

        #expect(decoded.id == model.id)
        #expect(decoded.name == model.name)
        #expect(decoded.capabilities == model.capabilities)
        #expect(decoded.reasoningModeAvailable == true)
        #expect(decoded.isAvailable == true)
        #expect(decoded.isDefault == true)
        #expect(decoded.priceTier == "premium")
        #expect(decoded.summary == "Latest GPT-4o model")
        #expect(decoded.groupKey == "gpt-4o")
        #expect(decoded.groupName == "GPT-4o Family")
        #expect(decoded.createdAt == 1710500000)
        #expect(decoded.promptPrice == 0.000005)
        #expect(decoded.completionPrice == 0.000015)
    }

    @Test("Ai Model Minimal Roundtrip")
    func aiModelMinimalRoundtrip() throws {
        let model = AIModel(
            id: "minimal",
            name: "Minimal",
            capabilities: [],
            reasoningModeAvailable: false,
            isAvailable: false,
            isDefault: false,
            priceTier: "free"
        )

        let data = try encoder.encode(model)
        let decoded = try decoder.decode(AIModel.self, from: data)

        #expect(decoded.id == "minimal")
        #expect(decoded.summary == nil)
        #expect(decoded.groupKey == nil)
        #expect(decoded.promptPrice == nil)
    }


    @Test("Tc20_1_1_legacy Conversation No Folder ID")
    func tc20_1_1_legacyConversationNoFolderID() throws {
        let json = """
        {
            "id": "660E8400-E29B-41D4-A716-446655440010",
            "title": "Legacy Chat",
            "providerID": "550E8400-E29B-41D4-A716-446655440001",
            "providerKind": "openAI",
            "modelID": "gpt-4o",
            "useMemory": true,
            "previewText": "Hello",
            "estimatedCost": 0.01,
            "isDraft": false,
            "messages": []
        }
        """
        let data = json.data(using: .utf8)!
        let conv = try decoder.decode(Conversation.self, from: data)

        #expect(conv.id.uuidString == "660E8400-E29B-41D4-A716-446655440010")
        #expect(conv.title == "Legacy Chat")
        #expect(conv.folderID == nil)
    }

    @Test("Tc20_1_2_conversation Codable Folder IDOptional")
    func tc20_1_2_conversationCodableFolderIDOptional() throws {
        let folderUUID = UUID(uuidString: "AABBCCDD-1234-5678-9ABC-DEF012345678")!
        let conv = TestFactories.makeConversation(folderID: folderUUID)

        let data = try encoder.encode(conv)
        let decoded = try decoder.decode(Conversation.self, from: data)
        #expect(decoded.folderID == folderUUID)

        let jsonNoFolder = """
        {
            "id": "660E8400-E29B-41D4-A716-446655440011",
            "title": "No Folder",
            "providerID": "550E8400-E29B-41D4-A716-446655440001",
            "providerKind": "anthropic",
            "modelID": "claude-4",
            "useMemory": true,
            "previewText": "",
            "estimatedCost": 0,
            "isDraft": false,
            "messages": []
        }
        """
        let noFolderConv = try decoder.decode(Conversation.self, from: jsonNoFolder.data(using: .utf8)!)
        #expect(noFolderConv.folderID == nil)
    }

    @Test("Tc20_1_3_snapshot No Folders Field")
    func tc20_1_3_snapshotNoFoldersField() throws {
        let json = """
        {
            "selectedTab": "home",
            "hasCompletedOnboarding": true,
            "providers": [],
            "conversations": []
        }
        """
        let data = json.data(using: .utf8)!
        let snapshot = try decoder.decode(AppSessionSnapshot.self, from: data)

        #expect(snapshot.selectedTab == .home)
        #expect(snapshot.hasCompletedOnboarding == true)
        #expect(snapshot.providers.isEmpty)
        #expect((snapshot.conversations ?? []).isEmpty)
        #expect(snapshot.folders == nil || snapshot.folders?.isEmpty == true)
    }
}


private final class BundleLocator {}
