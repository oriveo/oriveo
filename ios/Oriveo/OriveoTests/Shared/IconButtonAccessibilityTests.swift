import Foundation
import Testing
@testable import Oriveo

/// Buttons that show only an icon or a symbol need a screen reader label: without one VoiceOver can only read the
/// system's guess for the symbol ("robot face", "question mark", "ellipsis"), or nothing at all.
@Suite("Icon button accessibility")
struct IconButtonAccessibilityTests {
    struct Case: CustomStringConvertible, Sendable {
        let file: String
        /// The call that builds the control (`Button`, `Menu`, `navToneButton`)
        let callee: String
        /// Text that only appears inside that call; the nearest `callee` before it is the control
        let inner: String

        var description: String { "\(file) · \(callee) ⊃ \(inner)" }
    }

    static let iconButtons: [Case] = [
        Case(file: "Features/Skills/SkillEditView.swift", callee: "Button", inner: "iconInput = icon"),
        Case(file: "Features/Skills/SkillEditView.swift", callee: "Button", inner: "Text(\"?\")"),
        Case(file: "Features/Skills/SkillsListView.swift", callee: "navToneButton", inner: "navToneButton(systemName: \"plus\""),
        Case(file: "Features/Notes/NoteDetailView.swift", callee: "Button", inner: "Image(systemName: \"arrow.up.circle.fill\")"),
        Case(file: "Features/Providers/ProviderEnabledModels.swift", callee: "Button", inner: "Image(systemName: \"bubble.left.and.bubble.right.fill\")"),
        // The "…" control is a Menu; find it from its first item
        Case(file: "Features/Providers/ProviderEnabledModels.swift", callee: "Menu", inner: "L10n.tr(\"Set as Default\", table: .providers)"),
        Case(file: "Features/Chat/ChatAttachmentPicker.swift", callee: "Button", inner: "onRemove(attachment.id)"),
    ]

