import SwiftUI

// Shared parts of the grid-style Settings home (cross-platform cases:
// `shared/theme-contracts/settings-home.v1.json`).

/// Grid layout: 4 items 2×2; 3 items 1×3; 2 items 1×2; 1 item fills a whole row; 0 items render nothing.
nonisolated func settingsGridShape(count: Int) -> (columns: Int, rows: Int) {
    switch count {
    case ...0: return (0, 0)
    case 1: return (1, 1)
    case 2: return (2, 1)
    case 3: return (3, 1)
    default: return (2, (count + 1) / 2)
    }
}

/// Opacity of the solid center of the grid line in dark mode: primary @ (0.18 + 0.16 × glowK).
nonisolated func settingsGridLineDarkAlpha(glowK: Double) -> Double {
    0.18 + 0.16 * glowK
}

struct SettingsHomeGridItem: Identifiable {
    /// Icon key (memory / context / ...); also forms `settings_<key>_tile`.
    let key: String
    let title: String
    var value: String? = nil
    /// accessibilityIdentifier of the former list row (kept for UI tests; set on the button, while the outer container carries `_tile`).
    var legacyIdentifier: String? = nil
    var showsFeatureBadge: Bool = false
    /// Explicit icon asset name when it does not match the key derivation (the web search cell key is `webSearch`, icon `SettingsSearch`).
    var iconAssetName: String? = nil
    let action: @MainActor () -> Void

    var id: String { key }
    var iconAsset: String { iconAssetName ?? SettingsHomeIcon.assetName(key) }
    var tileIdentifier: String { "settings_\(key)_tile" }
}

enum SettingsHomeIcon {
    /// `Assets.xcassets/Settings<Key>.imageset` (two-tone SVG shared by light and dark, does not follow the theme color).
    static func assetName(_ key: String) -> String {
        "Settings" + key.prefix(1).uppercased() + key.dropFirst()
    }
}

/// A grid without card backgrounds: tiles are separated only by cross lines pinned at the center and fading out at both ends.
struct SettingsHomeGrid: View {
    enum Style {
        /// AI / Tools & connections: tile height 104, icon 26, name 15 / 600 plus the current value.
        case feature
        /// Help & About: tile height 76, icon 23, name 12.5 / 500 in the secondary color.
        case compact
    }

    let items: [SettingsHomeGridItem]
    var style: Style = .feature

    var body: some View {
        let shape = settingsGridShape(count: items.count)
        if shape.columns > 0 {
            VStack(spacing: 0) {
                ForEach(0..<shape.rows, id: \.self) { row in
                    HStack(spacing: 0) {
                        ForEach(0..<shape.columns, id: \.self) { column in
                            let index = row * shape.columns + column
                            if index < items.count {
                                tile(items[index], columns: shape.columns)
                            } else {
                                Color.clear.frame(maxWidth: .infinity, maxHeight: .infinity)
                            }
                        }
                    }
                }
            }
            .overlay {
                SettingsHomeGridLines(
                    columns: shape.columns,
                    rows: shape.rows,
                    verticalInset: verticalLineInset(shape)
                )
            }
        }
    }

    private var tileHeight: CGFloat { style == .compact ? 76 : 104 }

    private func verticalLineInset(_ shape: (columns: Int, rows: Int)) -> CGFloat {
        if style == .compact { return 16 }
        return shape.rows > 1 ? 10 : 18
    }

    @ViewBuilder
    private func tile(_ item: SettingsHomeGridItem, columns: Int) -> some View {
        let button = Button(action: item.action) {
            tileContent(item)
                .padding(.horizontal, columns >= 3 ? 8 : 14)
                .frame(maxWidth: .infinity)
                .frame(height: tileHeight)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)

        if let legacy = item.legacyIdentifier {
            button
                .accessibilityIdentifier(legacy)
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier(item.tileIdentifier)
        } else {
            button.accessibilityIdentifier(item.tileIdentifier)
        }
    }

