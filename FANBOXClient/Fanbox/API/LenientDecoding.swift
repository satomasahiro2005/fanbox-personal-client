import Foundation

/// String-based coding key so DTOs can read fields by name without declaring a `CodingKeys` enum.
struct AnyCodingKey: CodingKey, Hashable {
    var stringValue: String
    var intValue: Int?

    init(_ string: String) {
        stringValue = string
        intValue = nil
    }

    init?(stringValue: String) { self.init(stringValue) }

    init?(intValue: Int) {
        stringValue = String(intValue)
        self.intValue = intValue
    }
}

/// Tolerant field access used by every FANBOX DTO (SPEC §37).
/// - Missing keys, `null` and type mismatches yield `nil` instead of throwing.
/// - ids may be numbers or strings ⇒ `String`; fees / counts may be strings ⇒ `Int`; bools may be 0/1 or "true".
/// - Arrays skip elements that fail to decode; dictionaries skip values that fail to decode.
struct LenientObject {
    let container: KeyedDecodingContainer<AnyCodingKey>

    init(_ decoder: Decoder) throws {
        container = try decoder.container(keyedBy: AnyCodingKey.self)
    }

    var keys: [String] { container.allKeys.map(\.stringValue) }

    func has(_ key: String) -> Bool { container.contains(AnyCodingKey(key)) }

    func isNull(_ key: String) -> Bool {
        let k = AnyCodingKey(key)
        guard container.contains(k) else { return true }
        return (try? container.decodeNil(forKey: k)) ?? true
    }

    func string(_ key: String) -> String? {
        let k = AnyCodingKey(key)
        guard container.contains(k), !isNull(key) else { return nil }
        if let s = try? container.decode(String.self, forKey: k) { return s }
        if let i = try? container.decode(Int64.self, forKey: k) { return String(i) }
        if let d = try? container.decode(Double.self, forKey: k) { return JSONValue.format(number: d) }
        if let b = try? container.decode(Bool.self, forKey: k) { return b ? "true" : "false" }
        return nil
    }

    /// Like `string` but treats "" as nil.
    func nonEmptyString(_ key: String) -> String? {
        guard let s = string(key), !s.isEmpty else { return nil }
        return s
    }

    func int(_ key: String) -> Int? {
        let k = AnyCodingKey(key)
        guard container.contains(k), !isNull(key) else { return nil }
        if let i = try? container.decode(Int.self, forKey: k) { return i }
        if let d = try? container.decode(Double.self, forKey: k), d.isFinite, abs(d) < 9.0e18 { return Int(d) }
        if let s = try? container.decode(String.self, forKey: k) { return JSONValue.parseInt(s) }
        if let b = try? container.decode(Bool.self, forKey: k) { return b ? 1 : 0 }
        return nil
    }

    func bool(_ key: String) -> Bool? {
        let k = AnyCodingKey(key)
        guard container.contains(k), !isNull(key) else { return nil }
        if let b = try? container.decode(Bool.self, forKey: k) { return b }
        if let i = try? container.decode(Int.self, forKey: k) { return i != 0 }
        if let s = try? container.decode(String.self, forKey: k) { return JSONValue.parseBool(s) }
        return nil
    }

    func date(_ key: String) -> Date? {
        let k = AnyCodingKey(key)
        guard container.contains(k), !isNull(key) else { return nil }
        if let s = try? container.decode(String.self, forKey: k) { return FanboxDateParser.parse(s) }
        if let d = try? container.decode(Double.self, forKey: k) { return FanboxDateParser.date(epoch: d) }
        return nil
    }

    func decode<T: Decodable>(_ key: String, as type: T.Type = T.self) -> T? {
        let k = AnyCodingKey(key)
        guard container.contains(k), !isNull(key) else { return nil }
        return try? container.decode(T.self, forKey: k)
    }

    func json(_ key: String) -> JSONValue? {
        let k = AnyCodingKey(key)
        guard container.contains(k) else { return nil }
        return try? container.decode(JSONValue.self, forKey: k)
    }

    /// Array of `T`, skipping elements that fail to decode. nil when the key is missing / not an array.
    func array<T: Decodable>(_ key: String, of type: T.Type = T.self) -> [T]? {
        let k = AnyCodingKey(key)
        guard container.contains(k), !isNull(key), var nested = try? container.nestedUnkeyedContainer(forKey: k) else { return nil }
        return LenientObject.decodeElements(&nested, as: T.self)
    }

    /// Array of strings (numbers are converted), skipping other values.
    func stringArray(_ key: String) -> [String]? {
        guard let values = array(key, of: JSONValue.self) else { return nil }
        return values.compactMap(\.stringValue)
    }

