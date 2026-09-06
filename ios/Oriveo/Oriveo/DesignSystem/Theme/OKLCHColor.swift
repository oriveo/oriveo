import SwiftUI
import UIKit

/// ```swift
/// let color = OKLCHColor.color(l: 0.62, c: 0.14, h: 165)
/// let color = OKLCHColor.dynamic(hue: 165, c: OriveoColorTokens.providerChroma)
/// ```
enum OKLCHColor {

    // MARK: - Public API

    /// - Parameters:
    static func color(l: Double, c: Double, h: Double) -> Color {
        let (r, g, b) = oklchToSRGB(l: l, c: c, h: h)
        return Color(red: r, green: g, blue: b)
    }

    static func dynamic(
        hue: Double,
        c: Double,
        lightL: Double = OriveoColorTokens.providerLightnessLight,
        darkL: Double = OriveoColorTokens.providerLightnessDark
    ) -> Color {
        let dynamicUIColor = UIColor { trait in
            let l = trait.userInterfaceStyle == .dark ? darkL : lightL
            let (r, g, b) = oklchToSRGB(l: l, c: c, h: hue)
            return UIColor(red: r, green: g, blue: b, alpha: 1.0)
        }
        return Color(uiColor: dynamicUIColor)
    }

    // MARK: - Conversion (OKLCH → OKLab → Linear sRGB → sRGB)

    static func oklchToSRGB(l: Double, c: Double, h: Double) -> (Double, Double, Double) {
        let hRad = h * .pi / 180.0
        let aLab = c * cos(hRad)
        let bLab = c * sin(hRad)

        // 2. OKLab → linear sRGB (Björn Ottosson reference matrices)
        let l_ = l + 0.3963377774 * aLab + 0.2158037573 * bLab
        let m_ = l - 0.1055613458 * aLab - 0.0638541728 * bLab
        let s_ = l - 0.0894841775 * aLab - 1.2914855480 * bLab

        let lCube = l_ * l_ * l_
        let mCube = m_ * m_ * m_
        let sCube = s_ * s_ * s_

        let r =  4.0767416621 * lCube - 3.3077115913 * mCube + 0.2309699292 * sCube
        let g = -1.2684380046 * lCube + 2.6097574011 * mCube - 0.3413193965 * sCube
        let b = -0.0041960863 * lCube - 0.7034186147 * mCube + 1.7076147010 * sCube

        // 3. Linear sRGB → sRGB gamma encode + clamp
        return (
            srgbGamma(r),
            srgbGamma(g),
            srgbGamma(b)
        )
    }

    private static func srgbGamma(_ v: Double) -> Double {
        let clamped = max(0.0, min(1.0, v))
        if clamped <= 0.0031308 {
            return 12.92 * clamped
        }
        return 1.055 * pow(clamped, 1.0 / 2.4) - 0.055
    }
}

// MARK: - Provider Color Tokens

enum OriveoColorTokens {
    static let providerLightnessLight: Double = 0.62
    static let providerLightnessDark: Double = 0.72
    static let providerChroma: Double = 0.14

    static let providerBrandHexes: [String: UInt32] = [
        "openai":      0x10A37F,  // OpenAI green
        "anthropic":   0xC7956D,  // Anthropic warm tan
        "gemini":      0x4285F4,  // Google Gemini blue
        "deepseek":    0x4D6BFE,  // DeepSeek blue-violet
        "grok":        0x0F0F10,  // xAI black
        "xai":         0x0F0F10,
        "openrouter":  0x6D63FF,  // OpenRouter purple
        "groq":        0xF55036,  // Groq red
        "together":    0x0EA5E9,  // Together sky
        "togetherai":  0x0EA5E9,
        "fireworks":   0xFF6B35,  // Fireworks orange
        "fireworksai": 0xFF6B35,
        "minimax":     0xE8457C,  // MiniMax pink
        "zhipu":       0x1F63EC,
        "qwen":        0x615CED,
        "moonshot":    0x5B3AFF,  // Moonshot violet
        "kimi":        0x5B3AFF,
        "mistral":     0xFA500F,  // Mistral orange
        "siliconflow": 0x7C3AED,  // SiliconFlow purple
    ]

