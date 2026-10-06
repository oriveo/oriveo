import Foundation

/// Pure logic of the additional request body editor: from the text it computes the per-field "when sent" list, the lines to highlight, the syntax coloring tokens,
/// and the layout after "Format".
///
/// Whether the body can be sent is decided by `AdditionalRequestBody.parse` alone; there is no second standard here, only the
/// specifics of which line, which field and why.
enum AdditionalRequestBodyInspector {
    struct Field: Equatable, Identifiable {
        enum Status: Equatable {
            /// Merged into the request as written.
            case added
            /// A field of the request skeleton, filled in by Oriveo; it cannot be changed.
            case protected
            /// A name that cannot be used as a field name.
            case blockedName
        }

        /// Dot path, for example `chat_template_kwargs.enable_thinking`.
        let path: String
        /// The line of this key in the text (starting at 1).
        let line: Int
        let status: Status

        var id: String { "\(line):\(path)" }
        /// The last path segment, the key's own name.
        var name: String { path.split(separator: ".").last.map(String.init) ?? path }
    }

    struct Report: Equatable {
        let fields: [Field]
        /// The verdict of the on-device validation; nil means this content can be sent (blank content is nil as well).
        let rejection: AdditionalRequestBodyRejection?
        /// Lines to highlight as a whole.
        let errorLines: Set<Int>
        /// The text is blank.
        let isBlank: Bool

        /// The number of fields that will be added to the request.
        var addedCount: Int { fields.filter { $0.status == .added }.count }
    }

    /// How many levels nested objects are expanded; anything deeper counts as one field.
    static let maxExpandedDepth = 4

