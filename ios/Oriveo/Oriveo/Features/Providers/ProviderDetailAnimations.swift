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

struct ProviderModelRemovalBanner: View {
    let model: AIModel
    var undoAction: () -> Void

    var body: some View {
        HStack(spacing: OriveoTheme.Spacing.md) {
            Image(systemName: "minus.circle.fill")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(OriveoTheme.Palette.warning)

            Text(String(format: L10n.tr("Removed %@", table: .providers), model.name))
                .font(OriveoTheme.Typography.caption)
                .foregroundStyle(OriveoTheme.Palette.textPrimary)
                .lineLimit(1)

            Spacer(minLength: OriveoTheme.Spacing.md)

            Button(L10n.tr("Undo", table: .providers), action: undoAction)
                .buttonStyle(OriveoTextButtonStyle())
        }
        .padding(.horizontal, OriveoTheme.Spacing.lg)
        .padding(.vertical, OriveoTheme.Spacing.md)
        .oriveoRoundedSurface(
            fill: OriveoTheme.Palette.surfaceElevated,
            border: OriveoTheme.Palette.borderStrong,
            radius: OriveoTheme.Radius.md
        )
        .shadow(color: OriveoTheme.Palette.shadow, radius: 18, x: 0, y: 10)
    }
}

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

final class ProviderDetailFrameBox {
    var frame: CGRect = .null
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