    static let fallbackPaletteHexes: [UInt32] = [
        0x6366F1,  // indigo
        0x22C55E,  // green
        0xF59E0B,  // amber
        0xEF4444,  // red
        0x06B6D4,  // cyan
    ]

    static let relayPaletteHexes: [UInt32] = [
        0x14B8A6,  // teal 500
        0xF59E0B,  // amber 500
        0xD946EF,  // fuchsia 500
        0x84CC16,  // lime 500
        0xEC4899,  // pink 500
        0xEAB308,  // yellow 500
        0xFB923C,  // orange 400
        0x0891B2,  // cyan 600
    ]

    static func djb2Index(forId id: String, count: Int) -> Int {
        guard !id.isEmpty, count > 0 else { return 0 }
        var h: UInt64 = 5381
        for byte in id.utf8 {
            h = h &* 33 &+ UInt64(byte)
        }
        return Int(h % UInt64(count))
    }

    static func fallbackPaletteIndex(forId id: String) -> Int {
        djb2Index(forId: id, count: fallbackPaletteHexes.count)
    }
}


/// (Android `ProviderBrandColors.kt` / Web `provider-tints.ts`).
enum ProviderTints {

    static func tint(for providerKind: String) -> Color {
        tint(for: providerKind, fallbackId: "")
    }

    /// ```swift
    /// ProviderTints.tint(for: item.providerKind, fallbackId: item.providerId)
    /// ```
    static func tint(for providerKind: String, fallbackId: String) -> Color {
        let key = providerKind.lowercased()

        if key == "relay" {
            let hashKey = fallbackId.isEmpty ? key : fallbackId
            let idx = OriveoColorTokens.djb2Index(forId: hashKey, count: OriveoColorTokens.relayPaletteHexes.count)
            return brandColor(hex: OriveoColorTokens.relayPaletteHexes[idx])
        }

        if let hex = OriveoColorTokens.providerBrandHexes[key] {
            return brandColor(hex: hex)
        }
        let hashKey = fallbackId.isEmpty ? key : fallbackId
        if hashKey.isEmpty {
            return OriveoTheme.Palette.textSecondary
        }
        let idx = OriveoColorTokens.djb2Index(forId: hashKey, count: OriveoColorTokens.fallbackPaletteHexes.count)
        return brandColor(hex: OriveoColorTokens.fallbackPaletteHexes[idx])
    }

    static func softTint(for providerKind: String) -> Color {
        let key = providerKind.lowercased()
        guard let hex = OriveoColorTokens.providerBrandHexes[key] else {
            return OriveoTheme.Palette.surfaceInset
        }
        return brandColor(hex: hex).opacity(0.12)
    }

    private static func brandColor(hex: UInt32) -> Color {
        let baseUI = UIColor(brandHex: hex)
        let lightness = baseUI.perceivedLightness
        let dynamicUI = UIColor { trait in
            guard trait.userInterfaceStyle == .dark else { return baseUI }
            if lightness < 0.25 { return baseUI.lightened(by: 0.30) }
            if lightness < 0.45 { return baseUI.lightened(by: 0.10) }
            return baseUI
        }
        return Color(uiColor: dynamicUI)
    }
}

// MARK: - UIColor brand helpers

private extension UIColor {
    convenience init(brandHex: UInt32) {
        self.init(
            red: CGFloat((brandHex >> 16) & 0xFF) / 255,
            green: CGFloat((brandHex >> 8) & 0xFF) / 255,
            blue: CGFloat(brandHex & 0xFF) / 255,
            alpha: 1
        )
    }

    var perceivedLightness: CGFloat {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        guard getRed(&r, green: &g, blue: &b, alpha: &a) else { return 0.5 }
        return 0.2126 * r + 0.7152 * g + 0.0722 * b
    }

    func lightened(by ratio: CGFloat) -> UIColor {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        guard getRed(&r, green: &g, blue: &b, alpha: &a) else { return self }
        let clamped = max(0, min(1, ratio))
        return UIColor(
            red: r + (1 - r) * clamped,
            green: g + (1 - g) * clamped,
            blue: b + (1 - b) * clamped,
            alpha: a
        )
    }
}
