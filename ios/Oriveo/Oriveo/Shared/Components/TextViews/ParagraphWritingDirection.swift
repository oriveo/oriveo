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

    private static let letters = CharacterSet.letters

    private static func strongDirection(of scalar: Unicode.Scalar) -> NSWritingDirection? {
        switch scalar.value {
        case 0x200E, 0x202A, 0x202D, 0x2066:  // LRM / LRE / LRO / LRI
            return .leftToRight
        case 0x061C, 0x200F, 0x202B, 0x202E, 0x2067:  // ALM / RLM / RLE / RLO / RLI
            return .rightToLeft
        default:
            break
        }
        for range in rightToLeftRanges where range.contains(scalar.value) {
            return .rightToLeft
        }
        return letters.contains(scalar) ? .leftToRight : nil
    }
}
