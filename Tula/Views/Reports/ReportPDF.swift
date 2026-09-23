import ERPNextKit
import QuickLook
import SwiftUI

#if os(macOS)
    import AppKit
#endif

/// Native PDF export for reports (ARCHITECTURE.md §12 Phase 5): the loaded
/// result is re-rendered by print-styled SwiftUI pages and drawn into a
/// paginated vector PDF via `ImageRenderer` — no Desk print formats, no
/// WebKit, so it works offline and in demo mode.
@MainActor
enum ReportPDF {
    /// Half-inch page margins, in PDF points.
    private static let margin: CGFloat = 36

    static func render(
        title: String, subtitle: String?, result: ReportResult, fallbackCurrency: String?
    ) -> URL? {
        let contentWidth = ReportPrintPage.width(for: result)

        // Locale paper, flipped to landscape when the column set outgrows
        // portrait; wider still and the content scales down to fit.
        let paper = paperSize()
        let pageSize =
            contentWidth > paper.width - 2 * margin
            ? CGSize(width: paper.height, height: paper.width)
            : paper
        let scale = min(1, (pageSize.width - 2 * margin) / contentWidth)
        let pageWidth = (pageSize.width - 2 * margin) / scale
        let pageHeight = (pageSize.height - 2 * margin) / scale

        let pages = paginate(rows: result.rows, subtitle: subtitle, pageHeight: pageHeight)

        let directory = FileManager.default.temporaryDirectory
            .appending(path: "Exports", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true)
        let safeTitle = title.replacingOccurrences(of: "/", with: "-")
        let url = directory.appending(component: "\(safeTitle).pdf")
        try? FileManager.default.removeItem(at: url)

        var mediaBox = CGRect(origin: .zero, size: pageSize)
        guard let context = CGContext(url as CFURL, mediaBox: &mediaBox, nil) else {
            return nil
        }
        for (index, rows) in pages.enumerated() {
            let renderer = ImageRenderer(
                content: ReportPrintPage(
                    title: title, subtitle: subtitle, result: result,
                    fallbackCurrency: fallbackCurrency, rows: rows,
                    pageNumber: index + 1, pageCount: pages.count,
                    size: CGSize(width: pageWidth, height: pageHeight)))
            renderer.proposedSize = ProposedViewSize(width: pageWidth, height: pageHeight)
            renderer.render { _, draw in
                context.beginPDFPage(nil)
                context.saveGState()
                context.translateBy(x: margin, y: margin)
                context.scaleBy(x: scale, y: scale)
                draw(context)
                context.restoreGState()
                context.endPDFPage()
            }
        }
        context.closePDF()
        return FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) ? url : nil
    }

    /// Greedy row packing against the fixed print metrics: the first page
    /// reserves the title block, every page keeps the column header and a
    /// footer line.
    private static func paginate(
        rows: [ReportRow], subtitle: String?, pageHeight: CGFloat
    ) -> [[(offset: Int, row: ReportRow)]] {
        let chrome = ReportPrintPage.headerHeight + ReportPrintPage.footerHeight
        var remaining =
            pageHeight - chrome
            - ReportPrintPage.titleBlockHeight(hasSubtitle: subtitle != nil)
        var pages: [[(offset: Int, row: ReportRow)]] = []
        var current: [(offset: Int, row: ReportRow)] = []
        for (offset, row) in rows.enumerated() {
            let height =
                row.isBlank ? ReportPrintPage.blankRowHeight : ReportPrintPage.rowHeight
            if height > remaining, !current.isEmpty {
                pages.append(current)
                current = []
                remaining = pageHeight - chrome
            }
            current.append((offset, row))
            remaining -= height
        }
        if !current.isEmpty || pages.isEmpty {
            pages.append(current)
        }
        return pages
    }

    private static func paperSize() -> CGSize {
        // Letter regions per common paper-size convention; A4 elsewhere.
        let region = Locale.current.region?.identifier ?? ""
        return ["US", "CA", "MX", "PH"].contains(region)
            ? CGSize(width: 612, height: 792)
            : CGSize(width: 595, height: 842)
    }
}

/// One print-styled page: fixed light appearance, fixed row metrics (so
/// pagination is arithmetic, never measurement), column header on every page,
/// title block on the first, page footer pinned to the bottom.
struct ReportPrintPage: View {
    let title: String
    let subtitle: String?
    let result: ReportResult
    let fallbackCurrency: String?
    let rows: [(offset: Int, row: ReportRow)]
    let pageNumber: Int
    let pageCount: Int
    let size: CGSize

    static let rowHeight: CGFloat = 22
    static let blankRowHeight: CGFloat = 10
    static let headerHeight: CGFloat = 26
    static let footerHeight: CGFloat = 24

    static func titleBlockHeight(hasSubtitle: Bool) -> CGFloat {
        30 + (hasSubtitle ? 20 : 0) + 16 + 10
    }

