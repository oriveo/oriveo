import UIKit

final class LatexAttachment: NSTextAttachment {
    private let renderedImage: UIImage
    private let baselineOffset: CGFloat
    let latexSource: String
    let isInline: Bool

    /// - Parameters:
    init(image: UIImage, font: UIFont, isInline: Bool, latex: String) {
        self.renderedImage = image
        self.latexSource = latex
        self.isInline = isInline
        if isInline {
            self.baselineOffset = -font.descender - (image.size.height - font.capHeight) / 2
        } else {
            self.baselineOffset = 0
        }
        super.init(data: nil, ofType: nil)
        self.image = image
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func attachmentBounds(
        for textContainer: NSTextContainer?,
        proposedLineFragment lineFrag: CGRect,
        glyphPosition position: CGPoint,
        characterIndex charIndex: Int
    ) -> CGRect {
        CGRect(x: 0, y: baselineOffset, width: renderedImage.size.width, height: renderedImage.size.height)
    }

    override func image(
        forBounds imageBounds: CGRect,
        textContainer: NSTextContainer?,
        characterIndex charIndex: Int
    ) -> UIImage? {
        renderedImage
    }
}
