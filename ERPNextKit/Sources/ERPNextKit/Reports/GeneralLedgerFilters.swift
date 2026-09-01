import Foundation

/// Editable filter state for the General Ledger screen. Drill-downs from the
/// financial statements *seed* this state through the route's options (Desk's
/// `frappe.route_options` semantics: applied once, then fully editable) —
/// nothing stays pinned invisibly over the filter bar.
public struct GeneralLedgerFilterState: Sendable, Hashable {
    /// Wire dates; nil follows the global fiscal-year span.
    public var fromDate: String?
    public var toDate: String?
    public var account: String?
    public var project: String?
    public var costCenter: String?
    public var financeBook: String?
    public var presentationCurrency: String?
    public var includeDefaultBookEntries: Bool
    /// Desk's grouping mode, without the "Group by"/"Categorize by" verb —
    /// one of `Self.categorizeChoices`.
    public var categorizeBy: String

    public static let defaultCategorizeBy = "Voucher (Consolidated)"
    public static let categorizeChoices = [
        "Voucher (Consolidated)", "Voucher", "Account", "Party",
    ]

    public init(
        fromDate: String? = nil, toDate: String? = nil, account: String? = nil,
        project: String? = nil, costCenter: String? = nil, financeBook: String? = nil,
        presentationCurrency: String? = nil, includeDefaultBookEntries: Bool = true,
        categorizeBy: String = GeneralLedgerFilterState.defaultCategorizeBy
    ) {
        self.fromDate = fromDate
        self.toDate = toDate
        self.account = account
        self.project = project
        self.costCenter = costCenter
        self.financeBook = financeBook
        self.presentationCurrency = presentationCurrency
        self.includeDefaultBookEntries = includeDefaultBookEntries
        self.categorizeBy = categorizeBy
    }

    /// Decodes a drill-down route's options. Scoping filters accept either a
    /// bare string or Desk's one-element MultiSelectList array.
    public init(routeOptions: [String: FrappeValue]) {
        func single(_ name: String) -> String? {
            routeOptions[name]?.arrayValue?.first?.nonEmptyString
                ?? routeOptions[name]?.nonEmptyString
        }
        self.init(
            fromDate: routeOptions["from_date"]?.nonEmptyString,
            toDate: routeOptions["to_date"]?.nonEmptyString,
            account: single("account"),
            project: single("project"),
            costCenter: single("cost_center"),
            financeBook: routeOptions["finance_book"]?.nonEmptyString,
            presentationCurrency: routeOptions["presentation_currency"]?.nonEmptyString,
            includeDefaultBookEntries: routeOptions["include_default_book_entries"]?.boolValue
                ?? true)
    }

    /// The same state as route options for a `.queryReport` drill route
    /// (round-trips through `init(routeOptions:)`).
    public var routeOptions: [String: FrappeValue] {
        var options: [String: FrappeValue] = [:]
        if let fromDate { options["from_date"] = .string(fromDate) }
        if let toDate { options["to_date"] = .string(toDate) }
        if let account { options["account"] = .array([.string(account)]) }
        if let project { options["project"] = .array([.string(project)]) }
        if let costCenter { options["cost_center"] = .array([.string(costCenter)]) }
        if let financeBook { options["finance_book"] = .string(financeBook) }
        if let presentationCurrency {
            options["presentation_currency"] = .string(presentationCurrency)
        }
        if !includeDefaultBookEntries { options["include_default_book_entries"] = .int(0) }
        return options
    }

    /// Applies this state over the descriptor's base filters (which carry the
    /// company and the fiscal-year fallback dates).
    public func apply(to filters: inout [String: FrappeValue]) {
        if let fromDate { filters["from_date"] = .string(fromDate) }
        if let toDate { filters["to_date"] = .string(toDate) }
        // Single values as one-element lists, matching Desk's MultiSelectList
        // wire shape; the server expands group accounts/cost centers itself.
        if let account { filters["account"] = .array([.string(account)]) }
        if let project { filters["project"] = .array([.string(project)]) }
        if let costCenter { filters["cost_center"] = .array([.string(costCenter)]) }
        if let financeBook { filters["finance_book"] = .string(financeBook) }
        if let presentationCurrency {
            filters["presentation_currency"] = .string(presentationCurrency)
        }
        filters["include_default_book_entries"] = .int(includeDefaultBookEntries ? 1 : 0)
        // ERPNext v16 renamed the grouping filter group_by → categorize_by
        // (values relabeled to match). Sending both spellings keeps every
        // version grouping the same way without a version probe.
        filters["group_by"] = .string("Group by \(categorizeBy)")
        filters["categorize_by"] = .string("Categorize by \(categorizeBy)")
    }

    /// True when any popover filter differs from its default (drives the
    /// filled filter-icon state).
    public var hasAdvancedFilters: Bool {
        project != nil || costCenter != nil || financeBook != nil
            || presentationCurrency != nil || !includeDefaultBookEntries
            || categorizeBy != Self.defaultCategorizeBy
    }

    /// Stable identity for screen caches (every field participates).
    public var cacheToken: String {
        [
            fromDate ?? "-", toDate ?? "-", account ?? "-", project ?? "-",
            costCenter ?? "-", financeBook ?? "-", presentationCurrency ?? "-",
            includeDefaultBookEntries ? "1" : "0", categorizeBy,
        ].joined(separator: "|")
    }
}
