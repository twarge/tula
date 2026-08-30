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
        XCTAssertEqual(bundle.metas.map(\.name), ["Sales Invoice", "Sales Invoice Item"])

        // Desk per-user grid settings ride along in the same response.
        XCTAssertEqual(
            bundle.gridColumns["Sales Invoice Item"]?.map(\.fieldname),
            ["item_code", "qty", "amount"])
        XCTAssertEqual(bundle.listSortBy, "posting_date")
        XCTAssertEqual(bundle.listSortDescending, true)

        let meta = bundle.metas[0]
        XCTAssertEqual(meta.titleField, "customer_name")
        XCTAssertEqual(
            meta.listFields.map(\.fieldname),
            ["customer_name", "posting_date", "grand_total", "status"])

        let layout = FormLayout.parse(meta)
        XCTAssertEqual(layout.tabs.map(\.label), ["Details", "More Info"])

        let details = layout.tabs[0]
        XCTAssertEqual(details.sections.count, 5)
        // The unlabeled continuation section merges into the Totals card at render.
        XCTAssertNil(details.sections[4].label)
        // First (implicit) section: three columns split by the two column breaks.
        XCTAssertEqual(details.sections[0].columns.count, 3)
        XCTAssertEqual(details.sections[0].columns[0].map(\.fieldname), ["customer", "customer_name"])
        // Items section holds the scan-barcode affordance plus the child table.
        XCTAssertEqual(details.sections[1].label, "Items")
        XCTAssertEqual(details.sections[1].tables.map(\.fieldname), ["items"])
        XCTAssertEqual(
            details.sections[1].columns.flatMap { $0 }.map(\.fieldname), ["scan_barcode"])
        XCTAssertTrue(meta.field(named: "scan_barcode")?.isScanBarcodeField ?? false)

        // Child meta drives the child-table columns.
        XCTAssertEqual(
            bundle.metas[1].listFields.map(\.fieldname),
            ["item_code", "item_name", "qty", "rate", "amount"])
    }

    func testHiddenFieldsExcludedFromLayout() throws {
        let bundle = try MetaDecoder.bundle(from: Data(DemoFixtures.accountMeta.utf8))
        let layout = FormLayout.parse(bundle.metas[0])
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

final class DependsOnTests: XCTestCase {
    private func makeDoc(_ raw: [String: FrappeValue]) -> Document {
        Document(raw: raw)
    }

    func testEvalExpressions() {
        let evaluator = DependsOnEvaluator(
            document: makeDoc([
                "is_return": .int(0), "status": .string("Paid"), "qty": .double(3),
            ]))
        XCTAssertFalse(evaluator.isVisible("eval:doc.is_return"))
        XCTAssertTrue(evaluator.isVisible("eval:!doc.is_return"))
        XCTAssertTrue(evaluator.isVisible("eval:doc.status == \"Paid\""))
        XCTAssertFalse(evaluator.isVisible("eval:doc.status != \"Paid\""))
        XCTAssertTrue(evaluator.isVisible("eval:doc.qty > 1 && !doc.is_return"))
        XCTAssertTrue(evaluator.isVisible("eval:in_list([\"Paid\", \"Unpaid\"], doc.status)"))
    }

    func testBareFieldnameAndDefaults() {
        let evaluator = DependsOnEvaluator(
            document: makeDoc(["customer": .string("Northwind"), "discount": .double(0)]))
        XCTAssertTrue(evaluator.isVisible("customer"))
        XCTAssertFalse(evaluator.isVisible("discount"))
        XCTAssertFalse(evaluator.isVisible("missing_field"))
        XCTAssertTrue(evaluator.isVisible(nil))
        XCTAssertTrue(evaluator.isVisible(""))
        // Unevaluable expressions fail open: show more, never less.
        XCTAssertTrue(evaluator.isVisible("eval:frappe.boot.something.unknowable"))
        XCTAssertTrue(evaluator.isVisible("eval:))broken(("))
    }
}

final class HTMLTableTests: XCTestCase {
    func testParsesDemoTaxBreakup() throws {
        let invoice = try Document.list(from: Data(DemoFixtures.salesInvoiceDocs.utf8))[0]
        let html = try XCTUnwrap(invoice["other_charges_calculation"]?.stringValue)
        let table = try XCTUnwrap(HTMLTable.firstTable(in: html))
        XCTAssertEqual(table.headers, ["Item", "Taxable Amount", "Shipping & Handling"])
        XCTAssertEqual(table.rows.count, 3)
        XCTAssertEqual(table.rows[0], ["WT-1000", "$ 7,400.00", "(5.0%) $ 370.00"])
        XCTAssertFalse(table.columnIsNumeric(0))
        XCTAssertTrue(table.columnIsNumeric(1))
        XCTAssertTrue(table.columnIsNumeric(2))
    }

    func testNonTableHTMLReturnsNil() {
        XCTAssertNil(HTMLTable.firstTable(in: "<p>Just a note</p>"))
        XCTAssertNil(HTMLTable.firstTable(in: "plain text"))
    }
}

final class ListViewSettingsTests: XCTestCase {
    func testParsesFieldsJSON() {
        let doc = Document(raw: [
            "name": .string("Sales Invoice"),
            "fields": .string(
                #"[{"fieldname":"status","label":"Status"},{"fieldname":"grand_total"}]"#),
        ])
        XCTAssertEqual(
            LiveDataSource.columns(fromListViewSettings: doc), ["status", "grand_total"])

        let empty = Document(raw: ["fields": .string("[]")])
        XCTAssertNil(LiveDataSource.columns(fromListViewSettings: empty))
    }
}

final class DeskURLTests: XCTestCase {
    private let base = URL(string: "https://erp.example.com")!

    func testDeskURLs() {
        XCTAssertEqual(DeskURL.slug("Sales Invoice"), "sales-invoice")
        XCTAssertEqual(
            DeskURL.list(base: base, doctype: "Sales Invoice").absoluteString,
            "https://erp.example.com/app/sales-invoice")
        XCTAssertEqual(
            DeskURL.document(base: base, doctype: "Sales Invoice", name: "ACC-SINV-2025-00042")
                .absoluteString,
            "https://erp.example.com/app/sales-invoice/ACC-SINV-2025-00042")
        XCTAssertEqual(
            DeskURL.queryReport(base: base, reportName: "Profit and Loss Statement")
                .absoluteString,
            "https://erp.example.com/app/query-report/Profit%20and%20Loss%20Statement")
    }

    func testNameNeedingEncoding() {
        // Account names routinely contain spaces and can contain slashes;
        // both must stay inside one path component.
        let url = DeskURL.document(base: base, doctype: "Account", name: "Repairs / Maintenance - TL")
        XCTAssertEqual(
            url.absoluteString,
            "https://erp.example.com/app/account/Repairs%20%2F%20Maintenance%20-%20TL")
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
        func metaBundle(for doctype: String) async throws -> MetaBundle { MetaBundle(metas: []) }
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
        let invoiceMeta = try MetaDecoder.bundle(from: Data(DemoFixtures.salesInvoiceMeta.utf8)).metas[0]
        XCTAssertEqual(
            invoiceMeta.standardFilterFields.map(\.fieldname), ["customer", "status"])

        let accountMeta = try MetaDecoder.bundle(from: Data(DemoFixtures.accountMeta.utf8)).metas[0]
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

final class ReportFilterParserTests: XCTestCase {
    /// Shaped like a real ERPNext report script: computed date defaults,
    /// session-company default, select options as newline string, a
    /// function-valued key, reqd/hidden flags.
    private let script = #"""
        frappe.query_reports["Accounts Receivable Summary"] = {
            "filters": [
                {
                    "fieldname": "company",
                    "label": __("Company"),
                    "fieldtype": "Link",
                    "options": "Company",
                    "default": frappe.defaults.get_user_default("Company"),
                    "reqd": 1
                },
                {
                    "fieldname": "report_date",
                    "label": __("Posting Date"),
                    "fieldtype": "Date",
                    "default": frappe.datetime.get_today()
                },
                {
                    "fieldname": "ageing_based_on",
                    "label": __("Ageing Based On"),
                    "fieldtype": "Select",
                    "options": "Posting Date\nDue Date",
                    "default": "Due Date"
                },
                {
                    "fieldname": "customer",
                    "label": __("Customer"),
                    "fieldtype": "Link",
                    "options": "Customer",
                    "get_query": function() { return { filters: { disabled: 0 } }; }
                },
                {
                    "fieldname": "show_future_payments",
                    "label": __("Show Future Payments"),
                    "fieldtype": "Check"
                },
                {
                    "fieldname": "party_hidden",
                    "fieldtype": "Data",
                    "hidden": 1
                }
            ]
        };
        """#

    func testParsesRealisticScript() throws {
        let defs = try XCTUnwrap(
            ReportFilterParser.definitions(
                reportName: "Accounts Receivable Summary", script: script,
                defaultCompany: "Wind Power LLC"))
        XCTAssertEqual(defs.count, 6)

        let company = defs[0]
        XCTAssertEqual(company.fieldtype, .link)
        XCTAssertEqual(company.options, "Company")
        XCTAssertEqual(company.defaultValue, "Wind Power LLC")
        XCTAssertTrue(company.required)

        let date = defs[1]
        XCTAssertEqual(date.fieldtype, .date)
        // Computed default resolves to a real yyyy-MM-dd date.
        XCTAssertNotNil(date.defaultValue)
        XCTAssertEqual(date.defaultValue?.count, 10)

        let ageing = defs[2]
        XCTAssertEqual(ageing.selectOptions, ["Posting Date", "Due Date"])
        XCTAssertEqual(ageing.defaultValue, "Due Date")

        XCTAssertEqual(defs[3].options, "Customer")
        XCTAssertEqual(defs[4].fieldtype, .check)
        XCTAssertTrue(defs[5].hidden)
    }

    func testBrokenScriptFailsOpen() {
        XCTAssertNil(
            ReportFilterParser.definitions(
                reportName: "X", script: "this is (((not js"))
        XCTAssertNil(
            ReportFilterParser.definitions(
                reportName: "X", script: "frappe.query_reports[\"Y\"] = {};"))
    }
}

final class SortCountAndSnapshotTests: XCTestCase {
    func testDemoSortAndCount() async throws {
        let demo = DemoDataSource()
        let ascending = try await demo.list(
            "Sales Invoice", fields: [], filters: [], orderBy: "posting_date asc",
            limitStart: 0, limitPageLength: 50)
        XCTAssertEqual(ascending.first?.name, "ACC-SINV-2025-00039")
        let descending = try await demo.list(
            "Sales Invoice", fields: [], filters: [], orderBy: "grand_total desc",
            limitStart: 0, limitPageLength: 50)
        XCTAssertEqual(descending.first?.name, "ACC-SINV-2025-00040")

        let total = try await demo.count("Sales Invoice", filters: [])
        XCTAssertEqual(total, 4)
        let paid = try await demo.count(
            "Sales Invoice", filters: [ListFilter("status", "=", .string("Paid"))])
        XCTAssertEqual(paid, 2)
    }

    func testReportResultCodableRoundTrip() throws {
        let original = try ReportResult.decode(from: Data(DemoFixtures.profitAndLoss.utf8))
        let encoded = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(ReportResult.self, from: encoded)
        XCTAssertEqual(decoded, original)
    }

    func testChartDecodes() throws {
        let result = try ReportResult.decode(from: Data(DemoFixtures.profitAndLoss.utf8))
        let chart = try XCTUnwrap(result.chart)
        XCTAssertEqual(chart.type, "bar")
        XCTAssertEqual(chart.labels.count, 4)
        XCTAssertEqual(chart.datasets.map(\.name), ["Income", "Expense"])
        XCTAssertEqual(chart.datasets[0].values[3], 268790.0)
    }

    func testDemoGlobalSearch() async throws {
        let demo = DemoDataSource()
        let hits = try await demo.globalSearch(query: "northwind")
        XCTAssertEqual(hits.count, 2)
        XCTAssertEqual(hits.first?.doctype, "Sales Invoice")
        let accounts = try await demo.globalSearch(query: "rent")
        XCTAssertEqual(accounts.map(\.name), ["Rent - WPL"])
        let empty = try await demo.globalSearch(query: "")
        XCTAssertTrue(empty.isEmpty)
    }

    func testDemoReportsCatalog() async throws {
        let reports = try await DemoDataSource().reports()
        XCTAssertEqual(reports.count, 5)
        XCTAssertEqual(reports.first?.module, "Accounts")
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
        let meta = try await demo.metaBundle(for: "Sales Invoice").metas[0]
        let itemsField = try XCTUnwrap(meta.field(named: "items"))
        XCTAssertEqual(invoice.childRows(for: itemsField).count, 3)
    }
}
