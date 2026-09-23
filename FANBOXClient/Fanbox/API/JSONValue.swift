import Foundation

/// Untyped JSON value used for tolerant decoding (SPEC §37: unknown fields must never break decoding),
/// JSON request bodies and API Inspector input. Numbers are stored as `Double`; identifiers that FANBOX
/// sometimes sends as numbers are read back through `stringValue` without a trailing ".0".
enum JSONValue: Sendable, Hashable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    // MARK: Accessors

    subscript(key: String) -> JSONValue? {
        if case .object(let dict) = self { return dict[key] }
        return nil
    }

    subscript(index: Int) -> JSONValue? {
        if case .array(let items) = self, items.indices.contains(index) { return items[index] }
        return nil
    }

    var isNull: Bool {
        if case .null = self { return true }
        return false
    }

    var objectValue: [String: JSONValue]? {
        if case .object(let dict) = self { return dict }
        return nil
    }

    var arrayValue: [JSONValue]? {
        if case .array(let items) = self { return items }
        return nil
    }

    /// Strings as-is; integral numbers without a fraction ("123" not "123.0"); bools as "true"/"false".
    var stringValue: String? {
        switch self {
        case .string(let s): return s
        case .number(let n): return JSONValue.format(number: n)
        case .bool(let b): return b ? "true" : "false"
        default: return nil
        }
    }

    /// Numbers (truncated) and numeric strings.
    var intValue: Int? {
        switch self {
        case .number(let n):
            guard n.isFinite, abs(n) < 9.0e18 else { return nil }
            return Int(n)
        case .string(let s): return JSONValue.parseInt(s)
        case .bool(let b): return b ? 1 : 0
        default: return nil
        }
    }

    var boolValue: Bool? {
        switch self {
        case .bool(let b): return b
        case .number(let n): return n != 0
        case .string(let s): return JSONValue.parseBool(s)
        default: return nil
        }
    }

    // MARK: Serialization

    /// Parses arbitrary JSON (object, array or scalar at the top level).
    static func parse(_ data: Data) throws -> JSONValue {
        try JSONDecoder().decode(JSONValue.self, from: data)
    }

    /// Compact JSON. Keys are sorted so request bodies are deterministic (tests, Research Mode diffs).
    func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(self)
    }

    // MARK: Lenient scalar parsing shared with DTO decoding

    static func format(number n: Double) -> String {
        if n.isFinite, n.rounded() == n, abs(n) < 9.0e15 {
            return String(Int64(n))
        }
        return String(n)
    }

    static func parseInt(_ raw: String) -> Int? {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: ",", with: "")
        if s.isEmpty { return nil }
        if let i = Int(s) { return i }
        if let d = Double(s), d.isFinite, abs(d) < 9.0e18 { return Int(d) }
        return nil
    }

    static func parseBool(_ raw: String) -> Bool? {
        switch raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "true", "1", "yes": return true
        case "false", "0", "no", "": return false
        default: return nil
        }
    }
}

extension JSONValue: Codable {
    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let b = try? container.decode(Bool.self) {
            self = .bool(b)
        } else if let n = try? container.decode(Double.self) {
            self = .number(n)
        } else if let s = try? container.decode(String.self) {
            self = .string(s)
        } else if let a = try? container.decode([JSONValue].self) {
            self = .array(a)
        } else if let o = try? container.decode([String: JSONValue].self) {
            self = .object(o)
        } else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unsupported JSON value")
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case .bool(let b): try container.encode(b)
        case .number(let n):
            if n.isFinite, n.rounded() == n, abs(n) < 9.0e15 {
                try container.encode(Int64(n))
            } else {
                try container.encode(n)
            }
        case .string(let s): try container.encode(s)
        case .array(let a): try container.encode(a)
        case .object(let o): try container.encode(o)
        }
    }
}

extension JSONValue: ExpressibleByStringLiteral, ExpressibleByIntegerLiteral, ExpressibleByBooleanLiteral,
    ExpressibleByArrayLiteral, ExpressibleByDictionaryLiteral, ExpressibleByNilLiteral, ExpressibleByFloatLiteral {
    init(stringLiteral value: String) { self = .string(value) }
    init(integerLiteral value: Int) { self = .number(Double(value)) }
    init(floatLiteral value: Double) { self = .number(value) }
    init(booleanLiteral value: Bool) { self = .bool(value) }
    init(arrayLiteral elements: JSONValue...) { self = .array(elements) }
    init(dictionaryLiteral elements: (String, JSONValue)...) {
        var dict: [String: JSONValue] = [:]
        for (k, v) in elements { dict[k] = v }
        self = .object(dict)
    }
    init(nilLiteral: ()) { self = .null }
}