    @ViewBuilder
    private func tileContent(_ item: SettingsHomeGridItem) -> some View {
        switch style {
        case .feature:
            VStack(spacing: 0) {
                Image(item.iconAsset)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 26, height: 26)
                    .accessibilityHidden(true)

                HStack(spacing: 5) {
                    Text(item.title)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(OriveoTheme.Palette.textPrimary)
                        // A name that does not fit wraps to a second line (long ja / ru names are not truncated)
                        .lineLimit(2)
                        .multilineTextAlignment(.center)
                        .minimumScaleFactor(0.9)
                    if item.showsFeatureBadge {
                        OriveoFeatureBadgeDot()
                    }
                }
                .padding(.top, 10)

                // With no value this line is not rendered: no placeholder, no "none" text.
                if let value = item.value, !value.isEmpty {
                    Text(value)
                        .font(.system(size: 12))
                        .foregroundStyle(OriveoTheme.Palette.textTertiary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .padding(.top, 3)
                }
            }
        case .compact:
            VStack(spacing: 0) {
                Image(item.iconAsset)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 23, height: 23)
                    .accessibilityHidden(true)

                Text(item.title)
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(OriveoTheme.Palette.textSecondary)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                    .minimumScaleFactor(0.9)
                    .padding(.top, 9)
            }
        }
    }
}

