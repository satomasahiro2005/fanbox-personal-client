import Foundation

/// Structure-preserving anonymizer for live FANBOX responses (Live API check, Research Mode).
///
/// The result keeps everything a decoder depends on — object keys, nesting, JSON types, number values, date formats,
/// enum-like values of structural keys, the numeric-ness and cross references of ids — and drops what identifies people or
/// content: free text becomes `"<text:N>"`, ids are replaced by consistent pseudonyms (the same id always maps to the same
/// pseudonym within one report, so `imageId` in a block still points at its `imageMap` entry), URLs keep only their host
/// and path shape. Secrets (tokens, cookies, CSRF) are always replaced.
///
/// A masked response is still a valid decoding fixture: `LiveContractTests` decode reports captured on a device with the
/// app's own DTOs and adapter.
struct LiveAPIShape {
    /// Values of these keys are kept verbatim (they drive decoding / mapping and carry no personal data).
    static let structuralKeys: Set<String> = [
        "type", "status", "extension", "serviceProvider", "paymentMethod", "commentingPermissionScope", "lang",
        "coverImageType", "mimeType", "contentType", "kind", "category", "currency", "fanboxUserStatus",
    ]
    /// Arrays keep their first `maxArrayElements` elements plus the first element of every other `type` value (so every
    /// block / notification kind stays visible), at most `maxArrayCap` in total.
    static let maxArrayElements = 3
    static let maxArrayCap = 30

    private let salt: UInt64

    /// `salt` makes pseudonyms unguessable across reports (a dictionary of creator ids cannot reverse them).
    init(salt: UInt64 = UInt64.random(in: .min ... .max)) {
        self.salt = salt
    }

    /// Masked, pretty-printed JSON (sorted keys), or nil when `data` is not JSON.
    func maskedJSON(_ data: Data) -> Data? {
        guard let root = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) else { return nil }
        let masked = mask(root, key: "", parentKey: "")
        return try? JSONSerialization.data(withJSONObject: masked, options: [.prettyPrinted, .sortedKeys, .fragmentsAllowed])
    }

    func mask(_ value: Any, key: String, parentKey: String) -> Any {
        if Self.isSecretKey(key) { return "<secret>" }
        switch value {
        case let dict as [String: Any]:
            var out: [String: Any] = [:]
            let idKeyed = key.hasSuffix("Map")
            for (k, v) in dict {
                let outKey = idKeyed ? pseudonym(k) : k
                out[outKey] = mask(v, key: k, parentKey: key)
            }
            return out
        case let array as [Any]:
            var kept: [Any] = []
            var seenTypes = Set<String>()
            for (index, element) in array.enumerated() {
                let type = (element as? [String: Any])?["type"] as? String
                let newType = type.map { !seenTypes.contains($0) } ?? false
                guard index < Self.maxArrayElements || newType else { continue }
                if let type { seenTypes.insert(type) }
                kept.append(mask(element, key: key, parentKey: parentKey))
                if kept.count >= Self.maxArrayCap { break }
            }
            return kept
        case let string as String:
            return maskString(string, key: key)
        default:
            return value   // numbers, booleans, NSNull
        }
    }

    func maskString(_ s: String, key: String) -> String {
        if s.isEmpty { return s }
        if Self.isDate(s) { return s }
        if Self.structuralKeys.contains(key) && s.count <= 40 { return s }
        if s.allSatisfy(\.isASCIIDigitCharacter) { return pseudonymDigits(s) }
        // Identifier fields are always pseudonymized the same way as map keys, so references stay resolvable.
        if Self.isIDKey(key), !s.contains(" "), s.count <= 80 { return pseudonym(s) }
        if let url = URL(string: s), let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
           let host = url.host { return maskURL(url, scheme: scheme, host: host) }
        if Self.isIDLike(s) { return pseudonym(s) }
        return "<text:\(s.count)>"
    }

    // MARK: Pseudonyms

    /// Same-length digit string, stable within this report.
    func pseudonymDigits(_ s: String) -> String {
        var h = hash(s)
        var out = ""
        for i in 0..<s.count {
            let digit = Int(h % 10)
            h /= 10
            if h == 0 { h = hash(s + String(i)) }
            out.append(Character(String(i == 0 && s.count > 1 ? max(1, digit) : digit)))
        }
        return out
    }

    func pseudonym(_ s: String) -> String {
        if s.allSatisfy(\.isASCIIDigitCharacter) { return pseudonymDigits(s) }
        return "id" + String(hash(s) & 0xFFFF_FFFF, radix: 16)
    }

    private func maskURL(_ url: URL, scheme: String, host: String) -> String {
        // Creator subdomains (<creator>.fanbox.cc) identify the creator.
        var maskedHost = host
        let parts = host.split(separator: ".")
        if parts.count == 3, parts[1] == "fanbox", parts[2] == "cc", parts[0] != "www", parts[0] != "api", parts[0] != "downloads" {
            maskedHost = pseudonym(String(parts[0])) + ".fanbox.cc"
        }
        let path = url.path.split(separator: "/", omittingEmptySubsequences: false).map { segment -> String in
            let s = String(segment)
            if s.isEmpty { return s }
            if s.hasPrefix("@") { return "@" + pseudonym(String(s.dropFirst())) }
            if s.allSatisfy(\.isASCIIDigitCharacter) { return pseudonymDigits(s) }
            if s.count > 16 {
                let ext = (s as NSString).pathExtension
                return pseudonym(s) + (ext.isEmpty ? "" : "." + ext)
            }
            return s
        }.joined(separator: "/")
        var out = "\(scheme)://\(maskedHost)\(path)"
        if let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems, !items.isEmpty {
            out += "?" + items.map(\.name).joined(separator: "&")
        }
        return out
    }

    private func hash(_ s: String) -> UInt64 {
        var h: UInt64 = 0xcbf2_9ce4_8422_2325 ^ salt
        for byte in s.utf8 {
            h ^= UInt64(byte)
            h = h &* 0x100_0000_01b3
        }
        return h
    }

    // MARK: Classification

    static func isSecretKey(_ key: String) -> Bool {
        let k = key.lowercased()
        if k == "tt" { return true }
        return ["csrf", "token", "sessid", "password", "cookie", "secret", "authorization"].contains { k.contains($0) }
    }

    /// `id`, `postId`, `imageId`, `creatorId`, … (values that reference other objects).
    static func isIDKey(_ key: String) -> Bool {
        key == "id" || key.hasSuffix("Id") || key.hasSuffix("ID") || key.hasSuffix("Ids")
    }

    static func isDate(_ s: String) -> Bool {
        s.range(of: #"^\d{4}-\d{2}-\d{2}([T ]\d{2}:\d{2}(:\d{2})?.*)?$"#, options: .regularExpression) != nil
    }

    /// Opaque identifiers (hashes, slugs, content ids): one token of URL-safe characters with at least one digit or a
    /// length typical of generated ids.
    static func isIDLike(_ s: String) -> Bool {
        guard s.count >= 6, s.count <= 80,
              s.range(of: #"^[A-Za-z0-9_.-]+$"#, options: .regularExpression) != nil else { return false }
        return s.contains(where: \.isASCIIDigitCharacter) || s.count >= 16
    }
}

private extension Character {
    var isASCIIDigitCharacter: Bool { isASCII && isNumber }
}
