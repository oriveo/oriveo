import SwiftUI

enum FolderColor: String, CaseIterable, Codable {
    case blue, purple, pink, red, orange, yellow, green, teal, indigo, gray


    var gradientColors: [Color] {
        switch self {
        case .blue:   return [Color(hex: 0x3B82F6), Color(hex: 0x2563EB)]
        case .purple: return [Color(hex: 0x8B5CF6), Color(hex: 0x7C3AED)]
        case .pink:   return [Color(hex: 0xEC4899), Color(hex: 0xDB2777)]
        case .red:    return [Color(hex: 0xEF4444), Color(hex: 0xDC2626)]
        case .orange: return [Color(hex: 0xF97316), Color(hex: 0xEA580C)]
        case .yellow: return [Color(hex: 0xEAB308), Color(hex: 0xCA8A04)]
        case .green:  return [Color(hex: 0x22C55E), Color(hex: 0x16A34A)]
        case .teal:   return [Color(hex: 0x14B8A6), Color(hex: 0x0D9488)]
        case .indigo: return [Color(hex: 0x6366F1), Color(hex: 0x4F46E5)]
        case .gray:   return [Color(hex: 0x6B7280), Color(hex: 0x4B5563)]
        }
    }

    var color: Color { gradientColors[0] }


    var accessibilityLabel: String {
        L10n.tr("color_\(rawValue)")
    }

    // MARK: - Fallback

    static let fallback: FolderColor = .blue

    static func from(_ tag: String?) -> FolderColor {
        guard let tag, let c = FolderColor(rawValue: tag) else { return .fallback }
        return c
    }


    static let ordered: [FolderColor] = FolderColor.allCases

    static func nextColor(after folders: [Folder]) -> FolderColor {
        guard let lastFolder = folders.sorted(by: { $0.sortOrder < $1.sortOrder }).last,
              let lastColor = FolderColor(rawValue: lastFolder.colorTag ?? ""),
              let lastIndex = ordered.firstIndex(of: lastColor) else {
            return .blue
        }
        return ordered[(lastIndex + 1) % ordered.count]
    }
}


private extension Color {
    init(hex: UInt32) {
        self.init(
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255
        )
    }
}
