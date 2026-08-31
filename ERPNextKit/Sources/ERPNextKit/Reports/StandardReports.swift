import Foundation

public struct Company: Sendable, Hashable, Identifiable {
    public var name: String
    public var defaultCurrency: String?

    public init(name: String, defaultCurrency: String? = nil) {
        self.name = name
        self.defaultCurrency = defaultCurrency
    }

    public var id: String { name }
}

public struct FiscalYear: Sendable, Hashable, Identifiable {
    public var name: String
    /// Frappe wire dates: "yyyy-MM-dd".
    public var startDate: String
    public var endDate: String

    public init(name: String, startDate: String, endDate: String) {
        self.name = name
        self.startDate = startDate
        self.endDate = endDate
    }

    public var id: String { name }
}

public enum Periodicity: String, Sendable, Hashable, CaseIterable, Identifiable {
    case monthly = "Monthly"
    case quarterly = "Quarterly"
    case halfYearly = "Half-Yearly"
    case yearly = "Yearly"

    public var id: String { rawValue }
}

/// Shared filter state for the standard financial statements — Desk's full
/// conventional filter set for `erpnext.financial_statements` (these are
/// script-report filters defined in bundled JS, not servable metadata, so
/// they live here natively; ARCHITECTURE.md §7).
public struct FinancialFilterState: Sendable, Hashable {
    public var company: Company?
    /// The From fiscal year (and the whole span when `toFiscalYear` is nil).
    public var fiscalYear: FiscalYear?
    public var periodicity: Periodicity

    // Advanced set (Desk parity). Defaults reproduce the pre-existing
    // behavior, so untouched screens render identically.
    /// Desk's "filter based on": false = Fiscal Year, true = Date Range.
    public var basedOnDateRange: Bool
    /// Wire dates, used only with `basedOnDateRange`.
    public var periodStartDate: String?
    public var periodEndDate: String?
    /// nil = same as `fiscalYear` (a single-year span).
    public var toFiscalYear: FiscalYear?
    public var financeBook: String?
    public var presentationCurrency: String?
    public var costCenter: String?
    public var project: String?
    /// nil = the statement's own Desk default.
    public var accumulatedValues: Bool?
    public var includeDefaultBookEntries: Bool

    public init(
        company: Company? = nil, fiscalYear: FiscalYear? = nil,
        periodicity: Periodicity = .quarterly,
        basedOnDateRange: Bool = false,
        periodStartDate: String? = nil, periodEndDate: String? = nil,
        toFiscalYear: FiscalYear? = nil,
        financeBook: String? = nil, presentationCurrency: String? = nil,
        costCenter: String? = nil, project: String? = nil,
        accumulatedValues: Bool? = nil, includeDefaultBookEntries: Bool = true
    ) {
        self.company = company
        self.fiscalYear = fiscalYear
        self.periodicity = periodicity
        self.basedOnDateRange = basedOnDateRange
        self.periodStartDate = periodStartDate
        self.periodEndDate = periodEndDate
        self.toFiscalYear = toFiscalYear
        self.financeBook = financeBook
        self.presentationCurrency = presentationCurrency
        self.costCenter = costCenter
        self.project = project
        self.accumulatedValues = accumulatedValues
        self.includeDefaultBookEntries = includeDefaultBookEntries
    }

    /// True when any advanced filter differs from its default.
    public var hasAdvancedFilters: Bool {
        basedOnDateRange || toFiscalYear != nil || financeBook != nil
            || presentationCurrency != nil || costCenter != nil || project != nil
            || accumulatedValues != nil || !includeDefaultBookEntries
    }

    /// Stable identity for screen caches (every field participates).
    public var cacheToken: String {
        [
            company?.name ?? "-", fiscalYear?.name ?? "-", periodicity.rawValue,
            basedOnDateRange ? "range" : "fy",
            periodStartDate ?? "-", periodEndDate ?? "-",
            toFiscalYear?.name ?? "-", financeBook ?? "-",
            presentationCurrency ?? "-", costCenter ?? "-", project ?? "-",
            accumulatedValues.map { $0 ? "1" : "0" } ?? "-",
            includeDefaultBookEntries ? "1" : "0",
        ].joined(separator: "|")
    }

    /// The effective reporting span as wire dates (for drill-downs).
    public var effectiveDateSpan: (start: String, end: String)? {
        if basedOnDateRange, let periodStartDate, let periodEndDate {
            return (periodStartDate, periodEndDate)
        }
        guard let fiscalYear else { return nil }
        return (fiscalYear.startDate, (toFiscalYear ?? fiscalYear).endDate)
    }
}

