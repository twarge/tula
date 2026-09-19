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
        let quarters = ["mar_2025", "jun_2025", "sep_2025", "dec_2025"]
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

    func testRepeatedChildDoctypeCollapses() throws {
        // getdoctype appends one child meta per Table field, so two tables of
        // the same child DocType repeat it in `docs`.
        let json = """
            {"docs": [
              {"name": "Cost Pool", "fields": [
                {"fieldname": "debit_accounts", "fieldtype": "Table", "options": "Cost Pool Account"},
                {"fieldname": "credit_accounts", "fieldtype": "Table", "options": "Cost Pool Account"}]},
              {"name": "Cost Pool Account", "istable": 1, "fields": []},
              {"name": "Cost Pool Account", "istable": 1, "fields": []}
            ]}
            """
        let bundle = try MetaDecoder.bundle(from: Data(json.utf8))
        XCTAssertEqual(bundle.metas.map(\.name), ["Cost Pool", "Cost Pool Account"])
        XCTAssertEqual(Array(bundle.childMetas.keys), ["Cost Pool Account"])

        // Hand-built bundles may still repeat; the accessor must not trap.
        let repeated = MetaBundle(metas: bundle.metas + [bundle.metas[1]])
        XCTAssertEqual(repeated.childMetas.count, 1)
    }

    func testTableMultiSelectFlowsWithFields() throws {
        // Desk renders Table MultiSelect as a pill input among the fields,
        // keyed on the child DocType's first Link field.
        let json = """
            {"docs": [
              {"name": "Cost Pool", "fields": [
                {"fieldname": "title", "fieldtype": "Data", "label": "Title"},
                {"fieldname": "accounts", "fieldtype": "Table MultiSelect",
                 "label": "Accounts", "options": "Cost Pool Account"},
                {"fieldname": "lines", "fieldtype": "Table", "options": "Cost Pool Line"}]},
              {"name": "Cost Pool Account", "istable": 1, "fields": [
                {"fieldname": "note", "fieldtype": "Data"},
                {"fieldname": "account", "fieldtype": "Link", "options": "Account"}]},
              {"name": "Cost Pool Line", "istable": 1, "fields": []}
            ]}
            """
        let bundle = try MetaDecoder.bundle(from: Data(json.utf8))
        let section = FormLayout.parse(bundle.metas[0]).tabs[0].sections[0]
        XCTAssertEqual(section.columns.flatMap { $0 }.map(\.fieldname), ["title", "accounts"])
        XCTAssertEqual(section.tables.map(\.fieldname), ["lines"])
        XCTAssertEqual(
            bundle.childMetas["Cost Pool Account"]?.multiSelectLinkField?.fieldname, "account")
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

final class NumberInputTests: XCTestCase {
    func testGroupingAndDecimalFollowTheLocale() {
        let us = Locale(identifier: "en_US")
        XCTAssertEqual(NumberInput.double(from: "100,000", locale: us), 100_000)
        XCTAssertEqual(NumberInput.double(from: "1,442,593.4025", locale: us), 1_442_593.4025)
        XCTAssertEqual(NumberInput.double(from: "$ 1,000.50", locale: us), 1000.5)
        XCTAssertEqual(NumberInput.double(from: "-2.5", locale: us), -2.5)
        XCTAssertEqual(NumberInput.double(from: "3.", locale: us), 3)
        // In-progress typing keeps tracking the digits so far.
        XCTAssertEqual(NumberInput.double(from: "100,", locale: us), 100)
        XCTAssertNil(NumberInput.double(from: "", locale: us))
        XCTAssertNil(NumberInput.double(from: "-", locale: us))

        let de = Locale(identifier: "de_DE")
        XCTAssertEqual(NumberInput.double(from: "100.000", locale: de), 100_000)
        XCTAssertEqual(NumberInput.double(from: "1.234,5", locale: de), 1234.5)
    }

    func testIntegersRejectFractions() {
        let us = Locale(identifier: "en_US")
        XCTAssertEqual(NumberInput.int(from: "100,000", locale: us), 100_000)
        XCTAssertNil(NumberInput.int(from: "1.5", locale: us))
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

final class WriteClientTests: XCTestCase {
    func testOpenCountParsingBothDialects() throws {
        let modern = """
            {"message": {"count": {
              "external_links_found": [
                {"doctype": "Purchase Order", "count": 37, "open_count": 13},
                {"doctype": "Supplier Quotation", "count": 28, "open_count": 0},
                {"doctype": "Stock Entry", "count": "?", "open_count": 0}
              ],
              "internal_links_found": [
                {"doctype": "Sales Order", "open_count": 0, "count": 2,
                 "names": ["SO-1", "SO-2"]}
              ]}}}
            """
        let counts = try XCTUnwrap(LiveDataSource.parseOpenCounts(Data(modern.utf8)))
        XCTAssertEqual(counts["Purchase Order"], LinkCount(total: 37, open: 13))
        XCTAssertEqual(counts["Supplier Quotation"], LinkCount(total: 28, open: 0))
        // "?" (statement timeout) parses as no total rather than zero.
        XCTAssertEqual(counts["Stock Entry"], LinkCount(total: nil, open: 0))
        XCTAssertEqual(
            counts["Sales Order"],
            LinkCount(total: 2, open: 0, names: ["SO-1", "SO-2"]))

        let legacy = """
            {"message": {"count": [
              {"name": "Payment Entry", "count": 2, "open_count": 1}]}}
            """
        let legacyCounts = try XCTUnwrap(LiveDataSource.parseOpenCounts(Data(legacy.utf8)))
        XCTAssertEqual(legacyCounts["Payment Entry"], LinkCount(total: 2, open: 1))
    }

    func testDashboardSpecParsing() throws {
        let bundle = try MetaDecoder.bundle(from: Data(DemoFixtures.salesInvoiceMeta.utf8))
        let spec = try XCTUnwrap(bundle.metas.first?.dashboard)
        XCTAssertEqual(spec.transactions.map(\.label), ["Payment", "Reference", "Returns"])
        XCTAssertEqual(spec.transactions[0].doctypes, ["Payment Entry", "Journal Entry"])
        // Non-standard fieldname override wins over the default fieldname.
        XCTAssertEqual(
            spec.filters(linking: "Payment Entry", to: "SI-1"),
            ["reference_name": "SI-1"])
        XCTAssertEqual(
            spec.filters(linking: "Sales Invoice", to: "SI-1"), ["return_against": "SI-1"])
        // Internal links produce no list filters — their names come from the doc.
        XCTAssertNil(spec.filters(linking: "Sales Order", to: "SI-1"))
        XCTAssertEqual(spec.internalLinks["Sales Order"], ["items", "sales_order"])

        // Dynamic links add the party_type-style second filter.
        let supplierDashboard = """
            {"fieldname": "supplier",
             "non_standard_fieldnames": {"Payment Entry": "party"},
             "dynamic_links": {"party": ["Supplier", "party_type"]},
             "transactions": [{"label": "Payments", "items": ["Payment Entry"]}]}
            """
        let party = DashboardSpec(raw: try FrappeValue.decode(from: Data(supplierDashboard.utf8)))
        XCTAssertEqual(
            party?.filters(linking: "Payment Entry", to: "ACME"),
            ["party": "ACME", "party_type": "Supplier"])
    }

    func testUserSettingsSortMerge() throws {
        let existing = #"{"GridView": {"Sales Invoice Item": [{"fieldname": "item_code"}]}, "List": {"sort_by": "modified", "sort_order": "desc"}}"#
        let merged = WriteSession.mergedListSort(
            into: existing, sortBy: "posting_date", descending: false)
        // The GridView blob survives the sort write untouched.
        XCTAssertNotNil(merged["GridView"]?.objectValue?["Sales Invoice Item"])
        XCTAssertEqual(
            merged["List"]?.objectValue?["sort_by"]?.stringValue, "posting_date")
        XCTAssertEqual(merged["List"]?.objectValue?["sort_order"]?.stringValue, "asc")
        // No existing blob: a fresh settings object.
        let fresh = WriteSession.mergedListSort(into: nil, sortBy: "name", descending: true)
        XCTAssertEqual(fresh["List"]?.objectValue?["sort_order"]?.stringValue, "desc")
    }

    func testBulkParameterShaping() throws {
        XCTAssertEqual(
            WriteSession.jsonList(["ACC-SINV-2025-00042", "ACC-SINV-2025-00041"]),
            #"["ACC-SINV-2025-00042","ACC-SINV-2025-00041"]"#)
        XCTAssertEqual(WriteSession.jsonList([]), "[]")
    }

    func testAmendSeed() throws {
        let doc = try Document.list(from: Data(DemoFixtures.salesInvoiceDocs.utf8))[0]
        let seed = WriteSession.draftCopy(
            of: doc.raw, doctype: "Sales Invoice", amendedFrom: doc.name)
        XCTAssertEqual(seed["amended_from"]?.stringValue, "ACC-SINV-2025-00042")
        XCTAssertNil(seed["name"])
        XCTAssertNil(seed["docstatus"])
        XCTAssertEqual(seed["doctype"]?.stringValue, "Sales Invoice")
    }

    func testDuplicableRawStripsSystemFields() throws {
        let doc = try Document.list(from: Data(DemoFixtures.salesInvoiceDocs.utf8))[0]
        let copy = WriteSession.duplicableRaw(doc.raw, doctype: "Sales Invoice")
        XCTAssertNil(copy["name"])
        XCTAssertNil(copy["docstatus"])
        XCTAssertNil(copy["_assign"])
        XCTAssertEqual(copy["doctype"]?.stringValue, "Sales Invoice")
        XCTAssertEqual(copy["customer"]?.stringValue, "Northwind Research")
        let items = try XCTUnwrap(copy["items"]?.arrayValue)
        XCTAssertEqual(items.count, 3)
        XCTAssertNil(items[0].objectValue?["name"])
        XCTAssertEqual(items[0].objectValue?["item_code"]?.stringValue, "WT-1000")
    }


    func testMultipartBodyShape() {
        let body = WriteClient.multipartBody(
            boundary: "B", fileName: "a b.pdf", fileData: Data("XYZ".utf8),
            fields: ["doctype": "Sales Invoice", "docname": "SINV-1", "is_private": "1"])
        let text = String(decoding: body, as: UTF8.self)
        XCTAssertTrue(text.contains("--B\r\nContent-Disposition: form-data; name=\"doctype\"\r\n\r\nSales Invoice\r\n"))
        XCTAssertTrue(text.contains("name=\"file\"; filename=\"a b.pdf\""))
        XCTAssertTrue(text.contains("XYZ\r\n--B--\r\n"))
        XCTAssertTrue(text.hasSuffix("--B--\r\n"))
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

final class FinancialPeriodsTests: XCTestCase {
    func testQuarterlyCalendarYear() {
        let periods = FinancialPeriods.periods(
            spanStart: "2025-01-01", spanEnd: "2025-12-31",
            periodicity: .quarterly, alignsFirstPeriodToMonth: false)
        XCTAssertEqual(periods.map(\.key), ["mar_2025", "jun_2025", "sep_2025", "dec_2025"])
        XCTAssertEqual(periods.first?.fromDate, "2025-01-01")
        XCTAssertEqual(periods.first?.toDate, "2025-03-31")
        XCTAssertEqual(periods.last?.fromDate, "2025-10-01")
        XCTAssertEqual(periods.last?.toDate, "2025-12-31")
    }

    func testMonthlyOffsetFiscalYear() {
        // An Apr–Mar fiscal year: keys cross the calendar-year boundary.
        let periods = FinancialPeriods.periods(
            spanStart: "2025-04-01", spanEnd: "2026-03-31",
            periodicity: .monthly, alignsFirstPeriodToMonth: false)
        XCTAssertEqual(periods.count, 12)
        XCTAssertEqual(periods.first?.key, "apr_2025")
        XCTAssertEqual(periods.last?.key, "mar_2026")
        XCTAssertEqual(periods[9].fromDate, "2026-01-01")
        XCTAssertEqual(periods[9].toDate, "2026-01-31")
    }

    func testDateRangeFirstPeriodEndsAtMonthBoundary() {
        // Server: the first Date Range period runs from the raw start date to
        // add_months(get_first_day(start), n) - 1 day.
        let monthly = FinancialPeriods.periods(
            spanStart: "2025-01-15", spanEnd: "2025-04-30",
            periodicity: .monthly, alignsFirstPeriodToMonth: true)
        XCTAssertEqual(monthly.map(\.key), ["jan_2025", "feb_2025", "mar_2025", "apr_2025"])
        XCTAssertEqual(monthly.first?.fromDate, "2025-01-15")
        XCTAssertEqual(monthly.first?.toDate, "2025-01-31")
        XCTAssertEqual(monthly[1].fromDate, "2025-02-01")

        let quarterly = FinancialPeriods.periods(
            spanStart: "2025-01-15", spanEnd: "2025-04-30",
            periodicity: .quarterly, alignsFirstPeriodToMonth: true)
        XCTAssertEqual(quarterly.map(\.key), ["mar_2025", "apr_2025"])
        XCTAssertEqual(quarterly[1].fromDate, "2025-04-01")
        XCTAssertEqual(quarterly[1].toDate, "2025-04-30")
    }

    func testFinalPeriodClampsToSpanEnd() {
        // Yearly periodicity over a 15-month span: the second "year" is the
        // 3-month remainder, exactly as the server clamps it.
        let periods = FinancialPeriods.periods(
            spanStart: "2025-01-01", spanEnd: "2026-03-31",
            periodicity: .yearly, alignsFirstPeriodToMonth: false)
        XCTAssertEqual(periods.map(\.key), ["dec_2025", "mar_2026"])
        XCTAssertEqual(periods.last?.fromDate, "2026-01-01")
        XCTAssertEqual(periods.last?.toDate, "2026-03-31")
    }

    func testDegenerateSpansAreEmpty() {
        XCTAssertTrue(
            FinancialPeriods.periods(
                spanStart: "2025-06-30", spanEnd: "2025-01-01",
                periodicity: .monthly, alignsFirstPeriodToMonth: false
            ).isEmpty)
        XCTAssertTrue(
            FinancialPeriods.periods(
                spanStart: "garbage", spanEnd: "2025-01-01",
                periodicity: .monthly, alignsFirstPeriodToMonth: false
            ).isEmpty)
    }
}

final class GeneralLedgerFilterStateTests: XCTestCase {
    func testRouteOptionsRoundTrip() {
        let state = GeneralLedgerFilterState(
            fromDate: "2025-10-01", toDate: "2025-12-31", account: "Marketing - WPL",
            project: "Turbine Retrofit", costCenter: "Main - WPL",
            financeBook: "Consolidated", presentationCurrency: "EUR",
            includeDefaultBookEntries: false)
        XCTAssertEqual(GeneralLedgerFilterState(routeOptions: state.routeOptions), state)
        XCTAssertEqual(GeneralLedgerFilterState(routeOptions: [:]), GeneralLedgerFilterState())
    }

    func testApplySendsDeskWireShapes() {
        var filters: [String: FrappeValue] = [
            "company": .string("Wind Power LLC"),
            "from_date": .string("2025-01-01"),
            "to_date": .string("2025-12-31"),
            "group_by": .string("Group by Voucher (Consolidated)"),
        ]
        var state = GeneralLedgerFilterState(account: "Marketing - WPL")
        state.fromDate = "2025-10-01"
        state.apply(to: &filters)

        // Explicit dates override the fiscal-year fallback; unset ones keep it.
        XCTAssertEqual(filters["from_date"], .string("2025-10-01"))
        XCTAssertEqual(filters["to_date"], .string("2025-12-31"))
        // Scoping filters travel as one-element MultiSelectList arrays.
        XCTAssertEqual(filters["account"], .array([.string("Marketing - WPL")]))
        XCTAssertNil(filters["project"])
        // Both grouping spellings: group_by (≤ v15) and categorize_by (v16).
        XCTAssertEqual(filters["group_by"], .string("Group by Voucher (Consolidated)"))
        XCTAssertEqual(
            filters["categorize_by"], .string("Categorize by Voucher (Consolidated)"))
        XCTAssertEqual(filters["include_default_book_entries"], .int(1))
    }
}

final class ReportDrillRulesTests: XCTestCase {
    private let numeric = ReportColumn(
        value: .object([
            "fieldname": .string("outstanding"), "label": .string("Outstanding Amount"),
            "fieldtype": .string("Currency"),
        ]), index: 1)!

    func testReceivableSummaryDrillsToDetail() {
        let drill = ReportDrillRules.drill(
            report: "Accounts Receivable Summary",
            row: ["party": .string("Grant Plastics Ltd."), "outstanding": .double(1200)],
            column: numeric,
            filters: [
                "company": .string("Wind Power LLC"),
                "report_date": .string("2025-12-31"),
                "party_type": .string("Customer"),
                "cost_center": .array([.string("Main - WPL")]),
            ])
        XCTAssertEqual(drill?.report, "Accounts Receivable")
        XCTAssertEqual(drill?.options["party"], .array([.string("Grant Plastics Ltd.")]))
        XCTAssertEqual(drill?.options["report_date"], .string("2025-12-31"))
        XCTAssertEqual(drill?.options["cost_center"], .array([.string("Main - WPL")]))

        // Text cells and total rows don't drill.
        XCTAssertNil(
            ReportDrillRules.drill(
                report: "Accounts Receivable Summary",
                row: ["party": .string("Grant Plastics Ltd.")], column: nil, filters: [:]))
        XCTAssertNil(
            ReportDrillRules.drill(
                report: "Accounts Receivable Summary",
                row: ["party": .string("'Total'")], column: numeric, filters: [:]))
    }

    func testStockBalanceDrillsToStockLedger() {
        let drill = ReportDrillRules.drill(
            report: "Stock Balance",
            row: [
                "item_code": .string("TURBINE-BLADE"),
                "warehouse": .string("Stores - WPL"),
                "bal_qty": .double(14),
            ],
            column: numeric,
            filters: [
                "company": .string("Wind Power LLC"),
                "from_date": .string("2025-01-01"), "to_date": .string("2025-12-31"),
            ])
        XCTAssertEqual(drill?.report, "Stock Ledger")
        XCTAssertEqual(drill?.options["item_code"], .string("TURBINE-BLADE"))
        XCTAssertEqual(drill?.options["warehouse"], .string("Stores - WPL"))
        XCTAssertEqual(drill?.options["from_date"], .string("2025-01-01"))
    }

    func testTrialBalanceForPartyDrillsToGL() {
        let drill = ReportDrillRules.drill(
            report: "Trial Balance for Party",
            row: ["party": .string("Northwind Research")],
            column: numeric,
            filters: [
                "company": .string("Wind Power LLC"),
                "from_date": .string("2025-01-01"), "to_date": .string("2025-12-31"),
                "party_type": .string("Customer"),
            ])
        XCTAssertEqual(drill?.report, "General Ledger")
        XCTAssertEqual(drill?.options["party"], .array([.string("Northwind Research")]))
        XCTAssertEqual(drill?.options["party_type"], .string("Customer"))
    }

    func testBudgetVarianceActualColumnParsing() {
        // Offset fiscal year: Jan belongs to the FY's closing calendar year.
        let years = [FiscalYear(name: "2025-2026", startDate: "2025-04-01", endDate: "2026-03-31")]
        let actualJan = ReportColumn(
            value: .object([
                "fieldname": .string("actual_(jan)_2025_2026"),
                "label": .string("Actual (Jan) 2025-2026"),
                "fieldtype": .string("Float"),
            ]), index: 3)!
        let row: [String: FrappeValue] = [
            "budget_against": .string("Main - WPL"), "account": .string("Marketing - WPL"),
        ]
        let filters: [String: FrappeValue] = [
            "company": .string("Wind Power LLC"), "budget_against": .string("Cost Center"),
        ]
        let drill = ReportDrillRules.drill(
            report: "Budget Variance Report", row: row, column: actualJan,
            filters: filters, fiscalYears: years)
        XCTAssertEqual(drill?.report, "General Ledger")
        XCTAssertEqual(drill?.options["from_date"], .string("2026-01-01"))
        XCTAssertEqual(drill?.options["to_date"], .string("2026-01-31"))
        XCTAssertEqual(drill?.options["cost_center"], .array([.string("Main - WPL")]))
        XCTAssertEqual(drill?.options["account"], .array([.string("Marketing - WPL")]))

        // Quarterly suffix spans months; yearly has no suffix.
        XCTAssertEqual(
            ReportDrillRules.monthSpan("Oct-Dec", in: years[0])?.start, "2025-10-01")
        XCTAssertEqual(
            ReportDrillRules.monthSpan("Oct-Dec", in: years[0])?.end, "2025-12-31")
        let yearly = ReportColumn(
            value: .object([
                "fieldname": .string("actual_2025_2026"),
                "label": .string("Actual 2025-2026"),
                "fieldtype": .string("Float"),
            ]), index: 3)!
        let yearlyDrill = ReportDrillRules.drill(
            report: "Budget Variance Report", row: row, column: yearly,
            filters: filters, fiscalYears: years)
        XCTAssertEqual(yearlyDrill?.options["from_date"], .string("2025-04-01"))
        XCTAssertEqual(yearlyDrill?.options["to_date"], .string("2026-03-31"))

        // Budget columns never drill (not ledger-backed).
        let budget = ReportColumn(
            value: .object([
                "fieldname": .string("budget_(jan)_2025_2026"),
                "label": .string("Budget (Jan) 2025-2026"),
                "fieldtype": .string("Float"),
            ]), index: 2)!
        XCTAssertNil(
            ReportDrillRules.drill(
                report: "Budget Variance Report", row: row, column: budget,
                filters: filters, fiscalYears: years))
    }

    func testCategorizeByTravelsBothSpellings() {
        var filters: [String: FrappeValue] = [:]
        var state = GeneralLedgerFilterState()
        state.categorizeBy = "Account"
        state.apply(to: &filters)
        XCTAssertEqual(filters["group_by"], .string("Group by Account"))
        XCTAssertEqual(filters["categorize_by"], .string("Categorize by Account"))
    }

    func testMultiSelectListFilterParses() throws {
        // frappe.provide leads Desk's heavier report scripts (Accounts
        // Receivable et al) — the stub must survive it.
        let script = #"""
            frappe.provide("erpnext.utils");
            frappe.query_reports["Party Demo"] = {
                filters: [
                    { fieldname: "company", fieldtype: "Link", options: "Company" },
                    { fieldname: "party", fieldtype: "MultiSelectList", options: "party_type" }
                ]
            };
            erpnext.utils.add_dimensions("Party Demo", 9);
            """#
        let definitions = try XCTUnwrap(
            ReportFilterParser.definitions(reportName: "Party Demo", script: script))
        XCTAssertEqual(definitions.count, 2)
        XCTAssertFalse(definitions[0].isMultiSelect)
        XCTAssertTrue(definitions[1].isMultiSelect)
    }
}
