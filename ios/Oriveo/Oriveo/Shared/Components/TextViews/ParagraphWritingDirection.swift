import Foundation
import UIKit

nonisolated enum ParagraphWritingDirection {

    static func firstStrongDirection(in text: some StringProtocol) -> NSWritingDirection? {
        for scalar in text.unicodeScalars {
            if let direction = strongDirection(of: scalar) {
                return direction
            }
        }
        return nil
    }

    static func applyParagraphDirections(to string: NSMutableAttributedString) {
        let full = string.string as NSString
        guard full.length > 0 else { return }

        var location = 0
        while location < full.length {
            let paragraphRange = full.paragraphRange(for: NSRange(location: location, length: 0))
            defer { location = max(paragraphRange.upperBound, location + 1) }
            guard paragraphRange.length > 0 else { continue }
            guard let direction = firstStrongDirection(in: full.substring(with: paragraphRange)) else { continue }

            string.enumerateAttribute(
                .paragraphStyle,
                in: paragraphRange,
                options: []
            ) { value, range, _ in
                let base = (value as? NSParagraphStyle) ?? .default
                guard base.baseWritingDirection != direction else { return }
                guard let mutable = base.mutableCopy() as? NSMutableParagraphStyle else { return }
                mutable.baseWritingDirection = direction
                string.addAttribute(.paragraphStyle, value: mutable, range: range)
            }
        }
    }

    static func style(_ base: NSParagraphStyle, for content: some StringProtocol) -> NSParagraphStyle {
        guard let direction = firstStrongDirection(in: content),
              base.baseWritingDirection != direction,
              let mutable = base.mutableCopy() as? NSMutableParagraphStyle else {
            return base
        }
        mutable.baseWritingDirection = direction
        return mutable
    }


    private static let rightToLeftRanges: [ClosedRange<UInt32>] = [
        0x0590...0x05FF,   // Hebrew
        0x0600...0x07BF,   // Arabic, Syriac, Arabic Supplement, Thaana, NKo
        0x07C0...0x085F,   // NKo, Samaritan, Mandaic
        0x0860...0x08FF,   // Syriac Supplement, Arabic Extended-A/B
        0xFB1D...0xFB4F,   // Hebrew presentation forms
        0xFB50...0xFDFF,   // Arabic presentation forms-A
        0xFE70...0xFEFF,   // Arabic presentation forms-B
        0x10800...0x10FFF,
        0x1E800...0x1EFFF  // Mende Kikakui, Adlam, Arabic Mathematical Alphabetic Symbols
    ]

    /// Weak punctuation inside RTL blocks: Arabic comma (CS), percent sign (ET), decimal and thousands separators (AN).
    private static let weakRightToLeftPunctuation: Set<UInt32> = [0x060C, 0x066A, 0x066B, 0x066C]

    private static func strongDirection(of scalar: Unicode.Scalar) -> NSWritingDirection? {
        switch scalar.value {
        case 0x200E, 0x202A, 0x202D, 0x2066:  // LRM / LRE / LRO / LRI
            return .leftToRight
        case 0x061C, 0x200F, 0x202B, 0x202E, 0x2067:  // ALM / RLM / RLE / RLO / RLI
            return .rightToLeft
        // The category filter below would skip these as weak, but UAX#9 makes them strong:
        // the Syriac abbreviation mark (Cf, AL), NKo digits and Adlam digits (Nd, R).
        case 0x070F, 0x07C0...0x07C9, 0x1E950...0x1E959:
            return .rightToLeft
        default:
            break
        }
        // Digits (EN/AN), combining marks (NSM) and format characters are not strong; keep scanning.
        // This has to run before the block check: Arabic-Indic digits and harakat live inside the RTL
        // blocks, and treating them as strong R would resolve "١٢٣ hello" to RTL while TextKit's
        // natural direction (P2/P3) resolves it to LTR, flipping the paragraph once it is pinned.
        switch scalar.properties.generalCategory {
        case .decimalNumber, .letterNumber, .otherNumber,
             .nonspacingMark, .spacingMark, .enclosingMark, .format, .control:
            return nil
        default:
            break
        }
        if weakRightToLeftPunctuation.contains(scalar.value) { return nil }
        for range in rightToLeftRanges where range.contains(scalar.value) {
            return .rightToLeft
        }
        // Everything else that is strong is a letter: Latin, Cyrillic, Greek, Han, kana, Hangul... all L.
        // `CharacterSet.letters` is not used because it also includes combining marks (M*).
        switch scalar.properties.generalCategory {
        case .uppercaseLetter, .lowercaseLetter, .titlecaseLetter, .modifierLetter, .otherLetter:
            return .leftToRight
        default:
            return nil
        }
    }
}
