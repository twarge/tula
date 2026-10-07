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
    /// The filter inspector's per-report display checkboxes
    /// (`ReportDisplaySettings`).
    var showsSummary = true
    var showsChart = true
    /// The grid's sort (`result` arrives already sorted); headers set it.
    /// Nil leaves the headers inert.
    var sort: Binding<ReportSort?>? = nil
    /// Row + column → destination. A nil column means the row's label cell
    /// (whole-span drill); an amount cell passes its own column so the
    /// destination can narrow to that period.
    var drillRoute: ((ReportRow, ReportColumn?) -> Route?)? = nil
    /// What a cell's server-declared source (`ReportLink`) does when tapped;
    /// nil leaves links inert.
    var cellAction: ((ReportLink) -> ReportCellAction?)? = nil

    /// One scroll view, both axes, owns the whole body: the rows' lazy
    /// stack then sees the real visible region and builds only the rows on
    /// screen. (Inside a horizontal scroll view nested in a vertical one,
    /// the horizontal one was as tall as the report, so every row counted
    /// as visible and was built — tens of thousands of views on a long GL.)
    /// The tiles and chart scroll away with the rows and the navigation
    /// bar's large title collapses as it does in Mail.
    var body: some View {
        GeometryReader { geometry in
            let table = ReportTableView(
                result: result, fallbackCurrency: fallbackCurrency,
                viewportWidth: geometry.size.width, sort: sort, drillRoute: drillRoute,
                cellAction: cellAction)
            ScrollView([.vertical, .horizontal]) {
                VStack(alignment: .leading, spacing: 0) {
                    VStack(spacing: 0) {
                        if showsSummary, !result.summary.isEmpty {
                            SummaryTilesView(items: result.summary)
                            Divider()
                        }
                        if let rich = result.messageHTML.flatMap(HTMLRichText.init(html:)) {
                            // Desk shows the report's message above the grid:
                            // a title, notes, review warnings — formatted as
                            // there.
                            ReportMessageView(message: rich)
                                .padding(.horizontal, 16)
                                .padding(.vertical, 12)
                            Divider()
                        } else if let message = result.message {
                            // Report snapshots cached before the HTML was kept.
                            Text(message)
                                .font(.callout)
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 16)
                                .padding(.vertical, 10)
                            Divider()
                        }
                        if showsChart, let chart = result.chart {
                            ReportChartView(chart: chart)
                            Divider()
                        }
                    }
                    .frame(width: geometry.size.width)
                    // Only the grid scrolls sideways; this block holds still
                    // over the viewport.
                    .visualEffect { content, proxy in
                        content.offset(
                            x: -proxy.frame(in: .scrollView(axis: .horizontal)).minX)
                    }
                    table
                }
            }
            .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
            // No .refreshable here: UIKit's refresh control broke the nested
            // horizontal/vertical scroll geometry. Reports refresh via the
            // toolbar button and the auto-refresh probe.
        }
    }
}

/// A linked report cell either navigates or re-seeds the report's own
/// filters (a cross-reference between sections of one report).
enum ReportCellAction {
    case navigate(Route)
    case setFilters(() -> Void)
}

struct ReportTableView: View {
    let result: ReportResult
    let fallbackCurrency: String?
    /// The enclosing scroll view's width: the first column absorbs any
    /// slack, and wider tables scroll sideways.
    let viewportWidth: CGFloat
    /// Header clicks cycle a column ascending → descending → report order.
    var sort: Binding<ReportSort?>? = nil
    /// When provided, first-column cells navigate (P&L account → GL) and
    /// amount cells navigate scoped to their own column's period.
    var drillRoute: ((ReportRow, ReportColumn?) -> Route?)? = nil
    /// Server-declared cell links take precedence over the drill rules.
    var cellAction: ((ReportLink) -> ReportCellAction?)? = nil

    private var columns: [ReportColumn] { result.visibleColumns }

    private func baseWidth(_ index: Int) -> CGFloat {
        let column = columns[index]
        return index == 0
            ? max(240, CGFloat(column.width))
            : min(220, max(110, CGFloat(column.width)))
    }

    /// The grid inside the report body's two-axis scroll view
    /// (`ReportResultView`).
    var body: some View {
        let natural = (0..<columns.count).reduce(CGFloat(0)) { $0 + baseWidth($1) }
        let extra = max(0, viewportWidth - natural)

        VStack(spacing: 0) {
            headerRow(firstColumnExtra: extra)
                // Pinned by hand rather than with the lazy stack's pinned
                // section headers: this holds the header at the scroll
                // view's top once it would scroll past it.
                .visualEffect { content, proxy in
                    content.offset(
                        y: max(0, -proxy.frame(in: .scrollView(axis: .vertical)).minY))
                }
                .zIndex(1)
            LazyVStack(spacing: 0) {
                ForEach(Array(result.rows.enumerated()), id: \.element.id) { index, row in
                    rowView(row, index: index, firstColumnExtra: extra)
                }
            }
        }
        .frame(width: max(natural, viewportWidth))
    }

