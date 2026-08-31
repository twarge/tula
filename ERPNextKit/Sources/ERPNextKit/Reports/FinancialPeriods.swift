import Foundation

/// One column period of a financial statement, mirroring the server's
/// `get_period_list` (erpnext financial_statements.py). The server uses
/// `to_date.strftime("%b_%Y").lower()` as the column fieldname, so a client
/// that recomputes the same period list can map period columns back to the
/// date range they cover — the basis for per-period drill-downs.
public struct ReportPeriod: Sendable, Hashable {
    /// Column fieldname on the wire, e.g. "mar_2025".
    public var key: String
    /// Wire dates ("yyyy-MM-dd").
    public var fromDate: String
    public var toDate: String

    public init(key: String, fromDate: String, toDate: String) {
        self.key = key
        self.fromDate = fromDate
        self.toDate = toDate
    }
}

public enum FinancialPeriods {
    private static let wire: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    /// Python's `%b_%Y` under the server's default (English) locale.
    private static let key: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "MMM_yyyy"
        return formatter
    }()

    private static let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .current
        return calendar
    }()

    /// Replicates `get_period_list`: periods march by the periodicity's month
    /// count from the span start; in Date Range mode the first period ends at
    /// a month boundary (`add_months(get_first_day(start), n)`); the last
    /// period clamps to the span end.
    public static func periods(
        spanStart: String, spanEnd: String, periodicity: Periodicity,
        alignsFirstPeriodToMonth: Bool
    ) -> [ReportPeriod] {
        guard let startDate = wire.date(from: spanStart),
            let endDate = wire.date(from: spanEnd), startDate <= endDate
        else { return [] }

        var periods: [ReportPeriod] = []
        var cursor = startDate
        // Bounded like the server's ceil(months / months_to_add) loop; 600
        // months outlasts any real reporting span.
        for index in 0..<600 {
            let base = index == 0 && alignsFirstPeriodToMonth ? firstDay(of: cursor) : cursor
            guard
                let next = calendar.date(
                    byAdding: .month, value: periodicity.monthsPerPeriod, to: base),
                let periodEnd = calendar.date(byAdding: .day, value: -1, to: next)
            else { break }
            let clamped = min(periodEnd, endDate)
            periods.append(
                ReportPeriod(
                    key: key.string(from: clamped).lowercased(),
                    fromDate: wire.string(from: cursor),
                    toDate: wire.string(from: clamped)))
            if clamped == endDate { break }
            cursor = next
        }
        return periods
    }

    private static func firstDay(of date: Date) -> Date {
        calendar.date(from: calendar.dateComponents([.year, .month], from: date)) ?? date
    }
}

extension Periodicity {
    /// The server's `months_to_add` per period.
    public var monthsPerPeriod: Int {
        switch self {
        case .monthly: return 1
        case .quarterly: return 3
        case .halfYearly: return 6
        case .yearly: return 12
        }
    }
}
