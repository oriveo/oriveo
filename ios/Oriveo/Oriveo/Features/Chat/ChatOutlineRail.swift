import Foundation
import SwiftUI
import UIKit


nonisolated struct OutlineTick: Identifiable, Equatable {
    let id: UUID
    let preview: String
}

nonisolated enum ChatOutline {
    static let minUserTurns = 3

    static func resolvedActiveID(
        firstID: UUID?,
        lastID: UUID?,
        focusID: UUID?,
        atConversationStart: Bool,
        atConversationEnd: Bool
    ) -> UUID? {
        if atConversationEnd { return lastID ?? focusID ?? firstID }
        if atConversationStart { return firstID ?? focusID ?? lastID }
        return focusID ?? firstID ?? lastID
    }

    static func ticks(from messages: [ChatMessage], attachmentLabel: String) -> [OutlineTick] {
        messages.compactMap { message in
            guard message.role == .user else { return nil }
            return OutlineTick(id: message.id, preview: preview(of: message, attachmentLabel: attachmentLabel))
        }
    }

    static func preview(of message: ChatMessage, attachmentLabel: String) -> String {
        let firstLine = message.text.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false)
            .first.map(String.init) ?? ""
        let collapsed = firstLine
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
        if !collapsed.isEmpty { return collapsed }
        if let attachments = message.attachments, !attachments.isEmpty { return attachmentLabel }
        return attachmentLabel
    }

    static func clampPreview(_ preview: String, maxChars: Int) -> String {
        guard preview.count > maxChars else { return preview }
        let prefix = String(preview.prefix(maxChars)).trimmingCharacters(in: .whitespaces)
        return prefix + "…"
    }

    static func visibleRange(totalCount: Int, currentIndex: Int, capacity: Int) -> Range<Int> {
        guard totalCount > 0 else { return 0..<0 }
        guard capacity > 0, totalCount > capacity else { return 0..<totalCount }
        let cur = currentIndex >= 0 ? min(currentIndex, totalCount - 1) : totalCount - 1
        let pageFromEnd = (totalCount - 1 - cur) / capacity
        let end = totalCount - pageFromEnd * capacity
        return max(0, end - capacity)..<end
    }

    static func tickFadeOpacity(index: Int, count: Int, topFaded: Bool, bottomFaded: Bool, exempt: Bool) -> Double {
        if exempt { return 1 }
        if topFaded && index < 2 { return index == 0 ? 0.15 : 0.55 }
        if bottomFaded && index >= count - 2 { return index == count - 1 ? 0.15 : 0.55 }
        return 1
    }
}


@MainActor
@Observable
final class ChatOutlineState {
    var currentUserMessageID: UUID?
}


struct ChatOutlineRail: View {
    let ticks: [OutlineTick]
    let outlineState: ChatOutlineState
    let onJumpTo: (UUID) -> Void

    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var active = false
    @State private var pointedIndex: Int?
    @State private var collapseTask: Task<Void, Never>?
    @State private var isScrubbing = false
    @State private var frozenRange: Range<Int>?
    @State private var selectionFeedback = UISelectionFeedbackGenerator()

    private var isBar: Bool { sizeClass == .regular }
    private var railWidth: CGFloat { isBar ? 28 : 44 }
    private var rightMargin: CGFloat { isBar ? 8 : 6 }
    private var defaultRowH: CGFloat { isBar ? 14 : 12 }
    private var maxChars: Int { isBar ? 48 : 24 }
    private var tooltipMaxWidth: CGFloat { isBar ? 320 : 220 }

    private var currentTickIndex: Int {
        guard let id = outlineState.currentUserMessageID else { return -1 }
        return ticks.firstIndex { $0.id == id } ?? -1
    }

