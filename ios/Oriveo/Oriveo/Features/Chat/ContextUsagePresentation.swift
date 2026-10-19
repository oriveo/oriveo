import Foundation
import OriveoProviderKit
import SwiftUI

/// Latest valid checkpoint as seen by the usage summary.
nonisolated struct ContextUsageCheckpoint: Hashable, Sendable {
    /// Checkpoint rows stored for the conversation.
    var count: Int
    /// Epoch milliseconds of the latest valid checkpoint.
    var latestCreatedAt: Int64
    /// Estimate of the checkpoint text as one message (same estimate as the compaction separator's `after`).
    var latestSummaryTokens: Int
}

/// Context usage summary for the composer ring and the context panel; mirrors `usage.v1.json` summaryCases.
nonisolated struct ContextUsageSummary: Hashable, Sendable {
    enum Display: String, Hashable, Sendable {
        case percent, unavailable, none
    }

    enum Reason: String, Hashable, Sendable {
        case windowUnknown = "window_unknown"
        case neverObserved = "never_observed"
        case compactedSince = "compacted_since"
        case clearedSince = "cleared_since"
    }

    struct Ring: Hashable, Sendable {
        static let overLabel = "!"

        var label: String
        var tone: ContextRingTone
    }

    struct Segments: Hashable, Sendable {
        var conversation: Int
        var library: Int
        var summary: Int
        var instructions: Int
        var memory: Int
        var free: Int
    }

    struct Omitted: Hashable, Sendable {
        var notes: Int
        var knowledge: Int
        var memory: Int
    }

    static let instructionKinds: Set<ContextSegmentKind> = [
        .skill, .instructions, .standingInstructions, .purposeSystem, .toolSafety,
    ]
    static let memoryKinds: Set<ContextSegmentKind> = [.memory]
    static let libraryKinds: Set<ContextSegmentKind> = [.notes, .knowledge]

    var display: Display
    var reason: Reason?
    var percent: Int?
    var estimatedPercent: Int?
    var tone: ContextRingTone?
    var ring: Ring?
    var basis: ContextEstimateBasis?
    var used: Int?
    var B: Int?
    var W: Int?
    var segments: Segments?
    var omitted: Omitted?
    /// Checkpoint rows of the conversation when a valid checkpoint exists, else 0 (panel "compacted N times").
    var checkpointCount: Int = 0
    /// Creation time of the latest valid checkpoint (panel "compacted N times · <time>"); nil without one.
    var latestCompactedAt: Date?

    static let empty = Self(display: .none)

    // MARK: Pure summary

    /// Summary against the budget recorded on the latest manifest (the usage.v1 fixture reading).
    static func make(manifests: [ContextManifest], checkpoint: ContextUsageCheckpoint?) -> Self {
        make(manifests: manifests, checkpoint: checkpoint, currentB: manifests.last?.B)
    }

    /// `manifests` in createdAt order (latest last); `checkpoint` is the latest valid one, if any.
    /// `currentB` is the budget the send path would use now (cap changes apply before the next send);
    /// nil when the window is unknown.
    static func make(manifests: [ContextManifest], checkpoint: ContextUsageCheckpoint?, currentB: Int?) -> Self {
        guard let latest = manifests.last else { return .empty }
        let checkpointCount = checkpoint?.count ?? 0
        let latestCompactedAt = checkpoint.map { Date(timeIntervalSince1970: Double($0.latestCreatedAt) / 1000) }
        if let checkpoint, checkpoint.latestCreatedAt > latest.createdAt {
            return Self(
                display: .unavailable, reason: .compactedSince, B: currentB, W: latest.W,
                checkpointCount: checkpointCount, latestCompactedAt: latestCompactedAt
            )
        }
        // The latest request was built on a checkpoint that is no longer valid (cleared, or its messages
        // were deleted): its measurement is void until the next send records a new manifest.
        if latest.checkpointId != nil, checkpoint == nil {
            return Self(display: .unavailable, reason: .clearedSince, B: currentB, W: latest.W)
        }
        let used = latest.observedInput ?? latest.estimatedInput
        let basis: ContextEstimateBasis = latest.observedInput == nil ? .estimated : .observed
        let omitted = Omitted(
            notes: omittedCount(latest, kind: .notes),
            knowledge: omittedCount(latest, kind: .knowledge),
            memory: omittedCount(latest, kind: .memory)
        )
        guard let B = currentB, B > 0 else {
            return Self(
                display: .unavailable, reason: .windowUnknown, basis: basis, used: used, B: currentB, W: latest.W,
                omitted: omitted, checkpointCount: checkpointCount, latestCompactedAt: latestCompactedAt
            )
        }
        let instructions = tokens(latest, in: instructionKinds)
        let memory = tokens(latest, in: memoryKinds)
        let library = tokens(latest, in: libraryKinds)
        let summaryTokens = checkpoint?.latestSummaryTokens ?? 0
        let segments = Segments(
            conversation: max(0, used - instructions - memory - library - summaryTokens),
            library: library,
            summary: summaryTokens,
            instructions: instructions,
            memory: memory,
            free: max(0, B - used)
        )
        let ringDisplay = ContextBudget.display(
            windowKnown: true,
            pHat: used,
            B: B,
            basis: basis,
            observedEver: manifests.contains { $0.observedInput != nil },
            overflowed: latest.stopReason == .contextWindowExceeded
        )
        var summary = Self(
            display: .unavailable, basis: basis, used: used, B: B, W: latest.W,
            segments: segments, omitted: omitted, checkpointCount: checkpointCount,
            latestCompactedAt: latestCompactedAt
        )
        guard ringDisplay.display == .percent, let percent = ringDisplay.percent, let tone = ringDisplay.tone else {
            summary.reason = ringDisplay.estimatedPercent == nil ? .windowUnknown : .neverObserved
            summary.estimatedPercent = ringDisplay.estimatedPercent
            return summary
        }
        summary.display = .percent
        summary.percent = percent
        summary.tone = tone
        summary.ring = tone == .error || percent >= 100
            ? Ring(label: Ring.overLabel, tone: .error)
            : Ring(label: String(percent), tone: tone)
        return summary
    }

    private static func tokens(_ manifest: ContextManifest, in kinds: Set<ContextSegmentKind>) -> Int {
        manifest.segments.filter { kinds.contains($0.kind) }.reduce(0) { $0 + $1.tokens }
    }

    private static func omittedCount(_ manifest: ContextManifest, kind: ContextSegmentKind) -> Int {
        manifest.segments.filter { $0.kind == kind }.reduce(0) { $0 + ($1.omitted ?? 0) }
    }

    // MARK: Loader

    /// Reads the ledger and checkpoint rows and summarizes them. Blocking store reads: call off the main actor.
    /// `messages` is the conversation's full history, used only to pick the latest valid checkpoint.
    static func load(
        ledger: ContextLedgerStore,
        compaction: ContextCompactionStore,
        conversationId: String,
        messages: [ChatMessage],
        rhoHi: Double
    ) throws -> Self {
        let manifests = try ledger.manifests(conversationId: conversationId)
        guard !manifests.isEmpty else { return .empty }
        let rows = try compaction.list(conversationId: conversationId)
        let checkpoint = try rows.isEmpty
            ? nil
            : checkpointInput(compaction: compaction, conversationId: conversationId, rowCount: rows.count,
                              messages: messages, rhoHi: rhoHi)
        return make(manifests: manifests, checkpoint: checkpoint)
    }

    /// Latest valid checkpoint for the loaded history, with the separator's `after` estimate.
    static func checkpointInput(
        compaction: ContextCompactionStore,
        conversationId: String,
        rowCount: Int,
        messages: [ChatMessage],
        rhoHi: Double
    ) throws -> ContextUsageCheckpoint? {
        let history = messages.map { ContextCheckpoint.CoveredMessage(id: $0.id.uuidString, text: $0.text) }
        guard let latest = try compaction.latestValid(conversationId: conversationId, history: history) else {
            return nil
        }
        return ContextUsageCheckpoint(
            count: rowCount,
            latestCreatedAt: latest.createdAt,
            latestSummaryTokens: ContextBudget.estimateMessage(latest.text, rhoHi: rhoHi)
        )
    }

    /// Summary for the active conversation. Store reads and estimation run off the main actor; the main actor only
    /// hydrates message text (no file payloads) when the conversation has both manifests and checkpoint rows.
    /// Nil without a conversation id, when the stores cannot open, or when the calling task is cancelled.
    @MainActor
    static func current(in appState: AppState, conversationID: UUID?) async -> Self? {
        guard let conversationID,
              let ledger = ContextLedgerStore.forPartition(appState.sessionPartitionUID),
              let compaction = ContextCompactionStore.forPartition(appState.sessionPartitionUID)
        else { return nil }
        let conversationKey = conversationID.uuidString
        let resolvedB = appState.chatManager.currentContextBudget(conversationID: conversationID)
        let stored = await Task.detached(priority: .userInitiated) {
            (
                manifests: (try? ledger.manifests(conversationId: conversationKey)) ?? [],
                rowCount: ((try? compaction.list(conversationId: conversationKey)) ?? []).count
            )
        }.value
        guard !Task.isCancelled else { return nil }
        guard !stored.manifests.isEmpty else { return .empty }
        // When the conversation / connection / model cannot be resolved, do not pass the current B; fall back to the B of the latest ledger record.
        let currentB: Int? = resolvedB ?? stored.manifests.last?.B
        guard stored.rowCount > 0 else {
            return make(manifests: stored.manifests, checkpoint: nil, currentB: currentB)
        }
        guard appState.hydrateConversationMessagesIfNeeded(id: conversationID, hydrateFilePayloads: false),
              let conversation = appState.conversations.first(where: { $0.id == conversationID })
        else { return make(manifests: stored.manifests, checkpoint: nil, currentB: currentB) }
        let messages = conversation.messages
        let rhoHi = appState.chatManager.contextRhoHi(for: conversation)
        let summary = await Task.detached(priority: .userInitiated) {
            let checkpoint = try? checkpointInput(
                compaction: compaction, conversationId: conversationKey, rowCount: stored.rowCount,
                messages: messages, rhoHi: rhoHi
            )
            return make(manifests: stored.manifests, checkpoint: checkpoint, currentB: currentB)
        }.value
        return Task.isCancelled ? nil : summary
    }
}

