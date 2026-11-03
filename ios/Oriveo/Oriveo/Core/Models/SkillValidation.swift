import Foundation

// Production implementation of the shared skill_schema.v2 contract (validate / keywords / slash label).
// Pure functions: the editor calls them directly.

/// skill_schema.v2 `errorCodes`, declared in contract order.
nonisolated enum SkillValidationErrorCode: String, CaseIterable, Sendable, Hashable {
    case nameRequired = "name_required"
    case nameTooLong = "name_too_long"
    case whenToUseTooLong = "when_to_use_too_long"
    case whenToUseRequired = "when_to_use_required"
    case instructionsRequired = "instructions_required"
    case instructionsTooLong = "instructions_too_long"
    case startersTooMany = "starters_too_many"
    case starterTooLong = "starter_too_long"
}

nonisolated struct SkillValidationInput: Sendable, Equatable {
    var name: String
    var whenToUse: String
    var instructions: String
    var starters: [String]
    var autoInvoke: Bool
    /// Name currently stored on the Server; nil for a new skill.
    var savedName: String?
}

nonisolated struct SkillValidationNormalized: Sendable, Equatable {
    var name: String
    var whenToUse: String
    var instructions: String
    var starters: [String]
    var autoInvoke: Bool
}

nonisolated struct SkillValidationResult: Sendable, Equatable {
    var errors: [SkillValidationErrorCode]
    var normalized: SkillValidationNormalized
}

nonisolated struct SkillKeywordSegment: Sendable, Equatable {
    var text: String
    var highlight: Bool
}

nonisolated struct SkillKeywordSegmentation: Sendable, Equatable {
    var segments: [SkillKeywordSegment]
    var keywords: [String]
}

nonisolated enum SkillValidation {
    static let nameMax = 40
    static let nameServerMax = 50
    static let whenToUseMax = 200
    static let instructionsMax = 8000
    static let startersMax = 4
    static let starterMax = 40
    static let autoInvokeEnabledMax = 30
    static let slashLabelMax = 6
    static let keywordMax = 20
    static let keywordPairs: [(open: Unicode.Scalar, close: Unicode.Scalar)] = [
        ("\u{300C}", "\u{300D}"),
        ("\u{201C}", "\u{201D}"),
        ("\"", "\""),
        ("\u{00AB}", "\u{00BB}"),
        ("\u{201E}", "\u{201C}"),
    ]
    static let slashLabelEllipsis = "\u{2026}"

    /// assemble.v1 trim(): the Unicode White_Space set, applied per code point.
    static func isWhiteSpace(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x09...0x0D, 0x20, 0x85, 0xA0, 0x1680, 0x2000...0x200A, 0x2028, 0x2029, 0x202F, 0x205F, 0x3000:
            return true
        default:
            return false
        }
    }

    static func trim(_ string: String) -> String {
        let scalars = Array(string.unicodeScalars)
        guard let start = scalars.firstIndex(where: { !isWhiteSpace($0) }),
              let end = scalars.lastIndex(where: { !isWhiteSpace($0) }) else { return "" }
        var view = String.UnicodeScalarView()
        view.append(contentsOf: scalars[start...end])
        return String(view)
    }

    static func codePointCount(_ string: String) -> Int {
        string.unicodeScalars.count
    }

    static func validate(_ input: SkillValidationInput) -> SkillValidationResult {
        var errors = Set<SkillValidationErrorCode>()
        let name = trim(input.name)
        let whenToUse = trim(input.whenToUse)
        let instructions = trim(input.instructions)
        let starters = input.starters.map(trim).filter { !$0.isEmpty }

        if name.isEmpty {
            errors.insert(.nameRequired)
        } else if codePointCount(name) > nameMax {
            let keepsLegacyName = input.savedName.map { trim($0) == name } == true
                && codePointCount(name) <= nameServerMax
            if !keepsLegacyName { errors.insert(.nameTooLong) }
        }
        if codePointCount(whenToUse) > whenToUseMax { errors.insert(.whenToUseTooLong) }
        if input.autoInvoke && whenToUse.isEmpty { errors.insert(.whenToUseRequired) }
        if instructions.isEmpty {
            errors.insert(.instructionsRequired)
        } else if codePointCount(instructions) > instructionsMax {
            errors.insert(.instructionsTooLong)
        }
        if starters.count > startersMax { errors.insert(.startersTooMany) }
        if starters.contains(where: { codePointCount($0) > starterMax }) { errors.insert(.starterTooLong) }

        return SkillValidationResult(
            errors: SkillValidationErrorCode.allCases.filter { errors.contains($0) },
            normalized: SkillValidationNormalized(
                name: name,
                whenToUse: whenToUse,
                instructions: instructions,
                starters: starters,
                autoInvoke: input.autoInvoke
            )
        )
    }

    /// Keyword highlighting for `whenToUse`; scans code points left to right, never nests.
    static func whenToUseSegments(_ text: String) -> SkillKeywordSegmentation {
        let chars = Array(text.unicodeScalars)
        var segments: [SkillKeywordSegment] = []

        func push(_ scalars: ArraySlice<Unicode.Scalar>, highlight: Bool) {
            guard !scalars.isEmpty else { return }
            var view = String.UnicodeScalarView()
            view.append(contentsOf: scalars)
            push(String(view), highlight: highlight)
        }
        func push(_ piece: String, highlight: Bool) {
            guard !piece.isEmpty else { return }
            if !highlight, let last = segments.last, !last.highlight {
                segments[segments.count - 1].text += piece
            } else {
                segments.append(SkillKeywordSegment(text: piece, highlight: highlight))
            }
        }

        var i = 0
        while i < chars.count {
            if let pair = keywordPairs.first(where: { $0.open == chars[i] }) {
                var j = i + 1
                while j < chars.count, chars[j] != pair.close, chars[j] != "\n" { j += 1 }
                if j < chars.count, chars[j] == pair.close {
                    var innerView = String.UnicodeScalarView()
                    innerView.append(contentsOf: chars[(i + 1)..<j])
                    let inner = trim(String(innerView))
                    if !inner.isEmpty, codePointCount(inner) <= keywordMax {
                        push(inner, highlight: true)
                        i = j + 1
                        continue
                    }
                }
            }
            push(chars[i...i], highlight: false)
            i += 1
        }

        var keywords: [String] = []
        for segment in segments where segment.highlight && !keywords.contains(segment.text) {
            keywords.append(segment.text)
        }
        return SkillKeywordSegmentation(segments: segments, keywords: keywords)
    }

    /// "/name" key-cap label, cut by grapheme clusters (Swift `Character`).
    static func slashLabel(_ name: String) -> String {
        let graphemes = Array(trim(name))
        if graphemes.count > slashLabelMax {
            return "/" + String(graphemes.prefix(slashLabelMax)) + slashLabelEllipsis
        }
        return "/" + String(graphemes)
    }
}
