import Foundation

enum StreamingPacerLanguageProfile: Equatable {
    case ascii
    case cjk

    static func detect(in text: String) -> StreamingPacerLanguageProfile {
        guard !text.isEmpty else { return .ascii }
        var cjkCount = 0
        var letterCount = 0
        for scalar in text.unicodeScalars {
            let v = scalar.value
            let isCJK = (0x4E00...0x9FFF).contains(v)
                || (0x3040...0x30FF).contains(v)
                || (0xAC00...0xD7AF).contains(v)
            let isLatin = (0x41...0x5A).contains(v) || (0x61...0x7A).contains(v)
            if isCJK { cjkCount += 1 }
            if isCJK || isLatin { letterCount += 1 }
        }
        guard letterCount > 0 else { return .ascii }
        return Double(cjkCount) / Double(letterCount) > 0.3 ? .cjk : .ascii
    }

    var frameDelay: TimeInterval {
        switch self {
        case .ascii: return 0.033
        case .cjk:   return 0.040
        }
    }

    var lineDelay: TimeInterval {
        switch self {
        case .ascii: return 0.080
        case .cjk:   return 0.090
        }
    }

    var finalFrameDelay: TimeInterval {
        switch self {
        case .ascii: return 0.030
        case .cjk:   return 0.036
        }
    }

    var finalLineDelay: TimeInterval {
        switch self {
        case .ascii: return 0.075
        case .cjk:   return 0.085
        }
    }

    func stepSize(for backlog: Int) -> Int {
        switch self {
        case .ascii:
            switch backlog {
                case 0...60:    return 1
                case 61...200:  return 2
                case 201...500: return 3
                case 501...1_500: return 4
                default:        return 6
            }
        case .cjk:
            switch backlog {
                case 0...60:    return 1
                case 61...200:  return 2
                case 201...500: return 3
                case 501...1_500: return 4
                default:        return 5
            }
        }
    }
}
