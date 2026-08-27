import XCTest

@testable import ERPNextKit

final class ReportDecodingTests: XCTestCase {
    func testProfitAndLossFixtureDecodes() throws {
        let result = try ReportResult.decode(from: Data(DemoFixtures.profitAndLoss.utf8))
        XCTAssertEqual(result.columns.count, 6)
        XCTAssertEqual(result.columns.first?.fieldtype, .data)
        XCTAssertEqual(result.columns.last?.fieldtype, .currency)
        XCTAssertEqual(result.rows.count, 18)
        XCTAssertEqual(result.summary.count, 3)

        // Row 0 (Income) is a group row because row 1 is nested deeper.
        XCTAssertTrue(result.isGroupRow(at: 0))
        XCTAssertFalse(result.isGroupRow(at: 2))

        // Spacer rows decode as blank.
        XCTAssertTrue(result.rows[6].isBlank)
        XCTAssertFalse(result.rows[0].isBlank)

        // Quoted total labels are detected and stripped.
        let totalRow = result.rows[5]
        let label = try XCTUnwrap(totalRow.values["account"]?.stringValue)
        XCTAssertTrue(label.isQuotedTotalLabel)
        XCTAssertEqual(label.strippingTotalQuotes, "Total Income (Credit)")

        // Quarter totals sum to the year total on the profit row.
        let profit = result.rows[17]
        let quarters = ["q1_2025", "q2_2025", "q3_2025", "q4_2025"]
            .compactMap { profit.values[$0]?.doubleValue }
        XCTAssertEqual(quarters.reduce(0, +), profit.values["total"]?.doubleValue)
    }