    static func inspect(_ raw: String) -> Report {
        guard !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .init(fields: [], rejection: nil, errorLines: [], isBlank: true)
        }
        let rejection: AdditionalRequestBodyRejection? = {
            if case .failure(let rejection) = AdditionalRequestBody.parse(raw) { return rejection }
            return nil
        }()
        var parser = Parser(raw)
        let outcome = parser.parseDocument()
        var errorLines: Set<Int> = []
        var fields: [Field] = []
        switch outcome {
        case .success(.object(let members)):
            fields = Self.fields(of: members)
        case .success:
            // Valid JSON whose root is not an object: all of it is wrong, so the first line is highlighted.
            errorLines.insert(1)
        case .failure(let failure):
            errorLines.insert(failure.line)
        }
        for field in fields where field.status != .added { errorLines.insert(field.line) }
        if let line = rejection?.line { errorLines.insert(line) }
        // When the content cannot be sent and no line can be located, none is singled out: the note explains the reason.
        return .init(fields: fields, rejection: rejection, errorLines: rejection == nil ? [] : errorLines, isBlank: false)
    }

    private static func fields(of members: [Parser.Member]) -> [Field] {
        var result: [Field] = []
        func walk(_ member: Parser.Member, path: String, depth: Int) {
            if AdditionalRequestBody.blockedSegments.contains(member.key) {
                result.append(.init(path: path, line: member.line, status: .blockedName))
                return
            }
            if case .object(let children) = member.value, !children.isEmpty, depth < maxExpandedDepth {
                for child in children { walk(child, path: "\(path).\(child.key)", depth: depth + 1) }
            } else {
                result.append(.init(path: path, line: member.line, status: .added))
            }
        }
        for member in members {
            // Protected fields only count at the root; a key of the same name nested in another object is not restricted.
            if AdditionalRequestBody.protectedRootFields.contains(member.key) {
                result.append(.init(path: member.key, line: member.line, status: .protected))
            } else {
                walk(member, path: member.key, depth: 1)
            }
        }
        return result
    }

    /// "Format": lays valid JSON out again (two-space indent, key order unchanged). Returns nil for invalid JSON and leaves the text alone.
    static func formatted(_ raw: String) -> String? {
        var parser = Parser(raw)
        guard case .success(let node) = parser.parseDocument() else { return nil }
        var output = ""
        write(node, indent: 0, into: &output)
        return output
    }

    private static func write(_ node: Parser.Node, indent: Int, into output: inout String) {
        let pad = String(repeating: "  ", count: indent)
        let inner = String(repeating: "  ", count: indent + 1)
        switch node {
        case .scalar(let literal):
            output += literal
        case .object(let members):
            guard !members.isEmpty else { output += "{}"; return }
            output += "{\n"
            for (index, member) in members.enumerated() {
                output += "\(inner)\(member.rawKey): "
                write(member.value, indent: indent + 1, into: &output)
                output += index == members.count - 1 ? "\n" : ",\n"
            }
            output += "\(pad)}"
        case .array(let items):
            guard !items.isEmpty else { output += "[]"; return }
            output += "[\n"
            for (index, item) in items.enumerated() {
                output += inner
                write(item, indent: indent + 1, into: &output)
                output += index == items.count - 1 ? "\n" : ",\n"
            }
            output += "\(pad)]"
        }
    }

    // MARK: - Field notes

    /// The reason under a protected field's line. Field names come from a closed list.
    static func explanation(for field: Field) -> String {
        let reason: String
        switch field.status {
        case .added:
            return ""
        case .blockedName:
            reason = L10n.tr("This name can’t be used as a field name.", table: .chat)
        case .protected:
            switch field.name {
            case "messages", "input", "contents", "prompt":
                reason = L10n.tr("The conversation is filled in by Oriveo.", table: .chat)
            case "model":
                reason = L10n.tr("The model is the one you chose in Oriveo.", table: .chat)
            case "attachments":
                reason = L10n.tr("Attachments are filled in by Oriveo.", table: .chat)
            case "instructions", "system":
                reason = L10n.tr("The system prompt is filled in by Oriveo.", table: .chat)
            case "stream", "stream_options":
                reason = L10n.tr("Oriveo decides how the reply is streamed.", table: .chat)
            case "tools", "tool_choice", "plugins":
                reason = L10n.tr("Tools are managed by Oriveo.", table: .chat)
            default:
                reason = L10n.tr("This field is filled in by Oriveo.", table: .chat)
            }
        }
        return String(format: L10n.tr("%1$@ Remove line %2$lld to send.", table: .chat), reason, field.line)
    }

    // MARK: - Engine documentation

    struct EngineDocumentation: Equatable {
        let engineName: String
        let url: URL
    }

    /// Each engine's official documentation on which request body fields it supports. The addresses match the shared contract
    /// `generation_parameter_contract.v1.json#localEngineRules.sources` entry by entry (a test reconciles them);
    /// an engine not registered in the contract gets no link.
    static let engineDocumentationSources: [String: (name: String, url: String)] = [
        "llamacpp": ("llama.cpp", "https://github.com/ggml-org/llama.cpp/blob/master/tools/server/README.md"),
        "ollama": ("Ollama", "https://docs.ollama.com/api/openai-compatibility"),
        "lmstudio": ("LM Studio", "https://lmstudio.ai/docs/developer/openai-compat/chat-completions"),
        "vllm": ("vLLM", "https://docs.vllm.ai/en/latest/serving/online_serving/openai_compatible_server/"),
    ]

    static func engineDocumentation(engineProfile: String?) -> EngineDocumentation? {
        guard let engineProfile, let source = engineDocumentationSources[engineProfile],
              let url = URL(string: source.url) else { return nil }
        return .init(engineName: source.name, url: url)
    }

    /// The name this engine goes by in the interface (a brand name, not translated).
    static func engineName(engineProfile: String?) -> String? {
        switch engineProfile {
        case "openwebui": return "Open WebUI"
        case let profile?: return engineDocumentationSources[profile]?.name
        case nil: return nil
        }
    }

    // MARK: - Syntax coloring

    enum TokenKind: Equatable {
        case key
        case string
        case literal
        case punctuation
    }

    struct Token: Equatable {
        /// A UTF-16 range, usable directly with `NSAttributedString`.
        let range: NSRange
        let kind: TokenKind
        /// For `key` only: the text without quotes (escapes not resolved).
        let text: String
        /// The line it is on (starting at 1).
        let line: Int
        /// Nesting depth; direct children of the root object are 1.
        let depth: Int
    }

    /// A lenient tokenizer: invalid text is still colored, and nothing throws.
    static func tokens(_ raw: String) -> [Token] {
        let units = Array(raw.utf16)
        var tokens: [Token] = []
        var index = 0
        var line = 1
        var depth = 0
        func unit(_ character: Character) -> UInt16 { character.utf16.first ?? 0 }
        let quote = unit("\""), backslash = unit("\\"), newline = unit("\n"), colon = unit(":")
        let whitespace: Set<UInt16> = [unit(" "), unit("\t"), unit("\r"), newline]
        let delimiters: Set<UInt16> = [unit(","), unit("}"), unit("]"), unit(":"), unit("{"), unit("["), quote]
        while index < units.count {
            let current = units[index]
            if current == newline { line += 1; index += 1; continue }
            if whitespace.contains(current) { index += 1; continue }
            if current == quote {
                let startLine = line
                var cursor = index + 1
                while cursor < units.count, units[cursor] != quote {
                    if units[cursor] == backslash { cursor += 1 }
                    if cursor < units.count, units[cursor] == newline { line += 1 }
                    cursor += 1
                }
                let end = min(cursor + 1, units.count)
                var after = end
                while after < units.count, whitespace.contains(units[after]) { after += 1 }
                let isKey = after < units.count && units[after] == colon
                let contentEnd = min(cursor, units.count)
                let text = String(utf16CodeUnits: Array(units[(index + 1)..<max(index + 1, contentEnd)]), count: max(0, contentEnd - index - 1))
                tokens.append(.init(
                    range: NSRange(location: index, length: end - index),
                    kind: isKey ? .key : .string, text: isKey ? text : "", line: startLine, depth: depth
                ))
                index = end
                continue
            }
            if current == unit("{") || current == unit("[") {
                depth += 1
                tokens.append(.init(range: NSRange(location: index, length: 1), kind: .punctuation, text: "", line: line, depth: depth))
                index += 1
                continue
            }
            if current == unit("}") || current == unit("]") {
                tokens.append(.init(range: NSRange(location: index, length: 1), kind: .punctuation, text: "", line: line, depth: depth))
                depth = max(0, depth - 1)
                index += 1
                continue
            }
            if current == unit(",") || current == colon {
                tokens.append(.init(range: NSRange(location: index, length: 1), kind: .punctuation, text: "", line: line, depth: depth))
                index += 1
                continue
            }
            // Numbers, true / false / null, and any mistyped bare word: read up to the next separator.
            var cursor = index
            while cursor < units.count, !whitespace.contains(units[cursor]), !delimiters.contains(units[cursor]) {
                cursor += 1
            }
            if cursor == index { cursor += 1 }
            tokens.append(.init(
                range: NSRange(location: index, length: cursor - index), kind: .literal, text: "", line: line, depth: depth
            ))
            index = cursor
        }
        return tokens
    }

    /// The UTF-16 range of line `line` (starting at 1) in the text, without the trailing newline.
    static func range(ofLine line: Int, in raw: String) -> NSRange? {
        guard line >= 1 else { return nil }
        let text = raw as NSString
        var current = 1
        var location = 0
        while current < line {
            let found = text.range(of: "\n", range: NSRange(location: location, length: text.length - location))
            guard found.location != NSNotFound else { return nil }
            location = found.location + 1
            current += 1
        }
        let end = text.range(of: "\n", range: NSRange(location: location, length: text.length - location))
        let length = (end.location == NSNotFound ? text.length : end.location) - location
        return NSRange(location: location, length: length)
    }

    static func lineCount(_ raw: String) -> Int {
        raw.utf16.reduce(1) { $1 == 10 ? $0 + 1 : $0 }
    }
}

