import Foundation
import ImageIO
import UIKit

/// ImageIO-based decoding with downsampling. Never decodes a full-size bitmap just to show a thumbnail.
/// All functions are thread-safe and intended to run off the main actor.
enum ImageDownsampler {
    /// Size limit in pixels for each staged variant (SPEC §6): the longest side of a thumbnail, the shorter side of a
    /// display image (see `longestSideLimit(pixelSize:variant:)`). `nil` = full resolution.
    static func maxPixelSize(for variant: MediaVariant) -> CGFloat? {
        switch variant {
        case .thumbnail: return 400
        case .display: return 1600
        case .original: return nil
        }
    }

    /// Hard cap for "original" decoding to keep memory bounded on huge images.
    static let originalPixelCap: CGFloat = 8192

    /// Display images are shown at the full width of the screen, so their limit applies to the SHORTER side (a tall
    /// strip keeps its full width instead of being squeezed to 1600 px of height), within this many pixels.
    static let displayPixelBudget: CGFloat = 3 * 1600 * 1600

    /// A thumbnail keeps at least this many pixels on its shorter side (a square tile of a 1:5 strip would otherwise get
    /// 80 px of width), within `thumbnailPixelBudget`. Ordinary shapes (up to 2:1) keep the 400 px longest side.
    static let thumbnailMinShortSide: CGFloat = 200
    static let thumbnailPixelBudget: CGFloat = 3 * 400 * 400

    static func decode(fileURL: URL, variant: MediaVariant) -> UIImage? {
        let size = pixelSize(fileURL: fileURL) ?? .zero
        return decode(fileURL: fileURL, maxPixelSize: longestSideLimit(pixelSize: size, variant: variant))
    }

    /// The longest-side limit (what ImageIO takes) for decoding an image of `pixelSize` as `variant`. nil = full
    /// resolution up to `originalPixelCap`. An unknown size gets `maxPixelSize(for:)`.
    /// - Original: full size up to `originalPixelCap`, never smaller than the display decode of the same file (the viewer
    ///   replaces the display image with it).
    static func longestSideLimit(pixelSize: CGSize, variant: MediaVariant) -> CGFloat? {
        let width = pixelSize.width, height = pixelSize.height
        guard width > 0, height > 0 else { return maxPixelSize(for: variant) }
        let longest = max(width, height), shortest = min(width, height)
        let display = shortSideLimitedLongestSide(pixelSize: pixelSize, shortSide: maxPixelSize(for: .display) ?? 1600,
                                                  budget: displayPixelBudget) ?? longest
        switch variant {
        case .thumbnail:
            let thumbnailSide = maxPixelSize(for: .thumbnail) ?? 400
            let scale = min(1, max(thumbnailSide / longest, thumbnailMinShortSide / shortest),
                            (thumbnailPixelBudget / (width * height)).squareRoot())
            return max(1, (longest * scale).rounded(.down))
        case .display:
            return display
        case .original:
            return max(min(longest, originalPixelCap), display)
        }
    }

    /// The longest-side limit (what ImageIO takes) that caps the shorter side at `shortSide` and the area at `budget`,
    /// never enlarging. nil for an unknown size.
    static func shortSideLimitedLongestSide(pixelSize: CGSize, shortSide: CGFloat, budget: CGFloat) -> CGFloat? {
        let width = pixelSize.width, height = pixelSize.height
        guard width > 0, height > 0 else { return nil }
        let scale = min(1, shortSide / min(width, height), (budget / (width * height)).squareRoot())
        return max(1, (max(width, height) * scale).rounded(.down))
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
