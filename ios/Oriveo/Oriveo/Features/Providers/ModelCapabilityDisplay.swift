import SwiftUI

extension ModelCapability {
    var displayTone: StatusTone {
        switch self {
        case .text: return .neutral
        case .image: return .primary
        case .video: return .primary
        case .file: return .success
        case .web: return .warning
        case .imageGen: return .danger
        case .reasoning: return .primary
        case .nativePdf: return .neutral
        case .toolCall: return .success
        }
    }

    var displayHint: String {
        switch self {
        case .text: return L10n.tr("Plain text chat", table: .providers)
        case .image: return L10n.tr("Upload images to chat", table: .providers)
        case .video: return L10n.tr("Upload videos to chat")
        case .file: return L10n.tr("Attach PDFs / documents", table: .providers)
        case .web: return L10n.tr("Built-in web search", table: .providers)
        case .imageGen: return L10n.tr("Generate images in chat", table: .providers)
        case .reasoning: return L10n.tr("Thinking / reasoning mode", table: .providers)
        case .nativePdf: return "Native PDF upload"
        case .toolCall: return L10n.tr("Tools", table: .providers)
        }
    }
}
