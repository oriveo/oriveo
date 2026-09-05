import Foundation

/// ```
/// ```
enum OpenAIChatContentBlocks {

    static func fold(_ node: Any?) -> (reasoning: String, text: String)? {
        guard let blocks = node as? [Any] else { return nil }
        var reasoning = ""
        var text = ""
        for block in blocks {
            guard let dict = block as? [String: Any] else { continue }
            switch dict["type"] as? String {
            case "thinking":
                for part in (dict["thinking"] as? [Any]) ?? [] {
                    guard let partDict = part as? [String: Any],
                          partDict["type"] as? String == "text",
                          let partText = partDict["text"] as? String else { continue }
                    reasoning += partText
                }
            case "text":
                text += (dict["text"] as? String) ?? ""
            default:
                continue
            }
        }
        return (reasoning: reasoning, text: text)
    }
}

enum OpenAIChatMessageContent: Decodable {
    case string(String)
    case blocks([OpenAIChatContentBlock])

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let string = try? container.decode(String.self) {
            self = .string(string)
        } else {
            self = .blocks(try container.decode([OpenAIChatContentBlock].self))
        }
    }

    var text: String {
        switch self {
        case let .string(value):
            return value
        case let .blocks(blocks):
            return blocks
                .filter { $0.type == "text" }
                .compactMap(\.text)
                .joined()
        }
    }

    var reasoningText: String {
        switch self {
        case .string:
            return ""
        case let .blocks(blocks):
            return blocks
                .filter { $0.type == "thinking" }
                .flatMap { $0.thinking ?? [] }
                .filter { $0.type == "text" }
                .compactMap(\.text)
                .joined()
        }
    }
}

struct OpenAIChatContentBlock: Decodable {
    let type: String?
    let text: String?
    let thinking: [OpenAIChatThinkingPart]?
}

struct OpenAIChatThinkingPart: Decodable {
    let type: String?
    let text: String?
}
