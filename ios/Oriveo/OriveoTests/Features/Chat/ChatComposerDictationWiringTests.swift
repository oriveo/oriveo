import Foundation
import Testing
@testable import Oriveo

/// Dictation on the chat page's composer row.
/// Locks the slot key (the conversation key when there is a conversation, the home draft key in compose state, the same source as RecordingStore) and the composer bar's wiring points.
@Suite("Chat composer dictation wiring")
struct ChatComposerDictationWiringTests {

    @Test("with a conversation the slot key is that conversation's RecordingStore key")
    func slotKeyForConversation() {
        let id = UUID()
        #expect(ChatComposerBar.dictationSlotKey(conversationID: id) == RecordingStore.slotKey(conversationID: id))
    }

    @Test("in compose state (no conversation) the slot key is the home draft key")
    func slotKeyForComposeState() {
        #expect(ChatComposerBar.dictationSlotKey(conversationID: nil) == RecordingStore.homeDraftKey)
    }

    @Test("the composer row is wrapped in the dictation toggle container, the bar mounts the dictation host, and the text view passes out the selection")
    func composerBarWiresDictation() throws {
        let source = try composerBarSource()

        #expect(source.contains("DictationInputSwitcher("))
        #expect(source.contains(".dictationHost("))
        #expect(source.contains("DictationMicButton("))

        let textViewCall = try #require(source.range(of: "ComposerTextView("))
        let tail = source[textViewCall.upperBound...]
        let callEnd = try #require(tail.range(of: "\n            )"))
        #expect(tail[..<callEnd.lowerBound].contains("selectionProbe:"))
    }

    @Test("the dictation host sits at the root of the composer bar body, an ancestor of the microphone, the toggle container and the card slot")
    func dictationHostWrapsDictationViews() throws {
        let source = try composerBarSource()
        let hostType = try #require(
            DictationHostSourceScan.typeBody(source, type: "ChatComposerDictationHost", keyword: "private struct")
        )
        #expect(hostType.contains("content.dictationHost("))