    private func width(_ index: Int, extra: CGFloat) -> CGFloat {
        baseWidth(index) + (index == 0 ? extra : 0)
    }

    private func headerRow(firstColumnExtra extra: CGFloat) -> some View {
        HStack(spacing: 0) {
            ForEach(Array(columns.enumerated()), id: \.element.id) { index, column in
                headerCell(column)
                    .padding(.horizontal, 12)
                    .frame(
                        width: width(index, extra: extra),
                        alignment: column.alignsTrailing ? .trailing : .leading)
                    .contentShape(Rectangle())
            }
        }
        .padding(.vertical, 8)
        .background(.bar)
        .overlay(alignment: .bottom) { Divider() }
    }

    /// A column title, and with a sort binding a button that sorts by the
    /// column. The sorted column's title turns primary with a chevron,
    /// leading on number columns so the title stays flush with the values.
    @ViewBuilder
    private func headerCell(_ column: ReportColumn) -> some View {
        let direction = sort?.wrappedValue.flatMap {
            $0.fieldname == column.fieldname ? $0.ascending : nil
        }
        let title = HStack(spacing: 3) {
            if column.alignsTrailing { chevron(direction) }
            Text(column.label)
                .lineLimit(1)
            if !column.alignsTrailing { chevron(direction) }
        }
        .font(.caption.weight(.semibold))
        .foregroundStyle(direction == nil ? .secondary : .primary)

        if let sort {
            Button {
                sort.wrappedValue = ReportSort.next(
                    after: sort.wrappedValue, column: column.fieldname)
            } label: {
                title.contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(column.label)
            .accessibilityValue(
                direction.map { $0 ? "Sorted ascending" : "Sorted descending" } ?? "")
            .accessibilityHint("Sorts the report by this column")
        } else {
            title
        }
    }

    @ViewBuilder
    private func chevron(_ ascending: Bool?) -> some View {
        if let ascending {
            Image(systemName: ascending ? "chevron.up" : "chevron.down")
                .imageScale(.small)
        }
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
                            alignment: column.alignsTrailing ? .trailing : .leading)
                }
            }
            .padding(.vertical, 6)
            .fontWeight(isGroup || isTotal || row.isBold ? .semibold : .regular)
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
        if let link = row.link(for: column), let action = cellAction?(link) {
            linked(plainCell(row: row, column: column, isFirst: isFirst), link: link, action: action)
        } else if isFirst {
            if let drillRoute, let route = drillRoute(row, nil) {
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
            let isLinkColumn = column.fieldtype == .link || column.fieldtype == .dynamicLink
            let valueView = FieldValueView(
                fieldname: column.fieldname,
                fieldtype: column.fieldtype,
                options: isLinkColumn ? column.options : nil,
                value: row[column],
                currencyCode: ValueFormatting.currencyCode(
                    options: column.options, rowValues: row.values, fallback: fallbackCurrency),
                precision: column.precision,
                selectable: false,
                rowValues: row.values
            )
            .lineLimit(1)
            if let drillRoute, row[column] != nil, let route = drillRoute(row, column) {
                NavigationLink(value: route) {
                    valueView.contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Open this period in General Ledger")
            } else {
                valueView
            }
        }
    }

    /// The cell's content without navigation, for a server-declared link to
    /// wrap.
    @ViewBuilder
    private func plainCell(row: ReportRow, column: ReportColumn, isFirst: Bool) -> some View {
        if isFirst {
            Text(firstCellText(row).text)
                .lineLimit(1)
        } else {
            FieldValueView(
                fieldname: column.fieldname,
                fieldtype: column.fieldtype,
                options: nil,
                value: row[column],
                currencyCode: ValueFormatting.currencyCode(
                    options: column.options, rowValues: row.values, fallback: fallbackCurrency),
                precision: column.precision,
                linkEnabled: false,
                selectable: false,
                rowValues: row.values
            )
            .lineLimit(1)
        }
    }

    @ViewBuilder
    private func linked<Content: View>(
        _ content: Content, link: ReportLink, action: ReportCellAction
    ) -> some View {
        switch action {
        case .navigate(let route):
            let navigation = NavigationLink(value: route) {
                content.foregroundStyle(.tint).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if case .document(let doctype, let name) = link {
                navigation.modifier(DocumentQuickViewModifier(doctype: doctype, name: name))
            } else {
                navigation
            }
        case .setFilters(let apply):
            Button(action: apply) {
                content.foregroundStyle(.tint).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
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
