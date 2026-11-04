import Foundation
import ImageIO
import UIKit
import UniformTypeIdentifiers

/// ImageIO-based encode / downsample helpers. Decoding goes through thumbnails so a
/// full-resolution bitmap is never created for lists.
enum PhotoImageProcessing {
    struct Processed {
        var fullJPEG: Data
        var thumbnailJPEG: Data
        var pixelWidth: Int
        var pixelHeight: Int
        /// EXIF DateTimeOriginal when present.
        var takenDate: Date?
    }

    static let maxStoredPixelSize = 4096
    static let thumbnailPixelSize = 480

    /// Normalizes orientation, caps the stored size and builds a thumbnail.
    static func process(_ data: Data) -> Processed? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let full = downsample(source, maxPixelSize: maxStoredPixelSize),
              let thumb = downsample(source, maxPixelSize: thumbnailPixelSize),
              let fullJPEG = jpeg(full, quality: 0.85),
              let thumbJPEG = jpeg(thumb, quality: 0.75) else {
            return nil
        }
        return Processed(
            fullJPEG: fullJPEG,
            thumbnailJPEG: thumbJPEG,
            pixelWidth: full.width,
            pixelHeight: full.height,
            takenDate: exifDate(source)
        )
    }

    /// Downsampled image from a file; nil when missing or undecodable.
    static func downsampledImage(at url: URL, maxPixelSize: Int) -> UIImage? {
        let options = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithURL(url as CFURL, options),
              let image = downsample(source, maxPixelSize: maxPixelSize) else {
            return nil
        }
        return UIImage(cgImage: image)
    }

    static func thumbnailJPEG(fromFileAt url: URL) -> Data? {
        let options = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithURL(url as CFURL, options),
              let image = downsample(source, maxPixelSize: thumbnailPixelSize) else {
            return nil
        }
        return jpeg(image, quality: 0.75)
    }

    private static func downsample(_ source: CGImageSource, maxPixelSize: Int) -> CGImage? {
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    private static func jpeg(_ image: CGImage, quality: Double) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else {
            return nil
        }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }

    private static func exifDate(_ source: CGImageSource) -> Date? {
        guard let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any],
              let raw = exif[kCGImagePropertyExifDateTimeOriginal] as? String else {
            return nil
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy:MM:dd HH:mm:ss"
        return formatter.date(from: raw)
    }
}

/// Memory cache + background loader for gallery thumbnails.
final class PhotoThumbnailCache: @unchecked Sendable {
    static let shared = PhotoThumbnailCache()

    private let cache: NSCache<NSURL, UIImage> = {
        let cache = NSCache<NSURL, UIImage>()
        cache.countLimit = 400
        return cache
    }()

    func cached(_ url: URL) -> UIImage? {
        cache.object(forKey: url as NSURL)
    }

    /// Loads a thumbnail. Uses `thumbnailURL` when readable; otherwise downsamples `originalURL`
    /// and, when `regenerate` is true, writes the missing thumbnail back to `thumbnailURL`.
    func load(thumbnailURL: URL?, originalURL: URL, regenerate: Bool) async -> UIImage? {
        let key = (thumbnailURL ?? originalURL) as NSURL
        if let hit = cache.object(forKey: key) { return hit }
        let image = await Task.detached(priority: .userInitiated) { () -> UIImage? in
            if let thumbnailURL,
               let image = PhotoImageProcessing.downsampledImage(at: thumbnailURL, maxPixelSize: PhotoImageProcessing.thumbnailPixelSize) {
                return image
            }
            guard FileManager.default.fileExists(atPath: originalURL.path) else { return nil }
            if regenerate, let thumbnailURL, let data = PhotoImageProcessing.thumbnailJPEG(fromFileAt: originalURL) {
                try? FileManager.default.createDirectory(
                    at: thumbnailURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                try? data.write(to: thumbnailURL, options: [.atomic])
            }
            return PhotoImageProcessing.downsampledImage(at: originalURL, maxPixelSize: PhotoImageProcessing.thumbnailPixelSize)
        }.value
        if let image { cache.setObject(image, forKey: key) }
        return image
    }

    func evict(_ urls: [URL]) {
        for url in urls { cache.removeObject(forKey: url as NSURL) }
    }
}
