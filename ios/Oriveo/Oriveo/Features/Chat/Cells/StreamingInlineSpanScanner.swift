import Foundation

enum StreamingInlineSpanScanner {

    private enum OpenSpan {
        case code        // `...`
        case bold        // **...**
        case italic      // *...*
        case strike      // ~~...~~
        case link        // [...](...)
        case math        // $...$
    }

    private static let backtick: unichar = 0x60   // `
    private static let star: unichar = 0x2A       // *
    private static let tilde: unichar = 0x7E      // ~
    private static let dollar: unichar = 0x24     // $
    private static let lbracket: unichar = 0x5B   // [
    private static let rbracket: unichar = 0x5D   // ]
    private static let lparen: unichar = 0x28     // (
    private static let rparen: unichar = 0x29     // )

    static func safeBoundary(in line: String) -> Int {
        let ns = line as NSString
        let len = ns.length
        guard len > 0 else { return 0 }

        var open: OpenSpan?
        var openStart = 0
        var i = 0

        func ch(_ j: Int) -> unichar? { j >= 0 && j < len ? ns.character(at: j) : nil }

        while i < len {
            let c = ns.character(at: i)

            if let span = open {
                switch span {
                case .code:
                    if c == backtick, i > openStart + 1 {
                        open = nil
                    }
                    i += 1
                case .bold:
                    if c == star, ch(i + 1) == star {
                        open = nil
                        i += 2
                    } else {
                        i += 1
                    }
                case .italic:
                    if c == star, let next = ch(i + 1), next != star {
                        open = nil
                    }
                    i += 1
                case .strike:
                    if c == tilde, ch(i + 1) == tilde {
                        open = nil
                        i += 2
                    } else {
                        i += 1
                    }
                case .math:
                    if c == dollar, let next = ch(i + 1), next != dollar {
                        open = nil
                    }
                    i += 1
                case .link:
                    if c == rbracket, ch(i + 1) == lparen {
                        var j = i + 2
                        var closeParen: Int?
                        while j < len {
                            if ns.character(at: j) == rparen { closeParen = j; break }
                            j += 1
                        }
                        if let closeParen {
                            open = nil
                            i = closeParen + 1
                        } else {
                            i = len
                        }
                    } else {
                        i += 1
                    }
                }
                continue
            }

            switch c {
            case backtick:
                open = .code
                openStart = i
                i += 1
            case star:
                open = (ch(i + 1) == star) ? .bold : .italic
                openStart = i
                i += (open == .bold) ? 2 : 1
            case tilde:
                if ch(i + 1) == tilde {
                    open = .strike
                    openStart = i
                    i += 2
                } else if i + 1 == len {
                    open = .strike
                    openStart = i
                    i += 1
                } else {
                    i += 1
                }
            case dollar:
                if ch(i + 1) == dollar {
                    i += 2
                } else {
                    open = .math
                    openStart = i
                    i += 1
                }
            case lbracket:
                open = .link
                openStart = i
                i += 1
            default:
                i += 1
            }
        }

        return open == nil ? len : openStart
    }
}
