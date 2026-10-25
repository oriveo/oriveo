import SwiftUI

// MARK: - Animation State Types

struct ProviderModelAddFeedbackState: Identifiable {
    let id: UUID = UUID()
    let model: AIModel
    var position: CGPoint
    var scale: CGFloat
    var opacity: Double
}

struct ProviderModelRemovalBannerState: Identifiable {
    let id: UUID = UUID()
    let providerID: UUID
    let model: AIModel
    let shouldRestoreDefault: Bool
}

// MARK: - Animation Views

struct ProviderModelAddFeedbackChip: View {
    let model: AIModel

    var body: some View {
        HStack(spacing: OriveoTheme.Spacing.sm) {
            ModelVendorIcon(model: model, size: 22)

            Text(model.name)
                .font(OriveoTheme.Typography.footnote.weight(.semibold))
                .foregroundStyle(OriveoTheme.Palette.textPrimary)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: 150, alignment: .leading)

            Image(systemName: "plus")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(OriveoTheme.Palette.primary)
                .frame(width: 18, height: 18)
                .background(
                    Circle()
                        .fill(OriveoTheme.Palette.primarySoft)
                )
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            Capsule(style: .continuous)
                .fill(OriveoTheme.Palette.surfaceElevated)
        )
        .overlay(
            Capsule(style: .continuous)
                .stroke(OriveoTheme.Palette.primary.opacity(0.16), lineWidth: 1)
        )
        .shadow(color: OriveoTheme.Palette.primary.opacity(0.08), radius: 18, x: 0, y: 8)
        .fixedSize(horizontal: true, vertical: true)
    }
}

// MARK: - Frame Capture

/// The fly-in animation needs a geometry value only once, at the moment "+" is pressed.
///
/// A reference box instead of `@State`: `onGeometryChange` fires every frame while scrolling, and writing `@State` would
/// recompute the whole page body. The old approach was heavier: one `GeometryReader` per catalog row writing a preference,
/// merged into a dictionary in O(N) along the way and landed in `ProviderDetailView`'s `@State`, so every scroll frame
/// rebuilt all catalog rows (on pop, destroying that huge view list recursively went past the watchdog).
final class ProviderDetailFrameBox {
    /// The added section shares one lazy stack with the outer scroll axis: the section is no longer a single view and has
    /// no overall frame, so the header and each row record one slot each and reads take the union.
    private var framesByID: [String: CGRect] = [:]
    /// Fragments that have disappeared: excluded from the union but keeping their last frame. When a push moves away and
    /// a pop comes back the frame is unchanged, `onGeometryChange` does not fire again, and only onAppear brings that slot back in.
    private var inactiveIDs: Set<String> = []

    /// The union of the frames of the section fragments currently in the tree; `.null` when there is not a single slot.
    var frame: CGRect {
        framesByID.reduce(CGRect.null) { union, entry in
            inactiveIDs.contains(entry.key) ? union : union.union(entry.value)
        }
    }

    func record(_ frame: CGRect, for id: String) {
        guard framesByID[id] != frame else { return }
        framesByID[id] = frame
        #if DEBUG
        Self.debugFrameChangeCount += 1
        #endif
    }

    /// The fragment left the view tree (recycled by the lazy stack or covered by a push): only mark it inactive and keep its frame.
    func deactivate(_ id: String) {
        inactiveIDs.insert(id)
    }

    /// The fragment is back in the view tree: count it in the union again.
    func activate(_ id: String) {
        inactiveIDs.remove(id)
    }

    #if DEBUG
    /// DEBUG only: how often the frames of the added section's fragments actually changed. If fragments outside the viewport keep changing,
    /// the outer container is still laying out off-screen sections.
    nonisolated(unsafe) static var debugFrameChangeCount = 0

    /// DEBUG only: the added-section union read at the last "+" press, and whether the fly-in ended at it (otherwise the start-point-up fallback is used).
    struct DebugAddTarget {
        let enabledModelsFrame: CGRect
        let usesEnabledTarget: Bool
        /// The ids of the fragments counted in the union and their frames.
        let activeFragments: [String: CGRect]
    }

    var debugActiveFragments: [String: CGRect] {
        framesByID.filter { !inactiveIDs.contains($0.key) }
    }

    nonisolated(unsafe) static var debugLastAddTarget: DebugAddTarget?
    #endif
}

final class CatalogRowFrameStore {
    private var framesByModelID: [String: CGRect] = [:]

    func record(_ frame: CGRect, for modelID: String) {
        framesByModelID[modelID] = frame
    }

    func frame(for modelID: String) -> CGRect {
        framesByModelID[modelID] ?? .null
    }
}

extension CGRect {
    func isVisible(in viewport: CGRect) -> Bool {
        guard !isNull, !isEmpty else { return false }
        return intersects(viewport.insetBy(dx: 0, dy: -24))
    }
}