    var body: some View {
        GeometryReader { geo in
            let rowH = defaultRowH
            let capacity = railCapacity(available: geo.size.height)
            let range = frozenRange ?? ChatOutline.visibleRange(
                totalCount: ticks.count,
                currentIndex: currentTickIndex,
                capacity: capacity
            )
            let windowTicks = Array(ticks[range.clamped(to: 0..<ticks.count)])
            ZStack(alignment: .trailing) {
                VStack(spacing: 0) {
                    ForEach(Array(windowTicks.enumerated()), id: \.element.id) { index, tick in
                        tickRow(
                            index: index,
                            tick: tick,
                            rowH: rowH,
                            windowCount: windowTicks.count,
                            topFaded: range.lowerBound > 0,
                            bottomFaded: range.upperBound < ticks.count
                        )
                    }
                }
                .frame(width: railWidth)
                .padding(.trailing, rightMargin)
                .contentShape(Rectangle())
                .onContinuousHover(coordinateSpace: .local) { phase in
                    switch phase {
                    case .active(let location):
                        cancelCollapse()
                        if frozenRange == nil { frozenRange = range }
                        withAnimation(motionAnimation) { active = true }
                        pointedIndex = indexAt(location.y, rowH: rowH, count: windowTicks.count)
                    case .ended:
                        scheduleCollapse()
                    }
                }
                .gesture(
                    DragGesture(minimumDistance: 0, coordinateSpace: .local)
                        .onChanged { value in
                            cancelCollapse()
                            if frozenRange == nil { frozenRange = range }
                            if !active { selectionFeedback.prepare() }
                            withAnimation(motionAnimation) { active = true }
                            if abs(value.translation.height) > 8 || abs(value.translation.width) > 8 {
                                isScrubbing = true
                            }
                            let idx = indexAt(value.location.y, rowH: rowH, count: windowTicks.count)
                            guard idx != pointedIndex else { return }
                            pointedIndex = idx
                            if isScrubbing, idx >= 0, idx < windowTicks.count {
                                selectionFeedback.selectionChanged()
                                selectionFeedback.prepare()
                                jump(windowTicks[idx].id)
                            }
                        }
                        .onEnded { value in
                            let moved = isScrubbing
                                || abs(value.translation.height) > 8
                                || abs(value.translation.width) > 8
                            if let idx = pointedIndex, idx >= 0, idx < windowTicks.count {
                                if !moved { UIImpactFeedbackGenerator(style: .light).impactOccurred() }
                                jump(windowTicks[idx].id)
                            }
                            isScrubbing = false
                            scheduleCollapse()
                        }
                )

                if active, let idx = pointedIndex, idx >= 0, idx < windowTicks.count {
                    tooltip(text: windowTicks[idx].preview)
                        .padding(.trailing, railWidth + rightMargin + 6)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing)
                        .offset(y: tooltipOffsetY(index: idx, rowH: rowH, count: windowTicks.count))
                        .allowsHitTesting(false)
                        .transition(.opacity)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(L10n.tr("Conversation outline", table: .chat))
        .onChange(of: ticks.count) {
            frozenRange = nil
        }
    }

    @ViewBuilder
    private func tickRow(
        index: Int,
        tick: OutlineTick,
        rowH: CGFloat,
        windowCount: Int,
        topFaded: Bool,
        bottomFaded: Bool
    ) -> some View {
        let isCurrent = tick.id == outlineState.currentUserMessageID
        let isPointed = active && pointedIndex == index
        let size = tickSize(isCurrent: isCurrent, isPointed: isPointed)
        let fade = ChatOutline.tickFadeOpacity(
            index: index,
            count: windowCount,
            topFaded: topFaded,
            bottomFaded: bottomFaded,
            exempt: isCurrent || isPointed
        )

        ZStack(alignment: .trailing) {
            Capsule(style: .continuous)
                .fill(tickColor(isCurrent: isCurrent, isPointed: isPointed))
                .frame(width: size.width, height: size.height)
                .animation(motionAnimation, value: size)
                .animation(motionAnimation, value: isCurrent)
        }
        .opacity(fade)
        .frame(width: railWidth, height: rowH, alignment: .trailing)
        .contentShape(Rectangle())
        .accessibilityElement()
        .accessibilityLabel(String(format: L10n.tr("Jump to: %@", table: .chat), tick.preview))
        .accessibilityAddTraits(isCurrent ? [.isButton, .isSelected] : .isButton)
        .accessibilityAction { jump(tick.id) }
    }

    private func jump(_ id: UUID) {
        outlineState.currentUserMessageID = id
        onJumpTo(id)
    }

    private func tooltip(text: String) -> some View {
        Text(ChatOutline.clampPreview(text, maxChars: maxChars))
            .font(OriveoTheme.Typography.footnote.weight(.medium))
            .foregroundStyle(Color.white)
            .lineLimit(1)
            .truncationMode(.tail)
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .frame(maxWidth: tooltipMaxWidth, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Self.tooltipFill)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.08), lineWidth: 0.5)
            )
            .shadow(color: Color.black.opacity(0.28), radius: 12, y: 4)
    }

    private static let tooltipFill = Color(red: 0.12, green: 0.13, blue: 0.17)

    private func tooltipOffsetY(index: Int, rowH: CGFloat, count: Int) -> CGFloat {
        CGFloat(index) * rowH + rowH / 2 - CGFloat(count) * rowH / 2
    }

    private var motionAnimation: Animation? {
        reduceMotion ? nil : .easeOut(duration: 0.18)
    }

    private func tickColor(isCurrent: Bool, isPointed: Bool) -> Color {
        if isCurrent || isPointed { return OriveoTheme.Palette.primary }
        if active { return OriveoTheme.Palette.textSecondary }
        return OriveoTheme.Palette.textTertiary.opacity(0.55)
    }

    private func tickSize(isCurrent: Bool, isPointed: Bool) -> CGSize {
        if isBar {
            if isCurrent || isPointed { return CGSize(width: 22, height: 2.5) }
            if active { return CGSize(width: 18, height: 2) }
            return CGSize(width: 16, height: 2)
        } else {
            if isCurrent || isPointed { return CGSize(width: 7, height: 7) }
            if active { return CGSize(width: 6, height: 6) }
            return CGSize(width: 5, height: 5)
        }
    }

    private func railCapacity(available: CGFloat) -> Int {
        max(1, Int(max(0, available * 0.62) / defaultRowH))
    }

    private func indexAt(_ y: CGFloat, rowH: CGFloat, count: Int) -> Int {
        guard rowH > 0, count > 0 else { return 0 }
        let idx = Int(y / rowH)
        return min(max(idx, 0), count - 1)
    }

    private func scheduleCollapse() {
        collapseTask?.cancel()
        collapseTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 600_000_000)
            if Task.isCancelled { return }
            withAnimation(reduceMotion ? nil : .easeOut(duration: 0.2)) {
                active = false
                pointedIndex = nil
            }
            frozenRange = nil
        }
    }

    private func cancelCollapse() {
        collapseTask?.cancel()
        collapseTask = nil
    }
}
