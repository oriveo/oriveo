import Testing
import Foundation
import ZIPFoundation
@testable import Oriveo


@Suite("Backup Crossplatform")
struct BackupCrossplatformTests {


    private let webExportJSON = """
    {
      "version": 1,
      "createdAt": "2026-03-18T04:25:12.978Z",
      "appVersion": "1.0.0",
      "platform": "Web",
      "checksum": "sha256:fake",
      "containsKeys": false,
      "data": {
        "providers": [
          {
            "apiKey": "",
            "apiKeyPreview": "",
            "baseURLText": "https://openrouter.ai/api/v1",
            "catalogModels": [],
            "id": "622df546-0c17-4079-9681-dfb47e508d8a",
            "kind": "openRouter",
            "models": [
              {
                "capabilities": ["text", "image", "file", "web", "reasoning", "imageGeneration"],
                "completionPrice": 1.25e-06,
                "contextLength": 400000,
                "createdAt": 1773748187,
                "groupKey": "openai",
                "groupName": "OpenAI",
                "id": "openai/gpt-5.4-nano",
                "isAvailable": true,
                "isDefault": true,
                "name": "gpt-5.4-nano",
                "priceTier": "$0.2/M",
                "promptPrice": 2e-07,
                "reasoningModeAvailable": true,
                "summary": "A fast nano model"
              }
            ],
            "recommendedModels": [],
            "status": {"kind": "connected"}
          }
        ],
        "conversations": [
          {
            "draftText": "",
            "estimatedCost": 0.017,
            "hasCustomTitle": true,
            "id": "222bdff8-6aa8-417f-8ff1-e5f695ce50c7",
            "isDraft": false,
            "messages": [
              {
                "createdAt": "2026-03-18T03:02:08.388Z",
                "estimatedCost": 0,
                "id": "f38adccb-88b1-43ac-946b-fdb5ef7c7a6f",
                "modelName": "gpt-5-image-mini",
                "providerKind": "openRouter",
                "providerName": "OpenRouter",
                "role": "user",
                "state": "delivered",
                "text": "Hello from Web"
              },
              {
                "createdAt": "2026-03-18T03:02:10.000Z",
                "estimatedCost": 0.017,
                "id": "a1b2c3d4-0000-0000-0000-000000000001",
                "modelName": "gpt-5-image-mini",
                "providerKind": "openRouter",
                "providerName": "OpenRouter",
                "role": "assistant",
                "state": "delivered",
                "text": "Hello! How can I help?"
              }
            ],
            "modelID": "openai/gpt-5.4-nano",
            "previewText": "Hello! How can I help?",
            "providerID": "622df546-0c17-4079-9681-dfb47e508d8a",
            "providerKind": "openRouter",
            "title": "Web Chat Title",
            "updatedAt": "2026-03-18T03:02:10.000Z"
          }
        ]
      },
      "encryptedKeys": null,
      "attachmentChecksums": null
    }
    """.data(using: .utf8)!


    @Test("Decode Web JSON")
    func decodeWebJSON() throws {
        let (backupFile, images) = try BackupService.parseBackup(from: webExportJSON)

        #expect(backupFile.version == 1)
        #expect(backupFile.platform == "Web")
        #expect(backupFile.containsKeys == false)
        #expect(backupFile.encryptedKeys == nil)
        #expect(images.isEmpty)
    }

    @Test("Web Provider Extra Fields Ignored")
    func webProviderExtraFieldsIgnored() throws {
        let (backupFile, _) = try BackupService.parseBackup(from: webExportJSON)

        #expect(backupFile.data.providers.count == 1)
        let provider = backupFile.data.providers[0]
        #expect(provider.kind == .openRouter)
        #expect(provider.models.count == 1)
        #expect(provider.models[0].id == "openai/gpt-5.4-nano")
    }

    @Test("Image Generation Capability Mapping")
    func imageGenerationCapabilityMapping() throws {
        let (backupFile, _) = try BackupService.parseBackup(from: webExportJSON)

        let model = backupFile.data.providers[0].models[0]
        #expect(model.capabilities.contains(.imageGen))
        #expect(model.capabilities.contains(.text))
        #expect(model.capabilities.contains(.reasoning))
    }

