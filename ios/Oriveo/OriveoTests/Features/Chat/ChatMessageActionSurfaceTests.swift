import Testing
import UIKit
@testable import Oriveo

@Suite("Chat message action surface", .sharedProcessState)
@MainActor
struct ChatMessageActionSurfaceTests {

    @Test("Generating assistant keeps metadata visible but hides the completed action row")
    func generatingAssistantHidesFooterActions() {
        let metadataView = AssistantMetadataView()
        metadataView.configure(
            model: Self.makeAssistantModel(text: "", state: .generating),
            providerName: "OpenAI",
            modelName: "GPT-4o",
            leadingInset: 0,
            onRetry: {},
            onContinue: nil,
            onSaveNote: {},
            onCrosscheck: {}
        )

        #expect(Self.visibleLabelTexts(in: metadataView).contains("OpenAI"))
        #expect(Self.visibleLabelTexts(in: metadataView).contains("GPT-4o"))
        #expect(Self.visibleButtons(in: metadataView).isEmpty)
    }

    @Test("Delivered assistant reveals actions only after deferred visual rendering settles")
    func deliveredAssistantWaitsForVisualRenderBeforeShowingFooterActions() {
        let metadataView = AssistantMetadataView()
        metadataView.configure(
            model: Self.makeAssistantModel(text: "A paced answer."),
            providerName: "OpenAI",
            modelName: "GPT-4o",
            leadingInset: 0,
            onRetry: {},
            onContinue: nil,
            onSaveNote: {},
            onCrosscheck: {},
            isVisualRenderPending: true
        )

        #expect(Self.visibleButtons(in: metadataView).isEmpty)

        metadataView.markVisualRenderCompleted()

        let visibleTitles = Self.visibleButtonTitles(in: metadataView)
        #expect(visibleTitles.contains(L10n.tr("Copy")))
        #expect(visibleTitles.contains(L10n.tr("More", table: .chat)))
    }

    @Test("Delivered assistant footer exposes Copy and Save as Note, with retry inside More")
    func deliveredAssistantFooterUsesCopySaveAndMoreActions() throws {
        let metadataView = AssistantMetadataView()
        let model = Self.makeAssistantModel(text: "A useful answer.")

        metadataView.configure(
            model: model,
            providerName: "OpenAI",
            modelName: "GPT-4o",
            leadingInset: 0,
            onRetry: {},
            onContinue: nil,
            onSaveNote: {},
            onCrosscheck: {}
        )

        let visibleTitles = Self.visibleButtonTitles(in: metadataView)
        #expect(visibleTitles.contains(L10n.tr("Copy")))
        #expect(visibleTitles.contains(L10n.tr("Save as Note", table: .notes)))
        #expect(!visibleTitles.contains(L10n.tr("Regenerate", table: .chat)))
        #expect(!visibleTitles.contains(L10n.tr("Cross-check", table: .notes)))

        let menus = Self.buttonMenus(in: metadataView)
        let menuTitles = menus.flatMap(\.children).compactMap { ($0 as? UIAction)?.title }
        #expect(menuTitles.contains(L10n.tr("Regenerate", table: .chat)))
        #expect(menuTitles.contains(L10n.tr("Cross-check", table: .notes)))

        let moreButton = try #require(Self.visibleButtons(in: metadataView).first { $0.menu != nil })
        #expect(moreButton.accessibilityLabel == L10n.tr("More", table: .chat))
    }

    @Test("More menu leaves highlight and dismissal state to UIKit")
    func moreMenuDoesNotRewriteButtonConfigurationDuringDismissal() throws {
        let metadataView = AssistantMetadataView()
        metadataView.configure(
            model: Self.makeAssistantModel(text: "A useful answer."),
            providerName: "OpenAI",
            modelName: "GPT-4o",
            leadingInset: 0,
            onRetry: {},
            onContinue: nil,
            onCrosscheck: {}
        )

        let moreButton = try #require(Self.visibleButtons(in: metadataView).first { $0.menu != nil })
        #expect(moreButton.showsMenuAsPrimaryAction)
        #expect(
            moreButton.configurationUpdateHandler == nil,
            "Primary UIMenu source must not replace its configuration during highlight/dismiss transitions"
        )

