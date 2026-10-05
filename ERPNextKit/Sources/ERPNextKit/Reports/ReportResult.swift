import Foundation

/// One column of a query/script report, normalized from either wire form:
/// modern dict columns (`{"fieldname": ..., "fieldtype": ...}`) or legacy
/// `"Label:Fieldtype/Options:Width"` strings.
public struct ReportColumn: Sendable, Hashable, Identifiable, Codable {
    public var fieldname: String
    public var label: String
    public var fieldtype: FieldType
    public var options: String?
    public var width: Double
    public var hidden: Bool
    public var precision: Int?
    /// Desk's explicit column alignment (script reports set it on Data
    /// columns holding pre-formatted numbers).
    public var align: ReportColumnAlign?

    public var id: String { fieldname }

    /// Numbers, and anything the report aligns right, sit against the
    /// trailing edge.
    public var alignsTrailing: Bool { fieldtype.isNumeric || align == .right }

    init?(value: FrappeValue, index: Int) {
        if let dict = value.objectValue {
            label = dict["label"]?.nonEmptyString ?? dict["fieldname"]?.nonEmptyString ?? "Column \(index + 1)"
            fieldname = dict["fieldname"]?.nonEmptyString ?? Self.scrub(label)
            fieldtype = FieldType(rawValue: dict["fieldtype"]?.nonEmptyString ?? "Data")
            options = dict["options"]?.nonEmptyString
            width = dict["width"]?.doubleValue ?? 120
            hidden = dict["hidden"]?.boolValue ?? false
            precision = dict["precision"]?.intValue
            align = dict["align"]?.nonEmptyString.flatMap { ReportColumnAlign(rawValue: $0) }
        } else if let string = value.stringValue {
            // "Label:Fieldtype/Options:Width", with every part after Label optional.
            let parts = string.split(separator: ":", omittingEmptySubsequences: false)
            guard let first = parts.first else { return nil }
            label = String(first)
            fieldname = Self.scrub(label)
            if parts.count > 1 {
                let typeParts = parts[1].split(separator: "/", maxSplits: 1)
                fieldtype = FieldType(rawValue: typeParts.first.map(String.init) ?? "Data")
                options = typeParts.count > 1 ? String(typeParts[1]) : nil
            } else {
                fieldtype = .data
                options = nil
            }
            width = parts.count > 2 ? Double(parts[2]) ?? 120 : 120
            hidden = false
            precision = nil
            align = nil
        } else {
            return nil
        }
    }

    static func scrub(_ label: String) -> String {
        label.lowercased()
            .map { $0.isLetter || $0.isNumber ? $0 : "_" }
            .reduce(into: "") { result, char in
                if char == "_" && result.hasSuffix("_") { return }
                result.append(char)
            }
            .trimmingCharacters(in: CharacterSet(charactersIn: "_"))
    }
}

public enum ReportColumnAlign: String, Sendable, Hashable, Codable {
    case left, right, center
}

/// One report row, keyed by column fieldname. Array rows (legacy query
/// reports) are mapped to keys positionally during decoding.
public struct ReportRow: Sendable, Hashable, Identifiable, Codable {
    public let id: Int
    public let values: [String: FrappeValue]

    public subscript(column: ReportColumn) -> FrappeValue? {
        let value = values[column.fieldname]
        if case .null = value { return nil }
        return value
    }

    /// Tree depth for hierarchical reports (P&L account tree etc.).
    public var indent: Int { values["indent"]?.intValue ?? 0 }

    /// Row-level currency hint used by financial statements.
    public var currency: String? { values["currency"]?.nonEmptyString }

    /// Emphasis the report asks for (`bold: 1` on total rows), beyond the
    /// group-row heuristic.
    public var isBold: Bool { values["bold"]?.boolValue ?? false }

    /// The declared source of this row's cell in `column`, when the report
    /// ships one as `link_<fieldname>` (see `ReportLink`).
    public func link(for column: ReportColumn) -> ReportLink? {
        ReportLink(value: values["link_\(column.fieldname)"])
    }

    /// Spacer rows ({} or all-null) separate report sections.
    public var isBlank: Bool {
        values.allSatisfy { key, value in key == "indent" || value.isNull }
    }
}

public struct ReportSummaryItem: Sendable, Hashable, Identifiable, Codable {
    public var label: String
    public var value: FrappeValue
    public var datatype: FieldType
    public var currency: String?
    /// Desk color hint: "Green", "Red", "Blue", …
    public var indicator: String?

    public var id: String { label }

    init?(value: FrappeValue) {
        guard let dict = value.objectValue, let label = dict["label"]?.nonEmptyString else {
            return nil
        }
        self.label = label
        self.value = dict["value"] ?? .null
        self.datatype = FieldType(rawValue: dict["datatype"]?.nonEmptyString ?? "Data")
        self.currency = dict["currency"]?.nonEmptyString
        self.indicator = dict["indicator"]?.nonEmptyString
    }
}

