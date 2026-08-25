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

    public func metaBundle(for doctype: String) async throws -> [DocTypeMeta] {
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
        switch doctype {
        case "Account":
            return try Document.list(from: Data(DemoFixtures.accountList.utf8))
        case "Sales Invoice":
            return try Document.list(from: Data(DemoFixtures.salesInvoiceList.utf8))
        default:
            return []
        }
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
