import Foundation
import OriveoProviderKit
import Testing
import SwiftUI
@testable import Oriveo

/// The context panel's buttons, breaker retry, legend, and copy, plus the values of the settings sheet usage row.
extension ContextVisibilityTests {

    /// The panel opens at the large detent (ring, legend, and limit row visible on one screen), and the medium detent can still be dragged to.
    @Test("context panel opens at the large detent and keeps medium draggable")
    func contextPanelOpensLarge() {
        #expect(ContextUsagePanel.initialDetent == .large)
        #expect(ContextUsagePanel.detents == [.medium, .large])
        #expect(ContextUsagePanel.detents.contains(ContextUsagePanel.initialDetent))
    }

    private static let panelLocales = [
        "ar", "de", "en", "es", "fr", "hi", "id", "ja", "ko", "pt-BR", "ru", "th", "tr", "vi", "zh-Hans", "zh-Hant",
    ]

    /// Production summary path: a single manifest goes through `ContextUsageSummary.make`.
    private static func panelSummary(
        observed: Int?,
        estimated: Int = 40_000,
        B: Int? = 115_200,
        segments: [ContextManifestSegment] = [],
        checkpoint: ContextUsageCheckpoint? = nil,
        createdAt: Int64 = 1_000
    ) -> ContextUsageSummary {
        ContextUsageSummary.make(
            manifests: [panelManifest(observed: observed, estimated: estimated, B: B, segments: segments, createdAt: createdAt)],
            checkpoint: checkpoint
        )
    }

    private static func panelManifest(
        observed: Int?,
        estimated: Int = 40_000,
        B: Int? = 115_200,
        segments: [ContextManifestSegment] = [],
        checkpointId: String? = nil,
        createdAt: Int64 = 1_000
    ) -> ContextManifest {
        ContextManifest(
            requestId: "panel-\(createdAt)",
            conversationId: "conversation",
            purpose: .chat,
            transport: "openai_chat",
            model: "gpt-x",
            W: B == nil ? nil : 128_000,
            O: 4_096,
            B: B,
            basis: .estimated,
            estimatedInput: estimated,
            observedInput: observed,
            segments: segments,
            checkpointId: checkpointId,
            unansweredMerged: 0,
            reminder: false,
            stopReason: .stop,
            createdAt: createdAt
        )
    }

    // MARK: Panel buttons

    @Test func panel_buttons_follow_checkpoint() {
        let fresh = Self.panelSummary(observed: 30_000)
        #expect(fresh.checkpointCount == 0)
        #expect(ContextUsagePanel.buttons(for: fresh) == [.compact])
        #expect(ContextUsagePanel.compactedCountText(for: fresh) == nil)

        let compacted = Self.panelSummary(
            observed: 30_000,
            checkpoint: ContextUsageCheckpoint(count: 3, latestCreatedAt: 500, latestSummaryTokens: 200)
        )
        #expect(compacted.checkpointCount == 3)
        #expect(ContextUsagePanel.buttons(for: compacted) == [.compact, .newChatWithSummary, .clear])

        let english = Locale(identifier: "en_US")
        let now = Date(timeIntervalSince1970: 10_000)
        let text = try? #require(ContextUsagePanel.compactedCountText(for: compacted, now: now, locale: english))
        #expect(text?.contains("3") == true)
        #expect(text?.contains("{") == false)

        // [Compact context] is disabled while compacting or sending; it is always shown regardless of the checkpoint.
        #expect(ContextUsagePanel.isCompactDisabled(isCompacting: false, isSending: false) == false)
        #expect(ContextUsagePanel.isCompactDisabled(isCompacting: true, isSending: false))
        #expect(ContextUsagePanel.isCompactDisabled(isCompacting: false, isSending: true))
    }

