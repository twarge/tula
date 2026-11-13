import Foundation

// Desk's conventions for child-table rows that are pure data — shared by the
// row sheet, the inline grid editor, and the save path.

extension FrappeValue {
    /// JavaScript truthiness — the test Desk applies when it asks whether a
    /// grid cell holds anything (null, "", 0 and false are empty; "0" is not).
    public var isTruthy: Bool {
        switch self {
        case .null: return false
        case .string(let value): return !value.isEmpty
        case .int(let value): return value != 0
        case .double(let value): return value != 0 && !value.isNaN
        case .bool(let value): return value
        case .array, .object: return true
        }
    }
}

extension DocTypeMeta {
    /// Whether this child DocType carries the `amount = qty × rate` trio.
    public var hasRowAmountConvention: Bool {
        field(named: "qty") != nil && field(named: "rate") != nil
            && field(named: "amount") != nil
    }

    /// The row amount convention — with `ItemDetails.lineRate`, all the
    /// client-side math there is (ARCHITECTURE §12). Taxes and totals come
    /// back from the server on save. A row missing either factor is returned
    /// untouched.
    public func settingRowAmount(in row: [String: FrappeValue]) -> [String: FrappeValue] {
        guard hasRowAmountConvention,
            let qty = row["qty"]?.doubleValue, let rate = row["rate"]?.doubleValue
        else { return row }
        var row = row
        row["amount"] = .double(qty * rate)
        return row
    }

    /// Whether a row is empty the way Desk's `remove_empty_rows` means it:
    /// every `in_list_view` field is falsy, because that is what a person
    /// looking at the grid would call an empty line. Never true for a child
    /// DocType with no list-view fields — there the rule has nothing to go
    /// on, and dropping every row would be wrong.
    public func isEmptyRow(_ row: [String: FrappeValue]) -> Bool {
        let cells = fields.filter(\.inListView)
        guard !cells.isEmpty else { return false }
        return !cells.contains { row[$0.fieldname]?.isTruthy == true }
    }

    /// A copy of a document draft without its empty child rows — what Desk
    /// does at the top of every save, so a line added and left blank (the
    /// one Tab opens after the last cell, say) never reaches the server to
    /// fail its mandatory checks. `self` is the parent DocType.
    public func removingEmptyRows(
        from raw: [String: FrappeValue], childMetas: [String: DocTypeMeta]
    ) -> [String: FrappeValue] {
        var raw = raw
        for table in fields
        where table.fieldtype == .table || table.fieldtype == .tableMultiSelect {
            guard let childMeta = table.options.flatMap({ childMetas[$0] }),
                let rows = raw[table.fieldname]?.arrayValue
            else { continue }
            let kept = rows.filter { row in
                guard let row = row.objectValue else { return true }
                return !childMeta.isEmptyRow(row)
            }
            if kept.count != rows.count {
                raw[table.fieldname] = .array(kept)
            }
        }
        return raw
    }
}
