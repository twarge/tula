import Foundation

/// A report grid's sort, set from a column header or the filter
/// inspector: one column, either direction. No sort is the report's own
/// order.
public struct ReportSort: Sendable, Hashable {
    public var fieldname: String
    public var ascending: Bool

    public init(fieldname: String, ascending: Bool = true) {
        self.fieldname = fieldname
        self.ascending = ascending
    }

    /// A header click: a new column sorts ascending, the sorted column
    /// flips to descending, and a third click returns to report order.
    public static func next(after sort: ReportSort?, column: String) -> ReportSort? {
        guard let sort, sort.fieldname == column else { return ReportSort(fieldname: column) }
        return sort.ascending ? ReportSort(fieldname: column, ascending: false) : nil
    }
}

extension ReportRow {
    /// Rows that hold their place through a sort: spacers and the quoted
    /// pseudo-rows ('Opening', 'Total', 'Closing (Opening + Total)', a
    /// statement's totals). They split the rows into sections, and each
    /// section sorts on its own.
    var holdsPlaceInSort: Bool {
        isBlank || values.values.contains { $0.nonEmptyString?.isQuotedTotalLabel == true }
    }
}

extension ReportResult {
    /// The rows reordered by `sort`, keeping the report's structure: rows
    /// that hold their place (`holdsPlaceInSort`) stay put, and tree rows
    /// (`indent`) sort among their siblings, each carrying its subtree, so
    /// a statement's account tree survives. Empty values sort last in
    /// either direction. Unchanged when `sort` is nil or names no column.
    public func sorted(by sort: ReportSort?) -> ReportResult {
        guard let sort, let column = columns.first(where: { $0.fieldname == sort.fieldname })
        else { return self }
        var sorted: [ReportRow] = []
        sorted.reserveCapacity(rows.count)
        var section: [ReportRow] = []
        for row in rows {
            if row.holdsPlaceInSort {
                sorted += Self.sortedTree(section, column: column, ascending: sort.ascending)
                section.removeAll()
                sorted.append(row)
            } else {
                section.append(row)
            }
        }
        sorted += Self.sortedTree(section, column: column, ascending: sort.ascending)
        var result = self
        result.rows = sorted
        return result
    }

    private struct Node {
        var row: ReportRow
        var children: [Node]
    }

    private static func sortedTree(
        _ rows: [ReportRow], column: ReportColumn, ascending: Bool
    ) -> [ReportRow] {
        guard rows.count > 1 else { return rows }
        var index = 0
        let forest = parse(rows, &index, deeperThan: Int.min)
        var flattened: [ReportRow] = []
        flattened.reserveCapacity(rows.count)
        flatten(order(forest, column: column, ascending: ascending), into: &flattened)
        return flattened
    }

    /// The rows from `index` nested deeper than `indent`, each with the
    /// deeper rows that follow it as children.
    private static func parse(_ rows: [ReportRow], _ index: inout Int, deeperThan indent: Int)
        -> [Node] {
        var nodes: [Node] = []
        while index < rows.count, rows[index].indent > indent {
            let row = rows[index]
            index += 1
            nodes.append(Node(row: row, children: parse(rows, &index, deeperThan: row.indent)))
        }
        return nodes
    }

    private static func order(_ nodes: [Node], column: ReportColumn, ascending: Bool) -> [Node] {
        let keyed = nodes.enumerated().map { offset, node in
            var node = node
            node.children = order(node.children, column: column, ascending: ascending)
            return (offset: offset, node: node, key: SortKey(node.row[column], column: column))
        }
        return keyed.sorted { lhs, rhs in
            switch SortKey.compare(lhs.key, rhs.key, ascending: ascending) {
            case .orderedAscending: return true
            case .orderedDescending: return false
            case .orderedSame: return lhs.offset < rhs.offset
            }
        }
        .map(\.node)
    }

    private static func flatten(_ nodes: [Node], into rows: inout [ReportRow]) {
        for node in nodes {
            rows.append(node.row)
            flatten(node.children, into: &rows)
        }
    }
}

/// A cell's sort value: numbers by value for numeric columns, everything
/// else as text in Finder order (digits by value, case-insensitive) —
/// ISO dates sort by date that way too.
private enum SortKey {
    case number(Double)
    case text(String)
    case empty

    init(_ value: FrappeValue?, column: ReportColumn) {
        guard let value, let string = value.nonEmptyString else {
            self = .empty
            return
        }
        if column.fieldtype.isNumeric, let number = value.doubleValue {
            self = .number(number)
        } else {
            self = .text(string.strippingTotalQuotes)
        }
    }

    static func compare(_ lhs: SortKey, _ rhs: SortKey, ascending: Bool) -> ComparisonResult {
        let result: ComparisonResult
        switch (lhs, rhs) {
        case (.empty, .empty): return .orderedSame
        case (.empty, _): return .orderedDescending
        case (_, .empty): return .orderedAscending
        case (.number(let a), .number(let b)):
            result = a < b ? .orderedAscending : a > b ? .orderedDescending : .orderedSame
        case (.text(let a), .text(let b)):
            result = a.localizedStandardCompare(b)
        // A numeric column with a stray text cell: numbers first.
        case (.number, .text): result = .orderedAscending
        case (.text, .number): result = .orderedDescending
        }
        guard !ascending else { return result }
        switch result {
        case .orderedAscending: return .orderedDescending
        case .orderedDescending: return .orderedAscending
        case .orderedSame: return .orderedSame
        }
    }
}
