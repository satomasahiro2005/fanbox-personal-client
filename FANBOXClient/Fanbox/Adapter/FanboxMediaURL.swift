import Foundation

/// FANBOX media URL shapes (docs/API.md §1.9).
enum FanboxMediaURL {
    /// The un-resized original of a resized pximg image: `pixiv.pximg.net/c/{W}x{H}_90_a2_g5/fanbox/public/images/…`
    /// → `pixiv.pximg.net/fanbox/public/images/…` (the `/c/<size>/` segment dropped, as gallery-dl and PixivUtil2 do).
    /// The API serves icons at 160×160, creator covers at 1620×580, post covers at 1200×630 and plan covers at 936×600.
    /// nil for any other URL (already un-resized, another host, demo media). Callers keep the resized URL as the
    /// fallback: the original is loaded as the `.original` variant and may be refused.
    static func pximgOriginal(of url: String) -> String? {
        guard var components = URLComponents(string: url), FanboxHostPolicy.isPximgHost(components.host) else { return nil }
        // "", "c", "<size>", "fanbox", "public", "images", …
        let parts = components.percentEncodedPath.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count > 6, parts[0].isEmpty, parts[1] == "c", !parts[2].isEmpty,
              parts[3] == "fanbox", parts[4] == "public", parts[5] == "images" else { return nil }
        components.percentEncodedPath = "/" + parts.dropFirst(3).joined(separator: "/")
        return components.string
    }
}
