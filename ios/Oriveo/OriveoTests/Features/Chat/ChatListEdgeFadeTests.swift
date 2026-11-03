import CoreGraphics
import Foundation
import Testing
@testable import Oriveo

@Suite("Chat list edge mask fade")
struct ChatListEdgeFadeTests {
    @Test("Composer state: smoothstep fades from 40 pt above the composer top down to 0 at 4 pt")
    func composerAlphaTable() {
        #expect(ChatListEdgeFade.alpha(distanceToComposerTop: 60) == 1)
        #expect(ChatListEdgeFade.alpha(distanceToComposerTop: 40) == 1)
        #expect(abs(ChatListEdgeFade.alpha(distanceToComposerTop: 22) - 0.5) <= 0.02)
        #expect(ChatListEdgeFade.alpha(distanceToComposerTop: 4) == 0)
        #expect(ChatListEdgeFade.alpha(distanceToComposerTop: -10) == 0)
        // smoothstep changes slowly near both ends and quickly in the middle.
        let near = ChatListEdgeFade.alpha(distanceToComposerTop: 7.6)
        #expect(near > 0 && near < 0.1)
    }

    @Test("Stage state: smoothstep goes from 0 to 1 over the top 30% of the list's visible area; fully opaque when the stage is absent")
    func stageMaskTable() {
        let fraction = VoiceStageChrome.listFadeFraction
        #expect(ChatListEdgeFade.stageMask(fractionFromTop: 0) == 0)
        #expect(abs(ChatListEdgeFade.stageMask(fractionFromTop: fraction / 2) - 0.5) <= 0.02)
        #expect(ChatListEdgeFade.stageMask(fractionFromTop: fraction) == 1)
        #expect(ChatListEdgeFade.stageMask(fractionFromTop: 0.8) == 1)
        let early = ChatListEdgeFade.stageMask(fractionFromTop: fraction * 0.1)
        #expect(early > 0 && early < 0.1)
        // While the stage fades out, return linearly to fully opaque following listFadeOpacity.
        #expect(ChatListEdgeFade.stageMask(fractionFromTop: 0, fadeOpacity: 0) == 1)
        #expect(abs(ChatListEdgeFade.stageMask(fractionFromTop: 0, fadeOpacity: 0.25) - 0.75) <= 0.001)
    }

    @Test("ChatComposerBar and the stage panelBackground no longer paint a solid background over the list")
    func noSolidBackgroundFill() throws {
        let composer = try source("Oriveo/Features/Chat/ChatComposerBar.swift")
        #expect(composer.range(of: #"Palette\.background\b"#, options: .regularExpression) == nil)

        let bar = try source("Oriveo/Features/Chat/Voice/VoiceConversationBar.swift")
        guard let start = bar.range(of: "private var panelBackground") else {
            Issue.record("panelBackground not found")
            return
        }
        let tail = bar[start.upperBound...]
        let end = tail.range(of: "// MARK:")?.lowerBound ?? tail.endIndex
        let panel = String(tail[..<end])
        #expect(panel.range(of: #"Palette\.background\b"#, options: .regularExpression) == nil)
        #expect(!panel.contains("LinearGradient"))
        #expect(!bar.contains("panelFadeHeight"))
    }

    @Test("The scroll-to-bottom button sits outside the fade mask: the mask is attached only to the list content layer, and ChatView no longer applies a mask to the whole list")
    func scroll_to_bottom_button_outside_mask() throws {
        let chatView = try source("Oriveo/Features/Chat/ChatView.swift")
        #expect(!chatView.contains(".mask { voiceStageListFade"))

        let list = try source("Oriveo/Features/Chat/ChatMessageList.swift")
        guard let maskCall = list.range(of: ".mask { listEdgeFadeMask }"),
              let buttonCall = list.range(of: "scrollToBottomButton(hasMessages:"),
              let maskDef = list.range(of: "private var listEdgeFadeMask") else {
            Issue.record("ChatMessageList: mask or scroll-to-bottom button attachment not found")
            return
        }
        // The mask is attached to the content layer and the button call comes after it (layered above it in the same outer ZStack, not wrapped by the mask).
        #expect(maskCall.lowerBound < buttonCall.lowerBound)
        #expect(list.components(separatedBy: ".mask {").count == 2)
        let defTail = list[maskDef.upperBound...].prefix(400)
        #expect(defTail.contains("ChatListEdgeFadeMask(stageFadeOpacity: listFadeOpacity)"))
    }

    private func source(_ relativePath: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent(relativePath), encoding: .utf8)
    }
}
