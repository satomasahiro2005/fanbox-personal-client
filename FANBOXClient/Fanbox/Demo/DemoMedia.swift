import Foundation
import UIKit

/// `demo://` media URLs used by the demo world, plus an offline renderer so the media layer can "download" them
/// without any network access.
///
/// URL shapes:
/// - Image: `demo://image/<seed>?w=<px>&h=<px>&v=thumb|display|original`  (w/h = pixel size of THAT variant)
/// - File:  `demo://file/<name>.<ext>?size=<bytes>`                        (size = advertised size, metadata only)
///
/// Integration: `MediaService` can check `DemoMedia.isDemoURL(url)` and use `DemoMedia.placeholderData(for:)`
/// (or `renderImage(url:)`) instead of an HTTP fetch. Rendering is deterministic per URL.
enum DemoMedia {
    static let scheme = "demo"

    struct ImageSet: Sendable, Hashable {
        var thumbnail: String
        var display: String
        var original: String
        /// Original pixel size.
        var width: Int
        var height: Int
    }

    enum Resource: Sendable, Equatable {
        case image(seed: String, width: Int, height: Int, variant: MediaVariant)
        case file(name: String, size: Int)
    }

    // MARK: URL builders

    static func variantToken(_ variant: MediaVariant) -> String {
        switch variant {
        case .thumbnail: return "thumb"
        case .display: return "display"
        case .original: return "original"
        }
    }

    static func variant(fromToken token: String?) -> MediaVariant {
        switch token {
        case "thumb", "thumbnail": return .thumbnail
        case "original": return .original
        default: return .display
        }
    }

    static func imageURL(seed: String, width: Int, height: Int, variant: MediaVariant) -> String {
        "demo://image/\(escape(seed))?w=\(max(1, width))&h=\(max(1, height))&v=\(variantToken(variant))"
    }

    /// Thumbnail (long side 360) / display (long side 1200) / original URLs for one image.
    static func imageSet(seed: String, width: Int, height: Int) -> ImageSet {
        func fit(_ longSide: Int) -> (Int, Int) {
            let longest = max(width, height)
            guard longest > longSide else { return (width, height) }
            let scale = Double(longSide) / Double(longest)
            return (max(1, Int((Double(width) * scale).rounded())), max(1, Int((Double(height) * scale).rounded())))
        }
        let t = fit(360), d = fit(1200)
        return ImageSet(thumbnail: imageURL(seed: seed, width: t.0, height: t.1, variant: .thumbnail),
                        display: imageURL(seed: seed, width: d.0, height: d.1, variant: .display),
                        original: imageURL(seed: seed, width: width, height: height, variant: .original),
                        width: width, height: height)
    }

    /// Square avatar / icon URL.
    static func iconURL(seed: String, size: Int = 160) -> String {
        imageURL(seed: seed, width: size, height: size, variant: .thumbnail)
    }

    static func fileURL(name: String, size: Int) -> String {
        "demo://file/\(escape(name))?size=\(max(0, size))"
    }

    static func isDemoURL(_ url: String) -> Bool { url.hasPrefix("\(scheme)://") }

    static func parse(_ url: String) -> Resource? {
        guard isDemoURL(url), let components = URLComponents(string: url) else { return nil }
        let name = String(components.path.drop(while: { $0 == "/" }))
        guard !name.isEmpty else { return nil }
        let query = Dictionary((components.queryItems ?? []).map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { a, _ in a })
        switch components.host {
        case "image":
            let w = Int(query["w"] ?? "") ?? 800
            let h = Int(query["h"] ?? "") ?? 600
            return .image(seed: name, width: max(1, w), height: max(1, h), variant: variant(fromToken: query["v"]))
        case "file":
            return .file(name: name, size: Int(query["size"] ?? "") ?? 0)
        default:
            return nil
        }
    }

    // MARK: Rendering

    /// Aura-like palette (purple × mint accents on a dark base).
    private static let palette: [(UInt32, UInt32)] = [
        (0xA277FF, 0x61FFCA),
        (0x6D4AFF, 0x82E2FF),
        (0x61FFCA, 0x2D2A3E),
        (0xF694FF, 0xA277FF),
        (0xFFCA85, 0xA277FF),
        (0x82E2FF, 0x61FFCA),
        (0x3D375E, 0xA277FF),
        (0x61FFCA, 0xF694FF),
    ]