        let barWrapped = try #require(
            DictationHostSourceScan.wrappedSource(source, type: "ChatComposerBar", hostMarker: ".modifier(ChatComposerDictationHost(")
        )
        // The input row is its own view struct; it is under the host only because the wrapped root instantiates it.
        #expect(barWrapped.contains("ChatComposerInputRow("))
        let inputRow = try #require(
            DictationHostSourceScan.typeBody(source, type: "ChatComposerInputRow", keyword: "private struct")
        )
        let wrapped = barWrapped + String(inputRow)
        for target in ["DictationMicButton(", "DictationInputSwitcher(", "DictationPromptSlot("] {
            #expect(wrapped.contains(target), "the host does not wrap \(target)")
        }
    }

    @Test("when the text view is disabled (read-only / while answering) the microphone is disabled with it")
    func micButtonDisabledWithComposer() throws {
        let source = try composerBarSource()
        #expect(source.contains("DictationMicButton(controller: controller)\n                    .disabled(controlsDisabled)"))
    }

    @Test("the dictation card slot sits above the capability chip row")
    func promptSlotAboveCapabilityStrip() throws {
        let source = try composerBarSource()
        let slot = try #require(source.range(of: "DictationPromptSlot("))
        let strip = try #require(source.range(of: "ChatComposerCapabilityStrip("))
        #expect(slot.lowerBound < strip.lowerBound)
    }

    @Test("Check Connection: with a connection ID go to that connection's detail, otherwise go to provider setup")
    func checkConnectionRoute() {
        let id = UUID()
        #expect(ChatComposerBar.dictationCheckConnectionRoute(providerID: id) == .providerDetail(id))
        #expect(ChatComposerBar.dictationCheckConnectionRoute(providerID: nil) == .providerSetup)
    }

    @Test("the send key and the dictation host's onSend go through the same private send function")
    func openVoiceSettingsRoute() throws {
        let source = try composerBarSource()
        #expect(source.contains("onOpenVoiceSettings: openDictationVoiceSettings"))
        #expect(source.contains("private func openDictationVoiceSettings() {\n        navigation.attemptNavigate(to: .voiceSettings)"))
    }

    @Test("the send key and the dictation host's onSend go through the same private send function")
    func sendButtonAndDictationShareSubmit() throws {
        let source = try composerBarSource()
        // The realtime typing state is routed to the realtime session first; everything else still goes through the same onSend
        #expect(source.contains("private func submitComposer(text: String) {\n        if isRealtimeTyping {\n            submitRealtimeTyped(text: text)\n            return\n        }\n        onSend(text, pendingAttachments, pendingLibraryDocuments)"))

        let sendButton = try #require(source.range(of: ": (isVoice ? \"chat_voice_conversation_button\" : \"chat_send_button\")"))
        let buttonTail = source[sendButton.upperBound...]
        let buttonEnd = try #require(buttonTail.range(of: ".disabled(!isLit)"))
        #expect(buttonTail[..<buttonEnd.lowerBound].contains("submitComposer(text: composerText)"))

        let host = try #require(source.range(of: ".modifier(ChatComposerDictationHost("))
        let hostTail = source[host.upperBound...]
        let hostEnd = try #require(hostTail.range(of: "\n        ))"))
        #expect(hostTail[..<hostEnd.lowerBound].contains("onSend: { text in submitComposer(text: text) }"))
    }

    @Test("Live text: the host hands the selection exit and draft binding to the dictation host")
    func liveTextWiredThroughProbe() throws {
        let source = try composerBarSource()
        let host = try #require(source.range(of: ".modifier(ChatComposerDictationHost("))
        let hostTail = source[host.upperBound...]
        let hostEnd = try #require(hostTail.range(of: "\n        ))"))
        #expect(hostTail[..<hostEnd.lowerBound].contains("live: .probe(dictationProbe, text: $composerText)"))

        let hostType = try #require(
            DictationHostSourceScan.typeBody(source, type: "ChatComposerDictationHost", keyword: "private struct")
        )
        #expect(hostType.contains("live: live"))
    }

    @Test("While the voice stage is shown the managed quota row is absent from the view tree: both buttons sit 20 + safe area from the bottom, same as Android")
    func managedQuotaFooterHiddenDuringVoiceStage() throws {
        let source = try composerBarSource()
        let declaration = try #require(source.range(of: "private var managedQuotaFooter: some View {"))
        let tail = source[declaration.upperBound...]
        let end = try #require(tail.range(of: "\n    }\n"))
        let body = tail[..<end.lowerBound]
        #expect(body.contains("!showsVoiceStage"))
        #expect(source.contains("var showsVoiceStage: Bool"))
    }

    @Test("While recording or transcribing, the input field does not show the attachment \"+\"; in the normal state the attachment entry is shown")
    func attachmentEntryHiddenWhileDictating() throws {
        #expect(ChatComposerBar.showsAttachmentEntry(supportsEntry: true, phase: .normal))
        #expect(!ChatComposerBar.showsAttachmentEntry(supportsEntry: true, phase: .recording))
        #expect(!ChatComposerBar.showsAttachmentEntry(supportsEntry: true, phase: .busy))
        #expect(!ChatComposerBar.showsAttachmentEntry(supportsEntry: false, phase: .normal))

        let source = try composerBarSource()
        let shell = try #require(source.range(of: "private func composerTextInputShell(phase: DictationInputPhase) -> some View {"))
        let tail = source[shell.upperBound...]
        let end = try #require(tail.range(of: "ComposerTextView("))
        #expect(tail[..<end.lowerBound].contains("if showsAttachmentEntry {\n                attachmentEntryButton"))
        #expect(tail[..<end.lowerBound].contains("let showsAttachmentEntry = ChatComposerBar.showsAttachmentEntry(supportsEntry: supportsAttachmentEntry, phase: phase)"))
    }

    private func composerBarSource() throws -> String {
        let projectDirectory = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let sourceURL = projectDirectory
            .appendingPathComponent("Oriveo")
            .appendingPathComponent("Features")
            .appendingPathComponent("Chat")
            .appendingPathComponent("ChatComposerBar.swift")
        return try String(contentsOf: sourceURL, encoding: .utf8)
    }
}
