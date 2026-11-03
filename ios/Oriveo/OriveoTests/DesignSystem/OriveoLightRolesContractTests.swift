import Foundation
import SwiftUI
import Testing
import UIKit
@testable import Oriveo

/// Light tokens match the shared contract `theme-contracts/light-roles.v1.json` value by value.
/// Expected values are read from the JSON at test time; this file only maps contract names to tokens.
@MainActor
@Suite("Light roles contract")
struct OriveoLightRolesContractTests {
    /// Contract name (`roles.*.ios`) -> token.
    static let tokens: [String: Color] = [
        "Palette.primaryTextSafe": OriveoTheme.Palette.primaryTextSafe,
        "Palette.primaryPressed": OriveoTheme.Palette.primaryPressed,
        "Palette.onPrimary": OriveoTheme.Palette.onPrimary,
        "Palette.primaryTextOnSurface": OriveoTheme.Palette.primaryTextOnSurface,
        "Palette.primary": OriveoTheme.Palette.primary,
        "V2.Colors.primary": OriveoTheme.V2.Colors.primary,
        "Palette.primarySoft": OriveoTheme.Palette.primarySoft,
        "V2.Colors.primarySubtle": OriveoTheme.V2.Colors.primarySubtle,
        "Palette.primaryGlow": OriveoTheme.Palette.primaryGlow,
        "Palette.backgroundBase": OriveoTheme.Palette.backgroundBase,
        "V2.Colors.bgDefault": OriveoTheme.V2.Colors.bgDefault,
        "Palette.background": OriveoTheme.Palette.background,
        "V2.Colors.bgSubtle": OriveoTheme.V2.Colors.bgSubtle,
        "Palette.backgroundSecondary": OriveoTheme.Palette.backgroundSecondary,
        "V2.Colors.bgInset": OriveoTheme.V2.Colors.bgInset,
        "Palette.surfaceInset": OriveoTheme.Palette.surfaceInset,
        "Palette.surface": OriveoTheme.Palette.surface,
        "V2.Colors.surfaceDefault": OriveoTheme.V2.Colors.surfaceDefault,
        "Palette.surfaceElevated": OriveoTheme.Palette.surfaceElevated,
        "Palette.surfaceChrome": OriveoTheme.Palette.surfaceChrome,
        "V2.Colors.surfaceElevated": OriveoTheme.V2.Colors.surfaceElevated,
        "Palette.textPrimary": OriveoTheme.Palette.textPrimary,
        "V2.Colors.textPrimary": OriveoTheme.V2.Colors.textPrimary,
        "V2.Colors.textSecondary": OriveoTheme.V2.Colors.textSecondary,
        "V2.Colors.textTertiary": OriveoTheme.V2.Colors.textTertiary,
        "V2.Colors.primaryHover": OriveoTheme.V2.Colors.primaryHover,
        "V2.Colors.warning": OriveoTheme.V2.Colors.warning,
        "V2.Colors.warningSubtle": OriveoTheme.V2.Colors.warningSubtle,
        "V2.Colors.danger": OriveoTheme.V2.Colors.danger,
        "V2.Colors.shadowSm": OriveoTheme.V2.Colors.shadowSm,
        "Palette.textSecondary": OriveoTheme.Palette.textSecondary,
        "Palette.textTertiary": OriveoTheme.Palette.textTertiary,
        "Palette.textDisabledOnControl": OriveoTheme.Palette.textDisabledOnControl,
        "Palette.neutralFill": OriveoTheme.Palette.neutralFill,
        "Palette.border": OriveoTheme.Palette.border,
        "V2.Colors.borderDefault": OriveoTheme.V2.Colors.borderDefault,
        "Palette.borderStrong": OriveoTheme.Palette.borderStrong,
        "V2.Colors.borderEmphasis": OriveoTheme.V2.Colors.borderEmphasis,
        "V2.Colors.borderSubtle": OriveoTheme.V2.Colors.borderSubtle,
        "Palette.hairline": OriveoTheme.Palette.hairline,
        "Palette.switchThumb": OriveoTheme.Palette.switchThumb,
        "Palette.overlay": OriveoTheme.Palette.overlay,
        "Palette.shadow": OriveoTheme.Palette.shadow,
        "Palette.success": OriveoTheme.Palette.success,
        "Palette.successSoft": OriveoTheme.Palette.successSoft,
        "Palette.successText": OriveoTheme.Palette.successText,
        "Palette.onSuccess": OriveoTheme.Palette.onSuccess,
        "Palette.danger": OriveoTheme.Palette.danger,
        "Palette.dangerSoft": OriveoTheme.Palette.dangerSoft,
        "Palette.dangerText": OriveoTheme.Palette.dangerText,
        "Palette.onDanger": OriveoTheme.Palette.onDanger,
        "Palette.warning": OriveoTheme.Palette.warning,
        "Palette.warningSoft": OriveoTheme.Palette.warningSoft,
        "Palette.warningText": OriveoTheme.Palette.warningText,
        "Palette.onWarning": OriveoTheme.Palette.onWarning,
        "Palette.info": OriveoTheme.Palette.info,
        "Palette.infoSoft": OriveoTheme.Palette.infoSoft,
        "Palette.infoText": OriveoTheme.Palette.infoText,
        "Palette.onInfo": OriveoTheme.Palette.onInfo,
    ]

