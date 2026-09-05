import Foundation

public struct ThinkingTagParser: Sendable {
    public init() {}

    private static let openTag = "<think>"
    private static let closeTag = "</think>"
    private static let maxTagLength = closeTag.count

    public enum Segment: Equatable, Sendable {
        case text(String)
        case reasoning(String)
    }

    private enum Mode: Sendable {
        case normal
        case thinking
    }

    private var mode: Mode = .normal
    private var pending = ""
    private var fenceBackticks = 0
    private var inCodeFence = false

    public mutating func parse(_ input: String, final: Bool = false) -> [Segment] {
        guard !input.isEmpty || final else { return [] }

        let current = pending + input
        pending = ""

        var events: [Segment] = []
        var index = current.startIndex
        var out = ""

        func flush() {
            guard !out.isEmpty else { return }
            switch mode {
            case .normal:
                events.append(.text(out))
            case .thinking:
                events.append(.reasoning(out))
            }
            out = ""
        }

        while index < current.endIndex {
            if mode == .normal {
                updateFenceState(current[index])
            }

            if !inCodeFence, current[index...].hasPrefix(Self.openTag) {
                flush()
                mode = .thinking
                index = current.index(index, offsetBy: Self.openTag.count)
                continue
            }

            if !inCodeFence, current[index...].hasPrefix(Self.closeTag) {
                flush()
                mode = .normal
                index = current.index(index, offsetBy: Self.closeTag.count)
                continue
            }

            let suffix = String(current[index...])
            if !final, Self.isPossibleTagPrefix(suffix) {
                break
            }

            out.append(current[index])
            index = current.index(after: index)
        }

        pending = String(current[index...])
        if final, !pending.isEmpty {
            out += pending
            pending = ""
        }
        flush()

        return events
    }

    private static func isPossibleTagPrefix(_ value: String) -> Bool {
        let capped = String(value.prefix(maxTagLength))
        return capped.count < maxTagLength
            && (openTag.hasPrefix(capped) || closeTag.hasPrefix(capped))
    }

    private mutating func updateFenceState(_ char: Character) {
        if char == "`" {
            fenceBackticks += 1
            if fenceBackticks == 3 {
                inCodeFence.toggle()
                fenceBackticks = 0
            }
            return
        }
        fenceBackticks = 0
    }
}