/// Fading cross lines: vertical lines at column boundaries, horizontal lines (multi-row only) at row boundaries, not closed at the edges;
/// the line color goes transparent → solid at the center → transparent.
private struct SettingsHomeGridLines: View {
    let columns: Int
    let rows: Int
    let verticalInset: CGFloat

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.oriveoDarkPalette) private var darkPalette
    @Environment(\.displayScale) private var displayScale

    var body: some View {
        GeometryReader { proxy in
            let size = proxy.size
            let line = 1 / max(displayScale, 1)
            ZStack(alignment: .topLeading) {
                ForEach(1..<max(columns, 1), id: \.self) { column in
                    Rectangle()
                        .fill(fade(.vertical))
                        .frame(width: line, height: max(0, size.height - verticalInset * 2))
                        .position(
                            x: size.width * CGFloat(column) / CGFloat(columns),
                            y: size.height / 2
                        )
                }
                ForEach(1..<max(rows, 1), id: \.self) { row in
                    Rectangle()
                        .fill(fade(.horizontal))
                        .frame(width: max(0, size.width - 12), height: line)
                        .position(
                            x: size.width / 2,
                            y: size.height * CGFloat(row) / CGFloat(rows)
                        )
                }
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private var solid: Color {
        if colorScheme == .dark {
            let palette = darkPalette.palette
            return Color(hex: palette.primary, alpha: settingsGridLineDarkAlpha(glowK: palette.glowK))
        }
        return Color.black.opacity(0.10)
    }

    private func fade(_ axis: Axis) -> LinearGradient {
        LinearGradient(
            stops: [
                .init(color: solid.opacity(0), location: 0),
                .init(color: solid, location: 0.5),
                .init(color: solid.opacity(0), location: 1),
            ],
            startPoint: axis == .vertical ? .top : .leading,
            endPoint: axis == .vertical ? .bottom : .trailing
        )
    }
}

/// Section title: 13 / 600, letter spacing 0.02em, tertiary text color.
struct SettingsHomeSectionHeader: View {
    let title: String

    var body: some View {
        Text(title)
            .font(.system(size: 13, weight: .semibold))
            .tracking(13 * 0.02)
            .foregroundStyle(OriveoTheme.Palette.textTertiary)
            .accessibilityAddTraits(.isHeader)
    }
}

/// General-group list row: height 52, no card background; the hairline is drawn only under the right-hand area, and not on the last row.
struct SettingsHomeListRow: View {
    let key: String
    let title: String
    var value: String? = nil
    /// Theme row: a palette dot before the value (dark mode only).
    var showsPaletteDot: Bool = false
    var isLast: Bool = false
    let action: @MainActor () -> Void

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.oriveoDarkPalette) private var darkPalette
    @Environment(\.displayScale) private var displayScale

    var body: some View {
        Button(action: action) {
            HStack(spacing: 16) {
                Image(SettingsHomeIcon.assetName(key))
                    .resizable()
                    .scaledToFit()
                    .frame(width: 23, height: 23)
                    .accessibilityHidden(true)

                HStack(spacing: 8) {
                    Text(title)
                        .font(.system(size: 15.5, weight: .medium))
                        .foregroundStyle(OriveoTheme.Palette.textPrimary)
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    if showsPaletteDot && colorScheme == .dark {
                        Circle()
                            .fill(
                                LinearGradient(
                                    colors: [
                                        Color(hex: darkPalette.palette.primary),
                                        Color(hex: darkPalette.palette.accent),
                                    ],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                )
                            )
                            .frame(width: 8, height: 8)
                            .accessibilityHidden(true)
                    }

                    if let value, !value.isEmpty {
                        Text(value)
                            .font(.system(size: 14))
                            .foregroundStyle(OriveoTheme.Palette.textTertiary)
                            .lineLimit(1)
                    }

                    Image(systemName: "chevron.forward")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(OriveoTheme.Palette.textTertiary)
                        .accessibilityHidden(true)
                }
                .frame(maxHeight: .infinity)
                .overlay(alignment: .bottom) {
                    if !isLast {
                        Rectangle()
                            .fill(hairline)
                            .frame(height: 1 / max(displayScale, 1))
                    }
                }
            }
            .frame(height: 52)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("settings_\(key)_row")
    }

    private var hairline: Color {
        colorScheme == .dark ? Color.white.opacity(0.07) : Color.black.opacity(0.07)
    }
}

/// Top glow of the Settings home in dark mode: two radial ellipses layered, strength multiplied by the palette glowK; not drawn in light mode.
/// Attached only to the Settings home, on top of `.oriveoScreenBackground()`, without changing the shared background.
struct SettingsHomeTopGlow: View {
    static let height: CGFloat = 440

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.oriveoDarkPalette) private var darkPalette

    var body: some View {
        if colorScheme == .dark {
            let palette = darkPalette.palette
            let k = palette.glowK
            GeometryReader { proxy in
                let width = proxy.size.width
                let height = Self.height
                ZStack {
                    SettingsRadialEllipse(
                        color: Color(hex: palette.primary, alpha: 0.22 * k),
                        center: CGPoint(x: width * 0.12, y: 0),
                        radii: CGSize(width: width * 0.75, height: height * 0.55),
                        fadeStop: 0.70
                    )
                    SettingsRadialEllipse(
                        color: Color(hex: palette.accent, alpha: 0.13 * k),
                        center: CGPoint(x: width * 0.95, y: height * 0.04),
                        radii: CGSize(width: width * 0.60, height: height * 0.45),
                        fadeStop: 0.70
                    )
                }
                .frame(width: width, height: height)
                .clipped()
            }
            .frame(height: Self.height)
            .frame(maxHeight: .infinity, alignment: .top)
            .ignoresSafeArea()
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
    }
}

/// Equivalent of CSS `radial-gradient(ellipse rx ry at cx cy, color 0%, transparent fadeStop)`.
struct SettingsRadialEllipse: View {
    let color: Color
    let center: CGPoint
    let radii: CGSize
    let fadeStop: CGFloat

    var body: some View {
        Rectangle()
            .fill(
                EllipticalGradient(
                    stops: [
                        .init(color: color, location: 0),
                        .init(color: color.opacity(0), location: fadeStop),
                    ],
                    center: .center,
                    startRadiusFraction: 0,
                    endRadiusFraction: 0.5
                )
            )
            .frame(width: radii.width * 2, height: radii.height * 2)
            .position(center)
    }
}
