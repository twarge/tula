import ERPNextKit
import SwiftUI

/// One in-progress edit of a document (W3): the mutable draft, the
/// editability rules, and a depends_on evaluator kept in sync with the
/// draft so conditional visibility and read-only rules react live.
///
/// Placed in the SwiftUI environment so the whole form-rendering chain
/// (cards → sections → field rows → child tables) switches to editors
/// without threading bindings through every level. A child-row sheet
/// composes the same way: it wraps its content in its own local session
/// and writes the row back on Done.
@Observable @MainActor
final class EditSession {
    var draft: [String: FrappeValue] {
        didSet { cachedEvaluator = nil }
    }
    let docstatus: Int
    var isSaving = false
    var error: String?
    /// The document changed on the server while editing (TimestampMismatch).
    var conflict = false
    /// Uploads a file for an Attach field, returning its `file_url`
    /// (nil when the gate is locked, e.g. the preview hook).
    var uploadFile: ((String, Data) async throws -> String)?
    /// Called with the fieldname when a Link field's entry settles — a
    /// suggestion picked, Return, or focus leaving the field. For what Desk
    /// does on a link's change rather than on every keystroke (a picked
    /// item's details).
    var linkSettled: ((String) -> Void)?

    private var cachedEvaluator: DependsOnEvaluator?

    /// `docstatus` override: child-row sessions inherit the parent's, since
    /// rows of a fresh draft don't carry one yet.
    init(document: Document, docstatus: Int? = nil) {
        self.draft = document.raw
        self.docstatus = docstatus ?? document.raw["docstatus"]?.intValue ?? 0
    }

    /// Draft-backed evaluator, rebuilt lazily after each mutation so
    /// depends_on / read_only_depends_on follow the edit in progress.
    var evaluator: DependsOnEvaluator {
        if let cachedEvaluator { return cachedEvaluator }
        let evaluator = DependsOnEvaluator(document: Document(raw: draft))
        cachedEvaluator = evaluator
        return evaluator
    }

    func value(_ fieldname: String) -> FrappeValue? {
        draft[fieldname]
    }

    func set(_ fieldname: String, _ value: FrappeValue?) {
        draft[fieldname] = value
    }

    func binding(for fieldname: String) -> Binding<FrappeValue?> {
        Binding(
            get: { self.draft[fieldname] },
            set: { self.draft[fieldname] = $0 })
    }

    /// Desk's field-editability rules, in order: the fieldtype must have an
    /// editor; explicit read_only, elevated permlevel, and set_only_once
    /// lock a field; a submitted document only allows allow_on_submit
    /// fields; cancelled documents are frozen; read_only_depends_on
    /// evaluates against the draft.
    func isEditable(_ field: DocField) -> Bool {
        guard Self.hasEditor(field.fieldtype) else { return false }
        guard !field.readOnly, field.permlevel == 0, !field.setOnlyOnce else { return false }
        guard docstatus < 2 else { return false }
        if docstatus == 1 && !field.allowOnSubmit { return false }
        // Only a field with a rule needs the evaluator. Grid cells ask this
        // of every column on every keystroke, and each draft change costs
        // the evaluator a new JavaScript context.
        if let rule = field.readOnlyDependsOn, evaluator.isTruthy(rule) { return false }
        return true
    }

    /// Mandatory marker: static `reqd` or a triggered mandatory_depends_on.
    func isMandatory(_ field: DocField) -> Bool {
        if field.reqd { return true }
        guard let rule = field.mandatoryDependsOn else { return false }
        return evaluator.isTruthy(rule)
    }

    static func hasEditor(_ fieldtype: FieldType) -> Bool {
        switch fieldtype {
        case .data, .phone, .autocomplete, .int, .float, .currency, .percent,
            .check, .select, .link, .dynamicLink, .date, .datetime, .time,
            .smallText, .text, .longText, .code, .json, .markdown, .textEditor,
            .htmlEditor, .attach, .attachImage, .tableMultiSelect:
            return true
        default:
            return false
        }
    }

    // MARK: Child tables

    /// The draft's rows for a child table, in order.
    func rows(of tableFieldname: String) -> [[String: FrappeValue]] {
        (draft[tableFieldname]?.arrayValue ?? []).map { $0.objectValue ?? [:] }
    }

    func setRow(_ row: [String: FrappeValue], at index: Int, in tableFieldname: String) {
        var tableRows = draft[tableFieldname]?.arrayValue ?? []
        if tableRows.indices.contains(index) {
            tableRows[index] = .object(row)
        } else {
            tableRows.append(.object(row))
        }
        draft[tableFieldname] = .array(tableRows)
    }

    /// Appends a blank row and returns its index. The row carries only its
    /// DocType: everything else stays unset, for the server's own defaults
    /// to fill on save (and a picked item's details sooner, `ItemDetails`).
    @discardableResult
    func appendRow(to tableFieldname: String, doctype: String) -> Int {
        var tableRows = draft[tableFieldname]?.arrayValue ?? []
        tableRows.append(.object(["doctype": .string(doctype)]))
        draft[tableFieldname] = .array(tableRows)
        return tableRows.count - 1
    }

    func removeRow(at index: Int, from tableFieldname: String) {
        var tableRows = draft[tableFieldname]?.arrayValue ?? []
        guard tableRows.indices.contains(index) else { return }
        tableRows.remove(at: index)
        draft[tableFieldname] = .array(tableRows)
    }

    /// Whether rows may be added to or removed from a table — Desk's rule
    /// for an editable grid: the table itself is writable, and on a
    /// submitted document it must be `allow_on_submit`. (Cells of existing
    /// rows follow their own fields' rules through `rowSession`.)
    func allowsRowChanges(in table: DocField) -> Bool {
        guard !table.readOnly, table.permlevel == 0, docstatus < 2 else { return false }
        if docstatus == 1 && !table.allowOnSubmit { return false }
        if let rule = table.readOnlyDependsOn, evaluator.isTruthy(rule) { return false }
        return true
    }

    /// A session over one row of this document, for the row's own
    /// editability rules and depends_on evaluation. A row the server has
    /// already saved shares the document's docstatus; one added in this
    /// edit is a draft whatever its parent is, as in Desk.
    func rowSession(for row: [String: FrappeValue]) -> EditSession {
        let isSaved = row["name"]?.nonEmptyString != nil
        let session = EditSession(
            document: Document(raw: row), docstatus: isSaved ? docstatus : 0)
        session.uploadFile = uploadFile
        return session
    }

    /// Whether any field of the DocType could be edited at this docstatus —
    /// drives the Edit entry point.
    static func isEditable(meta: DocTypeMeta, docstatus: Int) -> Bool {
        guard docstatus < 2 else { return false }
        return meta.fields.contains { field in
            hasEditor(field.fieldtype) && !field.readOnly && field.permlevel == 0
                && !field.setOnlyOnce && (docstatus == 0 || field.allowOnSubmit)
        }
    }
}

extension EnvironmentValues {
    /// Non-nil while the enclosing document screen is in an edit session.
    @Entry var editSession: EditSession?
    /// The form's scroll view, for content that grows while it is being
    /// edited (a grid cell's suggestions) and has to bring itself into view.
    @Entry var formScroll: ScrollViewProxy?
}
