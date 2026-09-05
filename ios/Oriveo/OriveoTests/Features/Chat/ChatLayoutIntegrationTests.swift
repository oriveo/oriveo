import Testing
import ChatLayout
@testable import Oriveo

@MainActor
@Suite struct ChatLayoutIntegrationTests {
    @Test func chatLayout_flag() {
        let layout = CollectionViewChatLayout()
        layout.supportSelfSizingInvalidation = true
        layout.keepContentAtBottomOfVisibleArea = true
        layout.keepContentOffsetAtBottomOnBatchUpdates = true
        #expect(layout.supportSelfSizingInvalidation == true)
        #expect(layout.keepContentAtBottomOfVisibleArea == true)
        #expect(layout.keepContentOffsetAtBottomOnBatchUpdates == true)
    }
}
