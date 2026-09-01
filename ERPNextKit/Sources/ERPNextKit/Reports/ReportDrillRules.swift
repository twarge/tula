import Foundation

/// Declarative drill-down rules for server reports that render through the
/// generic report screen. Desk implements these as per-report JS formatters
/// we can't execute; this registry declares the same mappings — which rows
/// and columns are drillable, which report they open, and how the source's
/// filters carry over — for the high-traffic reports.
public enum ReportDrillRules {
    /// The drill target for a click on `row`/`column` of `report`, given the
    /// source screen's current wire filters. Nil = not a drillable cell.
    /// Only numeric cells drill — text cells (party, item) already navigate
    /// as Link/Dynamic Link fields.
    public static func drill(
        report: String, row: [String: FrappeValue], column: ReportColumn?,
        filters: [String: FrappeValue], fiscalYears: [FiscalYear] = []
    ) -> (report: String, options: [String: FrappeValue])? {
        guard let column, column.fieldtype.isNumeric else { return nil }

        switch report {
        case "Accounts Receivable Summary", "Accounts Payable Summary":
            // Party rows → the detailed ageing report for that party.
            guard let party = row["party"]?.nonEmptyString, !party.isQuotedTotalLabel
            else { return nil }
            var options: [String: FrappeValue] = ["party": .array([.string(party)])]
            carry(
                strings: ["company", "report_date", "party_type", "finance_book",
                          "party_account"],
                lists: ["cost_center", "project"],
                from: filters, into: &options)
            let target = report == "Accounts Receivable Summary"
                ? "Accounts Receivable" : "Accounts Payable"
            return (target, options)

        case "Trial Balance for Party":
            // Party rows → General Ledger for that party over the period.
            // GL shows Opening/Total/Closing rows, so one target ties to
            // every column (opening, movement, closing).
            guard let party = row["party"]?.nonEmptyString, !party.isQuotedTotalLabel
            else { return nil }
            var options: [String: FrappeValue] = ["party": .array([.string(party)])]
            carry(
                strings: ["company", "from_date", "to_date", "party_type"],
                lists: ["account", "cost_center"],
                from: filters, into: &options)
            return ("General Ledger", options)

        case "Stock Balance":
            // Item × warehouse quantities → Stock Ledger, the inventory
            // analogue of P&L → GL.
            guard let item = row["item_code"]?.nonEmptyString, !item.isQuotedTotalLabel
            else { return nil }
            var options: [String: FrappeValue] = ["item_code": .string(item)]
            // The row's own warehouse wins; the filter's only fills in when
            // rows aren't warehouse-split.
            if let warehouse = row["warehouse"]?.nonEmptyString {
                options["warehouse"] = .string(warehouse)
            }
            carry(
                strings: ["company", "from_date", "to_date", "warehouse", "project"],
                lists: [],
                from: filters, into: &options)
            return ("Stock Ledger", options)

        case "Budget Variance Report":
            return budgetVarianceDrill(
                row: row, column: column, filters: filters, fiscalYears: fiscalYears)

        default:
            return nil
        }
    }