    @Test("Every iOS name in the contract roles or iOS pending list is mapped to a token")
    func everyContractTokenIsMapped() throws {
        let contract = try Self.loadContract()
        let roles = try #require(contract["roles"] as? [String: [String: Any]])
        #expect(!roles.isEmpty)
        for (roleKey, role) in roles.sorted(by: { $0.key < $1.key }) {
            let names = try #require(role["ios"] as? [String], "roles.\(roleKey).ios")
            for name in names {
                #expect(Self.tokens[name] != nil, "roles.\(roleKey): \(name) is not mapped")
            }
        }
        for item in try Self.iosPending(contract) {
            #expect(Self.tokens[item.token] != nil, "pending: \(item.token) is not mapped")
        }
    }

    @Test("Every mapped token name appears in the contract roles or iOS pending list")
    func mappedTokensAreAllInContract() throws {
        let contract = try Self.loadContract()
        let roles = try #require(contract["roles"] as? [String: [String: Any]])
        var known = Set(roles.values.flatMap { $0["ios"] as? [String] ?? [] })
        for item in try Self.iosPending(contract) { known.insert(item.token) }
        for name in Self.tokens.keys.sorted() {
            #expect(known.contains(name), "\(name) is mapped but not in the contract")
        }
    }

    @Test("Dark status text equals its status color in every dark palette")
    func darkStatusTextEqualsStatusColor() {
        let pairs: [(String, Color, Color)] = [
            ("success", OriveoTheme.Palette.successText, OriveoTheme.Palette.success),
            ("danger", OriveoTheme.Palette.dangerText, OriveoTheme.Palette.danger),
            ("info", OriveoTheme.Palette.infoText, OriveoTheme.Palette.info),
        ]
        for id in OriveoDarkPaletteID.allCases {
            for (name, text, status) in pairs {
                let actualText = Self.rgba(text, scheme: .dark, palette: id)
                let actualStatus = Self.rgba(status, scheme: .dark, palette: id)
                #expect(
                    actualText.hex == actualStatus.hex && abs(actualText.alpha - actualStatus.alpha) < 1e-6,
                    "\(id.rawValue).\(name)Text: \(String(format: "#%06X", actualText.hex)) != \(String(format: "#%06X", actualStatus.hex))"
                )
            }
        }
    }

    @Test("Light tokens with the default palette equal the contract values")
    func lightTokensMatchContract() throws {
        let contract = try Self.loadContract()
        let tolerance = try #require((contract["alphaTolerance"] as? NSNumber)?.doubleValue)
        let roles = try #require(contract["roles"] as? [String: [String: Any]])
        var checked = 0
        for (roleKey, role) in roles.sorted(by: { $0.key < $1.key }) {
            let colorHex = try #require(role["color"] as? String, "roles.\(roleKey).color")
            let roleAlpha = (role["alpha"] as? NSNumber)?.doubleValue ?? 1
            for name in role["ios"] as? [String] ?? [] {
                guard let token = Self.tokens[name] else { continue }
                let expected = try Self.hex(colorHex)
                let actual = Self.lightRGBA(token)
                #expect(
                    actual.hex == expected,
                    "\(name) (\(roleKey)): \(String(format: "#%06X", actual.hex)) != \(String(format: "#%06X", expected))"
                )
                #expect(
                    abs(actual.alpha - roleAlpha) <= tolerance,
                    "\(name) (\(roleKey)): alpha \(actual.alpha) != \(roleAlpha)"
                )
                checked += 1
            }
        }
        #expect(checked > 0)
    }

    /// Pending tokens are known to differ from their role (a token is never in both a role and
    /// `pending`), so they are asserted against `current` until the fixing unit lands.
    @Test("iOS pending tokens are still at their contract current value")
    func pendingTokensStillAtCurrent() throws {
        let contract = try Self.loadContract()
        let tolerance = try #require((contract["alphaTolerance"] as? NSNumber)?.doubleValue)
        for item in try Self.iosPending(contract) {
            let token = try #require(Self.tokens[item.token], "pending: \(item.token) is not mapped")
            let expected = try Self.hex(item.current)
            let actual = Self.lightRGBA(token)
            #expect(
                actual.hex == expected,
                "pending \(item.token): \(String(format: "#%06X", actual.hex)) != \(item.current); remove the pending entry when its unit lands"
            )
            // A pending `current` is an opaque color, so it is asserted at alpha 1.
            #expect(abs(actual.alpha - 1) <= tolerance, "pending \(item.token): alpha \(actual.alpha) != 1")
        }
    }

    // MARK: - Helpers

    /// Contract `pending` entries whose `end` is iOS.
    private static func iosPending(_ contract: [String: Any]) throws -> [(token: String, current: String)] {
        let items = contract["pending"] as? [[String: Any]] ?? []
        return try items.filter { $0["end"] as? String == "ios" }.map { item in
            let token = try #require(item["token"] as? String, "pending.token")
            let current = try #require(item["current"] as? String, "pending.\(token).current")
            return (token, current)
        }
    }

    /// Resolves in the light appearance with the default palette set explicitly, so a palette
    /// selection left behind by another test cannot leak in.
    private static func lightRGBA(_ color: Color) -> (hex: UInt, alpha: Double) {
        rgba(color, scheme: .light, palette: OriveoDarkPaletteID.defaultID)
    }

    private static func rgba(
        _ color: Color, scheme: ColorScheme, palette: OriveoDarkPaletteID
    ) -> (hex: UInt, alpha: Double) {
        var env = EnvironmentValues()
        env.colorScheme = scheme
        env.oriveoDarkPalette = .preset(palette)
        let resolved = UIColor(cgColor: color.resolve(in: env).cgColor)
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        resolved.getRed(&r, green: &g, blue: &b, alpha: &a)
        let hex = (UInt((r * 255).rounded()) << 16) | (UInt((g * 255).rounded()) << 8) | UInt((b * 255).rounded())
        return (hex, Double(a))
    }

    private static func hex(_ string: String) throws -> UInt {
        let digits = string.hasPrefix("#") ? String(string.dropFirst()) : string
        return try #require(UInt(digits, radix: 16), "bad color \(string)")
    }

    static func loadContract() throws -> [String: Any] {
        var cursor = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        while cursor.path != "/" {
            let candidate = cursor
                .appendingPathComponent("\u{5171}\u{4EAB}") // shared contracts directory
                .appendingPathComponent("theme-contracts")
                .appendingPathComponent("light-roles.v1.json")
            if FileManager.default.fileExists(atPath: candidate.path) {
                let object = try JSONSerialization.jsonObject(with: Data(contentsOf: candidate))
                return try #require(object as? [String: Any])
            }
            cursor.deleteLastPathComponent()
        }
        throw CocoaError(.fileNoSuchFile)
    }
}
