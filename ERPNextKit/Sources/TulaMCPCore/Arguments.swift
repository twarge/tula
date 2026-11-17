import ERPNextKit
import Foundation

/// A failure the model should read and act on: a missing argument, a
/// malformed filter, a result too large to send.
public struct ToolError: Error, LocalizedError, Sendable {
    public var message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}

/// The arguments of one tool call, read tolerantly: models send "20" for 20
/// and a JSON string where an object was asked for often enough to allow it.
struct Arguments: Sendable {
    var values: [String: JSON]

    func string(_ key: String) -> String? {
        values[key]?.nonEmptyString?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func required(_ key: String) throws -> String {
        guard let value = string(key), !value.isEmpty else {
            throw ToolError("Missing required argument \"\(key)\".")
        }
        return value
    }

    func int(_ key: String, default fallback: Int, in range: ClosedRange<Int>) -> Int {
        min(max(values[key]?.intValue ?? fallback, range.lowerBound), range.upperBound)
    }

    func strings(_ key: String) -> [String] {
        if let array = structured(key)?.arrayValue {
            return array.compactMap(\.nonEmptyString)
        }
        return string(key).map { $0.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) } } ?? []
    }

    /// An object or array argument, also accepted as its JSON text.
    func structured(_ key: String) -> JSON? {
        guard let value = values[key], !value.isNull else { return nil }
        if case .string(let text) = value {
            return try? JSON.decode(from: Data(text.utf8))
        }
        return value
    }

    /// Frappe list filters. Accepts the wire form — `[[field, op, value]]`,
    /// or with the DocType leading each triple — and the shorthand object
    /// `{field: value}` / `{field: [op, value]}`.
    func filters(_ key: String = "filters") throws -> [ListFilter] {
        guard let value = values[key], !value.isNull else { return [] }
        guard let parsed = structured(key) else {
            throw ToolError("\"\(key)\" isn't valid JSON.")
        }
        if let object = parsed.objectValue {
            return object.sorted { $0.key < $1.key }.map { field, condition in
                if let pair = condition.arrayValue, pair.count == 2,
                    let op = pair[0].stringValue, Self.operators.contains(op.lowercased()) {
                    return ListFilter(field, op, pair[1])
                }
                return ListFilter(field, "=", condition)
            }
        }
        guard let rows = parsed.arrayValue else {
            throw ToolError("\"\(key)\" must be a list of [field, operator, value] conditions.")
        }
        // A single bare triple, not wrapped in a list.
        if (3...4).contains(rows.count), rows.allSatisfy({ $0.arrayValue == nil }),
            rows[rows.count - 2].stringValue.map({ Self.operators.contains($0.lowercased()) }) == true {
            return [try Self.filter(from: rows)]
        }
        return try rows.map { row in
            guard let parts = row.arrayValue else {
                throw ToolError("Each filter must be [field, operator, value]; got \(MCPServer.encode(row)).")
            }
            return try Self.filter(from: parts)
        }
    }

    private static func filter(from parts: [JSON]) throws -> ListFilter {
        // [doctype, field, op, value]: the DocType is implied by the call.
        let triple = parts.count == 4 ? Array(parts.dropFirst()) : parts
        guard triple.count == 3, let field = triple[0].nonEmptyString,
            let op = triple[1].nonEmptyString
        else {
            throw ToolError(
                "Each filter must be [field, operator, value]; got \(MCPServer.encode(.array(parts))).")
        }
        guard operators.contains(op.lowercased()) else {
            throw ToolError(
                "Unknown filter operator \"\(op)\". Use one of: \(operators.sorted().joined(separator: ", ")).")
        }
        return ListFilter(field, op, triple[2])
    }

    static let operators: Set<String> = [
        "=", "!=", ">", "<", ">=", "<=", "like", "not like", "in", "not in", "between", "is",
        "descendants of", "ancestors of", "not descendants of", "not ancestors of", "timespan",
    ]
}

extension JSON {
    /// Drops what Frappe pads every document with — nulls and empty strings
    /// — so a document costs the model only what it actually says.
    var compacted: JSON {
        switch self {
        case .object(let object):
            return .object(
                object.compactMapValues { value in
                    if value.isNull { return nil }
                    if case .string(let text) = value, text.isEmpty { return nil }
                    return value.compacted
                })
        case .array(let array):
            return .array(array.map(\.compacted))
        default:
            return self
        }
    }
}
