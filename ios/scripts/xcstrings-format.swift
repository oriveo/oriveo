// Rewrites .xcstrings files in Xcode's own serialization, byte for byte, so building or opening the
// project in Xcode does not reformat whole catalogs.
//
// Xcode writes string catalogs with JSONSerialization [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
// and no trailing newline: `"key" : value`, keys in Foundation's sort order (punctuation has its own order,
// not code point order). A catalog written by another tool (for example Python's json.dump, which emits
// `"key": value`) gets rewritten in full the moment Xcode touches any single key.
//
// Usage (from the ios directory):
//   swift scripts/xcstrings-format.swift <file.xcstrings>...          rewrite in place
//   swift scripts/xcstrings-format.swift --check <file.xcstrings>...  check only, exit 1 on drift
import Foundation

var arguments = Array(CommandLine.arguments.dropFirst())
let checkOnly = arguments.first == "--check"
if checkOnly { arguments.removeFirst() }
guard !arguments.isEmpty else {
    FileHandle.standardError.write(Data("usage: swift scripts/xcstrings-format.swift [--check] <file.xcstrings>...\n".utf8))
    exit(2)
}

func canonical(_ data: Data) throws -> Data {
    let object = try JSONSerialization.jsonObject(with: data)
    return try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
}

var failed = false
for path in arguments {
    let url = URL(fileURLWithPath: path)
    do {
        let raw = try Data(contentsOf: url)
        let formatted = try canonical(raw)
        if formatted == raw { continue }
        if checkOnly {
            print("not in Xcode format: \(path)")
            failed = true
            continue
        }
        // Only whitespace and key order may change; refuse anything else.
        let before = try JSONSerialization.jsonObject(with: raw) as? NSDictionary
        let after = try JSONSerialization.jsonObject(with: formatted) as? NSDictionary
        guard let before, let after, before.isEqual(after) else {
            print("refusing to rewrite (content would change): \(path)")
            failed = true
            continue
        }
        try formatted.write(to: url, options: .atomic)
        print("formatted: \(path)")
    } catch {
        print("error: \(path): \(error)")
        failed = true
    }
}
exit(failed ? 1 : 0)
