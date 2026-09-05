import Testing
@testable import Oriveo

@Suite("MemoryViewPresentation")
struct MemoryViewPresentationTests {

    @Test("Starter Mode Prefers Draft Generation When Recent Conversations Exist")
    func starterModePrefersDraftGenerationWhenRecentConversationsExist() {
        let presentation = MemoryViewPresentation.resolve(
            memoryText: "",
            isEditorFocused: false,
            hasRecentConversations: true
        )

        #expect(presentation.mode == .starter)
        #expect(presentation.heroStyle == .draftStarter)
        #expect(presentation.detailPanelStyle == .none)
        #expect(presentation.primaryAction == .generateDraft)
        #expect(presentation.secondaryAction == .focusEditor)
        #expect(presentation.showsExampleCard == false)
        #expect(presentation.showsSupportCards == false)
    }

    @Test("Starter Mode Falls Back To Manual Entry Without Recent Conversations")
    func starterModeFallsBackToManualEntryWithoutRecentConversations() {
        let presentation = MemoryViewPresentation.resolve(
            memoryText: "",
            isEditorFocused: false,
            hasRecentConversations: false
        )

        #expect(presentation.mode == .starter)
        #expect(presentation.heroStyle == .manualStarter)
        #expect(presentation.detailPanelStyle == .none)
        #expect(presentation.primaryAction == .focusEditor)
        #expect(presentation.secondaryAction == nil)
        #expect(presentation.showsExampleCard == false)
    }

    @Test("Editor Mode Shows Support Cards Without Repeating Detail Panels")
    func editorModeShowsSupportCardsWithoutRepeatingDetailPanels() {
        let withContent = MemoryViewPresentation.resolve(
            memoryText: "I prefer concise replies.",
            isEditorFocused: false,
            hasRecentConversations: true
        )
        let whileEditingEmpty = MemoryViewPresentation.resolve(
            memoryText: "",
            isEditorFocused: true,
            hasRecentConversations: true
        )

        #expect(withContent.mode == .editor)
        #expect(withContent.heroStyle == .activeMemory)
        #expect(withContent.detailPanelStyle == .none)
        #expect(withContent.showsExampleCard == false)
        #expect(withContent.showsSupportCards == true)

        #expect(whileEditingEmpty.mode == .editor)
        #expect(whileEditingEmpty.heroStyle == .activeMemory)
        #expect(whileEditingEmpty.detailPanelStyle == .none)
        #expect(whileEditingEmpty.showsSupportCards == true)
    }

    @Test("Editor Mode Exposes Draft Generation When Recent Conversations Exist")
    func editorModeExposesDraftGenerationWhenRecentConversationsExist() {
        let withContent = MemoryViewPresentation.resolve(
            memoryText: "I prefer concise replies.",
            isEditorFocused: false,
            hasRecentConversations: true
        )
        let whileEditingEmpty = MemoryViewPresentation.resolve(
            memoryText: "",
            isEditorFocused: true,
            hasRecentConversations: true
        )

        #expect(withContent.primaryAction == .generateDraft)
        #expect(withContent.secondaryAction == nil)

        #expect(whileEditingEmpty.primaryAction == .generateDraft)
        #expect(whileEditingEmpty.secondaryAction == nil)
    }

    @Test("Editor Mode Hides Primary Action Without Recent Conversations")
    func editorModeHidesPrimaryActionWithoutRecentConversations() {
        let presentation = MemoryViewPresentation.resolve(
            memoryText: "I prefer concise replies.",
            isEditorFocused: false,
            hasRecentConversations: false
        )

        #expect(presentation.mode == .editor)
        #expect(presentation.primaryAction == nil)
        #expect(presentation.secondaryAction == nil)
    }
}
