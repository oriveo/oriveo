import Foundation
import Testing
@testable import Oriveo

/// Source contract for the shared toast (top centered capsule + 24pt tinted round icon + optional action).
/// Android and Web implement the same spec.
@Suite("Unified Capsule Toast")
struct ToastCapsuleContractTests {
    private func source(_ relative: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // Features
            .deletingLastPathComponent() // OriveoTests
            .deletingLastPathComponent() // project root
        return try String(contentsOf: root.appendingPathComponent(relative), encoding: .utf8)
    }

    @Test("Capsule shape, round icon, and a glyph for every style")
    func capsuleWithIconForEveryStyle() throws {
        let overlay = try source("Oriveo/Shared/Components/ToastOverlay.swift")
        #expect(overlay.contains("Capsule(style: .continuous)"))
        #expect(overlay.contains(".frame(width: 24, height: 24)"))
        #expect(overlay.contains("Circle().fill(accent.opacity(0.16))"))
        for style in ["success", "error", "warning", "info", "removed", "neutral"] {
            #expect(overlay.contains("case .\(style)"), "\(style) has no glyph / color mapping")
        }
    }

    @Test("\"Removed · Undo\" uses the shared toast, with no bottom banner")
    func removalUsesUnifiedToast() throws {
        let detail = try source("Oriveo/Features/Providers/ProviderDetailView.swift")
        let animations = try source("Oriveo/Features/Providers/ProviderDetailAnimations.swift")
        #expect(detail.contains("style: .removed"))
        #expect(detail.contains("action: { undoPendingRemoval() }"))
        #expect(!detail.contains("removalBannerOverlay"))
        #expect(!animations.contains("struct ProviderModelRemovalBanner: View"))
    }
}
