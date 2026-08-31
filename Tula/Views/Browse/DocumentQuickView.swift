import ERPNextKit
import SwiftUI

/// Desk's link-preview popover, natively: a glanceable summary of a document
/// — title, status, and its preview fields — shown from any document link
/// without leaving the current screen. macOS reaches it by hovering the link;
/// iOS by long-pressing it (context-menu preview). Clicking/tapping still
/// navigates to the full document.
struct DocumentQuickView: View {
    let doctype: String
    let name: String

    @Environment(AppModel.self) private var model
    @State private var state: LoadState<Loaded> = .loading

    private struct Loaded {
        var meta: DocTypeMeta
        var document: Document
        /// The document's primary child table (invoice items, journal
        /// accounts, claimed expenses…) for the line-item glance.
        var itemsField: DocField?
        var itemsMeta: DocTypeMeta?
        var items: [Document] = []
    }

    var body: some View {
        Group {
            switch state {
            case .loading:
                ProgressView()
                    .frame(maxWidth: .infinity, minHeight: 70)
            case .failed(let message):
                VStack(alignment: .leading, spacing: 6) {
                    header(title: name)
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            case .loaded(let loaded):
                content(loaded)
            }
        }
        .padding(14)
        .frame(width: 380, alignment: .topLeading)
        .task { await load() }
    }

    private func header(title: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(doctype)
                .font(.caption2.weight(.medium))
                .textCase(.uppercase)
                .foregroundStyle(.secondary)
            Text(title)
                .font(.headline)
        }
    }

