import XCTest

@testable import ERPNextKit

final class HTMLRichTextTests: XCTestCase {
    typealias Run = HTMLRichText.Run

    /// The DCAA Incurred Cost Proposal Schedules message, as the server
    /// builds it (title, `<br>` lines, a link, muted note, warning list).
    func testReportMessageStructure() throws {
        let html = """
            <h4>Schedule K — Summary of Hours</h4><br>Wind Power LLC<br>Fiscal Year Ending 2026-12-31<br>\
            Manual inputs from draft <a href="https://erp.example.com/app/incurred-cost-proposal/ICP-2026">ICP-2026</a>.<br>\
            <span class='text-muted'>Prior years use billing rates.</span><br>\
            <div class='text-warning'><b>Review</b><ul><li>Contract projects without a Contract Number: NPSL</li>\
            <li>Second &amp; last: Schedule I&apos;s</li></ul></div>
            """
        let text = try XCTUnwrap(HTMLRichText(html: html))
        XCTAssertEqual(
            text.blocks,
            [
                .heading(level: 4, runs: [Run("Schedule K — Summary of Hours")]),
                .paragraph([Run("Wind Power LLC")]),
                .paragraph([Run("Fiscal Year Ending 2026-12-31")]),
                .paragraph([
                    Run("Manual inputs from draft "),
                    Run(
                        "ICP-2026",
                        link: "https://erp.example.com/app/incurred-cost-proposal/ICP-2026"),
                    Run("."),
                ]),
                .paragraph([Run("Prior years use billing rates.", tone: .muted)]),
                .paragraph([Run("Review", bold: true, tone: .warning)]),
                .listItem(
                    marker: "•", depth: 1,
                    runs: [Run("Contract projects without a Contract Number: NPSL", tone: .warning)]),
                .listItem(
                    marker: "•", depth: 1, runs: [Run("Second & last: Schedule I's", tone: .warning)]),
            ])
    }

    func testWhitespaceCollapsesAndEntitiesDecode() throws {
        let html = "<p>\n   Rate&nbsp;72.33%  &#8212; vs\t<em>plan</em> &#x2192; ok &bogus; </p>"
        let text = try XCTUnwrap(HTMLRichText(html: html))
        XCTAssertEqual(
            text.blocks,
            [.paragraph([Run("Rate\u{00A0}72.33% — vs "), Run("plan", italic: true), Run(" → ok &bogus;")])])
    }

    func testOrderedNestedListsAndLineBreaksInsideItems() throws {
        let html = """
            <ol><li>First<br>continued</li><li>Second<ul><li>Inner</li></ul></li></ol><p>After</p>
            """
        let text = try XCTUnwrap(HTMLRichText(html: html))
        XCTAssertEqual(
            text.blocks,
            [
                .listItem(marker: "1.", depth: 1, runs: [Run("First")]),
                .listItem(marker: nil, depth: 1, runs: [Run("continued")]),
                .listItem(marker: "2.", depth: 1, runs: [Run("Second")]),
                .listItem(marker: "•", depth: 2, runs: [Run("Inner")]),
                .paragraph([Run("After")]),
            ])
    }

    func testInnermostToneWinsAndStyleNests() throws {
        let html = """
            <div class="small text-danger">Over <b>budget <span class='text-success'>but</span></b>\
            <code>x</code></div>
            """
        let text = try XCTUnwrap(HTMLRichText(html: html))
        XCTAssertEqual(
            text.blocks,
            [
                .paragraph([
                    Run("Over ", tone: .danger),
                    Run("budget ", bold: true, tone: .danger),
                    Run("but", bold: true, tone: .success),
                    Run("x", code: true, tone: .danger),
                ])
            ])
    }

    func testSkipsScriptsCommentsAndUnknownMarkup() throws {
        let html = """
            <!-- note --><script>alert("<b>x</b>")</script><style>p{}</style>\
            <custom-tag data-x="1">Kept</custom-tag><img src="x.png"><hr><table><tr><th>A</th><td>1</td></tr></table>
            """
        let text = try XCTUnwrap(HTMLRichText(html: html))
        XCTAssertEqual(
            text.blocks,
            [
                .paragraph([Run("Kept")]),
                .rule,
                .paragraph([Run("A", bold: true), Run(" 1")]),
            ])
    }

    func testEmptyMarkupIsNil() {
        XCTAssertNil(HTMLRichText(html: "<br><div>  </div><ul><li> </li></ul>"))
        XCTAssertNil(HTMLRichText(html: ""))
    }

    func testReportResultKeepsTheMessageHTML() throws {
        let payload = """
            {"message": {"columns": ["A"], "result": [], "message": "<b>Hi</b>"}}
            """
        let result = try ReportResult.decode(from: Data(payload.utf8))
        XCTAssertEqual(result.messageHTML, "<b>Hi</b>")
        XCTAssertEqual(result.message, "Hi")
    }

    func testDeskURLTargets() {
        let base = URL(string: "https://erp.example.com")!
        XCTAssertEqual(
            DeskURL.target(
                of: URL(string: "https://erp.example.com/app/incurred-cost-proposal/ICP-2026")!,
                base: base),
            .document(slug: "incurred-cost-proposal", name: "ICP-2026"))
        XCTAssertEqual(
            DeskURL.target(of: URL(string: "/app/sales-invoice/ACC-SINV-2026-00001")!, base: nil),
            .document(slug: "sales-invoice", name: "ACC-SINV-2026-00001"))
        XCTAssertEqual(
            DeskURL.target(of: URL(string: "/app/query-report/General%20Ledger")!, base: base),
            .queryReport(name: "General Ledger"))
        XCTAssertNil(DeskURL.target(of: URL(string: "https://other.example.com/app/x/y")!, base: base))
        XCTAssertNil(DeskURL.target(of: URL(string: "/app/sales-invoice")!, base: base))
        XCTAssertNil(DeskURL.target(of: URL(string: "/app/sales-invoice/view/report")!, base: base))
        XCTAssertNil(DeskURL.target(of: URL(string: "https://erp.example.com/files/a.pdf")!, base: base))
    }
}
