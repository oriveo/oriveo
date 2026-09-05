import Foundation
import UIKit

enum RtfTextExtractor {
    static func extract(data: Data) throws -> String {
        let options: [NSAttributedString.DocumentReadingOptionKey: Any] = [
            .documentType: NSAttributedString.DocumentType.rtf,
        ]
        guard let attr = try? NSAttributedString(data: data, options: options, documentAttributes: nil) else {
            throw ExtractionError(code: .corruptedFile)
        }
        return attr.string
    }
}
