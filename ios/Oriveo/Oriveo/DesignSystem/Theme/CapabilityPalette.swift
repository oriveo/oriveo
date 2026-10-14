import SwiftUI

/// Capability palette: five fixed colors, with the 400 step of Tailwind for dark and the 600 step for light.
/// Capability icons and capability cards take their colors only from here; the capability matrix gate lint blocks hand-written values of these ten colors outside the token file.
enum CapabilityPalette {
    static let webSearch = Color.dynamic(light: 0x2563EB, dark: 0x60A5FA)
    static let reasoning = Color.dynamic(light: 0x7C3AED, dark: 0xA78BFA)
    static let attachment = Color.dynamic(light: 0xD97706, dark: 0xFBBF24)
    static let vision = Color.dynamic(light: 0x059669, dark: 0x34D399)
    static let tools = Color.dynamic(light: 0xDB2777, dark: 0xF472B6)
}

/// Row icon colors for relay / local detail pages: the same dark 400 / light 600 steps, not clashing with the capability colors.
/// The web row and the thinking row keep using the capability colors above and do not start a new one here.
enum DetailRowPalette {
    static let teal = Color.dynamic(light: 0x0D9488, dark: 0x2DD4BF)
    static let cyan = Color.dynamic(light: 0x0891B2, dark: 0x22D3EE)
    static let indigo = Color.dynamic(light: 0x4F46E5, dark: 0x818CF8)
    static let orange = Color.dynamic(light: 0xEA580C, dark: 0xFB923C)
    static let rose = Color.dynamic(light: 0xE11D48, dark: 0xFB7185)
}
