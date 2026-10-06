import Foundation

/// The "thinking" toggle on the model options panel for a custom LLM or a local engine.
///
/// Such a connection has no official configuration, and thinking can only be switched through the chat template:
/// `chat_template_kwargs.enable_thinking` in the additional request body. The toggle's displayed value and its writes land in the same place, the additional request body stored for
/// connection × model × this conversation, so the toggle on the panel and the line on the additional request body page are always the same thing.
nonisolated enum ChatTemplateThinkingSwitch {
    static let argumentsKey = "chat_template_kwargs"
    static let switchKey = "enable_thinking"

    enum State: Equatable, Sendable {
        case off
        case on
        /// The stored content has a problem (not a valid JSON object, rejected on the device, or the chat template arguments are not an object).
        /// The toggle cannot change it; it has to be fixed on the additional request body page first.
        case blocked
        /// The stored content has other fields and "Send with requests" is off. Flipping this toggle must not start sending those fields
        /// along; sending has to be turned on by the user on the additional request body page first.
        case notSending
    }

    /// The toggle only appears on a protocol that applies a chat template: Chat Completions. The criterion looks at the resolved protocol only,
    /// not at who the connection is or what the model is called. It does not appear while the protocol is undecided (nil).
    static func applies(toTransport transport: String?) -> Bool {
        transport == RelayTransport.openaiChatCompletions.rawValue
    }

    enum WriteError: Error, Equatable, Sendable {
        /// The stored content is not a JSON object.
        case notAnObject
        /// `chat_template_kwargs` already has a value, but it is not an object.
        case templateArgumentsNotAnObject
    }

    // MARK: - Reading

    /// "On" = this item is written as true, and the additional request body is sent with requests.
    static func state(of configuration: AdditionalRequestBodyConfiguration) -> State {
        let raw = configuration.rawJSON
        guard !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return .off }
        guard case let .success(object) = AdditionalRequestBody.parse(raw) else { return .blocked }
        var arguments: [String: Any] = [:]
        if let stored = object[argumentsKey] {
            guard let stored = stored as? [String: Any] else { return .blocked }
            arguments = stored
        }
        guard configuration.sendsWithRequest else {
            return carriesOtherFields(object: object, arguments: arguments) ? .notSending : .off
        }
        return isTrue(arguments[switchKey]) ? .on : .off
    }

    /// Whether anything is written besides the item this toggle controls.
    private static func carriesOtherFields(object: [String: Any], arguments: [String: Any]) -> Bool {
        object.keys.contains { $0 != argumentsKey } || arguments.keys.contains { $0 != switchKey }
    }

    private static func isTrue(_ value: Any?) -> Bool {
        guard let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else { return false }
        return number.boolValue
    }

    // MARK: - Writing

    /// Writes the toggle into the stored text: only the one value `chat_template_kwargs.enable_thinking` is touched;
    /// the user's other fields, their order and their formatting stay as they are. When the text is not a JSON object it is not overwritten and this fails.
    static func setting(_ isOn: Bool, in raw: String) -> Result<String, WriteError> {
        let literal = isOn ? "true" : "false"
        if raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return .success("{\n  \"\(argumentsKey)\": {\n    \"\(switchKey)\": \(literal)\n  }\n}")
        }
        guard var expected = (try? JSONSerialization.jsonObject(with: Data(raw.utf8))) as? [String: Any] else {
            return .failure(.notAnObject)
        }
        var arguments: [String: Any] = [:]
        if let existing = expected[argumentsKey] {
            guard let object = existing as? [String: Any] else { return .failure(.templateArgumentsNotAnObject) }
            arguments = object
        }
        arguments[switchKey] = isOn
        expected[argumentsKey] = arguments

        // After the in-place rewrite the text is parsed again, and the result is used only if it equals "just this one value changed" item by item.
        if let edited = editedInPlace(raw, literal: literal),
           let reparsed = (try? JSONSerialization.jsonObject(with: Data(edited.utf8))) as? [String: Any],
           NSDictionary(dictionary: reparsed).isEqual(to: expected) {
            return .success(edited)
        }
        // When the text is written in a way that cannot be rewritten in place (an escaped key name, for example) everything is laid out again, losing no content.
        guard let data = try? JSONSerialization.data(
            withJSONObject: expected, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        ) else { return .failure(.notAnObject) }
        return .success(String(decoding: data, as: UTF8.self))
    }

    /// What to store after the toggle is flipped: the content rewritten by `setting`, with "Send with requests" on.
    ///
    /// Flipping also turns sending on only when the content is empty or holds this item alone; when the stored content has a problem, or carries other fields while not
    /// being sent, this returns nil and the caller must not write.
    static func applying(
        _ isOn: Bool, to configuration: AdditionalRequestBodyConfiguration
    ) -> AdditionalRequestBodyConfiguration? {
        switch state(of: configuration) {
        case .blocked, .notSending: return nil
        case .on, .off: break
        }
        guard case let .success(raw) = setting(isOn, in: configuration.rawJSON) else { return nil }
        return .init(rawJSON: raw, sendsWithRequest: true)
    }

    /// The single write entry for the panel's toggle.
    ///
    /// It starts from what is **in effect** for this scope right now (the model default when the conversation layer has no record) and writes to the conversation layer:
    /// a conversation-layer record covers the model default entirely, so leaving the existing content out would delete the user's other fields.
    @MainActor
    @discardableResult
    static func write(
        _ isOn: Bool, providerID: UUID, modelID: String, conversationID: UUID?
    ) -> Bool {
        let store = GenerationParameterSettingsStore.shared
        let current = store.effectiveAdditionalRequestBody(
            providerID: providerID, modelID: modelID, conversationID: conversationID
        )
        guard let next = applying(isOn, to: current) else { return false }
        store.setAdditionalRequestBody(
            next, providerID: providerID, modelID: modelID, conversationID: conversationID
        )
        return true
    }

    // MARK: - In-place rewrite

    private static func editedInPlace(_ raw: String, literal: String) -> String? {
        let scanner = JSONTextScanner(bytes: Array(raw.utf8))
        guard let root = scanner.object(at: scanner.skippingWhitespace(from: 0)) else { return nil }
        let member = "\"\(switchKey)\": \(literal)"

        if let arguments = root.members.first(where: { $0.key == argumentsKey }) {
            guard let nested = scanner.object(at: arguments.valueStart) else { return nil }
            if let existing = nested.members.first(where: { $0.key == switchKey }) {
                return scanner.replacing(existing.valueStart..<existing.valueEnd, with: literal)
            }
            return scanner.appending(member, to: nested)
        }

        // When the root object is written over several lines the new part is put on its own lines too, indented like the original.
        let lead = scanner.leadingWhitespace(of: root)
        let nested: String
        if let newline = lead.lastIndex(of: "\n") {
            let indent = String(lead[lead.index(after: newline)...])
            nested = "{" + lead + indent + member + lead + "}"
        } else {
            nested = "{" + member + "}"
        }
        return scanner.appending("\"\(argumentsKey)\": " + nested, to: root)
    }
}

