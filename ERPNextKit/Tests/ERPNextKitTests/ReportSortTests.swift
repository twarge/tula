import XCTest

@testable import ERPNextKit

final class ReportSortTests: XCTestCase {
    private func ledger() throws -> ReportResult {
        let payload = #"""
            {"message": {
              "columns": [
                {"fieldname": "posting_date", "label": "Posting Date", "fieldtype": "Date"},
                {"fieldname": "account", "label": "Account", "fieldtype": "Link", "options": "Account"},
                {"fieldname": "debit", "label": "Debit", "fieldtype": "Currency"}
              ],
              "result": [
                {"account": "'Opening'", "debit": 0},
                {"posting_date": "2026-09-08", "account": "5141 - Materials", "debit": 20},
                {"posting_date": "2026-09-06", "account": "1201 - Bank", "debit": 100},
                {"posting_date": "2026-09-07", "account": "2110 - Payable", "debit": null},
                {"posting_date": "2026-09-09", "account": "5144 - Freight", "debit": 5},
                {"account": "'Total'", "debit": 125},
                {},
                {"account": "'Closing (Opening + Total)'", "debit": 125}
              ]
            }}
            """#
        return try ReportResult.decode(from: Data(payload.utf8))
    }

    private func accounts(_ result: ReportResult) -> [String] {
        result.rows.map { $0.values["account"]?.stringValue ?? "—" }
    }

    func testNumericSortKeepsPseudoRowsAndPutsEmptyLast() throws {
        let ascending = try ledger().sorted(by: ReportSort(fieldname: "debit"))
        XCTAssertEqual(
            accounts(ascending),
            [
                "'Opening'", "5144 - Freight", "5141 - Materials", "1201 - Bank",
                "2110 - Payable", "'Total'", "—", "'Closing (Opening + Total)'",
            ])
        let descending = try ledger().sorted(by: ReportSort(fieldname: "debit", ascending: false))
        XCTAssertEqual(
            Array(accounts(descending)[1...4]),
            ["1201 - Bank", "5141 - Materials", "5144 - Freight", "2110 - Payable"])
    }

    func testDateAndTextSorts() throws {
        let byDate = try ledger().sorted(by: ReportSort(fieldname: "posting_date"))
        XCTAssertEqual(
            byDate.rows[1...4].compactMap { $0.values["posting_date"]?.stringValue },
            ["2026-09-06", "2026-09-07", "2026-09-08", "2026-09-09"])
        let byAccount = try ledger().sorted(by: ReportSort(fieldname: "account", ascending: false))
        XCTAssertEqual(
            Array(accounts(byAccount)[1...4]),
            ["5144 - Freight", "5141 - Materials", "2110 - Payable", "1201 - Bank"])
    }

    func testNoSortOrUnknownColumnKeepsReportOrder() throws {
        let original = try ledger()
        XCTAssertEqual(original.sorted(by: nil), original)
        XCTAssertEqual(original.sorted(by: ReportSort(fieldname: "nope")), original)
    }

    /// The P&L's account tree: children sort among their siblings and stay
    /// under their parent; the parent keeps its subtree with it.
    func testTreeSortKeepsHierarchy() throws {
        let original = try ReportResult.decode(from: Data(DemoFixtures.profitAndLoss.utf8))
        let sorted = original.sorted(by: ReportSort(fieldname: "total", ascending: false))
        XCTAssertEqual(sorted.rows.count, original.rows.count)
        XCTAssertEqual(Set(sorted.rows.map(\.id)), Set(original.rows.map(\.id)))

        // Rows that hold their place are where they were.
        for (index, row) in original.rows.enumerated() where row.holdsPlaceInSort {
            XCTAssertEqual(sorted.rows[index].id, row.id)
        }
        // Every row's parent (nearest shallower row above it) is unchanged.
        func parents(_ result: ReportResult) -> [Int: Int] {
            var map: [Int: Int] = [:]
            for (index, row) in result.rows.enumerated() where !row.holdsPlaceInSort {
                if let parent = result.rows[..<index].last(where: {
                    $0.indent < row.indent || $0.holdsPlaceInSort
                }), !parent.holdsPlaceInSort {
                    map[row.id] = parent.id
                }
            }
            return map
        }
        XCTAssertEqual(parents(sorted), parents(original))
        // Siblings under each parent are in descending total order.
        for (index, row) in sorted.rows.enumerated() where !row.holdsPlaceInSort {
            guard
                let next = sorted.rows[(index + 1)...].first(where: {
                    $0.indent <= row.indent || $0.holdsPlaceInSort
                }), next.indent == row.indent, !next.holdsPlaceInSort,
                let a = row.values["total"]?.doubleValue,
                let b = next.values["total"]?.doubleValue
            else { continue }
            XCTAssertGreaterThanOrEqual(a, b)
        }
    }

    func testHeaderClickCycle() {
        let first = ReportSort.next(after: nil, column: "debit")
        XCTAssertEqual(first, ReportSort(fieldname: "debit", ascending: true))
        let second = ReportSort.next(after: first, column: "debit")
        XCTAssertEqual(second, ReportSort(fieldname: "debit", ascending: false))
        XCTAssertNil(ReportSort.next(after: second, column: "debit"))
        XCTAssertEqual(
            ReportSort.next(after: second, column: "account"),
            ReportSort(fieldname: "account", ascending: true))
    }
}
