import ERPNextKit
import SwiftUI

/// Renders any `ReportResult` as a scrollable grid with a pinned header:
/// column types drive formatting/alignment, `indent` drives the account tree,
/// group rows embolden, and Frappe's quoted `'Total …'` rows get total
/// styling. No report-specific code — P&L, Balance Sheet, GL all land here.
/// The full report body — summary tiles, native chart, hierarchical grid —
/// shared by the financial-statement and generic report screens.
struct ReportResultView: View {
    let result: ReportResult
    let fallbackCurrency: String?
    var drillRoute: ((ReportRow) -> Route?)? = nil

    var body: some View {
        VStack(spacing: 0) {
            if !result.summary.isEmpty {
                SummaryTilesView(items: result.summary)
                Divider()
            }
            if let chart = result.chart {
                ReportChartView(chart: chart)
                Divider()
            }
            ReportTableView(
                result: result, fallbackCurrency: fallbackCurrency, drillRoute: drillRoute)
        }
    }
}

struct ReportTableView: View {
    let result: ReportResult
    let fallbackCurrency: String?
    /// When provided, first-column cells navigate (P&L account → GL).
    var drillRoute: ((ReportRow) -> Route?)? = nil

    private var columns: [ReportColumn] { result.visibleColumns }

    private func baseWidth(_ index: Int) -> CGFloat {
        let column = columns[index]
        return index == 0
            ? max(240, CGFloat(column.width))
            : min(220, max(110, CGFloat(column.width)))
    }

    var body: some View {
        GeometryReader { geometry in
            let natural = (0..<columns.count).reduce(CGFloat(0)) { $0 + baseWidth($1) }
            let extra = max(0, geometry.size.width - natural)

            ScrollView(.horizontal) {
                ScrollView(.vertical) {
                    LazyVStack(spacing: 0, pinnedViews: .sectionHeaders) {
                        Section {
                            ForEach(Array(result.rows.enumerated()), id: \.element.id) {
                                index, row in
                                rowView(row, index: index, firstColumnExtra: extra)
                            }
                        } header: {
                            headerRow(firstColumnExtra: extra)
                        }
                    }
                }
                // No .refreshable here: UIKit's refresh control breaks the
                // nested horizontal/vertical scroll geometry. Reports refresh
                // via the toolbar button and the auto-refresh probe.
                .frame(width: max(natural, geometry.size.width))
            }
        }
    }

    private func width(_ index: Int, extra: CGFloat) -> CGFloat {
        baseWidth(index) + (index == 0 ? extra : 0)
    }

    private func headerRow(firstColumnExtra extra: CGFloat) -> some View {
        HStack(spacing: 0) {
            ForEach(Array(columns.enumerated()), id: \.element.id) { index, column in
                Text(column.label)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .padding(.horizontal, 12)
                    .frame(
                        width: width(index, extra: extra),
                        alignment: column.fieldtype.isNumeric ? .trailing : .leading)
            }
        }
        .padding(.vertical, 8)
        .background(.bar)
        .overlay(alignment: .bottom) { Divider() }
    }

    @ViewBuilder
    private func rowView(_ row: ReportRow, index: Int, firstColumnExtra extra: CGFloat)
        -> some View {
        if row.isBlank {
            Color.clear.frame(height: 16)
        } else {
            let isGroup = result.isGroupRow(at: index)
            let isTotal = firstCellText(row).sourceWasQuoted

            HStack(spacing: 0) {
                ForEach(Array(columns.enumerated()), id: \.element.id) { columnIndex, column in
                    cell(row: row, column: column, isFirst: columnIndex == 0)
                        .padding(.horizontal, 12)
                        .padding(
                            .leading,
                            columnIndex == 0 ? CGFloat(row.indent) * 18 : 0)
                        .frame(
                            width: width(columnIndex, extra: extra),
                            alignment: column.fieldtype.isNumeric ? .trailing : .leading)
                }
            }
            .padding(.vertical, 6)
            .fontWeight(isGroup || isTotal ? .semibold : .regular)
            .background(isTotal ? AnyShapeStyle(.quaternary.opacity(0.5)) : AnyShapeStyle(.clear))
            .overlay(alignment: .top) {
                if isTotal { Divider() }
            }
            .overlay(alignment: .bottom) {
                Divider().opacity(0.35)
            }
        }
    }

    @ViewBuilder
    private func cell(row: ReportRow, column: ReportColumn, isFirst: Bool) -> some View {
        if isFirst {
            if let drillRoute, let route = drillRoute(row) {
                NavigationLink(value: route) {
                    Text(firstCellText(row).text)
                        .lineLimit(1)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Open in General Ledger")
            } else {
                Text(firstCellText(row).text)
                    .lineLimit(1)
            }
        } else {
            FieldValueView(
                fieldname: column.fieldname,
                fieldtype: column.fieldtype,
                options: column.fieldtype == .link ? column.options : nil,
                value: row[column],
                currencyCode: ValueFormatting.currencyCode(
                    options: column.options, rowValues: row.values, fallback: fallbackCurrency),
                precision: column.precision
            )
            .lineLimit(1)
        }
    }

    /// Financial statements prefer the short `account_name` over the
    /// company-suffixed `account`; total labels arrive quoted.
    private func firstCellText(_ row: ReportRow) -> (text: String, sourceWasQuoted: Bool) {
        let column = columns.first
        let raw =
            row.values["account_name"]?.nonEmptyString
            ?? column.flatMap { row[$0]?.nonEmptyString }
            ?? ""
        return (raw.strippingTotalQuotes, raw.isQuotedTotalLabel)
    }
}
