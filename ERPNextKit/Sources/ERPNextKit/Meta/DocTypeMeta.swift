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
    /// Desk shows these fields as its sidebar "Filter By" quick filters.
    public var inStandardFilter: Bool { raw["in_standard_filter"]?.boolValue ?? false }
    /// Visibility rule evaluated against the document (`DependsOnEvaluator`):
    /// either a bare fieldname (truthiness) or `eval:<js expression>`.
    public var dependsOn: String? { raw["depends_on"]?.nonEmptyString }
    public var collapsible: Bool { raw["collapsible"]?.boolValue ?? false }
    public var precision: Int? { raw["precision"]?.intValue }

    public var selectChoices: [String] {
        guard fieldtype == .select, let options else { return [] }
        return options.split(separator: "\n").map(String.init).filter { !$0.isEmpty }
    }

    /// Desk's barcode-scanner input convention (a Data field with
    /// `options: Barcode`, e.g. `scan_barcode`). Rendered as an inert
    /// affordance in a read-only client.
    public var isScanBarcodeField: Bool {
        fieldtype == .data && (options == "Barcode" || fieldname.contains("scan_barcode"))
    }
}

/// One entry of a DocType's Connections tab (`links` in the metadata).
public struct DocTypeLink: Sendable, Hashable {
    public let doctype: String
    public let fieldname: String
    public let group: String?
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
    /// Nested-set tree DocType (Account, Cost Center, Item Group, …).
    public var isTree: Bool { raw["is_tree"]?.boolValue ?? false }
    /// Submittable documents carry docstatus (draft/submitted/cancelled).
    public var isSubmittable: Bool { raw["is_submittable"]?.boolValue ?? false }

    /// Desk's Connections tab: DocTypes linking back to this one.
    public var connectionLinks: [DocTypeLink] {
        raw["links"]?.arrayValue?.compactMap { entry in
            guard let dict = entry.objectValue,
                let doctype = dict["link_doctype"]?.nonEmptyString,
                let fieldname = dict["link_fieldname"]?.nonEmptyString,
                dict["hidden"]?.boolValue != true
            else { return nil }
            return DocTypeLink(
                doctype: doctype, fieldname: fieldname,
                group: dict["group"]?.nonEmptyString)
        } ?? []
    }

    /// Desk's form-dashboard blueprint, when the server ships one.
    public var dashboard: DashboardSpec? {
        DashboardSpec(raw: raw["__dashboard"])
    }

    /// Default list sort. `sort_field` occasionally carries a comma list
    /// ("posting_date, creation"); the first component is the primary sort.
    public var sortField: String {
        raw["sort_field"]?.nonEmptyString?
            .split(separator: ",").first
            .map { $0.trimmingCharacters(in: .whitespaces) } ?? "modified"
    }

    public var sortDescending: Bool {
        (raw["sort_order"]?.nonEmptyString ?? "DESC").uppercased() != "ASC"
    }

    public func field(named fieldname: String) -> DocField? {
        fields.first { $0.fieldname == fieldname }
    }

    /// Columns for the generic list view, in metadata order.
    public var listFields: [DocField] {
        fields.filter { $0.inListView && !$0.hidden && $0.fieldtype.isPresentable }
    }