    @Test("Web Model Extra Fields Ignored")
    func webModelExtraFieldsIgnored() throws {
        let (backupFile, _) = try BackupService.parseBackup(from: webExportJSON)

        let model = backupFile.data.providers[0].models[0]
        #expect(model.name == "gpt-5.4-nano")
        #expect(model.isDefault == true)
        #expect(model.promptPrice == 2e-07)
    }

    @Test("Web Conversation Extra Fields Ignored")
    func webConversationExtraFieldsIgnored() throws {
        let (backupFile, _) = try BackupService.parseBackup(from: webExportJSON)

        #expect(backupFile.data.conversations.count == 1)
        let conv = backupFile.data.conversations[0]
        #expect(conv.title == "Web Chat Title")
        #expect(conv.hasCustomTitle == true)
        #expect(conv.messages.count == 2)
    }

    @Test("Web Message State String")
    func webMessageStateString() throws {
        let (backupFile, _) = try BackupService.parseBackup(from: webExportJSON)

        let msg = backupFile.data.conversations[0].messages[0]
        #expect(msg.state == .delivered)
        #expect(msg.role == .user)
        #expect(msg.text == "Hello from Web")
    }

    @Test("Web Missing Preferences")
    func webMissingPreferences() throws {
        let (backupFile, _) = try BackupService.parseBackup(from: webExportJSON)

        #expect(backupFile.data.preferences == nil)
    }

    @Test("Web Missing Last Used Model Ref")
    func webMissingLastUsedModelRef() throws {
        let (backupFile, _) = try BackupService.parseBackup(from: webExportJSON)

        #expect(backupFile.data.lastUsedModelRef == nil)
    }


    @Test("Decode Web ZIP")
    func decodeWebZIP() throws {
        guard let archive = Archive(accessMode: .create) else {
            Issue.record("Unable to create ZIP")
            return
        }
        try archive.addEntry(
            with: "data.json",
            type: .file,
            uncompressedSize: UInt32(webExportJSON.count),
            provider: { (position: Int, size: Int) in
                webExportJSON[position..<(position + size)]
            }
        )
        guard let zipData = archive.data else {
            Issue.record("Unable to get ZIP data")
            return
        }

        let (backupFile, images) = try BackupService.parseBackup(from: zipData)

        #expect(backupFile.platform == "Web")
        #expect(backupFile.data.providers.count == 1)
        #expect(backupFile.data.conversations.count == 1)
        #expect(images.isEmpty)
    }


    @Test("Web Message With Image Attachment")
    func webMessageWithImageAttachment() throws {
        let json = """
        {
          "version": 1, "createdAt": "2026-03-18T04:00:00Z",
          "appVersion": "1.0.0", "platform": "Web",
          "checksum": "sha256:fake", "containsKeys": false,
          "data": {
            "providers": [],
            "conversations": [{
              "id": "00000000-0000-0000-0000-000000000001", "title": "Image Chat",
              "hasCustomTitle": false,
              "providerID": "00000000-0000-0000-0000-000000000005", "providerKind": "openRouter", "modelID": "gpt-4o",
              "previewText": "", "estimatedCost": 0,
              "updatedAt": "2026-03-18T04:00:00Z",
              "messages": [{
                "id": "00000000-0000-0000-0000-000000000002", "role": "assistant", "text": "",
                "providerKind": "openRouter", "providerName": "OpenRouter",
                "modelName": "gpt-5-image", "estimatedCost": 0,
                "state": "delivered",
                "createdAt": "2026-03-18T04:00:00Z",
                "attachments": [{
                  "id": "00000000-0000-0000-0000-000000000003",
                  "kind": "image",
                  "fileName": "generated.png",
                  "mimeType": "image/png",
                  "localImageID": "img-uuid-001",
                  "thumbnailBase64": "iVBORw0KGgo="
                }]
              }]
            }]
          },
          "encryptedKeys": null
        }
        """.data(using: .utf8)!

        let (backupFile, _) = try BackupService.parseBackup(from: json)

        let msg = backupFile.data.conversations[0].messages[0]
        #expect(msg.attachments?.count == 1)

        let att = msg.attachments![0]
        #expect(att.kind == .image)
        #expect(att.localImageID == "img-uuid-001")
        #expect(att.thumbnailBase64 == "iVBORw0KGgo=")
        #expect(att.base64Data == nil)
    }

