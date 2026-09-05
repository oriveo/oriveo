import UIKit
import SwiftMath

enum LatexImageCache {
    static let didRenderNotification = Notification.Name("LatexImageCache.didRender")
    static let userInfoLatexKey = "latex"

    static func image(
        latex: String,
        fontSize: CGFloat,
        textColor: UIColor,
        inline: Bool
    ) -> UIImage? {
        let resolvedColor = resolvedForCurrentTraits(textColor)
        let key = makeKey(latex: latex, fontSize: fontSize, textColor: resolvedColor, inline: inline)
        if let cached = cache.object(forKey: key) { return cached.image }
        return renderAndCache(key: key, latex: latex, fontSize: fontSize, textColor: resolvedColor, inline: inline)
    }

    static func cachedImage(
        latex: String,
        fontSize: CGFloat,
        textColor: UIColor,
        inline: Bool
    ) -> UIImage? {
        let key = makeKey(latex: latex, fontSize: fontSize, textColor: resolvedForCurrentTraits(textColor), inline: inline)
        return cache.object(forKey: key)?.image
    }

    @discardableResult
    static func requestImage(
        latex: String,
        fontSize: CGFloat,
        textColor: UIColor,
        inline: Bool
    ) -> UIImage? {
        let textColor = resolvedForCurrentTraits(textColor)
        let key = makeKey(latex: latex, fontSize: fontSize, textColor: textColor, inline: inline)
        if let cached = cache.object(forKey: key) { return cached.image }
        stateLock.lock()
        if failedKeys.contains(key) {
            stateLock.unlock()
            return nil
        }
        let alreadyInFlight = inFlight.contains(key)
        if !alreadyInFlight { inFlight.insert(key) }
        stateLock.unlock()
        guard !alreadyInFlight else { return nil }

        // (EXC_BREAKPOINT in `_xzm_xzone_malloc_freelist_outlined`).
        renderQueue.async {
            let image = renderAndCache(key: key, latex: latex, fontSize: fontSize, textColor: textColor, inline: inline)
            stateLock.lock()
            inFlight.remove(key)
            if image == nil { failedKeys.insert(key) }
            stateLock.unlock()
            guard image != nil else { return }
            DispatchQueue.main.async {
                NotificationCenter.default.post(
                    name: didRenderNotification,
                    object: nil,
                    userInfo: [userInfoLatexKey: latex]
                )
            }
        }
        return nil
    }

    private static func resolvedForCurrentTraits(_ color: UIColor) -> UIColor {
        color.resolvedColor(with: .current)
    }


    private static func renderAndCache(
        key: LatexImageCacheKey,
        latex: String,
        fontSize: CGFloat,
        textColor: UIColor,
        inline: Bool
    ) -> UIImage? {
        let mode: MTMathUILabelMode = inline ? .text : .display
        let mathImage = MTMathImage(
            latex: latex,
            fontSize: fontSize,
            textColor: textColor,
            labelMode: mode,
            textAlignment: .left
        )
        let (error, image) = mathImage.asImage()
        if error != nil { return nil }
        guard let image else { return nil }
        cache.setObject(
            Entry(image: image),
            forKey: key,
            cost: Int(image.size.width * image.size.height * image.scale * image.scale)
        )
        return image
    }

    private static func makeKey(
        latex: String,
        fontSize: CGFloat,
        textColor: UIColor,
        inline: Bool
    ) -> LatexImageCacheKey {
        LatexImageCacheKey(
            latex: latex,
            fontSize: fontSize,
            rgba: textColor.rgbaHex,
            inline: inline
        )
    }


    private final class Entry {
        let image: UIImage
        init(image: UIImage) { self.image = image }
    }

    private static let cache: NSCache<LatexImageCacheKey, Entry> = {
        let c = NSCache<LatexImageCacheKey, Entry>()
        c.countLimit = 200
        c.totalCostLimit = 32 * 1024 * 1024
        return c
    }()

    private static var inFlight: Set<LatexImageCacheKey> = []
    private static var failedKeys: Set<LatexImageCacheKey> = []
    private static let stateLock = NSLock()
    private static let renderQueue = DispatchQueue(label: "LatexImageCache.render", qos: .userInitiated)
}

private final class LatexImageCacheKey: NSObject {
    let latex: String
    let fontSize: CGFloat
    let rgba: UInt32
    let inline: Bool

    init(latex: String, fontSize: CGFloat, rgba: UInt32, inline: Bool) {
        self.latex = latex
        self.fontSize = fontSize
        self.rgba = rgba
        self.inline = inline
    }

    override var hash: Int {
        var hasher = Hasher()
        hasher.combine(latex)
        hasher.combine(fontSize)
        hasher.combine(rgba)
        hasher.combine(inline)
        return hasher.finalize()
    }

    override func isEqual(_ object: Any?) -> Bool {
        guard let other = object as? LatexImageCacheKey else { return false }
        return latex == other.latex
            && fontSize == other.fontSize
            && rgba == other.rgba
            && inline == other.inline
    }
}

private extension UIColor {
    var rgbaHex: UInt32 {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        if getRed(&r, green: &g, blue: &b, alpha: &a) {
            let R = UInt32(max(0, min(255, Int(r * 255))))
            let G = UInt32(max(0, min(255, Int(g * 255))))
            let B = UInt32(max(0, min(255, Int(b * 255))))
            let A = UInt32(max(0, min(255, Int(a * 255))))
            return (R << 24) | (G << 16) | (B << 8) | A
        }
        return 0
    }
}
