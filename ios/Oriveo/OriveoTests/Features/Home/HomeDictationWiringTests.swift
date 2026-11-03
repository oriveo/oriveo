import Foundation
import Testing
@testable import Oriveo

/// The home composer takes dictation, consistent with the chat page.
/// A source scan locks the wiring points: the toggle container, the card slot, the dictation host (home draft slot) and the text view's selection output.
@Suite("Home dictation wiring")
struct HomeDictationWiringTests {

    @Test("the home card is wrapped in the dictation toggle container, with the card slot above it, the dictation host attached, and the home draft slot used")
    func homeWiresDictation() throws {
        let source = try homeViewSource()

        #expect(source.contains("DictationInputSwitcher("))
        #expect(source.contains("DictationPromptSlot("))
        #expect(source.contains(".dictationHost("))
        #expect(source.contains("RecordingStore.homeDraftKey"))
    }

    @Test("the home text view passes out the selection")
    func openVoiceSettingsRoute() throws {
        let source = try homeViewSource()
        #expect(source.contains("onOpenVoiceSettings: openDictationVoiceSettings"))
        #expect(source.contains("private func openDictationVoiceSettings() {\n        navigation.attemptNavigate(to: .voiceSettings)"))
    }

    @Test("the home text view passes out the selection")
    func heroComposerPassesSelectionProbe() throws {
        let source = try homeViewSource()

        let textViewCall = try #require(source.range(of: "ComposerTextView("))
        let tail = source[textViewCall.upperBound...]
        let callEnd = try #require(tail.range(of: "\n            )"))
        #expect(tail[..<callEnd.lowerBound].contains("selectionProbe:"))
    }

    @Test("the dictation host sits at the root of the home body, an ancestor of the toggle container and the card slot")
    func dictationHostWrapsDictationViews() throws {
        let source = try homeViewSource()
        let hostType = try #require(DictationHostSourceScan.typeBody(source, type: "HomeDictationHost", keyword: "private struct"))
        #expect(hostType.contains("content.dictationHost("))

        let wrapped = try #require(
            DictationHostSourceScan.wrappedSource(source, type: "HomeView", hostMarker: ".modifier(HomeDictationHost(")
        )
        for target in ["DictationInputSwitcher(", "DictationPromptSlot("] {
            #expect(wrapped.contains(target), "the host does not wrap \(target)")
        }
    }

    @Test("home has no microphone; the recording bar's ↑ and the host's canSend both look at the sending state")
    func sendingDisablesMicAndSend() throws {
        let source = try homeViewSource()
        #expect(!source.contains("DictationMicButton("), "home bottom bar drops the microphone")
        #expect(source.contains("DictationInputSwitcher(controller: controller, canSend: canHandOffFromHero)"))

        let host = try #require(source.range(of: ".modifier(HomeDictationHost("))
        let hostTail = source[host.upperBound...]
        let hostEnd = try #require(hostTail.range(of: "\n        ))"))
        #expect(hostTail[..<hostEnd.lowerBound].contains("canSend: { canHandOffFromHero }"))

        let hostType = try #require(DictationHostSourceScan.typeBody(source, type: "HomeDictationHost", keyword: "private struct"))
        #expect(hostType.contains("canSend: canSend"))
        #expect(!hostType.contains("canSend: { true }"))
    }

    @Test("Live text: the home screen hands the selection exit and draft binding to the dictation host")
    func liveTextWiredThroughProbe() throws {
        let source = try homeViewSource()
        let host = try #require(source.range(of: ".modifier(HomeDictationHost("))
        let hostTail = source[host.upperBound...]
        let hostEnd = try #require(hostTail.range(of: "\n        ))"))
        #expect(hostTail[..<hostEnd.lowerBound].contains("live: .probe(dictationProbe, text: $heroText)"))

        let hostType = try #require(DictationHostSourceScan.typeBody(source, type: "HomeDictationHost", keyword: "private struct"))
        #expect(hostType.contains("live: live"))
    }

    private func homeViewSource() throws -> String {
        let projectDirectory = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let sourceURL = projectDirectory
            .appendingPathComponent("Oriveo")
            .appendingPathComponent("Features")
            .appendingPathComponent("Home")
            .appendingPathComponent("HomeView.swift")
        return try String(contentsOf: sourceURL, encoding: .utf8)
    }
}

/// View source scan: starting from the view property that mounts the dictation host, follow `var X: some View` property references and collect all the source the host wraps.
/// Only a host modifier attached to that property's root expression counts (a chained modifier at 8-space indentation), and everything before it is the wrapped content.
enum DictationHostSourceScan {
    /// The type body from `<keyword> <type>` to the first flush-left `}`.
    static func typeBody(_ source: String, type: String, keyword: String = "struct") -> Substring? {
        guard let start = source.range(of: "\n\(keyword) \(type):") else { return nil }
        let tail = source[start.upperBound...]
        guard let end = tail.range(of: "\n}\n") else { return nil }
        return tail[..<end.lowerBound]
    }

    /// The body of each `var X: some View {` and `func X(…) -> some View {` in the type body (up to the `}` indented by 4 spaces).
    static func viewProperties(in body: Substring) -> [String: Substring] {
        let text = String(body)
        let pattern = try! NSRegularExpression(
            pattern: #"(?m)^    (?:private |fileprivate )?(?:var (\w+): some View|func (\w+)\([^)\n]*\) -> some View) \{$"#
        )
        var result: [String: Substring] = [:]
        for match in pattern.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
            let nameGroup = match.range(at: 1).location != NSNotFound ? 1 : 2
            guard let nameRange = Range(match.range(at: nameGroup), in: text),
                  let whole = Range(match.range, in: text) else { continue }
            let tail = text[whole.upperBound...]
            guard let end = tail.range(of: "\n    }\n") else { continue }
            result[String(text[nameRange])] = tail[..<end.lowerBound]
        }
        return result
    }

    /// The root expression before the host modifier plus every view property body reachable from it; nil when the host is not on a property root.
    static func wrappedSource(_ source: String, type: String, hostMarker: String) -> String? {
        guard let body = typeBody(source, type: type) else { return nil }
        let properties = viewProperties(in: body)
        guard let (rootName, rootBody) = properties.first(where: { $0.value.contains(hostMarker) }),
              let marker = rootBody.range(of: "\n        " + hostMarker) else { return nil }
        var visited: Set<String> = [rootName]
        var pending = [String(rootBody[..<marker.lowerBound])]
        var collected = ""
        while let text = pending.popLast() {
            collected += text + "\n"
            for (name, propertyBody) in properties where !visited.contains(name) {
                let reference = try! NSRegularExpression(pattern: "\\b\(name)\\b")
                guard reference.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil else { continue }
                visited.insert(name)
                pending.append(String(propertyBody))
            }
        }
        return collected
    }
}