    private var columns: [ReportColumn] { result.visibleColumns }

    static func width(for result: ReportResult) -> CGFloat {
        let columns = result.visibleColumns
        return columns.enumerated().reduce(CGFloat(0)) { total, entry in
            total + Self.columnWidth(entry.element, isFirst: entry.offset == 0)
        }
    }

    private static func columnWidth(_ column: ReportColumn, isFirst: Bool) -> CGFloat {
        isFirst ? max(240, CGFloat(column.width)) : min(180, max(100, CGFloat(column.width)))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if pageNumber == 1 {
                titleBlock
            }
            header
            ForEach(rows.indices, id: \.self) { index in
                let entry = rows[index]
                if entry.row.isBlank {
                    Color.clear.frame(height: Self.blankRowHeight)
                } else {
                    rowView(entry.row, index: entry.offset)
                }
            }
            Spacer(minLength: 0)
            footer
        }
        .frame(width: size.width, height: size.height, alignment: .top)
        .background(Color.white)
        .environment(\.colorScheme, .light)
        .foregroundStyle(Color.black)
    }

    private var titleBlock: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title)
                .font(.title2.weight(.semibold))
                .lineLimit(1)
                .frame(height: 30, alignment: .leading)
            if let subtitle {
                Text(subtitle)
                    .font(.callout)
                    .foregroundStyle(Color(white: 0.35))
                    .lineLimit(1)
                    .frame(height: 20, alignment: .leading)
            }
            Text("Generated \(Date().formatted(date: .abbreviated, time: .shortened)) · Tula")
                .font(.caption)
                .foregroundStyle(Color(white: 0.45))
                .lineLimit(1)
                .frame(height: 16, alignment: .leading)
        }
        .padding(.bottom, 10)
    }

    private var header: some View {
        HStack(spacing: 0) {
            ForEach(Array(columns.enumerated()), id: \.element.id) { index, column in
                Text(column.label)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Color(white: 0.35))
                    .lineLimit(1)
                    .padding(.horizontal, 6)
                    .frame(
                        width: Self.columnWidth(column, isFirst: index == 0),
                        alignment: column.alignsTrailing ? .trailing : .leading)
            }
        }
        .frame(height: Self.headerHeight)
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
                    } else if let label = row[column]?.nonEmptyString,
                        label.isQuotedTotalLabel {
                        // Pseudo-row labels ('Opening', 'Total', …) arrive
                        // quoted in whichever column carries them.
                        Text(label.strippingTotalQuotes)
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
                .padding(.horizontal, 6)
                .frame(
                    width: Self.columnWidth(column, isFirst: columnIndex == 0),
                    alignment: column.alignsTrailing && columnIndex > 0
                        ? .trailing : .leading)
            }
        }
        .fontWeight(isGroup || isTotal ? .semibold : .regular)
        .frame(height: Self.rowHeight)
        .overlay(alignment: .bottom) { Color(white: 0.92).frame(height: 0.5) }
    }

    private var footer: some View {
        Text(pageCount > 1 ? "\(title) · Page \(pageNumber) of \(pageCount)" : title)
            .font(.caption)
            .foregroundStyle(Color(white: 0.45))
            .lineLimit(1)
            .frame(maxWidth: .infinity)
            .frame(height: Self.footerHeight, alignment: .bottom)
    }
}

/// Desk's report PDF, native: a toolbar button that renders the loaded
/// result into a paginated PDF on demand and opens it — Preview on macOS,
/// Quick Look on iOS — the same flow as the document print toolbar.
struct PDFExportToolbar: ToolbarContent {
    let title: String
    var subtitle: String?
    let result: ReportResult?
    let fallbackCurrency: String?

    @State private var rendering = false
    @State private var previewURL: URL?
    @State private var renderFailed = false

    var body: some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            Button {
                export()
            } label: {
                if rendering {
                    ProgressView().controlSize(.small)
                } else {
                    Label("PDF", systemImage: "printer")
                }
            }
            .disabled(result == nil || rendering)
            .help("Open the report as a PDF")
            .quickLookPreview($previewURL)
            .alert("Couldn't Render PDF", isPresented: $renderFailed) {
                Button("OK", role: .cancel) {}
            } message: {
                Text("The report couldn't be drawn into a PDF.")
            }
        }
    }

    private func export() {
        guard let result else { return }
        rendering = true
        Task { @MainActor in
            defer { rendering = false }
            // One runloop turn so the spinner appears before the synchronous
            // page rendering starts.
            await Task.yield()
            guard
                let url = ReportPDF.render(
                    title: title, subtitle: subtitle, result: result,
                    fallbackCurrency: fallbackCurrency)
            else {
                renderFailed = true
                return
            }
            #if os(macOS)
                NSWorkspace.shared.open(url)
            #else
                previewURL = url
            #endif
        }
    }
}