    /// Dictionary of id → `T`, skipping values that fail to decode. A JSON array of objects with "id" is also accepted.
    func map<T: Decodable & FanboxIdentifiedDTO>(_ key: String, of type: T.Type = T.self) -> [String: T]? {
        let k = AnyCodingKey(key)
        guard container.contains(k), !isNull(key) else { return nil }
        if let nested = try? container.nestedContainer(keyedBy: AnyCodingKey.self, forKey: k) {
            var result: [String: T] = [:]
            for entryKey in nested.allKeys {
                if let value = try? nested.decode(T.self, forKey: entryKey) {
                    result[entryKey.stringValue] = value
                }
            }
            return result
        }
        // Some serializers emit an empty map as [] — accept arrays of identified objects too.
        if var nested = try? container.nestedUnkeyedContainer(forKey: k) {
            let items = LenientObject.decodeElements(&nested, as: T.self)
            var result: [String: T] = [:]
            for item in items {
                if let id = item.dtoID { result[id] = item }
            }
            return result
        }
        return nil
    }

    static func decodeElements<T: Decodable>(_ container: inout UnkeyedDecodingContainer, as type: T.Type) -> [T] {
        var items: [T] = []
        while !container.isAtEnd {
            if let value = try? container.decode(T.self) {
                items.append(value)
            } else if (try? container.decode(JSONValue.self)) == nil {
                // Could not even skip the element; stop to avoid an infinite loop.
                break
            }
        }
        return items
    }
}

/// DTOs that carry an `id` (used for map / array fallbacks).
protocol FanboxIdentifiedDTO {
    var dtoID: String? { get }
}

/// A top-level array decoded leniently (elements that fail are skipped).
struct LenientArray<Element: Decodable>: Decodable {
    var items: [Element]

    init(items: [Element]) {
        self.items = items
    }

    init(from decoder: Decoder) throws {
        var container = try decoder.unkeyedContainer()
        items = LenientObject.decodeElements(&container, as: Element.self)
    }
}

/// Parses the date formats FANBOX uses.
/// - ISO-8601 with or without fractional seconds and with `Z` / `+09:00` / `+0900` offsets ("2026-09-01T12:34:56+09:00").
/// - Legacy cursor style "2026-09-01 12:34:56" (no offset ⇒ JST, the FANBOX server time zone).
/// - Date only "2026-09-01" (JST midnight).
/// - Epoch seconds / milliseconds as numbers.
enum FanboxDateParser {
    static let jst = TimeZone(secondsFromGMT: 9 * 3600)!

    private static let regex = try! NSRegularExpression(
        pattern: #"^\s*(\d{4})-(\d{1,2})-(\d{1,2})(?:[T ](\d{1,2}):(\d{2})(?::(\d{2})(?:[.,](\d+))?)?)?\s*(Z|z|[+-]\d{2}(?::?\d{2})?)?\s*$"#
    )

    static func parse(_ string: String) -> Date? {
        let ns = string as NSString
        guard let m = regex.firstMatch(in: string, range: NSRange(location: 0, length: ns.length)) else {
            if let d = Double(string.trimmingCharacters(in: .whitespaces)) { return date(epoch: d) }
            return nil
        }
        func group(_ i: Int) -> String? {
            let r = m.range(at: i)
            return r.location == NSNotFound ? nil : ns.substring(with: r)
        }
        guard let year = group(1).flatMap(Int.init), let month = group(2).flatMap(Int.init), let day = group(3).flatMap(Int.init) else {
            return nil
        }
        var tz = jst
        if let offset = group(8) {
            if offset == "Z" || offset == "z" {
                tz = TimeZone(secondsFromGMT: 0)!
            } else {
                let sign = offset.hasPrefix("-") ? -1 : 1
                let digits = offset.dropFirst().replacingOccurrences(of: ":", with: "")
                let hours = Int(digits.prefix(2)) ?? 0
                let minutes = digits.count >= 4 ? Int(digits.dropFirst(2).prefix(2)) ?? 0 : 0
                guard let zone = TimeZone(secondsFromGMT: sign * (hours * 3600 + minutes * 60)) else { return nil }
                tz = zone
            }
        }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = tz
        var comps = DateComponents()
        comps.year = year
        comps.month = month
        comps.day = day
        comps.hour = group(4).flatMap(Int.init) ?? 0
        comps.minute = group(5).flatMap(Int.init) ?? 0
        comps.second = group(6).flatMap(Int.init) ?? 0
        guard (1...12).contains(month), (1...31).contains(day), let base = calendar.date(from: comps) else { return nil }
        if let fraction = group(7), let value = Double("0." + fraction) {
            return base.addingTimeInterval(value)
        }
        return base
    }

    static func date(epoch value: Double) -> Date? {
        guard value.isFinite, value > 0 else { return nil }
        // Milliseconds when the value is clearly too large for seconds.
        return Date(timeIntervalSince1970: value > 1.0e11 ? value / 1000 : value)
    }

    /// "yyyy-MM" in JST (FANBOX billing months).
    static func monthKey(_ date: Date) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = jst
        let c = calendar.dateComponents([.year, .month], from: date)
        return String(format: "%04d-%02d", c.year ?? 0, c.month ?? 0)
    }
}
