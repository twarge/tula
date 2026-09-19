import ERPNextKit
import SwiftUI

/// Table MultiSelect the way Desk draws it: not a grid but one input whose
/// rows show as lozenges, keyed on the child DocType's first Link field.
/// Reading, each lozenge navigates to its document; editing, each carries
/// an ✕ and the trailing text field type-aheads new values (↑/↓/Return pick
/// a suggestion, Backspace on an empty field removes the last lozenge).
struct MultiSelectField: View {
    let field: DocField
    let childMeta: DocTypeMeta
    let linkField: DocField
    let rows: [FrappeValue]
    /// Non-nil while the enclosing screen is editing this field.
    let session: EditSession?

    @Environment(AppModel.self) private var model
    @State private var query = ""
    @State private var suggestions: [LinkOption] = []
    @State private var highlighted: String?
    @FocusState private var focused: Bool

    private var linkDoctype: String { linkField.options ?? "" }

    /// Rows that carry a value, with their position in the table so a
    /// removal never disturbs rows this control doesn't show.
    private var entries: [(index: Int, value: String)] {
        rows.enumerated().compactMap { index, row in
            row.objectValue?[linkField.fieldname]?.nonEmptyString.map { (index, $0) }
        }
    }

    var body: some View {
        if let session {
            editor(session)
        } else if entries.isEmpty {
            // Same reserved value line as any other empty field.
            Text(verbatim: " ")
        } else {
            FlowLayout(spacing: 6) {
                ForEach(entries, id: \.index) { entry in
                    NavigationLink(
                        value: Route.document(doctype: linkDoctype, name: entry.value)
                    ) {
                        lozenge(entry.value, onRemove: nil)
                            .foregroundStyle(.tint)
                    }
                    .buttonStyle(.plain)
                    .modifier(
                        DocumentQuickViewModifier(doctype: linkDoctype, name: entry.value))
                }
            }
        }
    }

    private func editor(_ session: EditSession) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            FlowLayout(spacing: 6) {
                ForEach(entries, id: \.index) { entry in
                    lozenge(entry.value) { remove(at: entry.index, from: session) }
                }
                TextField(entries.isEmpty ? linkDoctype : "", text: $query)
                    .textFieldStyle(.plain)
                    .focused($focused)
                    .autocorrectionDisabled()
                    .onSubmit {
                        pickHighlighted(into: session)
                        focused = true
                    }
                    .onKeyPress(.downArrow) { moveHighlight(by: 1) }
                    .onKeyPress(.upArrow) { moveHighlight(by: -1) }
                    // macOS reports Backspace as U+007F, not `.delete`'s U+0008.
                    .onKeyPress(keys: [.delete, KeyEquivalent("\u{7F}")]) { _ in
                        guard query.isEmpty, let last = entries.last else { return .ignored }
                        remove(at: last.index, from: session)
                        return .handled
                    }
                    .padding(.vertical, 3)
                    .layoutValue(key: FlowFillsRow.self, value: true)
            }
            .padding(6)
            .background(.background, in: RoundedRectangle(cornerRadius: 6))
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(focused ? AnyShapeStyle(.tint) : AnyShapeStyle(.quaternary)))
            .contentShape(Rectangle())
            .onTapGesture { focused = true }

            if focused && !suggestions.isEmpty {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(suggestions.prefix(8)) { option in
                        Button {
                            add(option.value, to: session)
                        } label: {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(option.value)
                                if let description = option.description,
                                    description != option.value {
                                    Text(description)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(
                                option.value == highlightedValue
                                    ? Color.accentColor.opacity(0.2) : .clear,
                                in: RoundedRectangle(cornerRadius: 5))
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(2)
                .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 6))
            }
        }
        .frame(maxWidth: 480, alignment: .leading)
        .task(id: "\(linkDoctype)|\(query)|\(focused)|\(entries.map(\.value))") {
            guard focused, !linkDoctype.isEmpty else {
                suggestions = []
                return
            }
            guard
                let options = await LinkSuggestField.options(
                    doctype: linkDoctype, query: query, model: model)
            else { return }
            // Desk hides what's already chosen.
            let chosen = Set(entries.map(\.value))
            suggestions = options.filter { !chosen.contains($0.value) }
        }
    }

    private func lozenge(_ value: String, onRemove: (() -> Void)?) -> some View {
        HStack(spacing: 5) {
            Text(value)
                .lineLimit(1)
                .truncationMode(.middle)
            if let onRemove {
                Button(action: onRemove) {
                    Image(systemName: "xmark")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.secondary)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Remove")
            }
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 3)
        .background(.quaternary.opacity(0.6), in: Capsule())
    }

    // MARK: Draft edits

    private func add(_ value: String, to session: EditSession) {
        guard !entries.contains(where: { $0.value == value }) else { return }
        var tableRows = session.draft[field.fieldname]?.arrayValue ?? []
        tableRows.append(
            .object([
                "doctype": .string(childMeta.name),
                linkField.fieldname: .string(value),
            ]))
        session.set(field.fieldname, .array(tableRows))
        query = ""
        highlighted = nil
    }

    private func remove(at index: Int, from session: EditSession) {
        var tableRows = session.draft[field.fieldname]?.arrayValue ?? []
        guard tableRows.indices.contains(index) else { return }
        tableRows.remove(at: index)
        session.set(field.fieldname, .array(tableRows))
    }

    // MARK: Suggestion highlight

    /// The arrow-key highlight, defaulting to the top suggestion — the one
    /// Return picks.
    private var highlightedValue: String? {
        let visible = suggestions.prefix(8)
        if let highlighted, visible.contains(where: { $0.value == highlighted }) {
            return highlighted
        }
        return visible.first?.value
    }

    private func moveHighlight(by delta: Int) -> KeyPress.Result {
        let visible = Array(suggestions.prefix(8))
        guard !visible.isEmpty else { return .ignored }
        let current = visible.firstIndex { $0.value == highlightedValue } ?? 0
        highlighted = visible[min(max(current + delta, 0), visible.count - 1)].value
        return .handled
    }

    private func pickHighlighted(into session: EditSession) {
        if let value = highlightedValue { add(value, to: session) }
    }
}