    @Test("Web Message With File Attachment")
    func webMessageWithFileAttachment() throws {
        let json = """
        {
          "version": 1, "createdAt": "2026-03-18T04:00:00Z",
          "appVersion": "1.0.0", "platform": "Web",
          "checksum": "sha256:fake", "containsKeys": false,
          "data": {
            "providers": [],
            "conversations": [{
              "id": "00000000-0000-0000-0000-000000000001", "title": "File Chat",
              "hasCustomTitle": false,
              "providerID": "00000000-0000-0000-0000-000000000005", "providerKind": "openAI", "modelID": "gpt-4o",
              "previewText": "", "estimatedCost": 0,
              "updatedAt": "2026-03-18T04:00:00Z",
              "messages": [{
                "id": "00000000-0000-0000-0000-000000000002", "role": "user", "text": "Here is a file",
                "providerKind": "openAI", "providerName": "OpenAI",
                "modelName": "gpt-4o", "estimatedCost": 0,
                "state": "delivered",
                "createdAt": "2026-03-18T04:00:00Z",
                "attachments": [{
                  "id": "00000000-0000-0000-0000-000000000004",
                  "kind": "file",
                  "fileName": "report.pdf",
                  "mimeType": "application/pdf",
                  "base64Data": "JVBERi0xLjQ="
                }]
              }]
            }]
          },
          "encryptedKeys": null
        }
        """.data(using: .utf8)!

        let (backupFile, _) = try BackupService.parseBackup(from: json)

        let att = backupFile.data.conversations[0].messages[0].attachments![0]
        #expect(att.kind == .file)
        #expect(att.fileName == "report.pdf")
        #expect(att.base64Data == "JVBERi0xLjQ=")
    }


    @Test("Web Legacy Attachment Entry Naming")
    func webLegacyAttachmentEntryNaming() throws {
        let json = """
        {
          "version": 1, "createdAt": "2026-03-18T04:00:00Z",
          "appVersion": "1.0.0", "platform": "Web",
          "checksum": "sha256:fake", "containsKeys": false,
          "data": {
            "providers": [],
            "conversations": [{
              "id": "00000000-0000-0000-0000-000000000001", "title": "Image Chat",
              "hasCustomTitle": false,
              "providerID": "00000000-0000-0000-0000-000000000005", "providerKind": "openAI", "modelID": "gpt-4o",
              "previewText": "", "estimatedCost": 0,
              "updatedAt": "2026-03-18T04:00:00Z",
              "messages": [{
                "id": "00000000-0000-0000-0000-000000000002", "role": "user", "text": "",
                "providerKind": "openAI", "providerName": "OpenAI",
                "modelName": "gpt-4o", "estimatedCost": 0,
                "state": "delivered",
                "createdAt": "2026-03-18T04:00:00Z",
                "attachments": [{
                  "id": "00000000-0000-0000-0000-000000000003",
                  "kind": "image",
                  "fileName": "photo.jpg",
                  "mimeType": "image/jpeg",
                  "localImageID": "IMG-0001"
                }]
              }]
            }]
          },
          "encryptedKeys": null
        }
        """.data(using: .utf8)!
        let imageBytes = Data("image-bytes".utf8)
        let thumbBytes = Data("thumb-bytes".utf8)

        guard let archive = Archive(accessMode: .create) else {
            Issue.record("Unable to create ZIP")
            return
        }
        try archive.addEntry(
            with: "data.json",
            type: .file,
            uncompressedSize: UInt32(json.count),
            provider: { (position: Int, size: Int) in json[position..<(position + size)] }
        )
        try archive.addEntry(
            with: "attachments/IMG-0001.jpg",
            type: .file,
            uncompressedSize: UInt32(imageBytes.count),
            provider: { (position: Int, size: Int) in imageBytes[position..<(position + size)] }
        )
        try archive.addEntry(
            with: "attachments/IMG-0001.thumb.jpg",
            type: .file,
            uncompressedSize: UInt32(thumbBytes.count),
            provider: { (position: Int, size: Int) in thumbBytes[position..<(position + size)] }
        )
        guard let zipData = archive.data else {
            Issue.record("Unable to get ZIP data")
            return
        }

        let (backupFile, images) = try BackupService.parseBackup(from: zipData)
        let att = try #require(backupFile.data.conversations[0].messages[0].attachments?.first)

        #expect(att.localImageID == "IMG-0001")
        #expect("\(att.id)" != att.localImageID)
        #expect(images["IMG-0001.jpg"] == imageBytes)
        #expect(images["IMG-0001.thumb.jpg"] == thumbBytes)
        #expect(images["\(att.id).jpg"] == nil)
    }