    private static func color(_ hex: UInt32, alpha: CGFloat = 1) -> UIColor {
        UIColor(red: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
    }

    /// Deterministic placeholder artwork. The long side is clamped to `maxPixelSize` to bound memory.
    static func renderImage(seed: String, width: Int, height: Int, variant: MediaVariant, maxPixelSize: Int = 1600) -> UIImage {
        let longest = max(1, max(width, height))
        let scale = longest > maxPixelSize ? Double(maxPixelSize) / Double(longest) : 1
        let size = CGSize(width: max(1, (Double(width) * scale).rounded()), height: max(1, (Double(height) * scale).rounded()))
        var rng = DemoRandom(seed: seed)
        let pair = palette[Int(DemoHash.fnv1a64(seed) % UInt64(palette.count))]

        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let renderer = UIGraphicsImageRenderer(size: size, format: format)
        return renderer.image { context in
            let cg = context.cgContext
            let colors = [color(pair.0).cgColor, color(pair.1).cgColor] as CFArray
            if let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 1]) {
                cg.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: size.width, y: size.height), options: [])
            }
            // Soft circles.
            for _ in 0..<5 {
                let r = CGFloat(0.12 + rng.unit() * 0.3) * min(size.width, size.height)
                let x = CGFloat(rng.unit()) * size.width
                let y = CGFloat(rng.unit()) * size.height
                cg.setFillColor(UIColor.white.withAlphaComponent(CGFloat(0.08 + rng.unit() * 0.12)).cgColor)
                cg.fillEllipse(in: CGRect(x: x - r, y: y - r, width: r * 2, height: r * 2))
            }
            // Label (skipped for tiny icons).
            let minSide = min(size.width, size.height)
            guard minSide >= 48 else { return }
            let paragraph = NSMutableParagraphStyle()
            paragraph.alignment = .center
            let title = NSAttributedString(string: "DEMO", attributes: [
                .font: UIFont.systemFont(ofSize: max(10, minSide * 0.16), weight: .heavy),
                .foregroundColor: UIColor.white.withAlphaComponent(0.9),
                .paragraphStyle: paragraph,
            ])
            let titleSize = title.size()
            title.draw(in: CGRect(x: 0, y: (size.height - titleSize.height) / 2 - titleSize.height * 0.3,
                                  width: size.width, height: titleSize.height))
            if minSide >= 120 {
                let caption = NSAttributedString(string: "\(seed) · \(variantToken(variant)) \(width)×\(height)", attributes: [
                    .font: UIFont.monospacedSystemFont(ofSize: max(8, minSide * 0.035), weight: .medium),
                    .foregroundColor: UIColor.white.withAlphaComponent(0.75),
                    .paragraphStyle: paragraph,
                ])
                let captionSize = caption.size()
                caption.draw(in: CGRect(x: 0, y: (size.height + titleSize.height) / 2, width: size.width, height: captionSize.height))
            }
        }
    }

    static func renderImage(url: String, maxPixelSize: Int = 1600) -> UIImage? {
        guard case .image(let seed, let w, let h, let v)? = parse(url) else { return nil }
        return renderImage(seed: seed, width: w, height: h, variant: v, maxPixelSize: maxPixelSize)
    }

    /// Bytes to store in the media cache for a `demo://` URL, or nil if the URL is not a demo URL.
    /// Images: JPEG (thumbnail: PNG). Files: a small valid document when the type allows (pdf / zip / txt),
    /// otherwise a short placeholder payload. File bytes are NOT padded to the advertised `size`.
    static func placeholderData(for url: String) -> Data? {
        switch parse(url) {
        case .image(let seed, let w, let h, let v)?:
            let image = renderImage(seed: seed, width: w, height: h, variant: v)
            return v == .thumbnail ? image.pngData() : image.jpegData(compressionQuality: 0.82)
        case .file(let name, _)?:
            return fileData(name: name)
        case nil:
            return nil
        }
    }

    private static func fileData(name: String) -> Data {
        let ext = (name as NSString).pathExtension.lowercased()
        let note = "FANBOX Personal Client — Demo file \"\(name)\". Synthetic placeholder content (not a real FANBOX file).\n"
        switch ext {
        case "zip":
            // Empty ZIP archive (end-of-central-directory record only).
            return Data([0x50, 0x4B, 0x05, 0x06] + [UInt8](repeating: 0, count: 18))
        case "pdf":
            let bounds = CGRect(x: 0, y: 0, width: 595, height: 842)
            return UIGraphicsPDFRenderer(bounds: bounds).pdfData { ctx in
                ctx.beginPage()
                NSAttributedString(string: "DEMO\n\n" + note, attributes: [.font: UIFont.systemFont(ofSize: 18)])
                    .draw(in: bounds.insetBy(dx: 48, dy: 64))
            }
        default:
            return Data(note.utf8)
        }
    }

    private static func escape(_ component: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return component.addingPercentEncoding(withAllowedCharacters: allowed) ?? component
    }
}
