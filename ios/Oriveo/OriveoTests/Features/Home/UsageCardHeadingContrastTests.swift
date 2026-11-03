import Foundation
import SwiftUI
import Testing
import UIKit
@testable import Oriveo

/// Usage cards draw the card sheen (`Palette.cardSheen`, white 7/255 in dark) over `surface`.
/// Must-read headings on those cards use `textSecondary`, checked against the composited background.
@MainActor
@Suite("Usage card heading contrast")
struct UsageCardHeadingContrastTests {
    private static func rgba(_ color: Color, _ style: ColorScheme) -> (hex: UInt, alpha: Double) {
        var env = EnvironmentValues()
        env.colorScheme = style
        env.oriveoDarkPalette = .preset(.darkForest)
        let resolved = UIColor(cgColor: color.resolve(in: env).cgColor)
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        resolved.getRed(&r, green: &g, blue: &b, alpha: &a)
        let hex = (UInt((r * 255).rounded()) << 16) | (UInt((g * 255).rounded()) << 8) | UInt((b * 255).rounded())
        return (hex, Double(a))
    }

    @Test("textSecondary meets 4.5:1 over surface + dark card sheen for every dark palette")
    func secondaryMeetsContrastOverHighlight() {
        let sheen = Self.rgba(OriveoTheme.Palette.cardSheen, .dark)
        #expect(sheen.hex == 0xFFFFFF)
        for id in OriveoDarkPaletteID.allCases {
            let palette = id.palette
            let background = Self.composite(white: sheen.alpha, over: palette.surface)
            let ratio = OriveoCustomPalette.contrast(palette.textSecondary, background)
            #expect(ratio >= 4.5, "\(id.rawValue): textSecondary over highlighted surface is \(ratio):1")
        }
    }

    @Test("Heading anchors in the three usage cards use textSecondary")
    func headingAnchorsUseSecondary() throws {
        let expectations: [(file: String, start: String, end: String)] = [
            ("BudgetCenterCard.swift", "Text(L10n.tr(\"Monthly budget\", table: .usageInsights))", "Spacer()"),
            ("CostCompositionCard.swift", "private var eyebrowColor: Color {", "return ProviderTints.textTint"),
            ("CostStoryHeroCard.swift", "Text(granularity.heroCaption)", ".font(OriveoTheme.Typography.caption"),
            ("CostStoryHeroCard.swift", "private var deltaCaptionText: some View {", "}"),
        ]
        for item in expectations {
            let source = try Self.source(item.file)
            let slice = try #require(source.slice(from: item.start, to: item.end), "\(item.file): anchor not found")
            #expect(!slice.contains("textTertiary"), "\(item.file): heading still uses textTertiary")
            #expect(slice.contains("textSecondary"), "\(item.file): heading does not use textSecondary")
        }
    }

    /// Over-budget amounts, percentages and alert copy use `dangerText` (no large-text exemption);
    /// icons, progress fills and accent bars keep `danger`.
    @Test("Over-budget text in usage cards uses dangerText while fills keep danger")
    func overBudgetTextUsesDangerText() throws {
        let textSlices: [(file: String, start: String, end: String)] = [
            ("BudgetCenterCard.swift", "let statusColor: Color = isOver", ": isWarning"),
            ("BudgetCenterCard.swift", "let percentColor = isOver", ": (isWarning"),
            ("BudgetCenterCard.swift", "let amountColor = isOver", ": OriveoTheme.Palette.textPrimary"),
            ("BudgetCenterCard.swift", "private func progressColor(ratio: Double) -> Color {", "Palette.warning"),
            ("CostStoryHeroCard.swift", "private func forecastTextColor(forecast: UsageForecast) -> Color {", "case .approaching"),
        ]
        for item in textSlices {
            let source = try Self.source(item.file)
            let slice = try #require(source.slice(from: item.start, to: item.end), "\(item.file): anchor not found: \(item.start)")
            #expect(slice.contains("Palette.dangerText"), "\(item.file): over-budget text does not use dangerText: \(item.start)")
        }

        let hero = try Self.source("CostStoryHeroCard.swift")
        let alertText = try #require(
            hero.slice(from: "Text(forecastAlertCompactText(forecast: forecast))", to: ".lineLimit(1)"),
            "CostStoryHeroCard.swift: alert text anchor not found"
        )
        #expect(alertText.contains(".foregroundStyle(textColor)"), "alert text must use the dangerText-aware color")

        let fillSlices: [(file: String, start: String, end: String)] = [
            ("BudgetCenterCard.swift", "let accent = isOver", ": Self.providerTint"),
            ("CostStoryHeroCard.swift", "private func forecastStatusColor(forecast: UsageForecast) -> Color {", "case .approaching"),
        ]
        for item in fillSlices {
            let source = try Self.source(item.file)
            let slice = try #require(source.slice(from: item.start, to: item.end), "\(item.file): anchor not found: \(item.start)")
            #expect(slice.contains("Palette.danger"), "\(item.file): fill/icon color must stay danger: \(item.start)")
            #expect(!slice.contains("dangerText"), "\(item.file): fill/icon color must not switch to dangerText: \(item.start)")
        }
    }

    private static func composite(white alpha: Double, over base: UInt) -> UInt {
        func channel(_ shift: UInt) -> UInt {
            let value = Double((base >> shift) & 0xFF)
            return UInt((value + (255 - value) * alpha).rounded())
        }
        return (channel(16) << 16) | (channel(8) << 8) | channel(0)
    }

    private static func source(_ file: String) throws -> String {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Oriveo/Features/Home/UsageInsightsCards")
            .appendingPathComponent(file)
        return try String(contentsOf: url, encoding: .utf8)
    }
}

private extension String {
    func slice(from startMarker: String, to endMarker: String) -> String? {
        guard let start = range(of: startMarker),
              let end = range(of: endMarker, range: start.upperBound..<endIndex) else {
            return nil
        }
        return String(self[start.lowerBound..<end.upperBound])
    }
}