    @Test("Web Encrypted Keys Decryptable")
    func webEncryptedKeysDecryptable() throws {
        let keysPayload = BackupKeysPayload(keys: [
            BackupKeyEntry(
                providerID: UUID(uuidString: "622df546-0c17-4079-9681-dfb47e508d8a")!,
                apiKey: "sk-or-v1-test-key-12345",
                apiKeyPreview: "sk-or-...345"
            )
        ])
        let payloadData = try JSONEncoder().encode(keysPayload)
        let encrypted = try BackupCrypto.encrypt(payloadData, password: "webpassword")
        let encBase64 = encrypted.base64EncodedString()

        let json = """
        {
          "version": 1, "createdAt": "2026-03-18T04:00:00Z",
          "appVersion": "1.0.0", "platform": "Web",
          "checksum": "sha256:fake",
          "containsKeys": true,
          "data": {"providers": [], "conversations": []},
          "encryptedKeys": "\(encBase64)"
        }
        """.data(using: .utf8)!

        let (backupFile, _) = try BackupService.parseBackup(from: json)

        #expect(backupFile.containsKeys == true)
        #expect(backupFile.encryptedKeys != nil)

        let encData = Data(base64Encoded: backupFile.encryptedKeys!)!
        let decrypted = try BackupCrypto.decrypt(encData, password: "webpassword")
        let restored = try JSONDecoder().decode(BackupKeysPayload.self, from: decrypted)

        #expect(restored.keys.count == 1)
        #expect(restored.keys[0].apiKey == "sk-or-v1-test-key-12345")
    }


    @Test("Version Too New")
    func versionTooNew() throws {
        let json = """
        {
          "version": 99, "createdAt": "2026-03-18T04:00:00Z",
          "appVersion": "9.0.0", "platform": "Web",
          "checksum": "sha256:fake", "containsKeys": false,
          "data": {"providers": [], "conversations": []},
          "encryptedKeys": null
        }
        """.data(using: .utf8)!

        let (backupFile, _) = try BackupService.parseBackup(from: json)
        #expect(backupFile.version == 99)
        #expect(backupFile.version > BackupService.currentVersion)
    }


    @Test("Preview Provider Dedup")
    func previewProviderDedup() throws {
        let (backupFile, _) = try BackupService.parseBackup(from: webExportJSON)

        let localProvider = Provider(
            id: UUID(), kind: .openRouter, status: .connected,
            models: [], catalogModels: [],
            apiKey: "sk-local", apiKeyPreview: "sk-...al"
        )
        let preview = BackupService.previewImport(
            backupFile: backupFile,
            localConversations: [],
            localProviders: [localProvider]
        )

        #expect(preview.existingProviders == 0)
        #expect(preview.totalProviders == 1)
    }

    @Test("Preview Relay Dedup")
    func previewRelayDedup() throws {
        let relayID = UUID()
        let json = """
        {
          "version": 1, "createdAt": "2026-03-18T04:00:00Z",
          "appVersion": "1.0.0", "platform": "Web",
          "checksum": "sha256:fake", "containsKeys": false,
          "data": {
            "providers": [
              {"id": "\(relayID.uuidString)", "kind": "relay", "models": [], "catalogModels": [], "customName": "My Relay", "baseURLText": "https://api.example.com/v1"}
            ],
            "conversations": []
          },
          "encryptedKeys": null
        }
        """.data(using: .utf8)!

        let (backupFile, _) = try BackupService.parseBackup(from: json)

        let localRelay = Provider(
            id: relayID, kind: .relay, status: .connected,
            models: [], catalogModels: [],
            apiKey: "sk-relay", apiKeyPreview: "sk-...ay",
            baseURLText: "https://api.example.com/v1", customName: "My Relay"
        )
        let preview = BackupService.previewImport(
            backupFile: backupFile,
            localConversations: [],
            localProviders: [localRelay]
        )

        #expect(preview.existingProviders == 1)
    }


