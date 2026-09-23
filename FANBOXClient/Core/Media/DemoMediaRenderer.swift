import CryptoKit
import Foundation
import UIKit

/// Parsed `demo://` media URL emitted by `DemoRemoteDataSource`:
///
///     demo://image/<seed>?w=<w>&h=<h>&v=<thumb|display|original>
///     demo://file/<name>.<ext>?size=<bytes>
enum DemoMediaURL: Equatable, Sendable {
    case image(seed: String, width: Int, height: Int, variant: MediaVariant?)
    case file(name: String, size: Int)

    init?(_ string: String) {
        guard string.hasPrefix("demo://"), let components = URLComponents(string: string) else { return nil }
        let query = Dictionary((components.queryItems ?? []).map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { a, _ in a })
        var path = components.percentEncodedPath.removingPercentEncoding ?? components.path
        while path.hasPrefix("/") { path.removeFirst() }
        switch components.host {
        case "image":
            let seed = path.isEmpty ? "demo" : path
            let width = Int(query["w"] ?? "") ?? 1200
            let height = Int(query["h"] ?? "") ?? 900
            let variant: MediaVariant?
            switch query["v"] {
            case "thumb", "thumbnail": variant = .thumbnail
            case "display": variant = .display
            case "original": variant = .original
            default: variant = nil
            }
            self = .image(seed: seed, width: max(1, width), height: max(1, height), variant: variant)
        case "file":
            let name = path.isEmpty ? "demo.bin" : path
            self = .file(name: name, size: max(0, Int(query["size"] ?? "") ?? 16_384))
        default:
            return nil
        }
    }
}

/// Renders demo media locally (no network): deterministic gradient images labeled with their seed, and small
/// generated files. Output goes through the regular cache path so policy / eviction / offline behavior is identical
/// to real downloads. Thread-safe (UIGraphicsImageRenderer is safe off the main thread).
enum DemoMediaRenderer {
    /// Generated files are capped so demo attachments stay small on disk.
    static let maxFileBytes = 512 * 1024

    static func canRender(_ url: String) -> Bool { DemoMediaURL(url) != nil }

    /// Renders the media for `url` into memory.
    static func render(url: String, requestedVariant: MediaVariant) throws -> Data {
        guard let parsed = DemoMediaURL(url) else { throw RemoteError.invalidRequest("demo URL を解釈できませんでした") }
        switch parsed {
        case let .image(seed, width, height, variant):
            guard let data = renderImage(seed: seed, width: width, height: height, variant: variant ?? requestedVariant) else {
                throw RemoteError.decoding(endpoint: "media.demo", detail: "render failed")
            }
            return data
        case let .file(name, size):
            return renderFile(name: name, size: size)
        }
    }

    static func renderImage(seed: String, width: Int, height: Int, variant: MediaVariant) -> Data? {
        let maxSide: CGFloat
        switch variant {
        case .thumbnail: maxSide = 400
        case .display: maxSide = 1600
        case .original: maxSide = 2400
        }
        let w = CGFloat(width), h = CGFloat(height)
        let scale = min(1, maxSide / max(w, h))
        let size = CGSize(width: max(16, (w * scale).rounded()), height: max(16, (h * scale).rounded()))

        let digest = Array(SHA256.hash(data: Data(seed.utf8)))
        let hue1 = CGFloat(digest[0]) / 255
        let hue2 = (hue1 + 0.18 + CGFloat(digest[1]) / 255 * 0.3).truncatingRemainder(dividingBy: 1)

        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let renderer = UIGraphicsImageRenderer(size: size, format: format)
        return renderer.jpegData(withCompressionQuality: variant == .thumbnail ? 0.7 : 0.82) { context in
            let cg = context.cgContext
            let colors = [
                UIColor(hue: hue1, saturation: 0.55, brightness: 0.92, alpha: 1).cgColor,
                UIColor(hue: hue2, saturation: 0.65, brightness: 0.62, alpha: 1).cgColor,
            ] as CFArray
            if let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 1]) {
                cg.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: size.width, y: size.height), options: [])
            }

            // A few deterministic translucent circles so different seeds look different.
            for i in 0..<5 {
                let b0 = CGFloat(digest[2 + i * 3]) / 255
                let b1 = CGFloat(digest[3 + i * 3]) / 255
                let b2 = CGFloat(digest[4 + i * 3]) / 255
                let radius = (0.12 + b2 * 0.3) * min(size.width, size.height)
                let center = CGPoint(x: b0 * size.width, y: b1 * size.height)
                cg.setFillColor(UIColor(white: 1, alpha: 0.10 + b2 * 0.12).cgColor)
                cg.fillEllipse(in: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2))
            }

            let label: String
            switch variant {
            case .thumbnail: label = "thumbnail"
            case .display: label = "display"
            case .original: label = "original"
            }
            let title = "\(seed)\n\(label) · \(width)×\(height)\nDEMO"
            let fontSize = max(10, min(size.width, size.height) * 0.07)
            let paragraph = NSMutableParagraphStyle()
            paragraph.alignment = .center
            let attributes: [NSAttributedString.Key: Any] = [
                .font: UIFont.systemFont(ofSize: fontSize, weight: .semibold),
                .foregroundColor: UIColor(white: 1, alpha: 0.92),
                .paragraphStyle: paragraph,
            ]
            let text = NSString(string: title)
            let bounds = text.boundingRect(with: CGSize(width: size.width * 0.9, height: size.height),
                                           options: [.usesLineFragmentOrigin], attributes: attributes, context: nil)
            let rect = CGRect(x: (size.width - bounds.width) / 2, y: (size.height - bounds.height) / 2,
                              width: bounds.width, height: bounds.height)
            text.draw(with: rect, options: [.usesLineFragmentOrigin], attributes: attributes, context: nil)
        }
    }

    /// Deterministic small file. Text-like extensions get readable content.
    static func renderFile(name: String, size: Int) -> Data {
        let count = min(max(size, 0), maxFileBytes)
        let ext = (name as NSString).pathExtension.lowercased()
        if ["txt", "md", "csv", "json", "log"].contains(ext) {
            let line = "FANBOX Personal Client demo file: \(name)\n"
            var data = Data()
            data.reserveCapacity(count)
            let lineData = Data(line.utf8)
            while data.count < count { data.append(lineData) }
            return data.prefix(count)
        }
        // Simple LCG seeded from the name: stable bytes, no randomness.
        var state = UInt64(truncatingIfNeeded: SHA256.hash(data: Data(name.utf8)).reduce(UInt64(1469598103934665603)) {
            ($0 ^ UInt64($1)) &* 1099511628211
        })
        var bytes = [UInt8](repeating: 0, count: count)
        for i in 0..<count {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            bytes[i] = UInt8(truncatingIfNeeded: state >> 33)
        }
        return Data(bytes)
    }
}
