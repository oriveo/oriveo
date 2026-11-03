import Foundation
import Testing
@testable import Oriveo

// The VoiceOver value of the Tools chip in the composer. When the chip is dimmed because the current
// model cannot use tools, a screen reader has to say why, instead of reading "Disabled" as it does
// when no server is turned on.

@Suite("VoiceOver value of the Tools chip")
struct ComposerToolsChipAccessibilityTests {
    @Test("the model cannot use tools: reads the reason, not Disabled and not the server count")
    func unavailableReadsTheReason() {
        let reason = L10n.tr("This model can't use tools", table: .mcp)
        #expect(!reason.isEmpty)
        #expect(reason != L10n.tr("Disabled"))
        #expect(ComposerToolsChipState(enabledServerCount: 0, isAvailable: false).accessibilityValue == reason)
        #expect(ComposerToolsChipState(enabledServerCount: 2, isAvailable: false).accessibilityValue == reason)
    }

    @Test("available: reads the count when servers are on and Disabled when none is")
    func availableKeepsExistingValues() {
        #expect(ComposerToolsChipState(enabledServerCount: 3, isAvailable: true).accessibilityValue == "3")
        #expect(ComposerToolsChipState(enabledServerCount: 0, isAvailable: true).accessibilityValue == L10n.tr("Disabled"))
    }

    @Test("Selected realtime model: screen reader reads the voice_realtime_no_tools copy, not the generic MCP reason")
    func realtimeReadsRealtimeReason() {
        let reason = RealtimeCapabilityCopy.reason("voice_realtime_no_tools")
        #expect(reason == L10n.tr("Realtime voice models can't use tools.", table: .voice))
        #expect(reason != L10n.tr("This model can't use tools", table: .mcp))
        let chip = ComposerToolsChipState(enabledServerCount: 1, isAvailable: false, unavailableReason: reason)
        #expect(chip.accessibilityValue == reason)
    }
}