    /// Quick-filter candidates, in metadata order — the same fields Desk
    /// offers in its list sidebar (ARCHITECTURE.md §10).
    public var standardFilterFields: [DocField] {
        fields.filter { $0.inStandardFilter && !$0.hidden && $0.fieldtype.isPresentable }
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

/// One column of a Desk child-table grid configuration.
public struct GridColumn: Sendable, Hashable {
    public var fieldname: String
    /// Desk grid width units (out of ~10). Informational — native grids size
    /// columns to content.
    public var columns: Int?

    public init(fieldname: String, columns: Int? = nil) {
        self.fieldname = fieldname
        self.columns = columns
    }
}

/// A DocType's metadata plus its child DocTypes and the requesting user's
/// Desk view preferences that ride along in the same response.
public struct MetaBundle: Sendable {
    public var metas: [DocTypeMeta]
    /// Child DocType → the user's configured grid columns (Desk's per-user
    /// "GridView" settings, saved from the grid's gear in the web UI).
    public var gridColumns: [String: [GridColumn]]
    /// The user's saved list sort from Desk (user settings "List" section).
    public var listSortBy: String?
    public var listSortDescending: Bool?

    public init(
        metas: [DocTypeMeta], gridColumns: [String: [GridColumn]] = [:],
        listSortBy: String? = nil, listSortDescending: Bool? = nil
    ) {
        self.metas = metas
        self.gridColumns = gridColumns
        self.listSortBy = listSortBy
        self.listSortDescending = listSortDescending
    }
}

/// Decodes metadata API responses into DocType bundles.
public enum MetaDecoder {
    /// `frappe.desk.form.load.getdoctype` returns the requested DocType plus
    /// the DocTypes of all its child tables in one `docs` array, and the
    /// user's per-DocType view settings as a JSON string in `user_settings`.
    public static func bundle(from data: Data) throws -> MetaBundle {
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
        let metas = docs.compactMap { $0.objectValue.map(DocTypeMeta.init(raw:)) }
            .filter { !$0.name.isEmpty }

        var gridColumns: [String: [GridColumn]] = [:]
        var listSortBy: String?
        var listSortDescending: Bool?
        let settingsRaw =
            root["user_settings"]?.nonEmptyString
            ?? root["message"]?.objectValue?["user_settings"]?.nonEmptyString
        if let settingsRaw,
            let settings = try? FrappeValue.decode(from: Data(settingsRaw.utf8)).objectValue {
            if let gridView = settings["GridView"]?.objectValue {
                for (childDoctype, value) in gridView {
                    let columns = (value.arrayValue ?? []).compactMap { entry -> GridColumn? in
                        guard let fieldname = entry.objectValue?["fieldname"]?.nonEmptyString
                        else { return nil }
                        return GridColumn(
                            fieldname: fieldname,
                            columns: entry.objectValue?["columns"]?.intValue)
                    }
                    if !columns.isEmpty { gridColumns[childDoctype] = columns }
                }
            }
            if let list = settings["List"]?.objectValue {
                // sort_by is occasionally table-qualified (`tabX`.`field`).
                if let sortBy = list["sort_by"]?.nonEmptyString {
                    listSortBy = sortBy.split(separator: ".").last
                        .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "` ")) }
                }
                if let order = list["sort_order"]?.nonEmptyString {
                    listSortDescending = order.uppercased() != "ASC"
                }
            }
        }

        return MetaBundle(
            metas: metas, gridColumns: gridColumns,
            listSortBy: listSortBy, listSortDescending: listSortDescending)
    }
}

/// The `__dashboard` object riding in the getdoctype response: Desk's
/// form-dashboard blueprint. It merges the module's `*_dashboard.py` data
/// with the DocType's links table — grouped linked DocTypes plus the
/// fieldname conventions needed to filter each linked list correctly.
public struct DashboardSpec: Sendable, Hashable {
    public struct Group: Sendable, Hashable {
        public var label: String
        public var doctypes: [String]
    }

    /// Default fieldname on linked DocTypes that refers back to this one.
    public var fieldname: String?
    /// Per-DocType overrides (e.g. Payment Entry links via `party`).
    public var nonStandardFieldnames: [String: String]
    /// fieldname → [doctype value, type fieldname]: a link through this
    /// fieldname also needs `<type fieldname> = <doctype value>` (party_type).
    public var dynamicLinks: [String: [String]]
    /// DocTypes referenced *by* this document; the value is the field path
    /// on the document ([child table field, link field] or [link field]).
    public var internalLinks: [String: [String]]
    public var transactions: [Group]

    init?(raw: FrappeValue?) {
        guard let dict = raw?.objectValue else { return nil }
        fieldname = dict["fieldname"]?.nonEmptyString
        nonStandardFieldnames = (dict["non_standard_fieldnames"]?.objectValue ?? [:])
            .compactMapValues(\.nonEmptyString)
        dynamicLinks = (dict["dynamic_links"]?.objectValue ?? [:]).compactMapValues {
            $0.arrayValue?.compactMap(\.nonEmptyString)
        }
        internalLinks = (dict["internal_links"]?.objectValue ?? [:]).compactMapValues { value in
            if let path = value.arrayValue?.compactMap(\.nonEmptyString), !path.isEmpty {
                return path
            }
            return value.nonEmptyString.map { [$0] }
        }
        transactions = (dict["transactions"]?.arrayValue ?? []).compactMap { entry in
            guard let dict = entry.objectValue else { return nil }
            let doctypes = (dict["items"]?.arrayValue ?? []).compactMap(\.nonEmptyString)
            guard !doctypes.isEmpty else { return nil }
            return Group(label: dict["label"]?.nonEmptyString ?? "", doctypes: doctypes)
        }
        if transactions.isEmpty { return nil }
    }

    /// Equality filters selecting documents of `linkedDoctype` that refer to
    /// this document, or nil for internal links (whose names live on the
    /// document itself).
    public func filters(linking linkedDoctype: String, to name: String) -> [String: String]? {
        guard internalLinks[linkedDoctype] == nil else { return nil }
        guard let field = nonStandardFieldnames[linkedDoctype] ?? fieldname else { return nil }
        var filters = [field: name]
        if let dynamic = dynamicLinks[field], dynamic.count >= 2 {
            filters[dynamic[1]] = dynamic[0]
        }
        return filters
    }
}
