import Foundation

/// A report cell's declared source, shipped by the server as
/// `link_<fieldname>` on the row. Desk expresses a cell's destination in
/// per-report JavaScript formatters, which a native client cannot run; a
/// report that resolves its links server-side into one of these shapes is
/// navigable in any client with no report-specific code. The DCAA module's
/// Incurred Cost Proposal Schedules is the first to do so.
public enum ReportLink: Sendable, Hashable {
    /// `{"doctype": ..., "name": ...}` — open the document.
    case document(doctype: String, name: String)
    /// `{"list": doctype, "filters": {...}}` — the DocType's list, filtered
    /// with Desk route-option semantics (`field: value`, or
    /// `field: [operator, value]`).
    case list(doctype: String, filters: [ListFilter])
    /// `{"ledger": {account, project, from_date, to_date}}` — the General
    /// Ledger entries behind a figure.
    case ledger(GeneralLedgerLink)
    /// `{"report": name, "filters": {...}}` — another report, seeded.
    case report(name: String, filters: [String: FrappeValue])
    /// `{"filters": {...}}` — the same report again with these filter
    /// values (a cross-reference between sections of one report).
    case filters([String: FrappeValue])

    public init?(value: FrappeValue?) {
        guard let dict = value?.objectValue else { return nil }
        if let doctype = dict["doctype"]?.nonEmptyString, let name = dict["name"]?.nonEmptyString {
            self = .document(doctype: doctype, name: name)
        } else if let doctype = dict["list"]?.nonEmptyString {
            self = .list(doctype: doctype, filters: Self.listFilters(dict["filters"]))
        } else if let ledger = dict["ledger"]?.objectValue {
            self = .ledger(GeneralLedgerLink(raw: ledger))
        } else if let name = dict["report"]?.nonEmptyString {
            self = .report(name: name, filters: dict["filters"]?.objectValue ?? [:])
        } else if let filters = dict["filters"]?.objectValue {
            self = .filters(filters)
        } else {
            return nil
        }
    }

    /// Desk list route options as list filters: a bare value is equality,
    /// `[operator, value]` carries its operator (`["<=", date]`,
    /// `["in", [...]]`).
    static func listFilters(_ value: FrappeValue?) -> [ListFilter] {
        (value?.objectValue ?? [:]).sorted { $0.key < $1.key }.map { key, raw in
            if let pair = raw.arrayValue, pair.count == 2, let op = pair[0].nonEmptyString,
                pair[1].objectValue == nil {
                return ListFilter(key, op, pair[1])
            }
            return ListFilter(key, "=", raw)
        }
    }
}

/// The General Ledger scope a `ReportLink.ledger` names. Accounts and
/// projects may be several (a group's parents, every contract project);
/// missing dates follow the target screen's fiscal-year default.
public struct GeneralLedgerLink: Sendable, Hashable {
    public var accounts: [String]
    public var projects: [String]
    public var fromDate: String?
    public var toDate: String?

    public init(accounts: [String], projects: [String] = [], fromDate: String? = nil, toDate: String? = nil) {
        self.accounts = accounts
        self.projects = projects
        self.fromDate = fromDate
        self.toDate = toDate
    }

    init(raw: [String: FrappeValue]) {
        accounts = Self.strings(raw["account"])
        projects = Self.strings(raw["project"])
        fromDate = raw["from_date"]?.nonEmptyString
        toDate = raw["to_date"]?.nonEmptyString
    }

    private static func strings(_ value: FrappeValue?) -> [String] {
        value?.arrayValue?.compactMap(\.nonEmptyString) ?? value?.nonEmptyString.map { [$0] } ?? []
    }

    /// The same scope as editable General Ledger filter state.
    public var filterState: GeneralLedgerFilterState {
        GeneralLedgerFilterState(
            fromDate: fromDate, toDate: toDate,
            account: accounts.first, project: projects.first,
            additionalAccounts: Array(accounts.dropFirst()),
            additionalProjects: Array(projects.dropFirst()))
    }
}
