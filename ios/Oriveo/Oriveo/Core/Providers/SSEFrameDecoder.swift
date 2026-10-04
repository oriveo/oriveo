import Foundation

/// One dispatched SSE event.
nonisolated struct SSEFrame: Equatable, Sendable {
    /// Event name; nil when the event carried no `event` field, or an empty one.
    var event: String?
    /// The data lines joined with LF, never trimmed.
    var data: String
    /// The data lines before joining.
    var dataLines: [String]
    /// Parallel to `dataLines`: the event name in effect when that data line arrived, used when lines are
    /// delivered one by one.
    var dataLineEvents: [String?]
    /// The last id seen up to this event; nil before the first.
    var id: String?
    /// The retry value of this event in milliseconds; nil when it carried none.
    var retry: Int?
}

/// What the decoder hands out, in order of appearance: a dispatched event, or a line that takes no part in
/// assembling one.
nonisolated enum SSEItem: Equatable, Sendable {
    case frame(SSEFrame)
    /// A comment, `id` / `retry`, an unknown field, or a blank line that dispatched nothing (an empty string);
    /// the associated value is the line as it arrived.
    case line(String)
}

/// SSE framing decoder following the WHATWG EventSource parsing algorithm:
///   - a line ends with CRLF, a lone LF or a lone CR; a CRLF cut across two chunks is still one line end
///   - a byte order mark at the start of the stream is dropped once, later ones are data
///   - a line that starts with a colon is a comment; the first colon separates field name and value,
///     and only the single space right after it is removed from the value (no trimming)
///   - the data lines of one event are joined with LF; a blank line dispatches the event, and an event
///     without a data line is not dispatched
///
/// One deliberate difference from the specification, because upstreams routinely close the connection
/// right after `data: [DONE]`: when the stream ends without a line end or without the final blank line,
/// `finish()` still counts the last line and dispatches the pending event, where the specification
/// discards both.
///
/// The end sentinel (`[DONE]`) is an ordinary event at this level; the protocol above gives it meaning.
/// Lines are split on bytes and decoded whole, so a multi-byte character cut between two chunks is
/// unaffected; invalid UTF-8 is replaced with U+FFFD where it occurs.
nonisolated struct SSEFrameDecoder: Sendable {
    /// Number of comment lines seen so far.
    private(set) var comments = 0

    private var line: [UInt8] = []
    /// The previous byte was CR: an LF right after it belongs to the same line end and is swallowed.
    private var previousWasCR = false
    private var atStreamStart = true
    private var dataLines: [String] = []
    private var dataLineEvents: [String?] = []
    private var eventName = ""
    private var lastID: String?
    private var retry: Int?

    init() {}

    /// Feeds one byte; when it ends a line, returns what that line produced.
    mutating func consume(_ byte: UInt8) -> SSEItem? {
        switch byte {
        case 0x0A:
            if previousWasCR {
                previousWasCR = false
                return nil
            }
            return endLine()
        case 0x0D:
            previousWasCR = true
            return endLine()
        default:
            previousWasCR = false
            line.append(byte)
            return nil
        }
    }

    /// End of stream: the last line counts even without a line end, and a pending event is dispatched.
    mutating func finish() -> [SSEItem] {
        var items: [SSEItem] = []
        if !line.isEmpty, let item = endLine() { items.append(item) }
        if let frame = dispatch() { items.append(.frame(frame)) }
        return items
    }

    private mutating func endLine() -> SSEItem? {
        var bytes = line
        line.removeAll(keepingCapacity: true)
        if atStreamStart {
            atStreamStart = false
            if bytes.starts(with: [0xEF, 0xBB, 0xBF]) { bytes.removeFirst(3) }
        }
        guard !bytes.isEmpty else {
            if let frame = dispatch() { return .frame(frame) }
            return .line("")
        }
        if bytes[0] == 0x3A {
            comments += 1
            return .line(String(decoding: bytes, as: UTF8.self))
        }

        let field: ArraySlice<UInt8>
        var value: ArraySlice<UInt8>
        if let colon = bytes.firstIndex(of: 0x3A) {
            field = bytes[..<colon]
            value = bytes[(colon + 1)...]
            if value.first == 0x20 { value = value.dropFirst() }
        } else {
            field = bytes[...]
            value = []
        }

        if field.elementsEqual("data".utf8) {
            dataLines.append(String(decoding: value, as: UTF8.self))
            dataLineEvents.append(eventName.isEmpty ? nil : eventName)
            return nil
        }
        if field.elementsEqual("event".utf8) {
            eventName = String(decoding: value, as: UTF8.self)
            return nil
        }
        if field.elementsEqual("id".utf8), !value.contains(0x00) {
            lastID = String(decoding: value, as: UTF8.self)
        }
        if field.elementsEqual("retry".utf8), !value.isEmpty, value.allSatisfy({ (0x30...0x39).contains($0) }) {
            retry = Int(String(decoding: value, as: UTF8.self))
        }
        return .line(String(decoding: bytes, as: UTF8.self))
    }

    private mutating func dispatch() -> SSEFrame? {
        defer {
            dataLines.removeAll(keepingCapacity: true)
            dataLineEvents.removeAll(keepingCapacity: true)
            eventName = ""
            retry = nil
        }
        guard !dataLines.isEmpty else { return nil }
        return SSEFrame(
            event: eventName.isEmpty ? nil : eventName,
            data: dataLines.joined(separator: "\n"),
            dataLines: dataLines,
            dataLineEvents: dataLineEvents,
            id: lastID,
            retry: retry
        )
    }
}