    /// [Compact context] is also disabled while an AI summary compaction is in flight (ChatManager writes aiCompactingConversationIDs).
    @Test func panel_compact_disabled_during_ai_compaction() {
        let state = AppState(seedDemoData: false, sessionUID: "context-panel-ai-\(UUID().uuidString)")
        let conversationID = UUID()
        let other = UUID()
        #expect(ContextUsagePanel.isCompactDisabled(
            isCompacting: false, isSending: false,
            aiCompactingIDs: state.aiCompactingConversationIDs, conversationID: conversationID
        ) == false)
        state.aiCompactingConversationIDs.insert(conversationID)
        #expect(ContextUsagePanel.isCompactDisabled(
            isCompacting: false, isSending: false,
            aiCompactingIDs: state.aiCompactingConversationIDs, conversationID: conversationID
        ))
        #expect(ContextUsagePanel.isCompactDisabled(
            isCompacting: false, isSending: false,
            aiCompactingIDs: state.aiCompactingConversationIDs, conversationID: other
        ) == false)
    }

    /// The time in "Compacted N times · time" comes from the summary (createdAt of the latest valid checkpoint); the panel no longer reads the database itself.
    @Test func panel_compacted_time_from_summary() {
        let checkpoint = ContextUsageCheckpoint(count: 2, latestCreatedAt: 600_000, latestSummaryTokens: 100)
        let ringSummary = Self.panelSummary(observed: 30_000, checkpoint: checkpoint, createdAt: 900_000)
        let compactedSince = Self.panelSummary(observed: 30_000, checkpoint: checkpoint, createdAt: 1_000)
        let expected = Date(timeIntervalSince1970: 600)
        #expect(ringSummary.latestCompactedAt == expected)
        #expect(compactedSince.latestCompactedAt == expected)
        #expect(Self.panelSummary(observed: 30_000).latestCompactedAt == nil)

        let english = Locale(identifier: "en_US")
        let now = Date(timeIntervalSince1970: 3_600)
        let text = ContextUsagePanel.compactedCountText(for: ringSummary, now: now, locale: english)
        let relative = RelativeDateTimeFormatter()
        relative.locale = L10n.formattingLocale(english)
        relative.unitsStyle = .full
        relative.dateTimeStyle = .named
        #expect(text?.contains(relative.localizedString(for: expected, relativeTo: now)) == true)
        #expect(ContextUsagePanel.compactedCountText(for: Self.panelSummary(observed: 30_000), locale: english) == nil)
    }

    /// The singular variant does not skip the argument: count=1 still shows "1 time" and carries the time string.
    @Test func compacted_count_singular_formats() throws {
        let checkpoint = ContextUsageCheckpoint(count: 1, latestCreatedAt: 600_000, latestSummaryTokens: 100)
        let summary = Self.panelSummary(observed: 30_000, checkpoint: checkpoint, createdAt: 900_000)
        let english = Locale(identifier: "en_US")
        let now = Date(timeIntervalSince1970: 3_600)
        let text = try #require(ContextUsagePanel.compactedCountText(for: summary, now: now, locale: english))
        let relative = RelativeDateTimeFormatter()
        relative.locale = L10n.formattingLocale(english)
        relative.unitsStyle = .full
        relative.dateTimeStyle = .named
        let time = relative.localizedString(for: Date(timeIntervalSince1970: 600), relativeTo: now)
        #expect(text.contains("1 time"), "\(text)")
        #expect(text.contains(time), "\(text)")
        #expect(!text.contains("%"), "\(text)")
    }

    /// The breaker state goes through ChatManager -> the production coordinator; [Retry] is shown while degraded and recovers after retrying.
    @Test func panel_breaker_retry_shown_when_fallback_only() throws {
        let state = AppState(seedDemoData: false, sessionUID: "context-panel-breaker-\(UUID().uuidString)")
        let conversationID = UUID()
        let chatManager = state.chatManager
        #expect(chatManager.compactionBreakerIsFallbackOnly(conversationId: conversationID) == false)
        #expect(ContextUsagePanel.showsBreakerRetry(isFallbackOnly: false) == false)

        let coordinator = try #require(chatManager.debugCompactionCoordinatorForTesting(uid: state.sessionPartitionUID))
        coordinator.debugSetBreakerForTesting(
            ContextCompactionBreaker(
                failures: ContextCompactionBreaker.failuresToTrip,
                turnsLeft: ContextCompactionBreaker.fallbackTurns
            ),
            conversationId: conversationID.uuidString
        )
        let tripped = chatManager.compactionBreakerIsFallbackOnly(conversationId: conversationID)
        #expect(tripped)
        #expect(ContextUsagePanel.showsBreakerRetry(isFallbackOnly: tripped))

        chatManager.retryCompaction(conversationId: conversationID)
        #expect(chatManager.compactionBreakerIsFallbackOnly(conversationId: conversationID) == false)
        #expect(coordinator.breakerState(conversationId: conversationID.uuidString).mode == .llm)
    }

    @Test func panel_legend_lists_positive_segments() {
        let summary = Self.panelSummary(
            observed: 30_000,
            segments: [
                ContextManifestSegment(kind: .instructions, tokens: 500, omitted: nil),
                ContextManifestSegment(kind: .notes, tokens: 700, omitted: 2),
                ContextManifestSegment(kind: .memory, tokens: 0, omitted: 4),
            ]
        )
        let legend = ContextUsagePanel.legend(for: summary)
        #expect(legend.map(\.segment) == [.conversation, .library, .instructions, .free])
        #expect(legend.first { $0.segment == .library }?.tokens == 700)
        #expect(legend.first { $0.segment == .free }?.tokens == 115_200 - 30_000)
        #expect(ContextUsagePanel.ringSlices(for: summary).map(\.segment) == [.conversation, .library, .instructions])

        // The conversation and free-space rows are always listed (even when 0).
        let full = Self.panelSummary(observed: 120_000)
        #expect(ContextUsagePanel.legend(for: full).map(\.segment) == [.conversation, .free])
        #expect(ContextUsagePanel.legend(for: full).last?.tokens == 0)

        // One row for each omitted category greater than 0.
        #expect(ContextUsagePanel.omittedRows(for: summary).map(\.kind) == [.notes, .memory])
        #expect(ContextUsagePanel.omittedRows(for: summary).map(\.count) == [2, 4])

        // percent / never_observed draw the ring; the rest draw a dashed circle plus a hint.
        #expect(ContextUsagePanel.mode(for: summary) == .ring)
        let neverObserved = Self.panelSummary(observed: nil, estimated: 12_000)
        #expect(neverObserved.reason == .neverObserved)
        #expect(ContextUsagePanel.mode(for: neverObserved) == .ring)
        #expect(ContextUsagePanel.mode(for: Self.panelSummary(observed: nil, B: nil)) == .dashed(hintKey: "context_usage_hint_window_unknown"))
        let compactedSince = Self.panelSummary(
            observed: 30_000,
            checkpoint: ContextUsageCheckpoint(count: 1, latestCreatedAt: 5_000, latestSummaryTokens: 100)
        )
        #expect(ContextUsagePanel.mode(for: compactedSince) == .dashed(hintKey: "context_usage_hint_compacted"))
    }

    // MARK: Cleared compaction and limit changes

    /// After compaction is cleared the latest manifest still points at the deleted checkpoint: the old measured value is void, and until the next send it shows unavailable plus hint_empty.
    @Test func cleared_compaction_shows_unavailable_until_next_send() {
        let compacted = Self.panelManifest(observed: 30_000, checkpointId: "checkpoint-1", createdAt: 1_000)
        let cleared = ContextUsageSummary.make(manifests: [compacted], checkpoint: nil, currentB: 115_200)
        #expect(cleared.display == .unavailable)
        #expect(cleared.reason == .clearedSince)
        #expect(cleared.used == nil)
        #expect(cleared.percent == nil)
        #expect(cleared.segments == nil)
        #expect(cleared.checkpointCount == 0)
        #expect(!ContextUsageRing.isVisible(cleared))
        #expect(ContextUsagePanel.mode(for: cleared) == .dashed(hintKey: "context_usage_hint_empty"))
        #expect(ContextUsagePanel.legend(for: cleared).isEmpty)
        #expect(ContextUsagePanel.settingsUsageValue(cleared, locale: Locale(identifier: "en_US"))
            == L10n.tr("context_usage_unavailable", table: .chat))

        // The checkpoint is still valid: show the measured usage as usual.
        let stillValid = ContextUsageSummary.make(
            manifests: [compacted],
            checkpoint: ContextUsageCheckpoint(count: 1, latestCreatedAt: 500, latestSummaryTokens: 100),
            currentB: 115_200
        )
        #expect(stillValid.display == .percent)
        #expect(stillValid.used == 30_000)

        // The next send writes a new manifest (without checkpointId): the percentage is restored.
        let nextSend = Self.panelManifest(observed: 12_000, createdAt: 2_000)
        let afterSend = ContextUsageSummary.make(manifests: [compacted, nextSend], checkpoint: nil, currentB: 115_200)
        #expect(afterSend.display == .percent)
        #expect(afterSend.used == 12_000)
        #expect(ContextUsageRing.isVisible(afterSend))
    }

    /// Changing the limit: the measured usage is kept and the denominator is recomputed from the current B; an unknown window stays window_unknown.
    @Test func cap_change_recomputes_denominator() {
        let manifest = Self.panelManifest(observed: 30_000, B: 115_200)
        let before = ContextUsageSummary.make(manifests: [manifest], checkpoint: nil, currentB: 115_200)
        #expect(before.B == 115_200)
        #expect(before.percent == 27)

        let after = ContextUsageSummary.make(manifests: [manifest], checkpoint: nil, currentB: 64_000)
        #expect(after.display == .percent)
        #expect(after.used == 30_000)
        #expect(after.B == 64_000)
        #expect(after.percent == 47)
        #expect(after.segments?.free == 64_000 - 30_000)
        #expect(after.ring == ContextUsageSummary.Ring(label: "47", tone: .neutral))

        let unknown = ContextUsageSummary.make(manifests: [manifest], checkpoint: nil, currentB: nil)
        #expect(unknown.display == .unavailable)
        #expect(unknown.reason == .windowUnknown)
        #expect(ContextUsagePanel.mode(for: unknown) == .dashed(hintKey: "context_usage_hint_window_unknown"))
    }

    // MARK: Settings usage row

    @Test func settings_usage_value_text() {
        let english = Locale(identifier: "en_US")
        let measured = Self.panelSummary(observed: 43_776)
        #expect(measured.display == .percent)
        #expect(ContextUsagePanel.settingsUsageValue(measured, locale: english) == "38%")

        let neverObserved = Self.panelSummary(observed: nil, estimated: 12_000)
        let estimatedPercent = try? #require(neverObserved.estimatedPercent)
        #expect(ContextUsagePanel.settingsUsageValue(neverObserved, locale: english) == L10n.format(
            L10n.tr("context_usage_about_percent", table: .chat), locale: english, estimatedPercent ?? -1
        ))

        let unavailable = L10n.tr("context_usage_unavailable", table: .chat)
        #expect(ContextUsagePanel.settingsUsageValue(Self.panelSummary(observed: nil, B: nil), locale: english) == unavailable)
        #expect(ContextUsagePanel.settingsUsageValue(.empty, locale: english) == unavailable)
        #expect(ContextUsagePanel.settingsUsageValue(nil, locale: english) == unavailable)
        #expect(unavailable != "context_usage_unavailable")
    }

    @Test func panel_strings_present_in_16_locales() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let catalog = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: root
            .appendingPathComponent("Oriveo").appendingPathComponent("Chat.xcstrings"))) as? [String: Any])
        let strings = try #require(catalog["strings"] as? [String: Any])
        let plain: [String: [String]] = [
            "context_usage_title": [],
            "context_usage_measured": [],
            "context_usage_estimated": [],
            "context_usage_about_percent": ["%lld"],
            "context_usage_segment_conversation": [],
            "context_usage_segment_library": [],
            "context_usage_segment_summary": [],
            "context_usage_segment_instructions": [],
            "context_usage_segment_memory": [],
            "context_usage_segment_free": [],
            "context_usage_unavailable": [],
            "context_usage_hint_window_unknown": [],
            "context_usage_hint_compacted": [],
            "context_usage_hint_empty": [],
            "context_usage_breaker_paused": [],
            "context_usage_retry": [],
            "context_compaction_action_compact": [],
            "context_compaction_action_new_chat_with_summary": [],
            "context_compaction_action_clear": [],
        ]
        let plural: [String: [String]] = [
            "context_usage_compacted_count": ["%arg", "%2$@"],
            "context_usage_omitted_notes": ["%arg"],
            "context_usage_omitted_knowledge": ["%arg"],
            "context_usage_omitted_memory": ["%arg"],
        ]
        var problems: [String] = []
        func check(_ value: String?, key: String, locale: String, required: [String]) {
            guard let value, !value.isEmpty else {
                problems.append("\(key) [\(locale)] missing")
                return
            }
            for token in required where !value.contains(token) {
                problems.append("\(key) [\(locale)] lacks \(token)")
            }
            if value.contains("{") { problems.append("\(key) [\(locale)] unconverted placeholder") }
        }
        for locale in Self.panelLocales {
            for (key, required) in plain.sorted(by: { $0.key < $1.key }) {
                let localizations = (strings[key] as? [String: Any])?["localizations"] as? [String: Any] ?? [:]
                let unit = (localizations[locale] as? [String: Any])?["stringUnit"] as? [String: Any]
                check(unit?["value"] as? String, key: key, locale: locale, required: required)
            }
            for (key, required) in plural.sorted(by: { $0.key < $1.key }) {
                let localizations = (strings[key] as? [String: Any])?["localizations"] as? [String: Any] ?? [:]
                let localization = localizations[locale] as? [String: Any]
                let root = (localization?["stringUnit"] as? [String: Any])?["value"] as? String
                #expect(root == "%#@count@", "\(key) [\(locale)] root")
                let substitution = (localization?["substitutions"] as? [String: Any])?["count"] as? [String: Any]
                let other = (((substitution?["variations"] as? [String: Any])?["plural"] as? [String: Any])?["other"]
                    as? [String: Any])?["stringUnit"] as? [String: Any]
                check(other?["value"] as? String, key: key, locale: locale, required: required)
            }
        }
        #expect(problems.isEmpty, "\(problems)")

        // The plural variants really resolve by count (production L10n path).
        let english = Locale(identifier: "en_US")
        let omitted = L10n.format(L10n.tr("context_usage_omitted_notes", table: .chat), locale: english, 5)
        #expect(omitted.contains("5"))
        #expect(!omitted.contains("%"))
    }
}
