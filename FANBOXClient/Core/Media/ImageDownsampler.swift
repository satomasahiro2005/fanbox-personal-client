import Foundation
import ImageIO
import UIKit

/// ImageIO-based decoding with downsampling. Never decodes a full-size bitmap just to show a thumbnail.
/// All functions are thread-safe and intended to run off the main actor.
enum ImageDownsampler {
    /// Longest side in pixels for each staged variant (SPEC §6). `nil` = full resolution.
    static func maxPixelSize(for variant: MediaVariant) -> CGFloat? {
        switch variant {
        case .thumbnail: return 400
        case .display: return 1600
        case .original: return nil
        }
    }

    /// Hard cap for "original" decoding to keep memory bounded on huge images.
    static let originalPixelCap: CGFloat = 8192

    static func decode(fileURL: URL, variant: MediaVariant) -> UIImage? {
        decode(fileURL: fileURL, maxPixelSize: maxPixelSize(for: variant))
    }

    static func decode(fileURL: URL, maxPixelSize: CGFloat?) -> UIImage? {
        let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithURL(fileURL as CFURL, sourceOptions),
              CGImageSourceGetCount(source) > 0 else { return nil }

        var limit = maxPixelSize
        if limit == nil {
            let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
            let width = (props?[kCGImagePropertyPixelWidth] as? NSNumber)?.doubleValue ?? 0
            let height = (props?[kCGImagePropertyPixelHeight] as? NSNumber)?.doubleValue ?? 0
            let longest = max(width, height)
            limit = longest > 0 ? min(CGFloat(longest), originalPixelCap) : originalPixelCap
        }

        let options = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: limit ?? originalPixelCap,
        ] as CFDictionary
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options) else { return nil }
        return UIImage(cgImage: cgImage)
    }

    /// Pixel size without decoding (used for layout hints).
    static func pixelSize(fileURL: URL) -> CGSize? {
        guard let source = CGImageSourceCreateWithURL(fileURL as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = (props[kCGImagePropertyPixelWidth] as? NSNumber)?.doubleValue,
              let height = (props[kCGImagePropertyPixelHeight] as? NSNumber)?.doubleValue else { return nil }
        return CGSize(width: width, height: height)
    }

    /// Approximate decoded size in bytes (NSCache cost).
    static func memoryCost(of image: UIImage) -> Int {
        guard let cg = image.cgImage else { return Int(image.size.width * image.size.height * 4) }
        return cg.bytesPerRow * cg.height
    }
}