// MARK: - Parsing that keeps key order and line numbers

extension AdditionalRequestBodyInspector {
    /// A strict JSON parser for two things only: the order and line of each key in the text (`JSONSerialization` gives neither),
    /// and the line a mistake is on.
    struct Parser {
        struct Failure: Error, Equatable {
            let line: Int
        }

        struct Member {
            /// The key name with escapes resolved.
            let key: String
            /// The key as written (with quotes), written back unchanged when formatting.
            let rawKey: String
            let line: Int
            let value: Node
        }

        indirect enum Node {
            case object([Member])
            case array([Node])
            /// The text of a string, number, or true / false / null.
            case scalar(String)
        }

        private let bytes: [UInt8]
        private var index = 0
        private var line = 1
        /// The line of the last valid token read. For errors where something expected is missing, such as a value or a closing bracket,
        /// the place to fix is this line, not the line of whichever `}` happens to be read next.
        private var lastTokenLine = 1

        init(_ raw: String) {
            bytes = Array(raw.utf8)
        }

        mutating func parseDocument() -> Result<Node, Failure> {
            do {
                skipWhitespace()
                let node = try parseValue(depth: 1)
                skipWhitespace()
                // Extra content after the root value: the surplus really is on this line.
                guard index == bytes.count else { throw Failure(line: line) }
                return .success(node)
            } catch let failure as Failure {
                return .failure(failure)
            } catch {
                return .failure(.init(line: line))
            }
        }

        private mutating func skipWhitespace() {
            while index < bytes.count {
                switch bytes[index] {
                case 10: line += 1; index += 1
                case 9, 13, 32: index += 1
                default: return
                }
            }
        }