/// A JSON text scanner that does just enough to locate object members. The input is already known to be valid JSON from `JSONSerialization`;
/// nothing is validated here, only located, and anything it does not understand returns nil so the caller falls back to laying everything out again.
private nonisolated struct JSONTextScanner {
    struct Member {
        let key: String
        let keyStart: Int
        let valueStart: Int
        let valueEnd: Int
    }

    struct ObjectSpan {
        let open: Int
        let close: Int
        let members: [Member]
    }

    let bytes: [UInt8]

    private static let whitespace: Set<UInt8> = [9, 10, 13, 32]

    func skippingWhitespace(from index: Int) -> Int {
        var cursor = index
        while cursor < bytes.count, Self.whitespace.contains(bytes[cursor]) { cursor += 1 }
        return cursor
    }

    /// `index` points at the opening quote; returns the position after the closing quote.
    private func endOfString(at index: Int) -> Int? {
        guard index < bytes.count, bytes[index] == 34 else { return nil }
        var cursor = index + 1
        while cursor < bytes.count {
            if bytes[cursor] == 92 {
                cursor += 2
            } else if bytes[cursor] == 34 {
                return cursor + 1
            } else {
                cursor += 1
            }
        }
        return nil
    }

    private func endOfValue(at index: Int) -> Int? {
        guard index < bytes.count else { return nil }
        switch bytes[index] {
        case 34:
            return endOfString(at: index)
        case 123, 91:
            var depth = 0
            var cursor = index
            while cursor < bytes.count {
                switch bytes[cursor] {
                case 34:
                    guard let end = endOfString(at: cursor) else { return nil }
                    cursor = end
                    continue
                case 123, 91:
                    depth += 1
                case 125, 93:
                    depth -= 1
                    if depth == 0 { return cursor + 1 }
                default:
                    break
                }
                cursor += 1
            }
            return nil
        default:
            var cursor = index
            while cursor < bytes.count, ![44, 125, 93].contains(bytes[cursor]),
                  !Self.whitespace.contains(bytes[cursor]) {
                cursor += 1
            }
            return cursor > index ? cursor : nil
        }
    }

    func object(at index: Int) -> ObjectSpan? {
        guard index < bytes.count, bytes[index] == 123 else { return nil }
        var members: [Member] = []
        var cursor = skippingWhitespace(from: index + 1)
        if cursor < bytes.count, bytes[cursor] == 125 {
            return ObjectSpan(open: index, close: cursor, members: [])
        }
        while cursor < bytes.count {
            let keyStart = cursor
            guard let keyEnd = endOfString(at: keyStart),
                  let key = (try? JSONSerialization.jsonObject(
                      with: Data(bytes[keyStart..<keyEnd]), options: [.fragmentsAllowed]
                  )) as? String else { return nil }
            cursor = skippingWhitespace(from: keyEnd)
            guard cursor < bytes.count, bytes[cursor] == 58 else { return nil }
            let valueStart = skippingWhitespace(from: cursor + 1)
            guard let valueEnd = endOfValue(at: valueStart) else { return nil }
            members.append(Member(key: key, keyStart: keyStart, valueStart: valueStart, valueEnd: valueEnd))
            cursor = skippingWhitespace(from: valueEnd)
            guard cursor < bytes.count else { return nil }
            if bytes[cursor] == 125 { return ObjectSpan(open: index, close: cursor, members: members) }
            guard bytes[cursor] == 44 else { return nil }
            cursor = skippingWhitespace(from: cursor + 1)
        }
        return nil
    }

    /// The whitespace between the opening brace and the first member; an empty string for an empty object.
    func leadingWhitespace(of object: ObjectSpan) -> String {
        guard let first = object.members.first else { return "" }
        return String(decoding: bytes[(object.open + 1)..<first.keyStart], as: UTF8.self)
    }

    func replacing(_ range: Range<Int>, with text: String) -> String {
        String(decoding: bytes[..<range.lowerBound] + Array(text.utf8) + bytes[range.upperBound...], as: UTF8.self)
    }

    /// Appended after the object's last member, separated the way the original is.
    func appending(_ member: String, to object: ObjectSpan) -> String {
        guard let last = object.members.last else {
            return replacing((object.open + 1)..<object.close, with: member)
        }
        let lead = leadingWhitespace(of: object)
        let separator = lead.contains("\n") ? "," + lead : ", "
        return replacing(last.valueEnd..<last.valueEnd, with: separator + member)
    }
}
