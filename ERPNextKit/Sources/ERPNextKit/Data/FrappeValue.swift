import Foundation

/// A dynamically-typed JSON value as returned by the Frappe API.
///
/// Frappe payloads are heterogeneous: report rows are dictionaries whose value
/// types depend on server-side metadata, booleans arrive as 0/1 integers, and
/// numbers may be ints or floats depending on the record. `FrappeValue` is the
/// lossless wire representation; typed accessors perform the tolerant coercions
/// the Desk UI itself applies.
public enum FrappeValue: Sendable, Hashable {
    case string(String)
    case int(Int)
    case double(Double)
    case bool(Bool)
    case array([FrappeValue])
    case object([String: FrappeValue])
    case null
}

extension FrappeValue: Codable {
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Int.self) {
            self = .int(value)
        } else if let value = try? container.decode(Double.self) {
            self = .double(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([FrappeValue].self) {
            self = .array(value)
        } else if let value = try? container.decode([String: FrappeValue].self) {
            self = .object(value)
        } else {
            throw DecodingError.dataCorruptedError(
                in: container, debugDescription: "Unsupported JSON value")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value): try container.encode(value)
        case .int(let value): try container.encode(value)
        case .double(let value): try container.encode(value)
        case .bool(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        case .null: try container.encodeNil()
        }
    }
}

extension FrappeValue {
    public var isNull: Bool {
        if case .null = self { return true }
        return false
    }

    public var stringValue: String? {
        switch self {
        case .string(let value): return value
        case .int(let value): return String(value)
        case .double(let value): return String(value)
        case .bool(let value): return value ? "1" : "0"
        default: return nil
        }
    }

    /// A non-empty string, or nil. Frappe uses "" and null interchangeably.
    public var nonEmptyString: String? {
        guard let value = stringValue, !value.isEmpty else { return nil }
        return value
    }

    public var intValue: Int? {
        switch self {
        case .int(let value): return value
        case .double(let value): return Int(value)
        case .bool(let value): return value ? 1 : 0
        case .string(let value): return Int(value)
        default: return nil
        }
    }

    public var doubleValue: Double? {
        switch self {
        case .int(let value): return Double(value)
        case .double(let value): return value
        case .string(let value): return Double(value)
        case .bool(let value): return value ? 1 : 0
        default: return nil
        }
    }

    /// Frappe booleans are 0/1 ints; "1"/"true" strings also appear.
    public var boolValue: Bool? {
        switch self {
        case .bool(let value): return value
        case .int(let value): return value != 0
        case .double(let value): return value != 0
        case .string(let value):
            switch value.lowercased() {
            case "1", "true", "yes": return true
            case "0", "false", "no", "": return false
            default: return nil
            }
        default: return nil
        }
    }

    public var arrayValue: [FrappeValue]? {
        if case .array(let value) = self { return value }
        return nil
    }

    public var objectValue: [String: FrappeValue]? {
        if case .object(let value) = self { return value }
        return nil
    }
}

extension FrappeValue {
    public static func decode(from data: Data) throws -> FrappeValue {
        try JSONDecoder().decode(FrappeValue.self, from: data)
    }

    public func encodedJSONString() throws -> String {
        let data = try JSONEncoder().encode(self)
        return String(decoding: data, as: UTF8.self)
    }
}