/// Marks the flow item that stretches across the rest of its row (the
/// multiselect's text field).
struct FlowFillsRow: LayoutValueKey {
    static let defaultValue = false
}

/// Left-to-right wrapping layout for lozenges. An item tagged
/// `FlowFillsRow` takes whatever is left of its row, moving to a fresh row
/// when less than `fillMinWidth` remains.
struct FlowLayout: Layout {
    var spacing: CGFloat = 6
    var fillMinWidth: CGFloat = 120

    private struct Arrangement {
        var frames: [CGRect] = []
        var size: CGSize = .zero
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        arrange(width: proposal.width ?? .infinity, subviews: subviews).size
    }

    func placeSubviews(
        in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()
    ) {
        let arrangement = arrange(width: bounds.width, subviews: subviews)
        for (subview, frame) in zip(subviews, arrangement.frames) {
            subview.place(
                at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY),
                proposal: ProposedViewSize(frame.size))
        }
    }

    private func arrange(width: CGFloat, subviews: Subviews) -> Arrangement {
        var arrangement = Arrangement()
        var rowStart = 0
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0

        // Vertically center the finished row's items, then start the next.
        func closeRow() {
            for index in rowStart..<arrangement.frames.count {
                arrangement.frames[index].origin.y +=
                    (rowHeight - arrangement.frames[index].height) / 2
            }
            rowStart = arrangement.frames.count
            x = 0
            y += rowHeight + spacing
            rowHeight = 0
        }

        for subview in subviews {
            var size = subview.sizeThatFits(
                ProposedViewSize(width: width.isFinite ? width : nil, height: nil))
            if subview[FlowFillsRow.self] {
                if x > 0, width - x < fillMinWidth { closeRow() }
                let fill = width.isFinite ? max(width - x, fillMinWidth) : fillMinWidth
                size = subview.sizeThatFits(ProposedViewSize(width: fill, height: nil))
                size.width = fill
            } else if x > 0, x + size.width > width {
                closeRow()
            }
            arrangement.frames.append(CGRect(origin: CGPoint(x: x, y: y), size: size))
            arrangement.size.width = max(arrangement.size.width, x + size.width)
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        if !arrangement.frames.isEmpty {
            closeRow()
            arrangement.size.height = y - spacing
        }
        return arrangement
    }
}
