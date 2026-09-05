import Foundation

/// Maps a tool id onto the `[a-zA-Z0-9_-]` alphabet that OpenAI-compatible function names
/// accept, and back again. Tool ids are namespaced with dots (`fs.read`), which that alphabet
/// forbids, so the mapping has to be injective: two different tool ids must never encode to
/// the same function name, or a model's answer would dispatch to the wrong tool.
///
/// The escape character is `_`:
/// - `[A-Za-z0-9]` passes through unchanged
/// - `.` becomes `__`, the common case, so namespaced ids stay readable (`fs.read` -> `fs__read`)
/// - anything else, including a literal `_` and `-`, becomes `_` followed by its UTF-8 byte in
///   lowercase hex
///
/// Escaping the underscore is what keeps the mapping injective: a naive "replace dots with
/// underscores" scheme collapses `fs.read` and `fs_read` onto the same name. Here they stay
/// apart as `fs__read` and `fs_5fread`.
public enum ToolFunctionNameCodec {
    public static func encode(_ toolID: String) -> String {
        var out = ""
        out.reserveCapacity(toolID.utf8.count)
        for byte in toolID.utf8 {
            switch byte {
            case 0x30 ... 0x39, 0x41 ... 0x5A, 0x61 ... 0x7A:
                out.append(Character(UnicodeScalar(byte)))
            case 0x2E: // '.'
                out += "__"
            default:
                out += String(format: "_%02x", byte)
            }
        }
        return out
    }

    /// Reverses `encode`. An escape that does not decode - because the model invented a name of
    /// its own, or a provider rewrote ours - is passed through byte for byte rather than
    /// rejected, so an unexpected name still reaches the caller and can be reported as an
    /// unknown tool instead of vanishing mid-stream.
    public static func decode(_ functionName: String) -> String {
        let source = Array(functionName.utf8)
        var bytes: [UInt8] = []
        bytes.reserveCapacity(source.count)
        var index = 0
        while index < source.count {
            let byte = source[index]
            guard byte == 0x5F else { // '_'
                bytes.append(byte)
                index += 1
                continue
            }
            if index + 1 < source.count, source[index + 1] == 0x5F {
                bytes.append(0x2E) // '.'
                index += 2
                continue
            }
            if index + 2 < source.count,
               let high = hexValue(source[index + 1]),
               let low = hexValue(source[index + 2]) {
                bytes.append(high << 4 | low)
                index += 3
                continue
            }
            bytes.append(byte)
            index += 1
        }
        return String(decoding: bytes, as: UTF8.self)
    }

    private static func hexValue(_ byte: UInt8) -> UInt8? {
        switch byte {
        case 0x30 ... 0x39: return byte - 0x30
        case 0x61 ... 0x66: return byte - 0x61 + 10
        case 0x41 ... 0x46: return byte - 0x41 + 10
        default: return nil
        }
    }
}
