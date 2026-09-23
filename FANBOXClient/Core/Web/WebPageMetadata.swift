import Foundation
import WebKit

/// Logged-in user as read from a www.fanbox.cc page (fallback when the API profile request fails during login).
struct WebLoginMetadata: Sendable, Hashable {
    var pixivUserID: String
    var name: String
    var iconURL: String?
    var creatorID: String?
    var fanboxUserID: String?

    init(pixivUserID: String, name: String, iconURL: String? = nil, creatorID: String? = nil, fanboxUserID: String? = nil) {
        self.pixivUserID = pixivUserID
        self.name = name
        self.iconURL = iconURL
        self.creatorID = creatorID
        self.fanboxUserID = fanboxUserID
    }

    var remoteUser: RemoteUser {
        RemoteUser(pixivUserID: pixivUserID, fanboxUserID: fanboxUserID, name: name, iconURL: iconURL, creatorID: creatorID)
    }
}

/// What the account-aware WebView learned from the current page.
/// `csrfToken` is a secret: it is only handed to `AccountService` (→ Keychain) and never logged or displayed (SPEC §38).
struct WebPageMetadata: Sendable, Hashable {
    var userAgent: String?
    /// Origin + path only (query / fragment dropped).
    var pageURL: String?
    var csrfToken: String?
    /// Non-nil only when the page says a user is logged in.
    var user: WebLoginMetadata?
    /// Explicit login flag from the page, when present.
    var isLoggedIn: Bool?

    init(userAgent: String? = nil, pageURL: String? = nil, csrfToken: String? = nil, user: WebLoginMetadata? = nil, isLoggedIn: Bool? = nil) {
        self.userAgent = userAgent
        self.pageURL = pageURL
        self.csrfToken = csrfToken
        self.user = user
        self.isLoggedIn = isLoggedIn
    }

    /// Parses the JSON string returned by `WebPageInspector.script`.
    static func fromScriptResult(_ json: String) -> WebPageMetadata? {
        guard let object = WebPageMetadataParser.jsonObject(json) as? [String: Any] else { return nil }
        var result = WebPageMetadata(userAgent: object["userAgent"] as? String, pageURL: object["href"] as? String)
        if let content = object["metadata"] as? String {
            result.apply(metadataContent: content)
        }
        if result.csrfToken == nil || result.user == nil, let nextData = object["nextData"] as? String {
            result.apply(nextData: nextData)
        }
        return result
    }

    /// Applies the JSON found in `<meta name="metadata" content="...">` of www.fanbox.cc pages:
    /// `{ "csrfToken": "...", "context": { "user": { "userId": "...", "name": "...", "iconUrl": "...", ... } } }`.
    mutating func apply(metadataContent content: String) {
        guard let root = WebPageMetadataParser.jsonObject(content) as? [String: Any] else { return }
        if csrfToken == nil, let token = root["csrfToken"] as? String, !token.isEmpty {
            csrfToken = token
        }
        if let context = root["context"] as? [String: Any], let userDict = context["user"] as? [String: Any] {
            applyUser(userDict)
        }
    }

    /// Fallback for pages rendered from embedded app data (`<script id="__NEXT_DATA__">`).
    /// Only a user object at `context.user` / `currentUser` / `loginUser` is accepted — creator objects elsewhere in the
    /// page also carry `userId` + `name` and must never be mistaken for the logged-in user.
    mutating func apply(nextData json: String) {
        guard let root = WebPageMetadataParser.jsonObject(json) else { return }
        var found = WebPageMetadataParser.Findings()
        WebPageMetadataParser.search(root, parentKey: nil, key: nil, depth: 0, findings: &found)
        if csrfToken == nil, let token = found.csrfToken { csrfToken = token }
        if user == nil, let userDict = found.user { applyUser(userDict) }
    }

