import ERPNextKit
import SwiftUI

/// Native rendering for tables extracted from server-generated HTML fields
/// (e.g. the tax breakup) — styled to match child tables, numeric columns
/// right-aligned.
struct HTMLTableView: View {
    let table: HTMLTable

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 6) {
                if !table.headers.isEmpty {
                    GridRow {
                        ForEach(Array(table.headers.enumerated()), id: \.offset) {
                            index, header in
                            Text(header)
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                                .gridColumnAlignment(
                                    table.columnIsNumeric(index) ? .trailing : .leading)
                        }
                    }
                    Divider()
                }
                ForEach(Array(table.rows.enumerated()), id: \.offset) { _, row in
                    GridRow {
                        ForEach(Array(row.enumerated()), id: \.offset) { index, cell in
                            Text(cell)
                                .monospacedDigit()
                        }
                    }
                }
            }
            .padding(10)
        }
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
    }
}