        moreButton.isHighlighted = true
        moreButton.isHighlighted = false
        #expect(moreButton.configuration?.image != nil)
        #expect(!moreButton.isHidden)
    }

    @Test("Assistant footer keeps model metadata and action buttons on separate rows")
    func assistantFooterSeparatesMetadataAndActionRows() throws {
        let metadataView = AssistantMetadataView()
        let model = Self.makeAssistantModel(
            text: "A useful answer.",
            providerName: "OpenRouter",
            modelName: "Xiaomi: MiMo-V2.5",
            estimatedCost: 0.006
        )

        metadataView.configure(
            model: model,
            providerName: "OpenRouter",
            modelName: "Xiaomi: MiMo-V2.5",
            leadingInset: 0,
            onRetry: {},
            onContinue: nil,
            onSaveNote: {},
            onCrosscheck: {}
        )

        #expect(metadataView.axis == .vertical)

        let rows = Self.visibleRows(in: metadataView)
        let infoRow = try #require(rows.first { row in
            let labels = Self.visibleLabelTexts(in: row)
            return labels.contains("OpenRouter")
                && labels.contains("Xiaomi: MiMo-V2.5")
                && labels.contains(CostFormatter.format(0.006))
        })
        #expect(Self.visibleButtonTitles(in: infoRow).isEmpty)

        let actionRow = try #require(rows.first { row in
            let titles = Self.visibleButtonTitles(in: row)
            return titles.contains(L10n.tr("Copy"))
                && titles.contains(L10n.tr("Save as Note", table: .notes))
        })
        let actionLabels = Self.visibleLabelTexts(in: actionRow)
        #expect(actionLabels.contains("OpenRouter") == false)
        #expect(actionLabels.contains("Xiaomi: MiMo-V2.5") == false)
        #expect(actionLabels.contains(CostFormatter.format(0.006)) == false)
    }

    @Test("Assistant footer metadata stays as a left-aligned continuous line on wide cells")
    func assistantFooterMetadataDoesNotSpreadAcrossWideRows() throws {
        let metadataView = AssistantMetadataView(frame: CGRect(x: 0, y: 0, width: 830, height: 120))
        let model = Self.makeAssistantModel(
            text: "A useful answer.",
            providerName: "OpenRouter",
            modelName: "Xiaomi: MiMo-V2.5",
            estimatedCost: 0.0058
        )

        metadataView.configure(
            model: model,
            providerName: "OpenRouter",
            modelName: "Xiaomi: MiMo-V2.5",
            leadingInset: 0,
            onRetry: {},
            onContinue: nil,
            onSaveNote: {},
            onCrosscheck: {}
        )
        metadataView.setNeedsLayout()
        metadataView.layoutIfNeeded()

        let labels = Self.visibleLabels(in: metadataView)
        let providerLabel = try #require(labels.first { $0.text == "OpenRouter" })
        let modelLabel = try #require(labels.first { $0.text == "Xiaomi: MiMo-V2.5" })
        let dotLabels = labels.filter { $0.text == "·" }.sorted { $0.frame.minX < $1.frame.minX }
        let firstDot = try #require(dotLabels.first)

        #expect(
            providerLabel.frame.width <= providerLabel.intrinsicContentSize.width + 8,
            "providerLabel stretched and pushed the model metadata to the centre, frame=\(providerLabel.frame.width) intrinsic=\(providerLabel.intrinsicContentSize.width)"
        )
        #expect(
            firstDot.frame.minX - providerLabel.frame.maxX <= 8,
            "a gap opened between the provider name and the first separator dot, gap=\(firstDot.frame.minX - providerLabel.frame.maxX)"
        )
        #expect(
            modelLabel.frame.minX - firstDot.frame.maxX <= 8,
            "the model metadata is not left-aligned right after the provider name, gap=\(modelLabel.frame.minX - firstDot.frame.maxX)"
        )
    }

    @Test("Assistant footer action buttons keep compact Android-style widths on wide cells")
    func assistantFooterActionsDoNotStretchAcrossWideRows() throws {
        let metadataView = AssistantMetadataView(frame: CGRect(x: 0, y: 0, width: 830, height: 140))
        let model = Self.makeAssistantModel(text: "A useful answer.")

        metadataView.configure(
            model: model,
            providerName: "OpenAI",
            modelName: "GPT-4o",
            leadingInset: 0,
            onRetry: {},
            onContinue: nil,
            onSaveNote: {},
            onCrosscheck: {}
        )
        metadataView.setNeedsLayout()
        metadataView.layoutIfNeeded()

        let rows = Self.visibleRows(in: metadataView)
        let actionRow = try #require(rows.first { row in
            let titles = Self.visibleButtonTitles(in: row)
            return titles.contains(L10n.tr("Copy"))
                && titles.contains(L10n.tr("Save as Note", table: .notes))
        })
        let buttons = Self.visibleButtons(in: actionRow)
        let copyButton = try #require(buttons.first { Self.buttonTitles($0).contains(L10n.tr("Copy")) })
        let saveButton = try #require(buttons.first { Self.buttonTitles($0).contains(L10n.tr("Save as Note", table: .notes)) })
        let moreButton = try #require(buttons.first { $0.menu != nil })

        #expect(copyButton.frame.width <= 180, "the Copy button stretched to fill the row, width=\(copyButton.frame.width)")
        #expect(saveButton.frame.width <= 220, "the Save as Note button stretched to fill the row, width=\(saveButton.frame.width)")
        #expect(moreButton.frame.width <= 46, "the More button must stay a compact square, width=\(moreButton.frame.width)")
    }

    @Test("Assistant footer action buttons stay inside footer bounds on phone width")
    func assistantFooterActionsDoNotBleedOutsidePhoneBounds() throws {
        let metadataView = AssistantMetadataView(frame: CGRect(x: 0, y: 0, width: 342, height: 140))
        let model = Self.makeAssistantModel(
            text: "A useful answer.",
            providerName: "OpenAI",
            modelName: "GPT-5.5",
            estimatedCost: 0.26
        )

        metadataView.configure(
            model: model,
            providerName: "OpenAI",
            modelName: "GPT-5.5",
            leadingInset: 4,
            onRetry: {},
            onContinue: nil,
            onSaveNote: {},
            onCrosscheck: {}
        )
        metadataView.setNeedsLayout()
        metadataView.layoutIfNeeded()

        let rows = Self.visibleRows(in: metadataView)
        let actionRow = try #require(rows.first { row in
            let titles = Self.visibleButtonTitles(in: row)
            return titles.contains(L10n.tr("Copy"))
                && titles.contains(L10n.tr("Save as Note", table: .notes))
        })

        for button in Self.visibleButtons(in: actionRow) {
            let frame = button.convert(button.bounds, to: metadataView)
            #expect(
                frame.minX >= 0,
                "footer action button bleeds left outside metadata bounds: \(frame)"
            )
            #expect(
                frame.maxX <= metadataView.bounds.width,
                "footer action button bleeds right outside metadata bounds: \(frame)"
            )
        }
    }

    @Test("Saved-note reference uses a dedicated row and includes the note title")
    func savedNoteReferenceUsesDedicatedRowWithNoteTitle() throws {
        let metadataView = AssistantMetadataView()
        let noteTitle = "Bubble sort in C"
        let savedNote = NoteSummary(NoteTestFactories.makeNote(
            title: noteTitle,
            captureKind: .fullAnswer
        ))
        let model = Self.makeAssistantModel(
            text: "A useful answer.",
            noteReferences: [savedNote]
        )

        metadataView.configure(
            model: model,
            providerName: "OpenAI",
            modelName: "GPT-4o",
            leadingInset: 0,
            onRetry: {},
            onContinue: nil,
            onSaveNote: {},
            onOpenNoteReferences: {},
            onCrosscheck: {}
        )

        let rows = Self.visibleRows(in: metadataView)
        let actionRow = try #require(rows.first { row in
            Self.visibleButtonTitles(in: row).contains(L10n.tr("Save as Note", table: .notes))
        })
        let savedNoteRow = try #require(rows.first { row in
            Self.visibleButtonTitles(in: row).contains { title in
                title.contains(L10n.tr("Saved as note", table: .notes))
                    && title.contains(noteTitle)
            }
        })

        #expect(savedNoteRow !== actionRow)
    }

    @Test("User message long-press menu exposes Copy before Save as Note")
    func userMessageContextMenuIncludesCopyBeforeSaveAsNote() throws {
        let source = try String(contentsOf: Self.userMessageCellSourceURL(), encoding: .utf8)
        let menuBlock = try #require(
            Self.sourceBlock(
                in: source,
                from: "extension UserMessageCell: UIContextMenuInteractionDelegate",
                to: "private func shouldYieldContextMenuToTextSelection"
            )
        )

        #expect(menuBlock.contains("L10n.tr(\"Copy\")"))
        #expect(menuBlock.contains("UIPasteboard.general.string"))

        let copyIndex = try #require(menuBlock.range(of: "L10n.tr(\"Copy\")")?.lowerBound)
        let saveIndex = try #require(menuBlock.range(of: "L10n.tr(\"Save as Note\", table: .notes)")?.lowerBound)
        #expect(copyIndex < saveIndex)
    }

    @Test("User message text selection menu receives the Save as Note callback")
    func userMessageSelectionMenuReceivesSaveAsNoteCallback() throws {
        let userCellSource = try String(contentsOf: Self.userMessageCellSourceURL(), encoding: .utf8)
        let configureBlock = try #require(
            Self.sourceBlock(
                in: userCellSource,
                from: "    func configure(",
                to: "        topPaddingConstraint.constant = model.topPadding"
            )
        )

        #expect(configureBlock.contains("onSaveSelection: ((String) -> Void)? = nil"))
        #expect(configureBlock.contains("textView.onSaveSelection = onSaveSelection"))
        #expect(userCellSource.contains("textView.onSaveSelection = nil"))
        #expect(userCellSource.contains("textView.onReplaceSelection = nil"))

        let dataSource = try String(contentsOf: Self.chatListDataSourceURL(), encoding: .utf8)
        let userBranch = try #require(
            Self.sourceBlock(
                in: dataSource,
                from: "        if message.role == .user {",
                to: "        let cell = collectionView.dequeueReusableCell(\n            withReuseIdentifier: Self.assistantReuseID"
            )
        )

        #expect(userBranch.contains("onSaveSelection: { text in context.onSaveSelection(message, text) }"))
    }

    @Test("User message whole-message menu yields to text selection inside the text view")
    func userMessageContextMenuDoesNotCoverTextSelection() throws {
        let cell = Self.layOutUserMessageCell(text: "Select this message text")
        let interaction = UIContextMenuInteraction(delegate: cell)
        let bubbleFrame = cell.bubbleFrameForTesting

        let textAreaPoint = CGPoint(x: bubbleFrame.width / 2, y: bubbleFrame.height / 2)
        let textAreaConfiguration = cell.contextMenuInteraction(
            interaction,
            configurationForMenuAtLocation: textAreaPoint
        )
        #expect(
            textAreaConfiguration == nil,
            "a long press on the text must hand over to the UITextView selection menu instead of showing the whole-message menu"
        )

        let bubblePaddingPoint = CGPoint(x: 2, y: 2)
        let paddingConfiguration = cell.contextMenuInteraction(
            interaction,
            configurationForMenuAtLocation: bubblePaddingPoint
        )
        #expect(
            paddingConfiguration != nil,
            "the non-text area of the bubble must keep the whole-message copy and save-as-note menu"
        )
    }

    @Test("Assistant footer stays attached to message content in an oversized reused cell")
    func userImageBubbleNotSentCaptionFollowsVisionProjection() async throws {
        let data = try Data(contentsOf: Self.repoFixtureURL("shared/test-fixtures/relay/metadata-fixture.json"))
        await MetadataClient.shared.resetForTesting()
        try await MetadataClient.shared.loadForTesting(json: String(decoding: data, as: UTF8.self))
        let model = AIModel(
            id: "bubble-not-sent-\(UUID().uuidString)", name: "relay", capabilities: [.text],
            reasoningModeAvailable: false, isAvailable: true, isDefault: true, priceTier: ""
        )
        let provider = Provider(
            id: UUID(), kind: .relay, status: .connected, models: [model], catalogModels: [],
            apiKey: "key", apiKeyPreview: "...key", baseURLText: "https://relay.test/v1",
            relayRequested: RelayRequestedConfig(transport: .openaiChatCompletions)
        )
        defer { CapabilityNegativeCache.shared.clearConnection(provider.id.uuidString) }
        func visionInput() -> CapabilityEvidenceFacade.InputCapabilityProjection? {
            let identity = CapabilityEvidenceProductionAdapter.uiDispatchIdentity(
                provider: provider, model: model, partitionID: "bubble-not-sent-tests"
            )
            return CapabilityEvidenceProductionAdapter.capabilityProjection(
                provider: provider, model: model, identity: identity,
                keys: [CapabilityEvidenceFacade.visionInputKey]
            ).inputProjection(for: CapabilityEvidenceFacade.visionInputKey)
        }
        let image = Oriveo.Attachment(
            id: UUID(), kind: .image, fileName: "p.png", mimeType: "image/png",
            base64Data: RelayCapabilityTest.imagePNGBase64
        )

        // Relay vision unknown: image goes out natively, no caption.
        let outbound = try #require(visionInput())
        #expect(outbound.outbound == .nativePart)
        let sendable = Self.layOutUserMessageCell(text: "look", attachments: [image], visionInput: outbound)
        #expect(sendable.notSentToModelCaptionForTesting == nil)
        #expect(!Self.visibleLabelTexts(in: sendable).contains(InputCapabilityCopy.bubbleNotSentToModel))

        // Relay rejection recorded: projection strips the image to a placeholder, caption appears.
        #expect(RelayRejectionRecording.recordImageRejection(
            provider: provider, model: model, transport: .openaiChatCompletions,
            rejection: RelayPreOutputRejection(
                status: 400, contentType: "application/json", body: Data(#"{"error":{"message":"x"}}"#.utf8)
            ),
            negativeCache: RelayNegativeCache(defaults: UserDefaults(suiteName: "bubble-not-sent-\(UUID().uuidString)")!)
        ))
        let placeholder = try #require(visionInput())
        #expect(placeholder.outbound == .placeholder)
        let stripped = Self.layOutUserMessageCell(text: "look", attachments: [image], visionInput: placeholder)
        #expect(stripped.notSentToModelCaptionForTesting == InputCapabilityCopy.bubbleNotSentToModel)
        #expect(Self.visibleLabelTexts(in: stripped).contains(InputCapabilityCopy.bubbleNotSentToModel))

        // Text-only message under the same placeholder projection: nothing to mark.
        let textOnly = Self.layOutUserMessageCell(text: "look", visionInput: placeholder)
        #expect(textOnly.notSentToModelCaptionForTesting == nil)
    }

    @Test("Production data source path: placeholder vision projection on the row reaches the user cell caption")
    func userImageBubbleNotSentCaptionThroughDataSource() throws {
        let model = AIModel(
            id: "ds-relay", name: "relay", capabilities: [.text],
            reasoningModeAvailable: false, isAvailable: true, isDefault: true, priceTier: ""
        )
        // Relay without a connection identity: production projection hard-blocks vision to a placeholder.
        let placeholder = try #require(CapabilityEvidenceProductionAdapter.capabilityProjection(
            form: .relay, providerKind: .relay, model: model, identity: nil,
            keys: [CapabilityEvidenceFacade.visionInputKey]
        ).inputProjection(for: CapabilityEvidenceFacade.visionInputKey))
        #expect(placeholder.outbound == .placeholder)
        let withImage = ChatMessage(
            id: UUID(), role: .user, text: "look", reasoningText: nil,
            providerKind: .relay, providerName: "Relay", modelName: "relay",
            estimatedCost: 0, state: .delivered,
            attachments: [Oriveo.Attachment(id: UUID(), kind: .image, fileName: "p.png", mimeType: "image/png")],
            citations: nil
        )
        let textOnly = ChatMessage(
            id: UUID(), role: .user, text: "plain", reasoningText: nil,
            providerKind: .relay, providerName: "Relay", modelName: "relay",
            estimatedCost: 0, state: .delivered, attachments: nil, citations: nil
        )
        let parent = UIViewController()
        let layout = UICollectionViewFlowLayout()
        let collectionView = UICollectionView(
            frame: CGRect(x: 0, y: 0, width: 393, height: 844), collectionViewLayout: layout
        )
        ChatListDataSource.register(on: collectionView)

        func captions(currentVisionInput: CapabilityEvidenceFacade.InputCapabilityProjection?) -> [String?] {
            let rows = ChatCollectionProjectionBuilder.makeRows(
                from: [withImage, textOnly], metadata: .empty, currentVisionInput: currentVisionInput
            )
            let plan = ChatCollectionProjectionBuilder.makeSnapshotPlan(from: rows, providerMetadataVersion: 0)
            let dataSource = ChatListDataSource()
            dataSource.commit(rows: rows, renderModels: plan.renderModelsByID, context: Self.makeRenderContext(parent: parent))
            return (0..<rows.count).map { item in
                (dataSource.collectionView(collectionView, cellForItemAt: IndexPath(item: item, section: 0))
                    as? UserMessageCell)?.notSentToModelCaptionForTesting
            }
        }

        #expect(captions(currentVisionInput: placeholder) == [InputCapabilityCopy.bubbleNotSentToModel, nil])
        #expect(captions(currentVisionInput: nil) == [nil, nil])
    }

    @Test("Assistant footer stays attached to message content in an oversized reused cell")
    func assistantFooterDoesNotStretchToBottomOfOversizedCell() throws {
        let cell = AssistantMessageCell(frame: CGRect(x: 0, y: 0, width: 390, height: 900))
        cell.contentView.frame = cell.bounds

        cell.configure(
            model: Self.makeAssistantModel(
                text: "Short answer.",
                providerName: "OpenRouter",
                modelName: "Xiaomi: MiMo-V2.5",
                estimatedCost: 0.0058
            ),
            parentViewController: UIViewController(),
            onContentHeightDidChange: nil,
            onRetry: {},
            onContinue: nil,
            onSaveNote: {},
            onCrosscheck: {}
        )

        cell.setNeedsLayout()
        cell.layoutIfNeeded()
        cell.contentView.setNeedsLayout()
        cell.contentView.layoutIfNeeded()

        let footerFrame = cell.metadataView.convert(cell.metadataView.bounds, to: cell.contentView)
        #expect(
            footerFrame.maxY < 320,
            "the footer was pulled down to the bottom of the cell, maxY=\(footerFrame.maxY)"
        )

        let attributes = UICollectionViewLayoutAttributes(forCellWith: IndexPath(item: 0, section: 0))
        attributes.frame = cell.bounds
        let preferred = cell.preferredLayoutAttributesFitting(attributes)
        #expect(
            preferred.size.height < 320,
            "cell self-sizing still reports the stale height of the reused cell, height=\(preferred.size.height)"
        )
    }

    @Test("More action uses the Chat localization table instead of default fallback")
    func moreActionUsesChatLocalizationTable() throws {
        let source = try String(contentsOf: Self.assistantMetadataViewSourceURL(), encoding: .utf8)
        #expect(source.contains("moreButton.accessibilityLabel = L10n.tr(\"More\", table: .chat)"))

        let chatStrings = try Self.loadXCStrings(tableName: "Chat")
        #expect(chatStrings["More"] != nil)
    }

    /// The missing state of the token usage popover must use a dedicated "no data" key and must not
    /// reuse `Unavailable`. The two keys mean different things: `Unavailable` says the capability is
    /// not supported, while the token popover only means the upstream did not report the number.
    /// Both directions are pinned here so a future translation pass cannot quietly merge them again.
    @Test("Token usage missing state uses a no-data key, not the capability Unavailable one")
    func tokenUsageMissingStateUsesNoDataKey() throws {
        let source = try String(contentsOf: Self.assistantMetadataViewSourceURL(), encoding: .utf8)
        #expect(
            source.contains("L10n.tr(\"No data\", table: .chat)"),
            "the token usage missing state must use the No data key"
        )
        #expect(
            !source.contains("L10n.tr(\"Unavailable\", table: .chat)"),
            "the token popover must not reuse Unavailable, which means the capability is not supported"
        )

        let chat = try Self.loadXCStrings(tableName: "Chat")
        let expectedLanguages = [
            "ar", "de", "en", "es", "fr", "hi", "id", "ja",
            "ko", "pt-BR", "ru", "th", "tr", "vi", "zh-Hans", "zh-Hant"
        ]

        func localizations(of key: String) throws -> [String: Any] {
            let entry = try #require(chat[key] as? [String: Any], "missing key: \(key)")
            return try #require(entry["localizations"] as? [String: Any])
        }

        func value(_ locs: [String: Any], _ language: String) throws -> String {
            let node = try #require(locs[language] as? [String: Any])
            let unit = try #require(node["stringUnit"] as? [String: Any])
            return try #require(unit["value"] as? String)
        }

        let noData = try localizations(of: "No data")
        for language in expectedLanguages {
            #expect(noData[language] != nil, "No data is missing \(language)")
        }
        // Pin the wording for the locales whose translation has drifted before. The Chinese
        // values are written as escapes so no ideograph appears in this source file.
        #expect(try value(noData, "zh-Hans") == "\u{6682}\u{65E0}")
        #expect(try value(noData, "zh-Hant") == "\u{66AB}\u{7121}")
        #expect(try value(noData, "ru") == "Нет данных")

        // Pin the other side too: the model-controls key must keep its "not supported" wording.
        let unavailable = try localizations(of: "Unavailable")
        #expect(try value(unavailable, "zh-Hans") == "\u{4E0D}\u{53EF}\u{7528}")

        // Subtitle: continuing a reply accumulates usage from several upstream requests onto one
        // message, so the wording must not promise a single request.
        #expect(source.contains("L10n.tr(\"This reply\", table: .chat)"))
        let thisReply = try localizations(of: "This reply")
        for language in expectedLanguages {
            #expect(thisReply[language] != nil, "This reply is missing \(language)")
        }
    }

    /// Token usage is the first action unconditionally inserted into the More menu.
    @Test("More menu always exposes the token usage entry")
    func moreMenuExposesTokenUsageEntry() throws {
        let metadataView = AssistantMetadataView()
        metadataView.configure(
            model: Self.makeAssistantModel(text: "A useful answer."),
            providerName: "OpenAI",
            modelName: "GPT-4o",
            leadingInset: 0,
            onRetry: {},
            onContinue: nil,
            onSaveNote: {},
            onCrosscheck: {}
        )

        let menus = Self.buttonMenus(in: metadataView)
        let menuTitles = menus.flatMap(\.children).compactMap { ($0 as? UIAction)?.title }
        #expect(menuTitles.contains(L10n.tr("Token usage", table: .chat)))
    }

    private static func makeAssistantModel(
        text: String,
        providerName: String = "OpenAI",
        modelName: String = "GPT-4o",
        modelID: String? = nil,
        estimatedCost: Double = 0,
        state: ChatMessageState = .delivered,
        noteReferences: [NoteSummary] = []
    ) -> ChatCollectionProjectionBuilder.MessageRenderModel {
        let message = ChatMessage(
            id: UUID(), role: .assistant, text: text, reasoningText: nil,
            providerKind: .openAI, providerName: providerName, modelID: modelID,
            modelName: modelName,
            estimatedCost: estimatedCost, state: state, attachments: nil, citations: nil
        )
        return ChatCollectionProjectionBuilder.MessageRenderModel(
            messageID: message.id, message: message, presentationKind: .assistant,
            showMetadata: true, resolvedProviderName: providerName, resolvedModelName: modelName,
            relayKind: nil, noteReferences: noteReferences, renderHint: nil, topPadding: 16,
            displayText: nil, textHash: text.hashValue, isStreaming: false, providerMetadataVersion: 0
        )
    }

    private static func makeUserModel(
        text: String, attachments: [Oriveo.Attachment]? = nil
    ) -> ChatCollectionProjectionBuilder.MessageRenderModel {
        let message = ChatMessage(
            id: UUID(), role: .user, text: text, reasoningText: nil,
            providerKind: .openAI, providerName: "OpenAI", modelName: "GPT-4o",
            estimatedCost: 0, state: .delivered, attachments: attachments, citations: nil
        )
        return ChatCollectionProjectionBuilder.MessageRenderModel(
            messageID: message.id, message: message, presentationKind: .user,
            showMetadata: false, resolvedProviderName: nil, resolvedModelName: nil,
            relayKind: nil, renderHint: nil, topPadding: 16,
            displayText: nil, textHash: text.hashValue, isStreaming: false, providerMetadataVersion: 0
        )
    }

    private static func layOutUserMessageCell(
        text: String,
        attachments: [Oriveo.Attachment]? = nil,
        visionInput: CapabilityEvidenceFacade.InputCapabilityProjection? = nil
    ) -> UserMessageCell {
        let cellWidth: CGFloat = 393
        let cell = UserMessageCell(frame: CGRect(x: 0, y: 0, width: cellWidth, height: 100))
        let parent = UIViewController()
        cell.configure(
            model: makeUserModel(text: text, attachments: attachments),
            maxBubbleWidth: 320,
            parentViewController: parent,
            onSaveNote: {},
            onSaveSelection: { _ in },
            visionInput: visionInput
        )
        cell.contentView.frame = CGRect(x: 0, y: 0, width: cellWidth, height: 100)
        let fit = cell.contentView.systemLayoutSizeFitting(
            CGSize(width: cellWidth, height: UIView.layoutFittingCompressedSize.height),
            withHorizontalFittingPriority: .required,
            verticalFittingPriority: .fittingSizeLevel
        )
        cell.frame = CGRect(x: 0, y: 0, width: cellWidth, height: fit.height)
        cell.contentView.frame = cell.bounds
        cell.setNeedsLayout()
        cell.layoutIfNeeded()
        cell.contentView.setNeedsLayout()
        cell.contentView.layoutIfNeeded()
        return cell
    }

    private static func makeRenderContext(parent: UIViewController) -> ChatListDataSource.RenderContext {
        ChatListDataSource.RenderContext(
            parentViewController: parent,
            maxBubbleWidth: 320,
            onRetry: { _ in }, onContinue: { _ in },
            onRegenerate: { _ in }, onEditMessage: { _ in }, onSwitchModel: {},
            isSendingMessage: false,
            isErrorDismissed: { _ in false }, isRecoveryDetailExpanded: { _ in false },
            onDismissError: { _ in }, onToggleRecoveryDetail: { _, _ in },
            streamingMessageID: nil, onConfigureStreamingCell: { _ in }
        )
    }

    private static func repoFixtureURL(_ relativePath: String) throws -> URL {
        var cursor = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        while cursor.path != "/" {
            let candidate = cursor.appendingPathComponent(relativePath)
            if FileManager.default.fileExists(atPath: candidate.path) { return candidate }
            cursor.deleteLastPathComponent()
        }
        throw CocoaError(.fileNoSuchFile)
    }

    private static func visibleButtonTitles(in view: UIView) -> [String] {
        var titles: [String] = []
        if let button = view as? UIButton, !button.isHidden {
            titles.append(contentsOf: buttonTitles(button))
        }
        for subview in view.subviews where !subview.isHidden {
            titles.append(contentsOf: visibleButtonTitles(in: subview))
        }
        return titles
    }

    private static func buttonTitles(_ button: UIButton) -> [String] {
        var titles: [String] = []
        if let title = button.configuration?.title, !title.isEmpty {
            titles.append(title)
        }
        if let title = button.configuration?.attributedTitle, !title.characters.isEmpty {
            titles.append(String(title.characters))
        }
        if let title = button.title(for: .normal), !title.isEmpty {
            titles.append(title)
        }
        if let title = button.accessibilityLabel, !title.isEmpty {
            titles.append(title)
        }
        return titles
    }

    private static func visibleRows(in stackView: UIStackView) -> [UIStackView] {
        stackView.arrangedSubviews.compactMap { $0 as? UIStackView }.filter { !$0.isHidden }
    }

    private static func visibleLabels(in view: UIView) -> [UILabel] {
        var labels: [UILabel] = []
        if let label = view as? UILabel, !label.isHidden {
            labels.append(label)
        }
        for subview in view.subviews where !subview.isHidden {
            labels.append(contentsOf: visibleLabels(in: subview))
        }
        return labels
    }

    private static func visibleLabelTexts(in view: UIView) -> [String] {
        var texts: [String] = []
        if let label = view as? UILabel, !label.isHidden, let text = label.text, !text.isEmpty {
            texts.append(text)
        }
        for subview in view.subviews where !subview.isHidden {
            texts.append(contentsOf: visibleLabelTexts(in: subview))
        }
        return texts
    }

    private static func buttonMenus(in view: UIView) -> [UIMenu] {
        var menus: [UIMenu] = []
        if let button = view as? UIButton, !button.isHidden, let menu = button.menu {
            menus.append(menu)
        }
        for subview in view.subviews where !subview.isHidden {
            menus.append(contentsOf: buttonMenus(in: subview))
        }
        return menus
    }

    private static func visibleButtons(in view: UIView) -> [UIButton] {
        var buttons: [UIButton] = []
        if let button = view as? UIButton, !button.isHidden {
            buttons.append(button)
        }
        for subview in view.subviews where !subview.isHidden {
            buttons.append(contentsOf: visibleButtons(in: subview))
        }
        return buttons
    }

    private static func assistantMetadataViewSourceURL() -> URL {
        let testDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let projectDirectory = testDirectory
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()

        return projectDirectory
            .appendingPathComponent("Oriveo")
            .appendingPathComponent("Features")
            .appendingPathComponent("Chat")
            .appendingPathComponent("Cells")
            .appendingPathComponent("AssistantMetadataView.swift")
    }

    private static func userMessageCellSourceURL() -> URL {
        let testDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let projectDirectory = testDirectory
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()

        return projectDirectory
            .appendingPathComponent("Oriveo")
            .appendingPathComponent("Features")
            .appendingPathComponent("Chat")
            .appendingPathComponent("Cells")
            .appendingPathComponent("UserMessageCell.swift")
    }

    private static func chatListDataSourceURL() -> URL {
        let testDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let projectDirectory = testDirectory
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()

        return projectDirectory
            .appendingPathComponent("Oriveo")
            .appendingPathComponent("Features")
            .appendingPathComponent("Chat")
            .appendingPathComponent("ChatListDataSource.swift")
    }

    private static func sourceBlock(in source: String, from startMarker: String, to endMarker: String) -> String? {
        guard let start = source.range(of: startMarker)?.lowerBound else { return nil }
        let tail = source[start...]
        guard let end = tail.range(of: endMarker)?.lowerBound else { return nil }
        return String(source[start..<end])
    }

    private static func loadXCStrings(tableName: String) throws -> [String: Any] {
        let testDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let projectDirectory = testDirectory
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let url = projectDirectory
            .appendingPathComponent("Oriveo")
            .appendingPathComponent("\(tableName).xcstrings")
        let data = try Data(contentsOf: url)
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        return json["strings"] as! [String: Any]
    }
}
