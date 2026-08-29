import Foundation

/// Serves bundled fixtures shaped exactly like real ERPNext responses, and
/// decodes them through the same pipeline as `LiveDataSource` — so demo mode
/// exercises the entire rendering stack with no server.
public struct DemoDataSource: DataSource {
    public init() {}

    public var displayName: String { "Demo Data" }

    public func ping() async throws {}

    public func companies() async throws -> [Company] {
        [Company(name: "Wind Power LLC", defaultCurrency: "USD")]
    }

    public func fiscalYears() async throws -> [FiscalYear] {
        [FiscalYear(name: "2025", startDate: "2025-01-01", endDate: "2025-12-31")]
    }

    public func runReport(_ reportName: String, filters: [String: FrappeValue]) async throws
        -> ReportResult {
        switch reportName {
        case StandardReports.profitAndLoss.name:
            return try ReportResult.decode(from: Data(DemoFixtures.profitAndLoss.utf8))
        case StandardReports.balanceSheet.name:
            return try ReportResult.decode(from: Data(DemoFixtures.balanceSheet.utf8))
        default:
            throw ERPNextError(
                message:
                    "\"\(reportName)\" isn't included in the demo data. Connect to an ERPNext server in Settings to run it.")
        }
    }

    public func metaBundle(for doctype: String) async throws -> MetaBundle {
        switch doctype {
        case "Account":
            return try MetaDecoder.bundle(from: Data(DemoFixtures.accountMeta.utf8))
        case "Sales Invoice":
            return try MetaDecoder.bundle(from: Data(DemoFixtures.salesInvoiceMeta.utf8))
        default:
            throw ERPNextError(
                message:
                    "\"\(doctype)\" isn't included in the demo data. Connect to an ERPNext server in Settings to browse it.")
        }
    }

    public func list(
        _ doctype: String, fields: [String], filters: [ListFilter],
        orderBy: String?, limitStart: Int, limitPageLength: Int
    ) async throws -> [Document] {
        let docs: [Document]
        switch doctype {
        case "Account":
            docs = try Document.list(from: Data(DemoFixtures.accountList.utf8))
        case "Sales Invoice":
            docs = try Document.list(from: Data(DemoFixtures.salesInvoiceList.utf8))
        default:
            return []
        }
        return Self.sort(Self.apply(filters, to: docs), by: orderBy)
    }

    public func count(_ doctype: String, filters: [ListFilter]) async throws -> Int? {
        let docs = try await list(
            doctype, fields: [], filters: filters, orderBy: nil, limitStart: 0,
            limitPageLength: Int.max)
        return docs.isEmpty ? nil : docs.count
    }

    /// Minimal `order_by` semantics ("field asc|desc") for demo parity.
    static func sort(_ docs: [Document], by orderBy: String?) -> [Document] {
        guard let orderBy else { return docs }
        let parts = orderBy.split(separator: " ")
        guard let field = parts.first.map(String.init) else { return docs }
        let descending = parts.count > 1 && parts[1].lowercased() == "desc"
        return docs.sorted { a, b in
            let left = a.raw[field]
            let right = b.raw[field]
            let ascending: Bool
            if let l = left?.doubleValue, let r = right?.doubleValue {
                ascending = l < r
            } else {
                ascending = (left?.stringValue ?? "") < (right?.stringValue ?? "")
            }
            return descending ? !ascending : ascending
        }
    }

    /// Minimal server-side filter semantics (`=` and `like`) so demo mode
    /// behaves like a live site for search and quick filters.
    static func apply(_ filters: [ListFilter], to docs: [Document]) -> [Document] {
        guard !filters.isEmpty else { return docs }
        return docs.filter { doc in
            filters.allSatisfy { filter in
                let actual = doc.raw[filter.fieldname]?.stringValue ?? ""
                switch filter.op {
                case "=":
                    return actual == (filter.value.stringValue ?? "")
                case "like":
                    let needle = (filter.value.stringValue ?? "")
                        .replacingOccurrences(of: "%", with: "").lowercased()
                    return needle.isEmpty || actual.lowercased().contains(needle)
                default:
                    return true
                }
            }
        }
    }

    public func reports() async throws -> [ReportInfo] {
        StandardReports.financialStatements.map {
            ReportInfo(
                name: $0.name, reportType: "Script Report", refDoctype: "GL Entry",
                module: "Accounts")
        }
    }

    public func searchLink(doctype: String, query: String) async throws -> [LinkOption] {
        guard doctype == "Customer" else { return [] }
        let customers = ["Grant Plastics Ltd.", "Northwind Research", "Zany Brainy"]
        return customers
            .filter { query.isEmpty || $0.lowercased().contains(query.lowercased()) }
            .map { LinkOption(value: $0) }
    }

    public func document(_ doctype: String, name: String) async throws -> Document {
        let fixtures: [String: String] = [
            "Sales Invoice": DemoFixtures.salesInvoiceDocs,
            "Account": DemoFixtures.accountDocs,
        ]
        guard let fixture = fixtures[doctype] else {
            throw ERPNextError(
                message:
                    "\"\(doctype)\" documents aren't included in the demo data. Connect to an ERPNext server in Settings.")
        }
        let docs = try Document.list(from: Data(fixture.utf8))
        if let match = docs.first(where: { $0.name == name }) {
            return match
        }
        // Any document not individually fixtured gets a representative one, so
        // link navigation stays alive in demo mode.
        guard let first = docs.first else {
            throw ERPNextError(message: "No demo document for \(doctype)")
        }
        return first
    }
}
