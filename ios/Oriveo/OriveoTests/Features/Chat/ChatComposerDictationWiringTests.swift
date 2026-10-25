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

        let wrapped = try #require(
            DictationHostSourceScan.wrappedSource(source, type: "ChatComposerBar", hostMarker: ".modifier(ChatComposerDictationHost(")
        )
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
        let strip = try #require(source.range(of: "capabilityStrip\n                        .padding(.bottom, -4)"))
        #expect(slot.lowerBound < strip.lowerBound)
    }

    @Test("Check Connection: with a connection ID go to that connection's detail, otherwise go to provider setup")
    func checkConnectionRoute() {
        let id = UUID()
        #expect(ChatComposerBar.dictationCheckConnectionRoute(providerID: id) == .providerDetail(id))
        #expect(ChatComposerBar.dictationCheckConnectionRoute(providerID: nil) == .providerSetup)
    }

    @Test("the send key and the dictation host's onSend go through the same private send function")
    func sendButtonAndDictationShareSubmit() throws {
        let source = try composerBarSource()
        #expect(source.contains("private func submitComposer(text: String) {\n        onSend(text, pendingAttachments)"))

        let sendButton = try #require(source.range(of: "systemImage: isVoice ? \"waveform\" : \"arrow.up\""))
        let buttonTail = source[sendButton.upperBound...]
        let buttonEnd = try #require(buttonTail.range(of: ".disabled(!isLit)"))
        #expect(buttonTail[..<buttonEnd.lowerBound].contains("submitComposer(text: composerText)"))

        let host = try #require(source.range(of: ".modifier(ChatComposerDictationHost("))
        let hostTail = source[host.upperBound...]
        let hostEnd = try #require(hostTail.range(of: "\n        ))"))
        #expect(hostTail[..<hostEnd.lowerBound].contains("onSend: { text in submitComposer(text: text) }"))
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
