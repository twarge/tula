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

/// Shared filter state for the standard financial statements.
public struct FinancialFilterState: Sendable, Hashable {
    public var company: Company?
    public var fiscalYear: FiscalYear?
    public var periodicity: Periodicity

    public init(
        company: Company? = nil, fiscalYear: FiscalYear? = nil,
        periodicity: Periodicity = .quarterly
    ) {
        self.company = company
        self.fiscalYear = fiscalYear
        self.periodicity = periodicity
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

    public func filters(for state: FinancialFilterState) -> [String: FrappeValue] {
        var filters: [String: FrappeValue] = [:]
        if let company = state.company {
            filters["company"] = .string(company.name)
        }
        let fiscalYear = state.fiscalYear

        switch filterStyle {
        case .financialStatement(let accumulated):
            filters["filter_based_on"] = .string("Fiscal Year")
            if let fiscalYear {
                filters["from_fiscal_year"] = .string(fiscalYear.name)
                filters["to_fiscal_year"] = .string(fiscalYear.name)
                filters["period_start_date"] = .string(fiscalYear.startDate)
                filters["period_end_date"] = .string(fiscalYear.endDate)
            }
            filters["periodicity"] = .string(state.periodicity.rawValue)
            filters["accumulated_values"] = .int(accumulated ? 1 : 0)
            filters["include_default_book_entries"] = .int(1)

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
