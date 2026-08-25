import Foundation

/// A Frappe document (or list row): a keyed bag of `FrappeValue`s.
public struct Document: Sendable, Hashable, Identifiable {
    public let raw: [String: FrappeValue]

    public init(raw: [String: FrappeValue]) {
        self.raw = raw
    }

    public var id: String { name }
    public var name: String { raw["name"]?.stringValue ?? "" }

    public subscript(fieldname: String) -> FrappeValue? {
        let value = raw[fieldname]
        if case .null = value { return nil }
        return value
    }

    /// Rows of a child table field.
    public func childRows(for field: DocField) -> [Document] {
        raw[field.fieldname]?.arrayValue?
            .compactMap { $0.objectValue.map(Document.init(raw:)) } ?? []
    }

    public func title(using meta: DocTypeMeta?) -> String {
        if let titleField = meta?.titleField,
            let title = raw[titleField]?.nonEmptyString {
            return title
        }
        return name
    }

    /// Decode `{"data": [...]}` list responses.
    public static func list(from data: Data) throws -> [Document] {
        guard let root = try FrappeValue.decode(from: data).objectValue,
            let rows = root["data"]?.arrayValue ?? root["message"]?.arrayValue
        else {
            throw ERPNextError(message: "Malformed list response")
        }
        return rows.compactMap { $0.objectValue.map(Document.init(raw:)) }
    }

    /// Decode `{"data": {...}}` single-document responses.
    public static func single(from data: Data) throws -> Document {
        guard let root = try FrappeValue.decode(from: data).objectValue,
            let doc = root["data"]?.objectValue ?? root["message"]?.objectValue
        else {
            throw ERPNextError(message: "Malformed document response")
        }
        return Document(raw: doc)
    }
}