    func testLegacyStringColumnsAndArrayRows() throws {
        let payload = #"""
            {
              "message": {
                "columns": ["Account:Link/Account:200", "Posting Date:Date:100", "Debit:Currency:120"],
                "result": [
                  ["Sales - WPL", "2025-03-01", 1200.5],
                  ["Rent - WPL", "2025-03-02", 900]
                ]
              }
            }
            """#
        let result = try ReportResult.decode(from: Data(payload.utf8))
        XCTAssertEqual(result.columns.map(\.fieldname), ["account", "posting_date", "debit"])
        XCTAssertEqual(result.columns[0].fieldtype, .link)
        XCTAssertEqual(result.columns[0].options, "Account")
        XCTAssertEqual(result.columns[0].width, 200)
        XCTAssertEqual(result.columns[1].fieldtype, .date)
        XCTAssertEqual(result.rows.count, 2)
        XCTAssertEqual(result.rows[0].values["account"]?.stringValue, "Sales - WPL")
        XCTAssertEqual(result.rows[1].values["debit"]?.doubleValue, 900)
    }
}

final class MetaTests: XCTestCase {
    func testSalesInvoiceBundleAndLayout() throws {
        let bundle = try MetaDecoder.bundle(from: Data(DemoFixtures.salesInvoiceMeta.utf8))
        XCTAssertEqual(bundle.map(\.name), ["Sales Invoice", "Sales Invoice Item"])

        let meta = bundle[0]
        XCTAssertEqual(meta.titleField, "customer_name")
        XCTAssertEqual(
            meta.listFields.map(\.fieldname),
            ["customer_name", "posting_date", "grand_total", "status"])

        let layout = FormLayout.parse(meta)
        XCTAssertEqual(layout.tabs.map(\.label), ["Details", "More Info"])

        let details = layout.tabs[0]
        XCTAssertEqual(details.sections.count, 3)
        // First (implicit) section: three columns split by the two column breaks.
        XCTAssertEqual(details.sections[0].columns.count, 3)
        XCTAssertEqual(details.sections[0].columns[0].map(\.fieldname), ["customer", "customer_name"])
        // Items section holds the child table, not regular fields.
        XCTAssertEqual(details.sections[1].label, "Items")
        XCTAssertEqual(details.sections[1].tables.map(\.fieldname), ["items"])
        XCTAssertTrue(details.sections[1].columns.allSatisfy(\.isEmpty))

        // Child meta drives the child-table columns.
        XCTAssertEqual(
            bundle[1].listFields.map(\.fieldname),
            ["item_code", "item_name", "qty", "rate", "amount"])
    }

    func testHiddenFieldsExcludedFromLayout() throws {
        let bundle = try MetaDecoder.bundle(from: Data(DemoFixtures.accountMeta.utf8))
        let layout = FormLayout.parse(bundle[0])
        let fieldnames = layout.tabs.flatMap(\.sections).flatMap(\.columns).flatMap { $0 }
            .map(\.fieldname)
        XCTAssertFalse(fieldnames.contains("lft"))
        XCTAssertTrue(fieldnames.contains("account_name"))
    }
}

final class EndpointTests: XCTestCase {
    private let base = URL(string: "https://erp.example.com")!

    func testResourceListURL() throws {
        let endpoint = Endpoint.resourceList(
            doctype: "Fiscal Year",
            fields: ["name", "year_start_date"],
            filters: [ListFilter("disabled", "=", .int(0))],
            orderBy: "year_start_date desc", limitStart: 0, limitPageLength: 50)
        let url = try endpoint.url(relativeTo: base)
        XCTAssertEqual(url.path(percentEncoded: false), "/api/resource/Fiscal Year")
        let query = try XCTUnwrap(
            URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
        XCTAssertEqual(
            query.first { $0.name == "filters" }?.value, #"[["disabled","=",0]]"#)
        XCTAssertEqual(
            query.first { $0.name == "fields" }?.value, #"["name","year_start_date"]"#)
    }

    func testMethodURLAndBasePathPreserved() throws {
        let nestedBase = URL(string: "https://example.com/erp/")!
        let endpoint = Endpoint.method(.runQueryReport, parameters: ["report_name": "Balance Sheet"])
        let url = try endpoint.url(relativeTo: nestedBase)
        XCTAssertEqual(
            url.path(percentEncoded: false), "/erp/api/method/frappe.desk.query_report.run")
        XCTAssertTrue(try XCTUnwrap(url.query(percentEncoded: false)).contains("Balance Sheet"))
    }
}

final class FrappeValueTests: XCTestCase {
    func testBoolCoercions() {
        XCTAssertEqual(FrappeValue.int(1).boolValue, true)
        XCTAssertEqual(FrappeValue.int(0).boolValue, false)
        XCTAssertEqual(FrappeValue.string("1").boolValue, true)
        XCTAssertEqual(FrappeValue.bool(true).boolValue, true)
        XCTAssertNil(FrappeValue.null.boolValue)
    }

    func testNumericCoercions() {
        XCTAssertEqual(FrappeValue.int(7).doubleValue, 7)
        XCTAssertEqual(FrappeValue.double(7.5).intValue, 7)
        XCTAssertEqual(FrappeValue.string("7.5").doubleValue, 7.5)
    }
}

final class ChangeProbeTests: XCTestCase {
    /// A source whose list endpoint returns a single `modified` row, as the
    /// live probe query would.
    private struct StubSource: DataSource {
        var displayName: String { "stub" }
        func ping() async throws {}
        func companies() async throws -> [Company] { [] }
        func fiscalYears() async throws -> [FiscalYear] { [] }
        func runReport(_ name: String, filters: [String: FrappeValue]) async throws
            -> ReportResult {
            throw ERPNextError(message: "unused")
        }
        func metaBundle(for doctype: String) async throws -> [DocTypeMeta] { [] }
        func list(
            _ doctype: String, fields: [String], filters: [ListFilter],
            orderBy: String?, limitStart: Int, limitPageLength: Int
        ) async throws -> [Document] {
            XCTAssertEqual(fields, ["modified"])
            XCTAssertEqual(orderBy, "modified desc")
            XCTAssertEqual(limitPageLength, 1)
            return [Document(raw: ["modified": .string("2026-08-24 10:15:03.120943")])]
        }
        func document(_ doctype: String, name: String) async throws -> Document {
            throw ERPNextError(message: "unused")
        }
    }

    func testProbeReturnsLatestModified() async throws {
        let signal = try await StubSource().latestModified("GL Entry")
        XCTAssertEqual(signal, "2026-08-24 10:15:03.120943")
    }

    func testDemoHasNoChangeSignal() async throws {
        // Demo fixtures never change; the probe must return nil so screens
        // don't churn.
        let signal = try await DemoDataSource().latestModified("GL Entry")
        XCTAssertNil(signal)
    }
}

final class QuickFilterTests: XCTestCase {
    func testStandardFilterFieldsFromMeta() throws {
        let invoiceMeta = try MetaDecoder.bundle(from: Data(DemoFixtures.salesInvoiceMeta.utf8))[0]
        XCTAssertEqual(
            invoiceMeta.standardFilterFields.map(\.fieldname), ["customer", "status"])

        let accountMeta = try MetaDecoder.bundle(from: Data(DemoFixtures.accountMeta.utf8))[0]
        XCTAssertEqual(accountMeta.standardFilterFields.map(\.fieldname), ["root_type"])
    }

    func testDemoAppliesEqualityAndLikeFilters() async throws {
        let demo = DemoDataSource()
        let paid = try await demo.list(
            "Sales Invoice", fields: [], filters: [ListFilter("status", "=", .string("Paid"))],
            orderBy: nil, limitStart: 0, limitPageLength: 50)
        XCTAssertEqual(paid.count, 2)

        let northwindPaid = try await demo.list(
            "Sales Invoice", fields: [],
            filters: [
                ListFilter("status", "=", .string("Paid")),
                ListFilter("customer", "=", .string("Northwind Research")),
            ],
            orderBy: nil, limitStart: 0, limitPageLength: 50)
        XCTAssertEqual(northwindPaid.map(\.name), ["ACC-SINV-2025-00042"])

        let grant = try await demo.list(
            "Sales Invoice", fields: [],
            filters: [ListFilter("customer_name", "like", .string("%grant%"))],
            orderBy: nil, limitStart: 0, limitPageLength: 50)
        XCTAssertEqual(grant.count, 1)
    }

    func testDemoSearchLink() async throws {
        let demo = DemoDataSource()
        let all = try await demo.searchLink(doctype: "Customer", query: "")
        XCTAssertEqual(all.count, 3)
        let north = try await demo.searchLink(doctype: "Customer", query: "north")
        XCTAssertEqual(north.map(\.value), ["Northwind Research"])
    }

    /// Regression: the app always calls through `any DataSource`. When
    /// searchLink was extension-only, this dispatched to the empty default
    /// and autocomplete silently returned nothing everywhere.
    func testSearchLinkDispatchesThroughExistential() async throws {
        let source: any DataSource = DemoDataSource()
        let results = try await source.searchLink(doctype: "Customer", query: "")
        XCTAssertEqual(results.count, 3)
    }
}

final class DemoDataSourceTests: XCTestCase {
    func testDemoServesEveryFixtureThroughTheLivePipeline() async throws {
        let demo = DemoDataSource()
        _ = try await demo.companies()
        _ = try await demo.fiscalYears()
        let pnl = try await demo.runReport(
            StandardReports.profitAndLoss.name,
            filters: StandardReports.profitAndLoss.filters(for: FinancialFilterState()))
        XCTAssertFalse(pnl.rows.isEmpty)
        _ = try await demo.runReport(StandardReports.balanceSheet.name, filters: [:])
        _ = try await demo.metaBundle(for: "Account")
        _ = try await demo.metaBundle(for: "Sales Invoice")

        let invoices = try await demo.list(
            "Sales Invoice", fields: [], filters: [], orderBy: nil, limitStart: 0,
            limitPageLength: 20)
        XCTAssertEqual(invoices.count, 4)

        let invoice = try await demo.document("Sales Invoice", name: "ACC-SINV-2025-00042")
        let meta = try await demo.metaBundle(for: "Sales Invoice")[0]
        let itemsField = try XCTUnwrap(meta.field(named: "items"))
        XCTAssertEqual(invoice.childRows(for: itemsField).count, 3)
    }
}