    private func content(_ loaded: Loaded) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top) {
                header(title: loaded.document.title(using: loaded.meta))
                Spacer()
                if let status = loaded.document.raw["status"]?.nonEmptyString {
                    StatusBadge(status: status)
                }
            }
            let fields = previewFields(loaded)
            if !fields.isEmpty {
                Divider()
                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 6) {
                    ForEach(fields) { field in
                        GridRow(alignment: .firstTextBaseline) {
                            Text(field.label)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            FieldValueView(
                                fieldname: field.fieldname,
                                fieldtype: field.fieldtype,
                                options: field.options,
                                value: loaded.document.raw[field.fieldname],
                                currencyCode: ValueFormatting.currencyCode(
                                    options: field.fieldtype == .currency
                                        ? field.options : nil,
                                    rowValues: loaded.document.raw,
                                    fallback: model.fallbackCurrencyCode),
                                precision: field.precision,
                                linkEnabled: false)
                                .lineLimit(2)
                        }
                    }
                }
            }
            if let itemsField = loaded.itemsField, let itemsMeta = loaded.itemsMeta,
                !loaded.items.isEmpty {
                Divider()
                lineItems(field: itemsField, meta: itemsMeta, loaded: loaded)
            }
        }
    }

    /// The voucher's core costs at a glance: one compact row per line item —
    /// name and amount, with description and qty × rate underneath.
    private func lineItems(field: DocField, meta: DocTypeMeta, loaded: Loaded) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(field.label)
                .font(.caption2.weight(.medium))
                .textCase(.uppercase)
                .foregroundStyle(.secondary)
            ForEach(Array(loaded.items.prefix(8).enumerated()), id: \.offset) { _, row in
                lineItem(row: row, meta: meta, parent: loaded.document)
            }
            if loaded.items.count > 8 {
                Text("+ \(loaded.items.count - 8) more")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func lineItem(row: Document, meta: DocTypeMeta, parent: Document) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(primaryText(row: row, meta: meta))
                    .font(.callout)
                    .lineLimit(1)
                Spacer(minLength: 12)
                if let (value, field) = amount(row: row, meta: meta) {
                    Text(
                        ValueFormatting.string(
                            for: value, fieldtype: field.fieldtype,
                            currencyCode: ValueFormatting.currencyCode(
                                options: field.fieldtype == .currency ? field.options : nil,
                                rowValues: row.raw, parentValues: parent.raw,
                                fallback: model.fallbackCurrencyCode),
                            precision: field.precision)
                    )
                    .font(.callout)
                    .monospacedDigit()
                }
            }
            if let detail = detailText(row: row, meta: meta, parent: parent) {
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
    }

    /// First meaningful text on the row: item name, expense type, account…
    private func primaryText(row: Document, meta: DocTypeMeta) -> String {
        let preferred = ["item_name", "item_code", "expense_type", "account", "against_account"]
        for name in preferred {
            if let value = row[name]?.nonEmptyString { return value }
        }
        if let field = meta.listFields.first(where: { !$0.fieldtype.isNumeric }),
            let value = row[field.fieldname]?.nonEmptyString {
            return value
        }
        return row[meta.titleField ?? "description"]?.nonEmptyString ?? "—"
    }

    /// The row's money: `amount` when set, else whichever of debit/credit is
    /// non-zero (journal rows), else the last currency list column.
    private func amount(row: Document, meta: DocTypeMeta) -> (FrappeValue, DocField)? {
        for name in ["amount", "debit", "credit"] {
            if let field = meta.field(named: name), let value = row[field.fieldname],
                (value.doubleValue ?? 0) != 0 {
                return (value, field)
            }
        }
        if let field = meta.field(named: "amount")
            ?? meta.listFields.last(where: { $0.fieldtype == .currency }),
            let value = row[field.fieldname], !value.isNull {
            return (value, field)
        }
        return nil
    }

    /// "3 × $200.00 · description" — whichever parts the row has.
    private func detailText(row: Document, meta: DocTypeMeta, parent: Document) -> String? {
        var parts: [String] = []
        if let qtyField = meta.field(named: "qty"), let qty = row[qtyField.fieldname],
            !qty.isNull {
            var quantity = ValueFormatting.string(for: qty, fieldtype: qtyField.fieldtype)
            if let rateField = meta.field(named: "rate"), let rate = row[rateField.fieldname],
                !rate.isNull {
                quantity += " × " + ValueFormatting.string(
                    for: rate, fieldtype: rateField.fieldtype,
                    currencyCode: ValueFormatting.currencyCode(
                        options: rateField.options, rowValues: row.raw,
                        parentValues: parent.raw, fallback: model.fallbackCurrencyCode),
                    precision: rateField.precision)
            }
            parts.append(quantity)
        }
        if let description = row["description"]?.nonEmptyString {
            let stripped = description.strippingSimpleHTML()
                .trimmingCharacters(in: .whitespacesAndNewlines)
            // Desk defaults description to the item code; repeating it says
            // nothing new at a glance.
            if !stripped.isEmpty, stripped != primaryText(row: row, meta: meta) {
                parts.append(stripped)
            }
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// Desk's preview recipe: `in_preview` fields, falling back to the list
    /// columns — set values only, capped for glanceability.
    private func previewFields(_ loaded: Loaded) -> [DocField] {
        let flagged = loaded.meta.fields.filter {
            $0.inPreview && !$0.hidden && $0.fieldtype.isPresentable
        }
        let source = flagged.isEmpty ? loaded.meta.listFields : flagged
        return Array(
            source.filter { field in
                field.fieldname != loaded.meta.titleField
                    && !(loaded.document.raw[field.fieldname]?.isNull ?? true)
            }.prefix(6))
    }

    private func load() async {
        do {
            let bundle = try await model.cache.metaBundle(for: doctype, using: model.dataSource)
            guard let meta = bundle.metas.first else {
                throw ERPNextError(message: "No metadata for \(doctype)")
            }
            let document = try await model.dataSource.document(doctype, name: name)
            var loaded = Loaded(meta: meta, document: document)
            let childMetas = Dictionary(
                uniqueKeysWithValues: bundle.metas.dropFirst().map { ($0.name, $0) })
            // The first populated child table is the document's substance
            // (invoice items, journal accounts, claimed expenses).
            for field in meta.fields where field.fieldtype == .table {
                let rows = document.childRows(for: field)
                guard !rows.isEmpty,
                    let childMeta = field.options.flatMap({ childMetas[$0] })
                else { continue }
                loaded.itemsField = field
                loaded.itemsMeta = childMeta
                loaded.items = rows
                break
            }
            state = .loaded(loaded)
        } catch {
            state = .failed(error.localizedDescription)
        }
    }
}

/// Attaches the quick view to a document link. macOS: Safari-style hover
/// preview — deliberate hover shows the popover, it stays while the pointer
/// is over the link or the popover, and dismisses shortly after leaving
/// both. iOS: long-press context menu with the preview and an Open action.
struct DocumentQuickViewModifier: ViewModifier {
    let doctype: String
    let name: String

    @Environment(AppModel.self) private var model
    @State private var showingPreview = false
    @State private var hoverTask: Task<Void, Never>?

    func body(content: Content) -> some View {
        #if os(macOS)
            content
                .onHover { hover($0) }
                .popover(isPresented: $showingPreview, arrowEdge: .bottom) {
                    DocumentQuickView(doctype: doctype, name: name)
                        .onHover { hover($0) }
                        .environment(model)
                }
        #else
            content
                .contextMenu {
                    Button {
                        model.pendingRoute = .document(doctype: doctype, name: name)
                    } label: {
                        Label("Open", systemImage: "arrow.up.right.square")
                    }
                } preview: {
                    DocumentQuickView(doctype: doctype, name: name)
                        .environment(model)
                }
        #endif
    }

    private func hover(_ hovering: Bool) {
        hoverTask?.cancel()
        if hovering {
            guard !showingPreview else { return }
            hoverTask = Task {
                try? await Task.sleep(for: .milliseconds(600))
                guard !Task.isCancelled else { return }
                showingPreview = true
            }
        } else {
            hoverTask = Task {
                try? await Task.sleep(for: .milliseconds(250))
                guard !Task.isCancelled else { return }
                showingPreview = false
            }
        }
    }
}
