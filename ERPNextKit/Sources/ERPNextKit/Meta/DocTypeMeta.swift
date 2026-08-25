import Foundation

/// One field definition from a DocType's metadata.
///
/// Wraps the raw metadata dictionary rather than decoding a fixed schema:
/// Frappe versions and server customizations add keys freely, and unknown
/// keys must never break decoding. Typed accessors cover what the renderer
/// needs; everything else stays available via `raw`.
public struct DocField: Sendable, Hashable, Identifiable {
    public let raw: [String: FrappeValue]

    public init(raw: [String: FrappeValue]) {
        self.raw = raw
    }

    public var id: String { fieldname.isEmpty ? (label + fieldtype.rawValue) : fieldname }

    public var fieldname: String { raw["fieldname"]?.nonEmptyString ?? "" }

    public var label: String {
        raw["label"]?.nonEmptyString
            ?? fieldname.replacingOccurrences(of: "_", with: " ").capitalized
    }

    public var fieldtype: FieldType {
        FieldType(rawValue: raw["fieldtype"]?.nonEmptyString ?? "Data")
    }

    /// Meaning depends on fieldtype: Link → target DocType, Select → newline-
    /// separated choices, Table → child DocType, Currency → sibling field
    /// holding the currency code, Dynamic Link → sibling field holding the
    /// target DocType.
    public var options: String? { raw["options"]?.nonEmptyString }

    public var hidden: Bool { raw["hidden"]?.boolValue ?? false }
    public var bold: Bool { raw["bold"]?.boolValue ?? false }
    public var inListView: Bool { raw["in_list_view"]?.boolValue ?? false }
    public var collapsible: Bool { raw["collapsible"]?.boolValue ?? false }
    public var precision: Int? { raw["precision"]?.intValue }

    public var selectChoices: [String] {
        guard fieldtype == .select, let options else { return [] }
        return options.split(separator: "\n").map(String.init).filter { !$0.isEmpty }
    }
}

/// A DocType's metadata: the schema that drives every generic renderer.
public struct DocTypeMeta: Sendable, Hashable {
    public let raw: [String: FrappeValue]
    public let fields: [DocField]

    public init(raw: [String: FrappeValue]) {
        self.raw = raw
        self.fields =
            raw["fields"]?.arrayValue?.compactMap { value in
                value.objectValue.map(DocField.init(raw:))
            } ?? []
    }

    public var name: String { raw["name"]?.nonEmptyString ?? "" }
    public var isTable: Bool { raw["istable"]?.boolValue ?? false }
    public var isSingle: Bool { raw["issingle"]?.boolValue ?? false }
    public var titleField: String? { raw["title_field"]?.nonEmptyString }

    public func field(named fieldname: String) -> DocField? {
        fields.first { $0.fieldname == fieldname }
    }

    /// Columns for the generic list view, in metadata order.
    public var listFields: [DocField] {
        fields.filter { $0.inListView && !$0.hidden && $0.fieldtype.isPresentable }
    }

    /// Fields whose values should be requested from the list endpoint.
    public var listFieldnames: [String] {
        var names = ["name"]
        if let titleField, !names.contains(titleField) { names.append(titleField) }
        for field in listFields where !names.contains(field.fieldname) {
            names.append(field.fieldname)
        }
        return names
    }
}

/// Decodes metadata API responses into DocType bundles.
public enum MetaDecoder {
    /// `frappe.desk.form.load.getdoctype` returns the requested DocType plus
    /// the DocTypes of all its child tables in one `docs` array.
    public static func bundle(from data: Data) throws -> [DocTypeMeta] {
        guard let root = try FrappeValue.decode(from: data).objectValue else {
            throw ERPNextError(message: "Malformed metadata response")
        }
        let docs =
            root["docs"]?.arrayValue
            ?? root["message"]?.objectValue?["docs"]?.arrayValue
            ?? (root["data"]?.objectValue).map { [FrappeValue.object($0)] }
        guard let docs, !docs.isEmpty else {
            throw ERPNextError(message: "Metadata response contained no DocTypes")
        }
        return docs.compactMap { $0.objectValue.map(DocTypeMeta.init(raw:)) }
            .filter { !$0.name.isEmpty }
    }
}
