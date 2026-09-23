import Foundation

/// Opaque paging cursor handed out through `RemotePage.nextCursor`. Callers treat it as an opaque string;
/// only `FanboxRemoteDataSource` creates and reads it.
enum FanboxCursor: Codable, Hashable, Sendable {
    /// A `nextUrl` returned by FANBOX (post.listHome / post.listSupporting / post.listTagged), replayed verbatim.
    case nextURL(String)
    /// Page `index` of `post.paginateCreator`'s `pageUrls` (the URL itself is kept so the page can be fetched directly).
    case creatorPage(index: Int, url: String)
    /// `post.getComments` offset.
    case offset(Int)
    /// Page number (bell.list: 1-based; creator.search: 0-based).
    case page(Int)

    private static let prefix = "fbc1."

    var encoded: String {
        guard let data = try? JSONEncoder().encode(self) else { return "" }
        let b64 = data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        return Self.prefix + b64
    }

    init?(encoded: String?) {
        guard let encoded, encoded.hasPrefix(Self.prefix) else { return nil }
        var b64 = String(encoded.dropFirst(Self.prefix.count))
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while b64.count % 4 != 0 { b64 += "=" }
        guard let data = Data(base64Encoded: b64), let value = try? JSONDecoder().decode(FanboxCursor.self, from: data) else { return nil }
        self = value
    }

    /// Reads one query value from a FANBOX URL (e.g. `offset` from a comments `nextUrl`, `page` from a bell `nextUrl`).
    static func queryValue(_ name: String, in urlString: String?) -> String? {
        guard let urlString, let comps = URLComponents(string: urlString) else { return nil }
        return comps.queryItems?.first { $0.name == name }?.value
    }
}

/// In-memory cache of `post.paginateCreator` results so "load more" does not refetch the page list every time.
/// The first page of a creator ALWAYS refetches (page boundaries shift when new posts appear; docs/API.md §19.2).
actor FanboxPageURLCache {
    private struct Entry {
        var urls: [String]
        var fetchedAt: Date
    }

    private var entries: [String: Entry] = [:]
    private let lifetime: TimeInterval

    init(lifetime: TimeInterval = 15 * 60) {
        self.lifetime = lifetime
    }

    func urls(for key: String, now: Date = .now) -> [String]? {
        guard let entry = entries[key], now.timeIntervalSince(entry.fetchedAt) < lifetime else { return nil }
        return entry.urls
    }

    func store(_ urls: [String], for key: String, now: Date = .now) {
        entries[key] = Entry(urls: urls, fetchedAt: now)
        if entries.count > 64 {
            // Keep the cache small: drop the oldest entries.
            let sorted = entries.sorted { $0.value.fetchedAt < $1.value.fetchedAt }
            for (k, _) in sorted.prefix(entries.count - 64) { entries[k] = nil }
        }
    }
}