extension Notification.Name {
    /// A usage-summary input other than messages and checkpoints changed (the conversation cap);
    /// userInfo[ContextCompactionStore.conversationIdKey] is the conversation id.
    nonisolated static let contextUsageInputsDidChange = Notification.Name("ContextUsageSummary.inputsDidChange")
}

/// Usage ring at the trailing end of the composer capability strip.
struct ContextUsageRing: View {
    static let diameter: CGFloat = 28
    private static let lineWidth: CGFloat = 2.5

    let summary: ContextUsageSummary
    let onTap: () -> Void

    /// Shown only when the summary displays a percent.
    nonisolated static func isVisible(_ summary: ContextUsageSummary?) -> Bool {
        summary?.display == .percent && summary?.ring != nil
    }

    @MainActor
    static func accessibilityText(
        for summary: ContextUsageSummary,
        locale: Locale = AppLocalization.currentLocale
    ) -> String {
        guard let ring = summary.ring, ring.label != ContextUsageSummary.Ring.overLabel,
              let percent = summary.percent, let B = summary.B
        else { return L10n.tr("context_usage_ring_over_a11y", table: .chat) }
        return L10n.format(
            L10n.tr("context_usage_ring_a11y", table: .chat),
            locale: locale,
            percent,
            ContextCompactionSeparator.compactCount(B, locale: locale)
        )
    }

    static func color(_ tone: ContextRingTone) -> Color {
        switch tone {
        case .neutral: OriveoTheme.Palette.textSecondary
        case .warm: OriveoTheme.Palette.warning
        case .error: OriveoTheme.Palette.danger
        }
    }

    var body: some View {
        if let ring = summary.ring {
            let tint = Self.color(ring.tone)
            let fraction = min(1, max(0, Double(summary.percent ?? 0) / 100))
            Button { onTap() } label: {
                ZStack {
                    Circle()
                        .stroke(tint.opacity(0.22), lineWidth: Self.lineWidth)
                    Circle()
                        .trim(from: 0, to: ring.label == ContextUsageSummary.Ring.overLabel ? 1 : fraction)
                        .stroke(tint, style: StrokeStyle(lineWidth: Self.lineWidth, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                    Text(ring.label)
                        .font(.system(size: 10, weight: .semibold, design: .monospaced))
                        .foregroundStyle(tint)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                }
                .padding(Self.lineWidth / 2)
                .frame(width: Self.diameter, height: Self.diameter)
                .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text(Self.accessibilityText(for: summary)))
        }
    }
}