/// A report's chart payload (Frappe Charts config), normalized for native
/// rendering with Swift Charts.
public struct ReportChart: Sendable, Hashable, Codable {
    public struct Dataset: Sendable, Hashable, Codable {
        public var name: String?
        public var values: [Double]
    }

    /// "bar", "line", "percentage", "pie", …
    public var type: String
    public var labels: [String]
    public var datasets: [Dataset]

    init?(value: FrappeValue?) {
        guard let dict = value?.objectValue,
            let data = dict["data"]?.objectValue,
            let labels = data["labels"]?.arrayValue
        else { return nil }
        self.type = dict["type"]?.nonEmptyString ?? "bar"
        self.labels = labels.compactMap { $0.stringValue }
        self.datasets = (data["datasets"]?.arrayValue ?? []).compactMap { entry in
            guard let dataset = entry.objectValue,
                let values = dataset["values"]?.arrayValue
            else { return nil }
            return Dataset(
                name: dataset["name"]?.nonEmptyString,
                values: values.map { $0.doubleValue ?? 0 })
        }
        guard !self.labels.isEmpty, !self.datasets.isEmpty else { return nil }
    }
}

/// The normalized output of `frappe.desk.query_report.run`.
public struct ReportResult: Sendable, Hashable, Codable {
    public var columns: [ReportColumn]
    public var rows: [ReportRow]
    public var summary: [ReportSummaryItem]
    public var chart: ReportChart?
    /// The report's `message` (Desk shows it above the grid as HTML), as
    /// plain lines: a title, notes, review warnings.
    public var message: String? = nil
    /// The same message as sent, for rich rendering (`HTMLRichText`).
    /// Optional so report snapshots cached before it existed still decode.
    public var messageHTML: String? = nil

    public var visibleColumns: [ReportColumn] { columns.filter { !$0.hidden } }

    /// A row is a "group" row if the next row is nested deeper — used to bold
    /// tree parents the way Desk does.
    public func isGroupRow(at index: Int) -> Bool {
        guard index + 1 < rows.count else { return false }
        return rows[index + 1].indent > rows[index].indent
    }

    public static func decode(from data: Data) throws -> ReportResult {
        guard let root = try FrappeValue.decode(from: data).objectValue else {
            throw ERPNextError(message: "Malformed report response")
        }
        let payload = root["message"]?.objectValue ?? root

        if let prepared = payload["prepared_report"]?.boolValue, prepared,
            payload["columns"]?.arrayValue == nil {
            throw ERPNextError(
                message:
                    "This report runs as a background (prepared) report on the server. Open it in Desk once, or reduce its date range.")
        }

        let columns = (payload["columns"]?.arrayValue ?? []).enumerated()
            .compactMap { ReportColumn(value: $0.element, index: $0.offset) }
        guard !columns.isEmpty else {
            throw ERPNextError(message: "Report returned no columns")
        }

        var rows: [ReportRow] = []
        for (index, element) in (payload["result"]?.arrayValue ?? []).enumerated() {
            if let dict = element.objectValue {
                rows.append(ReportRow(id: index, values: dict))
            } else if let array = element.arrayValue {
                var keyed: [String: FrappeValue] = [:]
                for (column, value) in zip(columns, array) {
                    keyed[column.fieldname] = value
                }
                rows.append(ReportRow(id: index, values: keyed))
            }
            // Anything else (e.g. a bare "Total" string) is dropped.
        }

        let summary = (payload["report_summary"]?.arrayValue ?? [])
            .compactMap(ReportSummaryItem.init(value:))

        let messageHTML = payload["message"]?.nonEmptyString
        return ReportResult(
            columns: columns, rows: rows, summary: summary,
            chart: ReportChart(value: payload["chart"]),
            message: messageHTML.flatMap(Self.plainText(fromHTML:)),
            messageHTML: messageHTML)
    }

    /// Block-level tags become line breaks, list items bullets, the rest is
    /// stripped and entity-decoded; nil when nothing readable remains.
    static func plainText(fromHTML html: String) -> String? {
        var text = html.replacingOccurrences(
            of: "<br\\s*/?>|</?(h[1-6]|p|div|ul|ol|tr|table)[^>]*>|</li>", with: "\n",
            options: [.regularExpression, .caseInsensitive])
        text = text.replacingOccurrences(
            of: "<li[^>]*>", with: "\n• ", options: [.regularExpression, .caseInsensitive])
        let lines = text.strippingSimpleHTML()
            .components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        return lines.isEmpty ? nil : lines.joined(separator: "\n")
    }
}

extension String {
    /// Financial statement total rows arrive as `'Total Income (Credit)'` —
    /// literally wrapped in single quotes. Desk styles them as totals.
    public var isQuotedTotalLabel: Bool {
        count >= 2 && hasPrefix("'") && hasSuffix("'")
    }

    public var strippingTotalQuotes: String {
        isQuotedTotalLabel ? String(dropFirst().dropLast()) : self
    }
}
