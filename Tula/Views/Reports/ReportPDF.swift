import ERPNextKit
import SwiftUI

/// Native PDF export for reports (ARCHITECTURE.md §12 Phase 5): the result is
/// re-rendered by a print-styled SwiftUI view and drawn into a single-page
/// PDF via `ImageRenderer` — no Desk print formats, no WebKit.
@MainActor
enum ReportPDF {
    static func render(
        title: String, subtitle: String?, result: ReportResult, fallbackCurrency: String?
    ) -> URL? {
        let content = ReportPrintView(
            title: title, subtitle: subtitle, result: result,
            fallbackCurrency: fallbackCurrency)
        let renderer = ImageRenderer(content: content)
        renderer.proposedSize = ProposedViewSize(
            width: ReportPrintView.width(for: result), height: nil)

        let directory = FileManager.default.temporaryDirectory
            .appending(path: "Exports", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true)
        let safeTitle = title.replacingOccurrences(of: "/", with: "-")
        let url = directory.appending(component: "\(safeTitle).pdf")
        try? FileManager.default.removeItem(at: url)

        renderer.render { size, draw in
            var box = CGRect(origin: .zero, size: size)
            guard let context = CGContext(url as CFURL, mediaBox: &box, nil) else { return }
            context.beginPDFPage(nil)
            draw(context)
            context.endPDFPage()
            context.closePDF()
        }
        return FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) ? url : nil
    }
}

/// Print-styled twin of `ReportTableView`: fixed light appearance, no
/// scrolling, every row laid out at once.
struct ReportPrintView: View {
    let title: String
    let subtitle: String?
    let result: ReportResult
    let fallbackCurrency: String?

    private var columns: [ReportColumn] { result.visibleColumns }

    static func width(for result: ReportResult) -> CGFloat {
        let columns = result.visibleColumns
        return columns.enumerated().reduce(CGFloat(48)) { total, entry in
            total + Self.columnWidth(entry.element, isFirst: entry.offset == 0)
        }
    }

    private static func columnWidth(_ column: ReportColumn, isFirst: Bool) -> CGFloat {
        isFirst ? max(240, CGFloat(column.width)) : min(180, max(100, CGFloat(column.width)))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.title2.weight(.semibold))
            if let subtitle {
                Text(subtitle)
                    .font(.callout)
                    .foregroundStyle(Color(white: 0.35))
            }
            Text("Generated \(Date().formatted(date: .abbreviated, time: .shortened)) · Tula")
                .font(.caption)
                .foregroundStyle(Color(white: 0.45))

            header
            ForEach(Array(result.rows.enumerated()), id: \.element.id) { index, row in
                if row.isBlank {
                    Color.clear.frame(height: 10)
                } else {
                    rowView(row, index: index)
                }
            }
        }
        .padding(24)
        .background(Color.white)
        .environment(\.colorScheme, .light)
        .foregroundStyle(Color.black)
    }

    private var header: some View {
        HStack(spacing: 0) {
            ForEach(Array(columns.enumerated()), id: \.element.id) { index, column in
                Text(column.label)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Color(white: 0.35))
                    .lineLimit(1)
                    .frame(
                        width: Self.columnWidth(column, isFirst: index == 0),
                        alignment: column.fieldtype.isNumeric ? .trailing : .leading)
            }
        }
        .padding(.vertical, 4)
        .overlay(alignment: .bottom) { Color(white: 0.7).frame(height: 1) }
    }

    private func rowView(_ row: ReportRow, index: Int) -> some View {
        let firstRaw =
            row.values["account_name"]?.nonEmptyString
            ?? columns.first.flatMap { row[$0]?.nonEmptyString } ?? ""
        let isTotal = firstRaw.isQuotedTotalLabel
        let isGroup = result.isGroupRow(at: index)

        return HStack(spacing: 0) {
            ForEach(Array(columns.enumerated()), id: \.element.id) { columnIndex, column in
                Group {
                    if columnIndex == 0 {
                        Text(firstRaw.strippingTotalQuotes)
                            .padding(.leading, CGFloat(row.indent) * 14)
                    } else {
                        Text(
                            ValueFormatting.string(
                                for: row[column], fieldtype: column.fieldtype,
                                currencyCode: ValueFormatting.currencyCode(
                                    options: column.options, rowValues: row.values,
                                    fallback: fallbackCurrency),
                                precision: column.precision))
                            .monospacedDigit()
                    }
                }
                .font(.callout)
                .lineLimit(1)
                .frame(
                    width: Self.columnWidth(column, isFirst: columnIndex == 0),
                    alignment: column.fieldtype.isNumeric && columnIndex > 0
                        ? .trailing : .leading)
            }
        }
        .fontWeight(isGroup || isTotal ? .semibold : .regular)
        .padding(.vertical, 3)
        .overlay(alignment: .bottom) { Color(white: 0.92).frame(height: 0.5) }
    }
}

/// Toolbar share affordance shown once a PDF has been generated.
struct PDFExportToolbar: ToolbarContent {
    let url: URL?

    var body: some ToolbarContent {
        if let url {
            ToolbarItem(placement: .primaryAction) {
                ShareLink(item: url) {
                    Label("Export PDF", systemImage: "square.and.arrow.up")
                }
                .help("Export as PDF")
            }
        }
    }
}