    private mutating func applyUser(_ dict: [String: Any]) {
        if let flag = dict["isLoggedIn"] as? Bool { isLoggedIn = flag }
        guard isLoggedIn != false else {
            user = nil
            return
        }
        guard let userID = WebPageMetadataParser.string(dict["userId"]), !userID.isEmpty else { return }
        let name = (dict["name"] as? String) ?? ""
        let icon = (dict["iconUrl"] as? String) ?? (dict["iconURL"] as? String)
        let creatorID = WebPageMetadataParser.string(dict["creatorId"]).flatMap { $0.isEmpty ? nil : $0 }
        let fanboxUserID = WebPageMetadataParser.string(dict["fanboxUserId"]).flatMap { $0.isEmpty ? nil : $0 }
        user = WebLoginMetadata(pixivUserID: userID, name: name, iconURL: icon, creatorID: creatorID, fanboxUserID: fanboxUserID)
        if isLoggedIn == nil { isLoggedIn = true }
    }
}

/// Descriptions never contain the CSRF token (SPEC §38), even if the value is printed while debugging.
extension WebPageMetadata: CustomStringConvertible, CustomDebugStringConvertible {
    var description: String {
        let token = csrfToken == nil ? "nil" : SecretRedactor.placeholder
        let loggedIn = isLoggedIn.map { $0 ? "true" : "false" } ?? "nil"
        return "WebPageMetadata(pageURL: \(pageURL ?? "nil"), csrfToken: \(token), user: \(user?.pixivUserID ?? "nil"), isLoggedIn: \(loggedIn))"
    }

    var debugDescription: String { description }
}

enum WebPageMetadataParser {
    struct Findings {
        var csrfToken: String?
        var user: [String: Any]?
        var visited = 0
    }

    static let maxDepth = 24
    static let maxNodes = 200_000

    static func jsonObject(_ string: String) -> Any? {
        guard let data = string.data(using: .utf8) else { return nil }
        return try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
    }

    /// String or (non-boolean) number → String.
    static func string(_ value: Any?) -> String? {
        if let s = value as? String { return s }
        if let n = value as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID() { return n.stringValue }
        return nil
    }

    static func isLoginUserKey(parentKey: String?, key: String?) -> Bool {
        guard let key else { return false }
        if key == "currentUser" || key == "loginUser" { return true }
        return key == "user" && parentKey == "context"
    }

    static func search(_ node: Any, parentKey: String?, key: String?, depth: Int, findings: inout Findings) {
        findings.visited += 1
        guard depth <= maxDepth, findings.visited <= maxNodes else { return }
        if findings.csrfToken != nil && findings.user != nil { return }
        if let dict = node as? [String: Any] {
            if findings.user == nil, isLoginUserKey(parentKey: parentKey, key: key), dict["userId"] != nil {
                findings.user = dict
            }
            if findings.csrfToken == nil, let token = dict["csrfToken"] as? String, !token.isEmpty {
                findings.csrfToken = token
            }
            for (childKey, child) in dict where child is [String: Any] || child is [Any] {
                search(child, parentKey: key, key: childKey, depth: depth + 1, findings: &findings)
            }
        } else if let array = node as? [Any] {
            for child in array where child is [String: Any] || child is [Any] {
                search(child, parentKey: parentKey, key: key, depth: depth + 1, findings: &findings)
            }
        }
    }
}

/// JavaScript helper run in the account WebView (isolated `.defaultClient` content world, so page scripts cannot tamper
/// with it). It only reads page data; parsing happens in Swift (`WebPageMetadata`).
enum WebPageInspector {
    /// Body of an async JS function (for `callAsyncJavaScript`). Returns a JSON string.
    static let script = """
    const out = { userAgent: navigator.userAgent, href: location.origin + location.pathname, metadata: null, nextData: null };
    try {
      const meta = document.querySelector('meta[name="metadata"]') || document.getElementById('metadata');
      if (meta) { out.metadata = meta.getAttribute('content'); }
    } catch (e) {}
    try {
      const next = document.getElementById('__NEXT_DATA__');
      if (next && next.textContent && next.textContent.length < 3000000) { out.nextData = next.textContent; }
    } catch (e) {}
    return JSON.stringify(out);
    """

    @MainActor
    static func inspect(_ webView: WKWebView) async -> WebPageMetadata? {
        do {
            let value = try await webView.callAsyncJavaScript(script, arguments: [:], in: nil, contentWorld: .defaultClient)
            guard let json = value as? String else { return nil }
            return WebPageMetadata.fromScriptResult(json)
        } catch {
            let ns = error as NSError
            AppLog.web.debug("page inspection failed (\(ns.domain, privacy: .public) \(ns.code, privacy: .public))")
            return nil
        }
    }
}
