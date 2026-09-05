import UIKit
import ImageIO

nonisolated enum ImageStore {


    private static let ensuredImageDirectoriesLock = NSLock()
    nonisolated(unsafe) private static var ensuredImageDirectories: Set<String> = []

    private static func imagesDirectory(for partitionUID: String? = nil) -> URL? {
        let dir = partitionUID.map(AppSessionStore.imagesDir(for:)) ?? AppSessionStore.imagesDir
        ensuredImageDirectoriesLock.lock()
        let alreadyEnsured = ensuredImageDirectories.contains(dir.path)
        ensuredImageDirectoriesLock.unlock()
        if !alreadyEnsured {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            ensuredImageDirectoriesLock.lock()
            ensuredImageDirectories.insert(dir.path)
            ensuredImageDirectoriesLock.unlock()
        }
        return dir
    }

    static func cachedImageAspectRatio(
        for id: String,
        thumbnail: Bool = false,
        partitionUID: String? = nil
    ) -> CGFloat? {
        cachedAspectRatio(for: aspectRatioCacheKey(for: id, thumbnail: thumbnail, partitionUID: partitionUID))
    }

    static func cachedInlineAspectRatio(cacheKey: String, partitionUID: String? = nil) -> CGFloat? {
        cachedAspectRatio(for: inlineAspectRatioCacheKey(for: cacheKey, partitionUID: partitionUID))
    }

    private static func imageURL(for id: String, partitionUID: String? = nil) -> URL? {
        imagesDirectory(for: partitionUID)?.appendingPathComponent("\(id).img")
    }

    private static func thumbnailURL(for id: String, partitionUID: String? = nil) -> URL? {
        imagesDirectory(for: partitionUID)?.appendingPathComponent("\(id).thumb")
    }

    static func storedImageSize(for id: String, partitionUID: String? = nil) -> Int {
        guard let url = imageURL(for: id, partitionUID: partitionUID) else { return 0 }
        let values = try? url.resourceValues(forKeys: [.fileSizeKey])
        return values?.fileSize ?? 0
    }

    static func clearAllCaches() {
        displayCache.removeAllObjects()
        thumbnailCache.removeAllObjects()
        originalCache.removeAllObjects()
        aspectRatioCache.removeAllObjects()
        ensuredImageDirectoriesLock.lock()
        ensuredImageDirectories.removeAll()
        ensuredImageDirectoriesLock.unlock()
    }

    // MARK: - NSCache

    private static let displayCache: NSCache<NSString, UIImage> = {
        let cache = NSCache<NSString, UIImage>()
        cache.countLimit = 50
        cache.totalCostLimit = 96 * 1024 * 1024
        return cache
    }()

    private static let thumbnailCache: NSCache<NSString, UIImage> = {
        let cache = NSCache<NSString, UIImage>()
        cache.countLimit = 100
        cache.totalCostLimit = 24 * 1024 * 1024
        return cache
    }()

    private static let originalCache: NSCache<NSString, UIImage> = {
        let cache = NSCache<NSString, UIImage>()
        cache.countLimit = 8
        cache.totalCostLimit = 64 * 1024 * 1024
        return cache
    }()

    private static let aspectRatioCache: NSCache<NSString, NSNumber> = {
        let cache = NSCache<NSString, NSNumber>()
        cache.countLimit = 300
        return cache
    }()


    static func save(imageData: Data, for id: String, partitionUID: String? = nil) {
        guard let url = imageURL(for: id, partitionUID: partitionUID) else { return }
        try? imageData.write(to: url, options: .atomic)
    }

    static func saveThumbnail(imageData: Data, for id: String, partitionUID: String? = nil) {
        guard let url = thumbnailURL(for: id, partitionUID: partitionUID) else { return }
        try? imageData.write(to: url, options: .atomic)
    }


    static func loadImageData(for id: String, partitionUID: String? = nil) -> Data? {
        guard let url = imageURL(for: id, partitionUID: partitionUID) else { return nil }
        return try? Data(contentsOf: url)
    }

    static func loadThumbnailData(for id: String, partitionUID: String? = nil) -> Data? {
        guard let url = thumbnailURL(for: id, partitionUID: partitionUID) else { return nil }
        return try? Data(contentsOf: url)
    }

    static func loadBase64(for id: String, partitionUID: String? = nil) -> String? {
        loadImageData(for: id, partitionUID: partitionUID)?.base64EncodedString()
    }

    static func imageAspectRatio(
        for id: String,
        thumbnail: Bool = false,
        partitionUID: String? = nil
    ) -> CGFloat? {
        let cacheKey = aspectRatioCacheKey(for: id, thumbnail: thumbnail, partitionUID: partitionUID)
        if let cached = cachedAspectRatio(for: cacheKey) {
            return cached
        }

        if let cached = cachedUIImage(for: id, thumbnail: thumbnail, partitionUID: partitionUID) {
            let ratio = cached.size.width / max(cached.size.height, 1)
            cacheAspectRatio(ratio, for: cacheKey)
            return ratio
        }

        let url = thumbnail
            ? thumbnailURL(for: id, partitionUID: partitionUID)
            : imageURL(for: id, partitionUID: partitionUID)
        guard let ratio = aspectRatio(for: url) else { return nil }
        cacheAspectRatio(ratio, for: cacheKey)
        return ratio
    }

    static func imageAspectRatio(
        forBase64Encoded base64: String,
        cacheKey: String? = nil,
        partitionUID: String? = nil
    ) -> CGFloat? {
        if let cacheKey,
           let cached = cachedAspectRatio(
               for: inlineAspectRatioCacheKey(for: cacheKey, partitionUID: partitionUID)
           ) {
            return cached
        }

        guard let data = Data(base64Encoded: base64),
              let ratio = aspectRatio(for: data) else {
            return nil
        }

        if let cacheKey {
            cacheAspectRatio(
                ratio,
                for: inlineAspectRatioCacheKey(for: cacheKey, partitionUID: partitionUID)
            )
        }
        return ratio
    }


    static func cachedUIImage(for id: String, thumbnail: Bool = false, partitionUID: String? = nil) -> UIImage? {
        let key = uiImageCacheKey(for: id, thumbnail: thumbnail, partitionUID: partitionUID)
        let cache = thumbnail ? thumbnailCache : displayCache
        return cache.object(forKey: key as NSString)
    }

    static func cacheUIImage(
        _ image: UIImage,
        for id: String,
        thumbnail: Bool = false,
        partitionUID: String? = nil
    ) {
        let key = uiImageCacheKey(for: id, thumbnail: thumbnail, partitionUID: partitionUID)
        let cache = thumbnail ? thumbnailCache : displayCache
        cache.setObject(image, forKey: key as NSString, cost: imageMemoryCost(image))
        cacheAspectRatio(
            image.size.width / max(image.size.height, 1),
            for: aspectRatioCacheKey(
                for: id,
                thumbnail: thumbnail,
                partitionUID: partitionUID
            )
        )
    }

    static func imageMemoryCost(_ image: UIImage) -> Int {
        if let cg = image.cgImage {
            return cg.bytesPerRow * cg.height
        }
        let scale = image.scale
        let pixelWidth = image.size.width * scale
        let pixelHeight = image.size.height * scale
        return Int(pixelWidth * pixelHeight) * 4
    }


    static func loadDisplayImage(
        for id: String,
        maxPixelSize: CGFloat = 960,
        partitionUID: String? = nil
    ) async -> UIImage? {
        if let cached = cachedUIImage(for: id, partitionUID: partitionUID) { return cached }

        return await Task.detached(priority: .userInitiated) {
            guard let url = imageURL(for: id, partitionUID: partitionUID) else { return nil as UIImage? }
            guard let source = imageSource(for: url),
                  let image = decodedImage(from: source, maxPixelSize: maxPixelSize) else {
                return nil
            }
            await MainActor.run { cacheUIImage(image, for: id, partitionUID: partitionUID) }
            return image
        }.value
    }

    static func loadOriginalImage(for id: String, partitionUID: String? = nil) async -> UIImage? {
        let cacheKey = originalCacheKey(for: id, partitionUID: partitionUID)
        if let cached = originalCache.object(forKey: cacheKey as NSString) {
            return cached
        }

        return await Task.detached(priority: .userInitiated) {
            guard let data = loadImageData(for: id, partitionUID: partitionUID),
                  let image = UIImage(data: data) else {
                return nil as UIImage?
            }
            await MainActor.run {
                originalCache.setObject(image, forKey: cacheKey as NSString, cost: imageMemoryCost(image))
            }
            return image
        }.value
    }

    static func decodeImage(_ data: Data, maxPixelSize: CGFloat? = nil) async -> UIImage? {
        await Task.detached(priority: .userInitiated) {
            decodedImage(from: data, maxPixelSize: maxPixelSize)
        }.value
    }

    static func thumbnailImage(
        forBase64Encoded base64: String,
        cacheKey: String,
        maxPixelSize: CGFloat = 240,
        partitionUID: String? = nil
    ) -> UIImage? {
        let storageKey = inlineThumbnailCacheKey(for: cacheKey, maxPixelSize: maxPixelSize)
        if let cached = cachedUIImage(for: storageKey, thumbnail: true, partitionUID: partitionUID) {
            return cached
        }

        guard let data = Data(base64Encoded: base64),
              let image = decodedImage(from: data, maxPixelSize: maxPixelSize) else {
            return nil
        }

        cacheUIImage(image, for: storageKey, thumbnail: true, partitionUID: partitionUID)
        return image
    }


    static func generateAndSaveThumbnail(from imageData: Data, for id: String, partitionUID: String? = nil) {
        guard let thumbData = makeThumbnailData(from: imageData) else { return }
        saveThumbnail(imageData: thumbData, for: id, partitionUID: partitionUID)
    }

    static func makeThumbnailData(from imageData: Data) -> Data? {
        let options: [CFString: Any] = [kCGImageSourceShouldCache: false]
        guard let source = CGImageSourceCreateWithData(imageData as CFData, options as CFDictionary) else { return nil }

        let thumbOptions: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 120
        ]
        guard let cgThumb = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbOptions as CFDictionary) else { return nil }

        let thumbImage = UIImage(cgImage: cgThumb)
        return thumbImage.jpegData(compressionQuality: 0.5)
    }

    static func makeThumbnailBase64(from imageData: Data) -> String? {
        makeThumbnailData(from: imageData)?.base64EncodedString()
    }


    static func deleteImage(for id: String, partitionUID: String? = nil) {
        if let url = imageURL(for: id, partitionUID: partitionUID) {
            try? FileManager.default.removeItem(at: url)
        }
        if let url = thumbnailURL(for: id, partitionUID: partitionUID) {
            try? FileManager.default.removeItem(at: url)
        }
        displayCache.removeObject(
            forKey: uiImageCacheKey(for: id, thumbnail: false, partitionUID: partitionUID) as NSString
        )
        thumbnailCache.removeObject(
            forKey: uiImageCacheKey(for: id, thumbnail: true, partitionUID: partitionUID) as NSString
        )
        originalCache.removeObject(forKey: originalCacheKey(for: id, partitionUID: partitionUID) as NSString)
        aspectRatioCache.removeObject(
            forKey: aspectRatioCacheKey(
                for: id,
                thumbnail: false,
                partitionUID: partitionUID
            ) as NSString
        )
        aspectRatioCache.removeObject(
            forKey: aspectRatioCacheKey(
                for: id,
                thumbnail: true,
                partitionUID: partitionUID
            ) as NSString
        )
        aspectRatioCache.removeObject(
            forKey: inlineAspectRatioCacheKey(for: id, partitionUID: partitionUID) as NSString
        )
    }

    static func imageExists(for id: String, partitionUID: String? = nil) -> Bool {
        guard let url = imageURL(for: id, partitionUID: partitionUID) else { return false }
        return FileManager.default.fileExists(atPath: url.path)
    }

    private static func aspectRatio(for url: URL?) -> CGFloat? {
        guard let url else { return nil }
        guard let source = imageSource(for: url) else { return nil }
        return aspectRatio(for: source)
    }

    private static func aspectRatio(for data: Data) -> CGFloat? {
        guard let source = imageSource(for: data) else { return nil }
        return aspectRatio(for: source)
    }

    private static func aspectRatio(for source: CGImageSource) -> CGFloat? {
        guard
            let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
            let width = properties[kCGImagePropertyPixelWidth] as? CGFloat,
            let height = properties[kCGImagePropertyPixelHeight] as? CGFloat,
            height > 0
        else {
            return nil
        }

        return width / height
    }

    private static func imageSource(for url: URL) -> CGImageSource? {
        let options: [CFString: Any] = [
            kCGImageSourceShouldCache: false
        ]
        return CGImageSourceCreateWithURL(url as CFURL, options as CFDictionary)
    }

    private static func imageSource(for data: Data) -> CGImageSource? {
        let options: [CFString: Any] = [
            kCGImageSourceShouldCache: false
        ]
        return CGImageSourceCreateWithData(data as CFData, options as CFDictionary)
    }

    private static func decodedImage(from data: Data, maxPixelSize: CGFloat?) -> UIImage? {
        if maxPixelSize == nil {
            return UIImage(data: data)
        }

        guard let source = imageSource(for: data) else { return nil }
        if CGImageSourceGetCount(source) > 1 {
            return UIImage(data: data)
        }
        return decodedImage(from: source, maxPixelSize: maxPixelSize)
    }

    private static func decodedImage(from source: CGImageSource, maxPixelSize: CGFloat?) -> UIImage? {
        if let maxPixelSize, maxPixelSize > 0 {
            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceShouldCacheImmediately: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: maxPixelSize
            ]
            guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
                return nil
            }
            return UIImage(cgImage: cgImage)
        }

        let options: [CFString: Any] = [
            kCGImageSourceShouldCacheImmediately: true
        ]
        guard let cgImage = CGImageSourceCreateImageAtIndex(source, 0, options as CFDictionary) else {
            return nil
        }
        return UIImage(cgImage: cgImage)
    }

    private static func scopedCacheID(for id: String, partitionUID: String?) -> String {
        (partitionUID.map { "\($0)|" } ?? "") + id
    }

    private static func uiImageCacheKey(for id: String, thumbnail: Bool, partitionUID: String?) -> String {
        (thumbnail ? "t_" : "d_") + scopedCacheID(for: id, partitionUID: partitionUID)
    }

    private static func aspectRatioCacheKey(
        for id: String,
        thumbnail: Bool,
        partitionUID: String?
    ) -> String {
        (thumbnail ? "ratio_t_" : "ratio_d_") + scopedCacheID(for: id, partitionUID: partitionUID)
    }

    private static func inlineAspectRatioCacheKey(for id: String, partitionUID: String?) -> String {
        "ratio_i_" + scopedCacheID(for: id, partitionUID: partitionUID)
    }

    private static func inlineThumbnailCacheKey(for id: String, maxPixelSize: CGFloat) -> String {
        "inline_t_\(id)|\(Int(ceil(maxPixelSize)))"
    }

    private static func originalCacheKey(for id: String, partitionUID: String?) -> String {
        (partitionUID.map { "\($0)|" } ?? "") + "orig|" + id
    }

    private static func cacheAspectRatio(_ ratio: CGFloat, for key: String) {
        aspectRatioCache.setObject(NSNumber(value: Double(ratio)), forKey: key as NSString)
    }

    private static func cachedAspectRatio(for key: String) -> CGFloat? {
        aspectRatioCache.object(forKey: key as NSString).map { CGFloat(truncating: $0) }
    }
}