/// Turns decoded items back into SSE lines, one per element, for the line loops of each provider. Every
/// loop receives lines that are already in canonical form:
///   - an event becomes `event: <name>` (when it has one) and `data: <the joined data>`
///   - an event with empty data produces no line, since there is no payload to deliver
///   - comments, `id` / `retry` and unknown field lines pass through as they arrived, so when the body is
///     not SSE at all (JSON lines, an error body) the caller sees what reading by line would give; blank
///     lines are not delivered
///
/// Some upstreams separate several JSON messages with a single line break and no blank line between
/// events, so the data joined per the specification is not valid JSON. Each data line is then delivered
/// on its own, with the event name that was in effect when it arrived, so that "every data line is a
/// message" keeps working.
nonisolated enum SSECanonicalLines {
    static func lines(for item: SSEItem) -> [String] {
        switch item {
        case let .line(raw):
            return raw.isEmpty ? [] : [raw]
        case let .frame(frame):
            guard !frame.data.isEmpty else { return [] }
            var lines: [String] = []
            if frame.dataLines.count > 1, !isJSON(frame.data) {
                for (index, line) in frame.dataLines.enumerated() where !line.isEmpty {
                    if let event = frame.dataLineEvents[index] { lines.append("event: \(event)") }
                    lines.append("data: \(line)")
                }
            } else {
                if let event = frame.event { lines.append("event: \(event)") }
                lines.append("data: \(frame.data)")
            }
            return lines
        }
    }

    /// The canonical lines for a whole run of bytes (for tests and one-shot parsing; streaming goes through
    /// `URLSession.AsyncBytes.utf8Lines`).
    static func lines<Bytes: Sequence>(in bytes: Bytes) -> [String] where Bytes.Element == UInt8 {
        var decoder = SSEFrameDecoder()
        var lines: [String] = []
        for byte in bytes {
            if let item = decoder.consume(byte) { lines.append(contentsOf: Self.lines(for: item)) }
        }
        for item in decoder.finish() { lines.append(contentsOf: Self.lines(for: item)) }
        return lines
    }

    private static func isJSON(_ text: String) -> Bool {
        (try? JSONSerialization.jsonObject(with: Data(text.utf8), options: [.fragmentsAllowed])) != nil
    }
}