        /// Consumes one structural token (`{ } [ ] : ,`).
        private mutating func consume() {
            index += 1
            lastTokenLine = line
        }

        /// A "something should be here" error: the content is missing after the last valid token, so it is located on that token's line.
        /// When the token read is one that should not be there, the problem is that token and it is located on the current line.
        private func missingOrUnexpected() -> Failure {
            guard index < bytes.count else { return Failure(line: lastTokenLine) }
            return [44, 58, 93, 125].contains(bytes[index]) ? Failure(line: lastTokenLine) : Failure(line: line)
        }

        private mutating func parseValue(depth: Int) throws -> Node {
            guard index < bytes.count else { throw missingOrUnexpected() }
            guard depth <= AdditionalRequestBody.maxDepth + 1 else { throw Failure(line: line) }
            switch bytes[index] {
            case 123: return try parseObject(depth: depth)
            case 91: return try parseArray(depth: depth)
            case 34: return .scalar(try parseString().raw)
            case 44, 58, 93, 125: throw missingOrUnexpected()
            default: return .scalar(try parseBareLiteral())
            }
        }

        private mutating func parseObject(depth: Int) throws -> Node {
            consume()
            var members: [Member] = []
            skipWhitespace()
            if index < bytes.count, bytes[index] == 125 { consume(); return .object(members) }
            while true {
                skipWhitespace()
                // A trailing comma before the close: the system parser used at the send boundary accepts it, and this stays consistent with that;
                // otherwise a body could be sent while its list is empty. "Format" removes the comma.
                if !members.isEmpty, index < bytes.count, bytes[index] == 125 { consume(); return .object(members) }
                guard index < bytes.count, bytes[index] == 34 else { throw missingOrUnexpected() }
                let keyLine = line
                let key = try parseString()
                skipWhitespace()
                guard index < bytes.count, bytes[index] == 58 else {
                    throw index < bytes.count ? Failure(line: line) : Failure(line: lastTokenLine)
                }
                consume()
                skipWhitespace()
                let value = try parseValue(depth: depth + 1)
                members.append(.init(key: key.decoded, rawKey: key.raw, line: keyLine, value: value))
                skipWhitespace()
                guard index < bytes.count else { throw Failure(line: lastTokenLine) }
                if bytes[index] == 44 { consume(); continue }
                if bytes[index] == 125 { consume(); return .object(members) }
                throw Failure(line: line)
            }
        }

        private mutating func parseArray(depth: Int) throws -> Node {
            consume()
            var items: [Node] = []
            skipWhitespace()
            if index < bytes.count, bytes[index] == 93 { consume(); return .array(items) }
            while true {
                skipWhitespace()
                if !items.isEmpty, index < bytes.count, bytes[index] == 93 { consume(); return .array(items) }
                items.append(try parseValue(depth: depth + 1))
                skipWhitespace()
                guard index < bytes.count else { throw Failure(line: lastTokenLine) }
                if bytes[index] == 44 { consume(); continue }
                if bytes[index] == 93 { consume(); return .array(items) }
                throw Failure(line: line)
            }
        }

        private mutating func parseString() throws -> (raw: String, decoded: String) {
            let start = index
            let startLine = line
            index += 1
            while index < bytes.count, bytes[index] != 34 {
                // A raw newline is not allowed inside a string; one means the closing quote is missing, and the error is on the line where the string starts.
                if bytes[index] == 10 { throw Failure(line: startLine) }
                if bytes[index] == 92 { index += 1 }
                index += 1
            }
            guard index < bytes.count else { throw Failure(line: startLine) }
            index += 1
            lastTokenLine = line
            let raw = String(decoding: bytes[start..<index], as: UTF8.self)
            guard let decoded = try? JSONSerialization.jsonObject(
                with: Data(bytes[start..<index]), options: [.fragmentsAllowed]
            ) as? String else { throw Failure(line: startLine) }
            return (raw, decoded)
        }

        private mutating func parseBareLiteral() throws -> String {
            let start = index
            while index < bytes.count, ![9, 10, 13, 32, 44, 93, 125].contains(bytes[index]) { index += 1 }
            let slice = bytes[start..<index]
            let raw = String(decoding: slice, as: UTF8.self)
            guard !slice.isEmpty,
                  (try? JSONSerialization.jsonObject(with: Data(slice), options: [.fragmentsAllowed])) != nil
            else { throw Failure(line: line) }
            lastTokenLine = line
            return raw
        }
    }
}
