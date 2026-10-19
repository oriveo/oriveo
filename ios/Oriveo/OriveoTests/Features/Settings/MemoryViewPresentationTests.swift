import Testing
@testable import Oriveo

@Suite("MemoryViewPresentation")
struct MemoryViewPresentationTests {

    @Test("With no items and recent conversations, shows the empty state: Add is primary and AI draft is secondary, without stacking repeated explanations")
    func starterModeAddsItemFirstAndOffersDraftWhenRecentConversationsExist() {
        let presentation = MemoryViewPresentation.resolve(
            hasItems: false,
            hasRecentConversations: true
        )

        #expect(presentation.mode == .starter)
        #expect(presentation.heroStyle == .draftStarter)
        #expect(presentation.detailPanelStyle == .none)
        #expect(presentation.primaryAction == .addItem)
        #expect(presentation.secondaryAction == .generateDraft)
        #expect(presentation.showsExampleCard == false)
        #expect(presentation.showsSupportCards == false)
    }

    @Test("With no items and no recent conversations, only Add is offered")
    func starterModeOnlyAddsItemWithoutRecentConversations() {
        let presentation = MemoryViewPresentation.resolve(
            hasItems: false,
            hasRecentConversations: false
        )

        #expect(presentation.mode == .starter)
        #expect(presentation.heroStyle == .manualStarter)
        #expect(presentation.detailPanelStyle == .none)
        #expect(presentation.primaryAction == .addItem)
        #expect(presentation.secondaryAction == nil)
        #expect(presentation.showsExampleCard == false)
    }

    @Test("With items it enters the list state and shows the privacy notice without repeating the preview panel")
    func listModeShowsSupportCardsWithoutRepeatingDetailPanels() {
        let presentation = MemoryViewPresentation.resolve(
            hasItems: true,
            hasRecentConversations: true
        )

        #expect(presentation.mode == .editor)
        #expect(presentation.heroStyle == .activeMemory)
        #expect(presentation.detailPanelStyle == .none)
        #expect(presentation.showsExampleCard == false)
        #expect(presentation.showsSupportCards == true)
    }

    @Test("In the list state, an AI draft entry is still offered when recent conversations exist")
    func listModeExposesDraftGenerationWhenRecentConversationsExist() {
        let presentation = MemoryViewPresentation.resolve(
            hasItems: true,
            hasRecentConversations: true
        )

        #expect(presentation.primaryAction == .generateDraft)
        #expect(presentation.secondaryAction == nil)
    }

    @Test("In the list state, no hero action button is shown without recent conversations")
    func listModeHidesPrimaryActionWithoutRecentConversations() {
        let presentation = MemoryViewPresentation.resolve(
            hasItems: true,
            hasRecentConversations: false
        )

        #expect(presentation.mode == .editor)
        #expect(presentation.primaryAction == nil)
        #expect(presentation.secondaryAction == nil)
    }
}