    @Test("Icon-only buttons carry a screen reader label", arguments: iconButtons)
    func iconButtonHasAccessibilityLabel(_ button: Case) throws {
        let source = try ProductionSource.read(button.file)
        let chain = try #require(
            SwiftCallScan.modifierChain(ofCall: button.callee, enclosing: button.inner, in: source),
            "\(button) not found"
        )
        #expect(chain.contains("accessibilityLabel"), "\(button) has no accessibilityLabel; modifier chain: \(chain)")
    }

    @Test("Memory alert buttons go through L10n and follow the in-app language, not the system language")
    func memoryAlertButtonsUseAppLanguage() throws {
        let memory = try ProductionSource.read("Features/Settings/MemoryView.swift")
        #expect(!memory.contains("Button(\"OK\""), "Button(\"OK\") looks up the system-language Localizable and ignores the in-app language setting")
    }

    @Test("Self check: the call scan finds the control and reads its modifier chain")
    func selfCheckModifierChainLookup() {
        let source = #"""
        Button { go(L10n.tr("x")) } label: { Image(systemName: "x") }
            .buttonStyle(.plain)
            // a comment between modifiers
            .accessibilityLabel(L10n.tr("A"))
        navToneButton(systemName: "plus", tint: .red) { add("(") }
            .accessibilityLabel(L10n.tr("B"))
        Menu {
            if canSetDefault {
                Button(action: setDefault) { Label("Default \(name)", systemImage: "star") }
            }
        } label: { Image(systemName: "ellipsis") }
        .buttonStyle(.plain)
        .accessibilityLabel(L10n.tr("More"))
        Button(L10n.tr("Plain")) { plain() }
        """#
        #expect(SwiftCallScan.modifierChain(ofCall: "Button", enclosing: "Image(systemName: \"x\")", in: source) == ["buttonStyle", "accessibilityLabel"])
        #expect(SwiftCallScan.modifierChain(ofCall: "navToneButton", enclosing: "navToneButton(systemName: \"plus\"", in: source) == ["accessibilityLabel"])
        #expect(SwiftCallScan.modifierChain(ofCall: "Menu", enclosing: "systemImage: \"star\"", in: source) == ["buttonStyle", "accessibilityLabel"])
        #expect(SwiftCallScan.modifierChain(ofCall: "Button", enclosing: "systemImage: \"star\"", in: source) == [])
        #expect(SwiftCallScan.modifierChain(ofCall: "Button", enclosing: "plain()", in: source) == [])
        #expect(SwiftCallScan.modifierChain(ofCall: "Button", enclosing: "missing()", in: source) == nil)
    }
}

/// A small forward scanner over Swift source for structural assertions: find a call, skip its arguments and trailing
/// closures, and list the modifiers chained after it. It skips string literals (including interpolation) and
/// comments, which is all these checks need.
enum SwiftCallScan {
    /// The names of the modifiers after the nearest `callee` call that starts before `inner` and whose arguments or
    /// trailing closures contain it. nil when there is no such call.
    static func modifierChain(ofCall callee: String, enclosing inner: String, in source: String) -> [String]? {
        let code = Array(source.utf8)
        guard let innerRange = source.range(of: inner) else { return nil }
        let innerStart = source.utf8.distance(from: source.startIndex, to: innerRange.lowerBound)
        let name = Array(callee.utf8)
        var start = min(innerStart, code.count - name.count)
        while start >= 0 {
            if isCall(name, at: start, in: code), let end = callEnd(nameStart: start, nameLength: name.count, in: code),
               end > innerStart {
                return modifiers(after: end, in: code)
            }
            start -= 1
        }
        return nil
    }

    private static func isCall(_ name: [UInt8], at index: Int, in code: [UInt8]) -> Bool {
        guard index + name.count <= code.count, Array(code[index..<index + name.count]) == name else { return false }
        if index > 0, isIdentifier(code[index - 1]) { return false }
        let next = skipSpace(from: index + name.count, in: code)
        return next < code.count && (code[next] == UInt8(ascii: "(") || code[next] == UInt8(ascii: "{"))
    }

    /// Index just past the call: its argument list plus any trailing closures (`{ … }`, `label: { … }`).
    private static func callEnd(nameStart: Int, nameLength: Int, in code: [UInt8]) -> Int? {
        var cursor = skipSpace(from: nameStart + nameLength, in: code)
        if cursor < code.count, code[cursor] == UInt8(ascii: "(") {
            guard let close = matching(from: cursor, in: code) else { return nil }
            cursor = close + 1
        }
        return trailingClosures(from: cursor, in: code)
    }

    private static func trailingClosures(from start: Int, in code: [UInt8]) -> Int? {
        var end = start
        while true {
            let next = skipSpace(from: end, in: code)
            if next < code.count, code[next] == UInt8(ascii: "{") {
                guard let close = matching(from: next, in: code) else { return nil }
                end = close + 1
                continue
            }
            // A labeled trailing closure: `label: { … }`
            var word = next
            while word < code.count, isIdentifier(code[word]) { word += 1 }
            let colon = skipSpace(from: word, in: code)
            if word > next, colon < code.count, code[colon] == UInt8(ascii: ":") {
                let brace = skipSpace(from: colon + 1, in: code)
                if brace < code.count, code[brace] == UInt8(ascii: "{"), let close = matching(from: brace, in: code) {
                    end = close + 1
                    continue
                }
            }
            return end
        }
    }

    private static func modifiers(after start: Int, in code: [UInt8]) -> [String] {
        var names: [String] = []
        var cursor = start
        while true {
            let dot = skipSpace(from: cursor, in: code)
            guard dot < code.count, code[dot] == UInt8(ascii: ".") else { return names }
            var word = dot + 1
            while word < code.count, isIdentifier(code[word]) { word += 1 }
            guard word > dot + 1 else { return names }
            names.append(String(decoding: code[(dot + 1)..<word], as: UTF8.self))
            cursor = word
            let open = skipSpace(from: cursor, in: code)
            if open < code.count, code[open] == UInt8(ascii: "("), let close = matching(from: open, in: code) {
                cursor = close + 1
            }
            guard let afterClosures = trailingClosures(from: cursor, in: code) else { return names }
            cursor = afterClosures
        }
    }

    /// Index of the bracket that closes the one at `open`, skipping strings and comments.
    private static func matching(from open: Int, in code: [UInt8]) -> Int? {
        var depth = 0
        var index = open
        while index < code.count {
            let byte = code[index]
            if byte == UInt8(ascii: "\"") {
                guard let end = stringEnd(from: index, in: code) else { return nil }
                index = end + 1
                continue
            }
            if byte == UInt8(ascii: "/"), index + 1 < code.count, code[index + 1] == UInt8(ascii: "/") {
                while index < code.count, code[index] != UInt8(ascii: "\n") { index += 1 }
                continue
            }
            if isOpen(byte) {
                depth += 1
            } else if isClose(byte) {
                depth -= 1
                if depth == 0 { return index }
            }
            index += 1
        }
        return nil
    }

    /// Index of the closing quote of the string literal that starts at `start` (single-line or `"""`).
    private static func stringEnd(from start: Int, in code: [UInt8]) -> Int? {
        let quote = UInt8(ascii: "\"")
        let multiline = start + 2 < code.count && code[start + 1] == quote && code[start + 2] == quote
        var index = start + (multiline ? 3 : 1)
        while index < code.count {
            let byte = code[index]
            if byte == UInt8(ascii: "\\") {
                if index + 1 < code.count, code[index + 1] == UInt8(ascii: "(") {
                    guard let close = matching(from: index + 1, in: code) else { return nil }
                    index = close + 1
                } else {
                    index += 2
                }
                continue
            }
            if byte == quote {
                if !multiline { return index }
                if index + 2 < code.count, code[index + 1] == quote, code[index + 2] == quote { return index + 2 }
            }
            index += 1
        }
        return nil
    }

    private static func skipSpace(from start: Int, in code: [UInt8]) -> Int {
        var index = start
        while index < code.count {
            let byte = code[index]
            if byte == UInt8(ascii: " ") || byte == UInt8(ascii: "\n") || byte == UInt8(ascii: "\t") || byte == UInt8(ascii: "\r") {
                index += 1
            } else if byte == UInt8(ascii: "/"), index + 1 < code.count, code[index + 1] == UInt8(ascii: "/") {
                while index < code.count, code[index] != UInt8(ascii: "\n") { index += 1 }
            } else {
                return index
            }
        }
        return index
    }

    private static func isOpen(_ byte: UInt8) -> Bool {
        byte == UInt8(ascii: "(") || byte == UInt8(ascii: "[") || byte == UInt8(ascii: "{")
    }

    private static func isClose(_ byte: UInt8) -> Bool {
        byte == UInt8(ascii: ")") || byte == UInt8(ascii: "]") || byte == UInt8(ascii: "}")
    }

    private static func isIdentifier(_ byte: UInt8) -> Bool {
        (byte >= UInt8(ascii: "a") && byte <= UInt8(ascii: "z"))
            || (byte >= UInt8(ascii: "A") && byte <= UInt8(ascii: "Z"))
            || (byte >= UInt8(ascii: "0") && byte <= UInt8(ascii: "9"))
            || byte == UInt8(ascii: "_")
    }
}