    @Test("Empty Backup")
    func emptyBackup() throws {
        let json = """
        {
          "version": 1, "createdAt": "2026-03-18T04:00:00Z",
          "appVersion": "1.0.0", "platform": "Web",
          "checksum": "sha256:fake", "containsKeys": false,
          "data": {"providers": [], "conversations": []},
          "encryptedKeys": null
        }
        """.data(using: .utf8)!

        let (backupFile, _) = try BackupService.parseBackup(from: json)

        #expect(backupFile.data.providers.isEmpty)
        #expect(backupFile.data.conversations.isEmpty)
    }

    @Test("Message Without Created At")
    func messageWithoutCreatedAt() throws {
        let json = """
        {
          "version": 1, "createdAt": "2026-03-18T04:00:00Z",
          "appVersion": "1.0.0", "platform": "Web",
          "checksum": "sha256:fake", "containsKeys": false,
          "data": {
            "providers": [],
            "conversations": [{
              "id": "00000000-0000-0000-0000-000000000001", "title": "Old Chat",
              "hasCustomTitle": false,
              "providerID": "00000000-0000-0000-0000-000000000005", "providerKind": "openAI", "modelID": "gpt-4o",
              "previewText": "Hi", "estimatedCost": 0,
              "updatedAt": "2026-03-18T04:00:00Z",
              "messages": [{
                "id": "00000000-0000-0000-0000-000000000002", "role": "user", "text": "Hi",
                "providerKind": "openAI", "providerName": "OpenAI",
                "modelName": "gpt-4o", "estimatedCost": 0,
                "state": "delivered"
              }]
            }]
          },
          "encryptedKeys": null
        }
        """.data(using: .utf8)!

        let (backupFile, _) = try BackupService.parseBackup(from: json)

        let msg = backupFile.data.conversations[0].messages[0]
        #expect(msg.createdAt == nil)
        #expect(msg.text == "Hi")
    }

    @Test("All Message States")
    func allMessageStates() throws {
        let states = ["delivered", "generating", "interrupted", "failed"]
        for state in states {
            let json = """
            {
              "version": 1, "createdAt": "2026-03-18T04:00:00Z",
              "appVersion": "1.0.0", "platform": "Web",
              "checksum": "sha256:fake", "containsKeys": false,
              "data": {
                "providers": [],
                "conversations": [{
                  "id": "00000000-0000-0000-0000-000000000001", "title": "T", "hasCustomTitle": false,
                  "providerID": "00000000-0000-0000-0000-000000000005", "providerKind": "openAI", "modelID": "gpt-4o",
                  "previewText": "", "estimatedCost": 0,
                  "updatedAt": "2026-03-18T04:00:00Z",
                  "messages": [{
                    "id": "00000000-0000-0000-0000-000000000002", "role": "user", "text": "x",
                    "providerKind": "openAI", "providerName": "OpenAI",
                    "modelName": "m", "estimatedCost": 0,
                    "state": "\(state)", "createdAt": "2026-03-18T04:00:00Z"
                  }]
                }]
              },
              "encryptedKeys": null
            }
            """.data(using: .utf8)!

            let (backupFile, _) = try BackupService.parseBackup(from: json)
            let msg = backupFile.data.conversations[0].messages[0]
            #expect(msg.state.rawValue == state)
        }
    }

    @Test("All Provider Kinds")
    func allProviderKinds() throws {
        let kinds = ["openAI", "anthropic", "gemini", "openRouter", "groq", "together", "fireworks", "miniMax", "zhipu", "qwen", "siliconFlow", "relay"]
        for kind in kinds {
            let json = """
            {
              "version": 1, "createdAt": "2026-03-18T04:00:00Z",
              "appVersion": "1.0.0", "platform": "Web",
              "checksum": "sha256:fake", "containsKeys": false,
              "data": {
                "providers": [{"id": "00000000-0000-0000-0000-000000000001", "kind": "\(kind)", "models": [], "catalogModels": []}],
                "conversations": []
              },
              "encryptedKeys": null
            }
            """.data(using: .utf8)!

            let (backupFile, _) = try BackupService.parseBackup(from: json)
            #expect(backupFile.data.providers[0].kind.rawValue == kind)
        }
    }
}