    /// Actual columns → General Ledger for the row's account + dimension over
    /// the column's period. Budget and Variance numbers aren't ledger-backed,
    /// so only "Actual" drills. Column labels are "Actual (Jan) 2025-2026",
    /// "Actual (Jan-Mar) 2025-2026", or "Actual 2025-2026" (yearly).
    private static func budgetVarianceDrill(
        row: [String: FrappeValue], column: ReportColumn,
        filters: [String: FrappeValue], fiscalYears: [FiscalYear]
    ) -> (report: String, options: [String: FrappeValue])? {
        guard let account = row["account"]?.nonEmptyString, !account.isQuotedTotalLabel,
            column.label.hasPrefix("Actual ")
        else { return nil }

        var rest = column.label.dropFirst("Actual".count)
            .trimmingCharacters(in: .whitespaces)
        var monthSuffix: String?
        if rest.hasPrefix("("), let close = rest.firstIndex(of: ")") {
            monthSuffix = String(rest[rest.index(after: rest.startIndex)..<close])
            rest = String(rest[rest.index(after: close)...])
                .trimmingCharacters(in: .whitespaces)
        }
        guard let fiscalYear = fiscalYears.first(where: { $0.name == rest }) else {
            return nil
        }
        var span: (start: String, end: String)
        if let monthSuffix {
            guard let monthSpan = monthSpan(monthSuffix, in: fiscalYear) else { return nil }
            span = monthSpan
        } else {
            span = (fiscalYear.startDate, fiscalYear.endDate)
        }
        // Cumulative columns run from the report's first fiscal year.
        if filters["show_cumulative"]?.boolValue == true,
            let fromName = filters["from_fiscal_year"]?.nonEmptyString,
            let fromYear = fiscalYears.first(where: { $0.name == fromName }) {
            span.start = fromYear.startDate
        }

        var options: [String: FrappeValue] = [
            "account": .array([.string(account)]),
            "from_date": .string(span.start),
            "to_date": .string(span.end),
        ]
        carry(strings: ["company"], lists: [], from: filters, into: &options)
        if let dimension = row["budget_against"]?.nonEmptyString {
            switch filters["budget_against"]?.nonEmptyString {
            case "Cost Center":
                options["cost_center"] = .array([.string(dimension)])
            case "Project":
                options["project"] = .array([.string(dimension)])
            default:
                // A custom accounting dimension — its GL filter fieldname
                // isn't knowable here; drill by account + period alone.
                break
            }
        }
        return ("General Ledger", options)
    }

    /// "Jan" or "Jan-Mar" → wire dates for those months inside the fiscal
    /// year (a month before the FY's start month belongs to its second
    /// calendar year — Jan of an Apr–Mar fiscal year is the closing January).
    static func monthSpan(
        _ suffix: String, in fiscalYear: FiscalYear
    ) -> (start: String, end: String)? {
        let parts = suffix.split(separator: "-").map {
            $0.trimmingCharacters(in: .whitespaces)
        }
        guard let firstMonth = parts.first.flatMap(monthNumber),
            let lastMonth = monthNumber(parts.count > 1 ? parts[1] : parts[0]),
            let yearStart = wire.date(from: fiscalYear.startDate)
        else { return nil }
        let base = calendar.dateComponents([.year, .month], from: yearStart)
        guard let baseYear = base.year, let baseMonth = base.month else { return nil }

        func firstDay(of month: Int) -> Date? {
            calendar.date(
                from: DateComponents(
                    year: month >= baseMonth ? baseYear : baseYear + 1, month: month, day: 1))
        }
        guard let start = firstDay(of: firstMonth), let lastStart = firstDay(of: lastMonth),
            start <= lastStart,
            let nextMonth = calendar.date(byAdding: .month, value: 1, to: lastStart),
            let end = calendar.date(byAdding: .day, value: -1, to: nextMonth)
        else { return nil }
        return (wire.string(from: start), wire.string(from: end))
    }

    /// Copies set filter values over, re-wrapping the MultiSelectList ones
    /// as one-element arrays.
    private static func carry(
        strings: [String], lists: [String],
        from filters: [String: FrappeValue], into options: inout [String: FrappeValue]
    ) {
        for key in strings where options[key] == nil {
            if let value = singleValue(filters[key]) {
                options[key] = .string(value)
            }
        }
        for key in lists where options[key] == nil {
            if let value = singleValue(filters[key]) {
                options[key] = .array([.string(value)])
            }
        }
    }

    /// A filter's scalar value, whether it arrived bare or as a one-element
    /// MultiSelectList array.
    private static func singleValue(_ value: FrappeValue?) -> String? {
        value?.nonEmptyString ?? value?.arrayValue?.first?.nonEmptyString
    }

    private static func monthNumber(_ abbreviation: String) -> Int? {
        let months = [
            "jan", "feb", "mar", "apr", "may", "jun",
            "jul", "aug", "sep", "oct", "nov", "dec",
        ]
        return months.firstIndex(of: abbreviation.lowercased()).map { $0 + 1 }
    }

    private static let wire: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    private static let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .current
        return calendar
    }()
}
