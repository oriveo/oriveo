import Foundation

enum LatexNormalizer {
    static func normalize(_ text: String) -> String {
        guard text.contains("\\(") || text.contains("\\[") else { return text }
        guard let masked = maskProtectedRegions(text) else { return text }
        var result = masked.text

        result = replaceBlockDelimiters(result)
        result = replaceInlineDelimiters(result)

        return restoreProtectedRegions(result, segments: masked.segments)
    }

    static func transformingOutsideCode(_ text: String, _ transform: (String) -> String) -> String {
        guard let masked = maskProtectedRegions(text) else { return transform(text) }
        return restoreProtectedRegions(transform(masked.text), segments: masked.segments)
    }


    private static let placeholderOpen: Character = "\u{E000}"
    private static let placeholderClose: Character = "\u{E001}"

    private struct ProtectedSegments {
        let text: String
        let segments: [String]
    }

    private static func maskProtectedRegions(_ text: String) -> ProtectedSegments? {
        var output = ""
        var segments: [String] = []
        let scalars = Array(text)
        var i = 0
        let n = scalars.count

        while i < n {
            let ch = scalars[i]
            let atLineStart: Bool = {
                guard i > 0 else { return true }
                return scalars[i - 1] == "\n"
            }()

            if atLineStart, ch == "`" || ch == "~" {
                let fenceChar = ch
                var fenceLen = 0
                var j = i
                while j < n, scalars[j] == fenceChar {
                    fenceLen += 1
                    j += 1
                }
                if fenceLen >= 3 {
                    var k = j
                    var closed = false
                    var closeEnd = n
                    while k < n {
                        if k == 0 || scalars[k - 1] == "\n" {
                            var lineFence = 0
                            var m = k
                            while m < n, scalars[m] == fenceChar {
                                lineFence += 1
                                m += 1
                            }
                            if lineFence >= fenceLen {
                                var p = m
                                while p < n, scalars[p] == " " || scalars[p] == "\t" {
                                    p += 1
                                }
                                if p == n || scalars[p] == "\n" {
                                    closed = true
                                    closeEnd = m
                                    break
                                }
                            }
                        }
                        k += 1
                    }

                    let blockEnd = closed ? closeEnd : n
                    let blockText = String(scalars[i..<blockEnd])
                    let idx = segments.count
                    segments.append(blockText)
                    output.append(placeholderOpen)
                    output.append(String(idx))
                    output.append(placeholderClose)
                    i = blockEnd
                    continue
                }
            }

            if ch == "`" {
                var tickLen = 0
                var j = i
                while j < n, scalars[j] == "`" {
                    tickLen += 1
                    j += 1
                }
                var k = j
                var found = false
                while k < n {
                    if scalars[k] == "`" {
                        var matchLen = 0
                        var m = k
                        while m < n, scalars[m] == "`" {
                            matchLen += 1
                            m += 1
                        }
                        if matchLen == tickLen {
                            let segText = String(scalars[i..<m])
                            let idx = segments.count
                            segments.append(segText)
                            output.append(placeholderOpen)
                            output.append(String(idx))
                            output.append(placeholderClose)
                            i = m
                            found = true
                            break
                        } else {
                            k = m
                            continue
                        }
                    }
                    if scalars[k] == "\n",
                       k + 1 < n,
                       scalars[k + 1] == "\n" {
                        break
                    }
                    k += 1
                }
                if !found {
                    output.append(String(scalars[i..<j]))
                    i = j
                }
                continue
            }

            output.append(ch)
            i += 1
        }

        return ProtectedSegments(text: output, segments: segments)
    }

    private static func restoreProtectedRegions(_ text: String, segments: [String]) -> String {
        guard !segments.isEmpty else { return text }
        var result = ""
        result.reserveCapacity(text.count)
        let chars = Array(text)
        var i = 0
        let n = chars.count
        while i < n {
            if chars[i] == placeholderOpen {
                var j = i + 1
                var num = ""
                while j < n, chars[j] != placeholderClose {
                    num.append(chars[j])
                    j += 1
                }
                if j < n, let idx = Int(num), idx >= 0, idx < segments.count {
                    result.append(segments[idx])
                    i = j + 1
                    continue
                }
            }
            result.append(chars[i])
            i += 1
        }
        return result
    }


    private static func replaceBlockDelimiters(_ text: String) -> String {
        guard text.contains("\\[") else { return text }
        var result = ""
        result.reserveCapacity(text.count)
        let chars = Array(text)
        var i = 0
        let n = chars.count
        while i < n {
            if chars[i] == "\\", i + 1 < n, chars[i + 1] == "[" {
                if let close = findEscapedClose(chars: chars, from: i + 2, closer: "]") {
                    result.append("$$")
                    result.append(String(chars[(i + 2)..<close]))
                    result.append("$$")
                    i = close + 2
                    continue
                }
            }
            result.append(chars[i])
            i += 1
        }
        return result
    }

    private static func replaceInlineDelimiters(_ text: String) -> String {
        guard text.contains("\\(") else { return text }
        var result = ""
        result.reserveCapacity(text.count)
        let chars = Array(text)
        var i = 0
        let n = chars.count
        while i < n {
            if chars[i] == "\\", i + 1 < n, chars[i + 1] == "(" {
                if let close = findInlineClose(chars: chars, from: i + 2) {
                    result.append("$")
                    result.append(String(chars[(i + 2)..<close]))
                    result.append("$")
                    i = close + 2
                    continue
                }
            }
            result.append(chars[i])
            i += 1
        }
        return result
    }

    private static func findEscapedClose(chars: [Character], from: Int, closer: Character) -> Int? {
        var i = from
        let n = chars.count
        while i < n - 1 {
            if chars[i] == placeholderOpen {
                while i < n, chars[i] != placeholderClose {
                    i += 1
                }
                i += 1
                continue
            }
            if chars[i] == "\\", chars[i + 1] == closer {
                return i
            }
            i += 1
        }
        return nil
    }

    private static func findInlineClose(chars: [Character], from: Int) -> Int? {
        var i = from
        let n = chars.count
        while i < n - 1 {
            if chars[i] == "\n" { return nil }
            if chars[i] == placeholderOpen {
                while i < n, chars[i] != placeholderClose {
                    i += 1
                }
                i += 1
                continue
            }
            if chars[i] == "\\", chars[i + 1] == ")" {
                return i
            }
            i += 1
        }
        return nil
    }
}
