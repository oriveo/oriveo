import Foundation

// MARK: - SSE (text/event-stream) parsing
//
// A Streamable HTTP response may be a single JSON document or an SSE stream, and **both must be supported**. An SSE
// stream may carry JSON-RPC notifications related to the request (no id); the final response ends the stream.
// Resuming with `Last-Event-ID` is not supported, so event ids are not kept here.

/// Incremental SSE parser: fed byte by byte, it emits each event's JSON payload as soon as the event is complete.
///
/// It has to be incremental: after the final response the server SHOULD close the stream but is not guaranteed to.
/// Parsing only on close would mean a write tool has already run while the client waits out the full timeout and then
/// reports failure.
///
/// Line endings follow the SSE specification: LF, CRLF and a lone CR; a BOM at the start of the stream is dropped;
/// multiple `data:` lines of one event are joined with `\n`; `event:` / `id:` / `retry:` and comment lines starting
/// with `:` are ignored. Payloads that do not parse as JSON are skipped (one bad frame does not stall the whole
/// stream); invalid UTF-8 is replaced with U+FFFD in place rather than discarded wholesale.
nonisolated struct McpSSEParser: Sendable {
    private var line: [UInt8] = []
    private var dataLines: [String] = []
    /// The previous byte was CR: an LF right after it belongs to the same line break and is swallowed.
    private var previousWasCR = false
    /// Still at the start of the stream (used to detect the BOM).
    private var atStreamStart = true
    /// This event's payload was already emitted early when its `data:` line ended; the blank line does not emit it
    /// again.
    private var emittedEarly = false

    init() {}

    /// Feeds one byte; returns the event's JSON payload when an event is complete.
    mutating func consume(_ byte: UInt8) -> JSONValue? {
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

    /// End of stream: also emits a last event that was not terminated by a blank line.
    ///
    /// The specification says an unterminated event should be discarded, but here "the response arrived in full, only
    /// the blank line is missing" would turn a call that already ran into a reported failure, so we err on the side
    /// of accepting it.
    mutating func finish() -> JSONValue? {
        var result: JSONValue?
        if !line.isEmpty { result = endLine() }
        return dispatch() ?? result
    }

    private mutating func endLine() -> JSONValue? {
        var bytes = line
        line.removeAll(keepingCapacity: true)
        if atStreamStart {
            atStreamStart = false
            if bytes.starts(with: [0xEF, 0xBB, 0xBF]) { bytes.removeFirst(3) }
        }
        guard !bytes.isEmpty else { return dispatch() }
        // Lines starting with a colon are comments.
        guard bytes[0] != 0x3A else { return nil }

        let field: ArraySlice<UInt8>
        var value: ArraySlice<UInt8>
        if let colon = bytes.firstIndex(of: 0x3A) {
            field = bytes[..<colon]
            value = bytes[(colon + 1)...]
            // Per the specification: strip one leading space from the value (only one).
            if value.first == 0x20 { value = value.dropFirst() }
        } else {
            // No colon: the whole line is the field name and the value is empty.
            field = bytes[...]
            value = []
        }
        guard field.elementsEqual("data".utf8) else { return nil }

        dataLines.append(String(decoding: value, as: UTF8.self))
        // Most servers send a single data line per event. When it is complete JSON on its own, emit it right away
        // without waiting for the blank line; some servers stop after the last data line and never send another byte.
        // Only done for the first line: re-parsing on every line of a multi-line data field would be quadratic, and a
        // peer could use that to stall us.
        if dataLines.count == 1, let value = try? JSONValue(parsing: dataLines[0]) {
            emittedEarly = true
            return value
        }
        return nil
    }

    private mutating func dispatch() -> JSONValue? {
        defer {
            dataLines.removeAll(keepingCapacity: true)
            emittedEarly = false
        }
        guard !dataLines.isEmpty else { return nil }
        // A single-line event emitted early is not repeated; one followed by more data lines (a multi-line event) is
        // re-parsed as the joined whole.
        if emittedEarly, dataLines.count == 1 { return nil }
        return try? JSONValue(parsing: dataLines.joined(separator: "\n"))
    }
}

nonisolated enum McpSSE {
    /// Parses a whole chunk of SSE bytes into an array of JSON-RPC messages (in order of appearance). Uses the same
    /// parser as streaming reads; only for the fallback when `Content-Type` is not truthful, and for tests.
    static func messages(in data: Data) -> [JSONValue] {
        var parser = McpSSEParser()
        var messages: [JSONValue] = []
        for byte in data {
            if let message = parser.consume(byte) { messages.append(message) }
        }
        if let message = parser.finish() { messages.append(message) }
        return messages
    }
}