/// A report the sidebar offers, plus the native filter set it needs.
/// Script-report filter definitions live in server-side JS, so the standard
/// statements get native filter builders here (see ARCHITECTURE.md §7).
public struct ReportDescriptor: Sendable, Hashable, Identifiable {
    public enum FilterStyle: Sendable, Hashable {
        /// company + fiscal year span + periodicity (P&L, Balance Sheet, Cash Flow)
        case financialStatement(accumulatedByDefault: Bool)
        /// company + fiscal year + derived date range (Trial Balance)
        case fiscalYearRange
        /// company + date range (General Ledger)
        case dateRange
    }

    public var name: String
    public var title: String
    public var systemImage: String
    public var filterStyle: FilterStyle
    /// DocType whose `modified` timestamp moving means this report is stale
    /// (see `DataSource.latestModified`). Nil disables auto-refresh.
    public var changeSignalDoctype: String?

    public var id: String { name }
    public var usesPeriodicity: Bool {
        if case .financialStatement = filterStyle { return true }
        return false
    }

    /// The statement's Desk default for Accumulated Values.
    public var accumulatedByDefault: Bool {
        if case .financialStatement(let accumulated) = filterStyle { return accumulated }
        return false
    }

    public func filters(for state: FinancialFilterState) -> [String: FrappeValue] {
        var filters: [String: FrappeValue] = [:]
        if let company = state.company {
            filters["company"] = .string(company.name)
        }
        let fiscalYear = state.fiscalYear

        switch filterStyle {
        case .financialStatement(let accumulatedByDefault):
            if state.basedOnDateRange, let start = state.periodStartDate,
                let end = state.periodEndDate {
                filters["filter_based_on"] = .string("Date Range")
                filters["period_start_date"] = .string(start)
                filters["period_end_date"] = .string(end)
            } else {
                filters["filter_based_on"] = .string("Fiscal Year")
                if let fiscalYear {
                    let toYear = state.toFiscalYear ?? fiscalYear
                    filters["from_fiscal_year"] = .string(fiscalYear.name)
                    filters["to_fiscal_year"] = .string(toYear.name)
                    filters["period_start_date"] = .string(fiscalYear.startDate)
                    filters["period_end_date"] = .string(toYear.endDate)
                }
            }
            filters["periodicity"] = .string(state.periodicity.rawValue)
            filters["accumulated_values"] = .int(
                (state.accumulatedValues ?? accumulatedByDefault) ? 1 : 0)
            filters["include_default_book_entries"] = .int(
                state.includeDefaultBookEntries ? 1 : 0)
            if let financeBook = state.financeBook {
                filters["finance_book"] = .string(financeBook)
            }
            if let currency = state.presentationCurrency {
                filters["presentation_currency"] = .string(currency)
            }
            // Desk sends these as MultiSelectList values; a one-element list
            // matches the server's get_*_with_children expectations.
            if let costCenter = state.costCenter {
                filters["cost_center"] = .array([.string(costCenter)])
            }
            if let project = state.project {
                filters["project"] = .array([.string(project)])
            }

        case .fiscalYearRange:
            if let fiscalYear {
                filters["fiscal_year"] = .string(fiscalYear.name)
                filters["from_date"] = .string(fiscalYear.startDate)
                filters["to_date"] = .string(fiscalYear.endDate)
            }
            filters["with_period_closing_entry_for_opening"] = .int(1)
            filters["show_net_values"] = .int(1)

        case .dateRange:
            if let fiscalYear {
                filters["from_date"] = .string(fiscalYear.startDate)
                filters["to_date"] = .string(fiscalYear.endDate)
            }
            filters["group_by"] = .string("Group by Voucher (Consolidated)")
        }
        return filters
    }
}

public enum StandardReports {
    public static let profitAndLoss = ReportDescriptor(
        name: "Profit and Loss Statement",
        title: "Profit and Loss",
        systemImage: "chart.line.uptrend.xyaxis",
        filterStyle: .financialStatement(accumulatedByDefault: false),
        changeSignalDoctype: "GL Entry")

    public static let balanceSheet = ReportDescriptor(
        name: "Balance Sheet",
        title: "Balance Sheet",
        systemImage: "scalemass",
        filterStyle: .financialStatement(accumulatedByDefault: true),
        changeSignalDoctype: "GL Entry")

    public static let cashFlow = ReportDescriptor(
        name: "Cash Flow",
        title: "Cash Flow",
        systemImage: "arrow.left.arrow.right",
        filterStyle: .financialStatement(accumulatedByDefault: false),
        changeSignalDoctype: "GL Entry")

    public static let trialBalance = ReportDescriptor(
        name: "Trial Balance",
        title: "Trial Balance",
        systemImage: "checklist",
        filterStyle: .fiscalYearRange,
        changeSignalDoctype: "GL Entry")

    public static let generalLedger = ReportDescriptor(
        name: "General Ledger",
        title: "General Ledger",
        systemImage: "book.closed",
        filterStyle: .dateRange,
        changeSignalDoctype: "GL Entry")

    public static let financialStatements: [ReportDescriptor] = [
        profitAndLoss, balanceSheet, cashFlow, trialBalance, generalLedger,
    ]
}
