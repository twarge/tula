import ERPNextKit
import SwiftUI

/// Generic read-only form view for any document: the DocType's flat field
/// list is parsed into tabs → sections → columns (`FormLayout`) and rendered
/// with the field registry — the native equivalent of Desk's form renderer.
struct DocumentScreen: View {
    let doctype: String
    let name: String

    @Environment(AppModel.self) private var model
    @State private var state: LoadState<Loaded> = .loading
    @State private var lastUpdated: Date?
    @State private var refreshToken = 0

    struct Loaded {
        var meta: DocTypeMeta
        var childMetas: [String: DocTypeMeta]
        var document: Document
    }

    var body: some View {
        Group {
            switch state {
            case .loading:
                ProgressView("Loading…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .failed(let message):
                ContentUnavailableView {
                    Label("Couldn't Load Document", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(message)
                }
            case .loaded(let loaded):
                ScrollView {
                    DocumentFormView(
                        meta: loaded.meta, childMetas: loaded.childMetas,
                        document: loaded.document)
                        .padding()
                        .frame(maxWidth: 900, alignment: .leading)
                        .frame(maxWidth: .infinity)
                }
                .refreshable { await load() }
            }
        }
        .navigationTitle(title)
        .toolbar {
            RefreshToolbar(lastUpdated: lastUpdated) { refreshToken += 1 }
        }
        .autoRefresh(signalDoctype: doctype) { refreshToken += 1 }
        .task(id: "\(model.sourceGeneration)-\(doctype)-\(name)-\(refreshToken)") {
            await load()
        }
    }

    private var title: String {
        if case .loaded(let loaded) = state {
            return loaded.document.title(using: loaded.meta)
        }
        return name
    }

    private func load() async {
        if case .loaded = state {
            // Silent refresh: keep content on screen.
        } else {
            state = .loading
        }
        do {
            let bundle = try await model.dataSource.metaBundle(for: doctype)
            guard let meta = bundle.first else {
                throw ERPNextError(message: "No metadata for \(doctype)")
            }
            let document = try await model.dataSource.document(doctype, name: name)
            let childMetas = Dictionary(
                uniqueKeysWithValues: bundle.dropFirst().map { ($0.name, $0) })
            state = .loaded(Loaded(meta: meta, childMetas: childMetas, document: document))
            lastUpdated = Date()
        } catch {
            state = .failed(error.localizedDescription)
        }
    }
}

/// The reusable form body: tabs → sections → columns → fields. Used by
/// `DocumentScreen` for top-level documents and by the child-row detail
/// sheet for table rows.
struct DocumentFormView: View {
    let meta: DocTypeMeta
    let childMetas: [String: DocTypeMeta]
    let document: Document
    private let layout: FormLayout

    @State private var selectedTab = 0

    init(meta: DocTypeMeta, childMetas: [String: DocTypeMeta], document: Document) {
        self.meta = meta
        self.childMetas = childMetas
        self.document = document
        self.layout = FormLayout.parse(meta)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if layout.tabs.count > 1 {
                Picker("Tab", selection: $selectedTab) {
                    ForEach(layout.tabs) { tab in
                        Text(tab.label).tag(tab.id)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }

            let tab = layout.tabs.first { $0.id == selectedTab } ?? layout.tabs.first
            if let tab {
                ForEach(tab.sections) { section in
                    FormSectionView(
                        section: section, childMetas: childMetas, document: document)
                }
            }
        }
    }
}

private struct FormSectionView: View {
    let section: FormLayout.Section
    let childMetas: [String: DocTypeMeta]
    let document: Document

    #if !os(macOS)
        @Environment(\.horizontalSizeClass) private var sizeClass
    #endif

    var body: some View {
        let columns = section.columns.filter { !$0.isEmpty }
        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                if !columns.isEmpty {
                    columnsView(columns)
                }
                ForEach(section.tables) { tableField in
                    childTable(for: tableField)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(4)
        } label: {
            if let label = section.label {
                Text(label)
                    .font(.headline)
                    .padding(.bottom, 2)
            }
        }
    }

    @ViewBuilder
    private func columnsView(_ columns: [[DocField]]) -> some View {
        if stackColumns {
            VStack(alignment: .leading, spacing: 12) {
                ForEach(Array(columns.enumerated()), id: \.offset) { _, column in
                    fieldStack(column)
                }
            }
        } else {
            HStack(alignment: .top, spacing: 24) {
                ForEach(Array(columns.enumerated()), id: \.offset) { _, column in
                    fieldStack(column)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    private var stackColumns: Bool {
        #if os(macOS)
            return false
        #else
            return sizeClass == .compact
        #endif
    }

    private func fieldStack(_ fields: [DocField]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(fields) { field in
                FieldRow(field: field, document: document)
            }
        }
    }

    @ViewBuilder
    private func childTable(for tableField: DocField) -> some View {
        let rows = document.childRows(for: tableField)
        if let childDoctype = tableField.options,
            let childMeta = childMetas[childDoctype], !rows.isEmpty {
            ChildTableView(
                title: tableField.label == section.label ? nil : tableField.label,
                meta: childMeta, rows: rows, parentValues: document.raw)
        }
    }
}

/// One form field, laid out the way Desk does it: checkboxes render as
/// `☑ Label` on a single line (box before text, always shown even when
/// unchecked); every other field puts the label on its own line with the
/// value beneath it.
private struct FieldRow: View {
    let field: DocField
    let document: Document

    @Environment(AppModel.self) private var model

    var body: some View {
        if field.fieldtype == .check {
            HStack(spacing: 6) {
                FieldValueView(
                    fieldname: field.fieldname,
                    fieldtype: .check,
                    value: document.raw[field.fieldname] ?? .int(0))
                Text(field.label)
            }
        } else if let value = document[field.fieldname] {
            VStack(alignment: .leading, spacing: 3) {
                Text(field.label)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                FieldValueView(
                    fieldname: field.fieldname,
                    fieldtype: field.fieldtype,
                    options: field.options,
                    value: value,
                    currencyCode: ValueFormatting.currencyCode(
                        options: field.fieldtype == .currency ? field.options : nil,
                        rowValues: document.raw,
                        fallback: model.fallbackCurrencyCode))
                    .fontWeight(field.bold ? .semibold : .regular)
            }
        }
    }
}

/// Read-only child table (invoice items etc.). Mirrors Desk's grid: a row
/// number column, user-choosable columns (gear menu, persisted per child
/// DocType; widths are content-sized, the native equivalent of Desk's width
/// settings), and a per-row details button that opens the full row in a
/// sheet — the native take on Desk's pencil.
private struct ChildTableView: View {
    let title: String?
    let meta: DocTypeMeta
    let rows: [Document]
    let parentValues: [String: FrappeValue]

    @Environment(AppModel.self) private var model
    @State private var visibleFieldnames: [String]
    @State private var detailRow: Document?

    init(title: String?, meta: DocTypeMeta, rows: [Document], parentValues: [String: FrappeValue]) {
        self.title = title
        self.meta = meta
        self.rows = rows
        self.parentValues = parentValues
        let stored = UserDefaults.standard.stringArray(forKey: Self.storageKey(meta.name))
        _visibleFieldnames = State(initialValue: stored ?? meta.listFields.map(\.fieldname))
    }

    private static func storageKey(_ doctype: String) -> String {
        "childTableColumns.\(doctype)"
    }

    private var availableFields: [DocField] {
        meta.fields.filter { $0.fieldtype.isPresentable && !$0.hidden }
    }

    /// Visible columns in metadata order; falls back to the DocType's list
    /// fields if the user deselects everything.
    private var visibleFields: [DocField] {
        let chosen = availableFields.filter { visibleFieldnames.contains($0.fieldname) }
        return chosen.isEmpty ? meta.listFields : chosen
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                if let title {
                    Text(title)
                        .font(.subheadline.weight(.semibold))
                }
                Spacer()
                columnsMenu
            }
            grid
        }
        .sheet(item: $detailRow) { row in
            ChildRowDetailSheet(meta: meta, row: row)
        }
    }

    private var columnsMenu: some View {
        Menu {
            ForEach(availableFields) { field in
                Toggle(isOn: columnBinding(for: field)) {
                    Text(field.label)
                }
            }
            Divider()
            Button("Reset Columns") {
                visibleFieldnames = meta.listFields.map(\.fieldname)
                persistColumns()
            }
        } label: {
            Image(systemName: "gearshape")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Choose columns")
    }

    private func columnBinding(for field: DocField) -> Binding<Bool> {
        Binding {
            visibleFieldnames.contains(field.fieldname)
        } set: { isOn in
            if isOn {
                visibleFieldnames.append(field.fieldname)
            } else {
                visibleFieldnames.removeAll { $0 == field.fieldname }
            }
            persistColumns()
        }
    }

    private func persistColumns() {
        UserDefaults.standard.set(visibleFieldnames, forKey: Self.storageKey(meta.name))
    }

    private var grid: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 6) {
                GridRow {
                    Text("#")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    ForEach(visibleFields) { field in
                        Text(field.label)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .gridColumnAlignment(field.fieldtype.isNumeric ? .trailing : .leading)
                    }
                    Text("")
                }
                Divider()
                ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                    GridRow {
                        Text("\(index + 1)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        ForEach(visibleFields) { field in
                            FieldValueView(
                                fieldname: field.fieldname,
                                fieldtype: field.fieldtype,
                                options: field.options,
                                value: row[field.fieldname],
                                currencyCode: ValueFormatting.currencyCode(
                                    options: field.fieldtype == .currency ? field.options : nil,
                                    rowValues: row.raw,
                                    parentValues: parentValues,
                                    fallback: model.fallbackCurrencyCode),
                                linkEnabled: false)
                                .lineLimit(1)
                        }
                        Button {
                            detailRow = row
                        } label: {
                            Image(systemName: "info.circle")
                        }
                        .buttonStyle(.borderless)
                        .help("Row details")
                    }
                }
            }
            .padding(10)
        }
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
    }
}

/// The full child row rendered through the generic form renderer — every
/// field, laid out by the child DocType's own section/column breaks.
private struct ChildRowDetailSheet: View {
    let meta: DocTypeMeta
    let row: Document

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                DocumentFormView(meta: meta, childMetas: [:], document: row)
                    .padding()
            }
            .navigationTitle(rowTitle)
            .navigationDestination(for: Route.self) { route in
                RouteView(route: route)
            }
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        #if os(macOS)
            .frame(minWidth: 560, minHeight: 480)
        #endif
    }

    private var rowTitle: String {
        if let titleField = meta.titleField, let title = row[titleField]?.nonEmptyString {
            return title
        }
        // Child rows have opaque autonames; prefer the first identifying value.
        let candidate = meta.listFields.first {
            ($0.fieldtype == .link || $0.fieldtype == .data)
                && row[$0.fieldname]?.nonEmptyString != nil
        }
        if let candidate, let value = row[candidate.fieldname]?.nonEmptyString {
            return value
        }
        return "Row Details"
    }
}
