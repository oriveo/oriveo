import Foundation
import OriveoProviderKit
import Testing
import UIKit
@testable import Oriveo

/// The incomplete / filtered answer notice row and [Continue generating], matching the stop-reason.v1 ui.
extension ContextVisibilityTests {

    private static let noticeLocales = [
        "ar", "de", "en", "es", "fr", "hi", "id", "ja", "ko", "pt-BR", "ru", "th", "tr", "vi", "zh-Hans", "zh-Hant",
    ]

    private static func stopReasonUI() throws -> [String: Any] {
        var cursor = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        while cursor.path != "/" {
            let candidate = cursor.appendingPathComponent("shared/context-contracts/stop-reason.v1.json")
            if FileManager.default.fileExists(atPath: candidate.path) {
                let object = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: candidate)) as? [String: Any])
                return try #require(object["ui"] as? [String: Any])
            }
            cursor.deleteLastPathComponent()
        }
        throw CocoaError(.fileNoSuchFile)
    }

    private static func noticeModel(
        stopReason: StopReason?,
        state: ChatMessageState = .delivered,
        isLast: Bool,
        isStreaming: Bool = false
    ) -> ChatCollectionProjectionBuilder.MessageRenderModel {
        let message = ChatMessage(
            id: UUID(), role: .assistant, text: "partial reply",
            providerKind: .openAI, providerName: "OpenAI", modelName: "GPT-4o",
            state: state,
            stopReason: stopReason
        )
        return ChatCollectionProjectionBuilder.MessageRenderModel(
            messageID: message.id, message: message, presentationKind: .assistant,
            showMetadata: true, resolvedProviderName: "OpenAI", resolvedModelName: "GPT-4o",
            relayKind: nil, renderHint: nil, topPadding: 16,
            displayText: nil, textHash: message.text.hashValue, isStreaming: isStreaming,
            providerMetadataVersion: 0,
            isLastInConversation: isLast
        )
    }

    private static func configuredMetadataView(
        _ model: ChatCollectionProjectionBuilder.MessageRenderModel
    ) -> AssistantMetadataView {
        let view = AssistantMetadataView()
        view.configure(
            model: model,
            providerName: "OpenAI", modelName: "GPT-4o", leadingInset: 0,
            onRetry: nil, onContinue: { /* no-op */ }
        )
        return view
    }

    private static func child<T>(_ label: String, in view: AssistantMetadataView) -> T? {
        Mirror(reflecting: view).children.first { $0.label == label }?.value as? T
    }

    @Test func reply_notice_follows_stop_reason_fixture() throws {
        let ui = try Self.stopReasonUI()
        #expect(Set(ui.keys) == Set(StopReason.allCases.map(\.rawValue)))
        for reason in StopReason.allCases {
            let presentation = ReplyNoticePresentation.make(
                stopReason: reason,
                isLastAssistant: true,
                isStreaming: false,
                hasRecoveryCard: false
            )
            if let entry = ui[reason.rawValue] as? [String: Any] {
                let notice = try #require(entry["notice"] as? String)
                let continueAction = try #require(entry["continueAction"] as? Bool)
                #expect(presentation?.titleKey == "reply_" + notice, "\(reason)")
                #expect(presentation?.showsContinue == continueAction, "\(reason)")
            } else {
                #expect(presentation == nil, "\(reason)")
            }
        }
        #expect(ReplyNoticePresentation.make(stopReason: nil, isLastAssistant: true, isStreaming: false, hasRecoveryCard: false) == nil)
        #expect(ReplyNoticePresentation.make(stopReason: .contentFilter, isLastAssistant: true, isStreaming: false, hasRecoveryCard: false)?.tone == .secondary)
        #expect(ReplyNoticePresentation.make(stopReason: .length, isLastAssistant: true, isStreaming: false, hasRecoveryCard: false)?.tone == .warning)

        // Production view: the notice row text comes from localization and never falls back to the raw key.
        let view = Self.configuredMetadataView(Self.noticeModel(stopReason: .length, isLast: true))
        let label: UILabel? = Self.child("replyNoticeLabel", in: view)
        #expect(label?.text == L10n.tr("reply_incomplete_output_limit", table: .chat))
        #expect(label?.text != "reply_incomplete_output_limit")
        let row: UIView? = Self.child("replyNoticeRow", in: view)
        #expect(row?.isHidden == false)
    }

    @Test func reply_continue_only_on_last_assistant() {
        for reason in [StopReason.length, .incomplete] {
            let last = ReplyNoticePresentation.make(stopReason: reason, isLastAssistant: true, isStreaming: false, hasRecoveryCard: false)
            let earlier = ReplyNoticePresentation.make(stopReason: reason, isLastAssistant: false, isStreaming: false, hasRecoveryCard: false)
            #expect(last?.showsContinue == true)
            #expect(earlier != nil)
            #expect(earlier?.showsContinue == false)
        }

        let lastView = Self.configuredMetadataView(Self.noticeModel(stopReason: .incomplete, isLast: true))
        let lastButton: UIButton? = Self.child("continueButton", in: lastView)
        #expect(lastButton?.isHidden == false)

        let earlierView = Self.configuredMetadataView(Self.noticeModel(stopReason: .incomplete, isLast: false))
        let earlierButton: UIButton? = Self.child("continueButton", in: earlierView)
        let earlierRow: UIView? = Self.child("replyNoticeRow", in: earlierView)
        #expect(earlierButton?.isHidden == true)
        #expect(earlierRow?.isHidden == false)

        let filteredView = Self.configuredMetadataView(Self.noticeModel(stopReason: .contentFilter, isLast: true))
        let filteredButton: UIButton? = Self.child("continueButton", in: filteredView)
        #expect(filteredButton?.isHidden == true)
    }

    @Test func reply_notice_hidden_when_recovery_card_or_streaming() {
        #expect(ReplyNoticePresentation.make(stopReason: .length, isLastAssistant: true, isStreaming: true, hasRecoveryCard: false) == nil)
        #expect(ReplyNoticePresentation.make(stopReason: .incomplete, isLastAssistant: true, isStreaming: false, hasRecoveryCard: true) == nil)

        let streaming = Self.configuredMetadataView(Self.noticeModel(stopReason: .length, state: .generating, isLast: true, isStreaming: true))
        let streamingRow: UIView? = Self.child("replyNoticeRow", in: streaming)
        #expect(streamingRow?.isHidden == true)

        // A failed last message goes through RecoveryCard and no longer stacks a notice row.
        let failed = Self.configuredMetadataView(Self.noticeModel(stopReason: .incomplete, state: .failed, isLast: true))
        let failedRow: UIView? = Self.child("replyNoticeRow", in: failed)
        let failedButton: UIButton? = Self.child("continueButton", in: failed)
        #expect(failedRow?.isHidden == true)
        #expect(failedButton?.isHidden == true)

        // Cleared on reuse.
        let reused = Self.configuredMetadataView(Self.noticeModel(stopReason: .length, isLast: true))
        reused.resetForReuse()
        let reusedRow: UIView? = Self.child("replyNoticeRow", in: reused)
        #expect(reusedRow?.isHidden == true)
    }

    /// An interrupted last message likewise goes through RecoveryCard (continue generating) and does not stack a notice row.
    @Test func reply_notice_hidden_when_interrupted_recovery() {
        let interrupted = Self.configuredMetadataView(Self.noticeModel(stopReason: .incomplete, state: .interrupted, isLast: true))
        let row: UIView? = Self.child("replyNoticeRow", in: interrupted)
        #expect(row?.isHidden == true)

        // An interrupted message that is not last has no RecoveryCard, so the notice row is shown as usual.
        let earlier = Self.configuredMetadataView(Self.noticeModel(stopReason: .incomplete, state: .interrupted, isLast: false))
        let earlierRow: UIView? = Self.child("replyNoticeRow", in: earlier)
        #expect(earlierRow?.isHidden == false)
    }

    @Test func reply_strings_present_in_16_locales() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let catalog = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: root
            .appendingPathComponent("Oriveo").appendingPathComponent("Chat.xcstrings"))) as? [String: Any])
        let strings = try #require(catalog["strings"] as? [String: Any])
        let keys = ["reply_incomplete_output_limit", "reply_incomplete_connection", "reply_filtered", "reply_context_overflow", "Continue Generating"]
        for locale in Self.noticeLocales {
            for key in keys {
                let localizations = (strings[key] as? [String: Any])?["localizations"] as? [String: Any] ?? [:]
                let unit = (localizations[locale] as? [String: Any])?["stringUnit"] as? [String: Any]
                let value = unit?["value"] as? String
                #expect(value?.isEmpty == false, "\(key) missing in \(locale)")
                #expect(value?.hasPrefix("reply_") != true, "\(key) untranslated in \(locale)")
            }
        }
    }
}
