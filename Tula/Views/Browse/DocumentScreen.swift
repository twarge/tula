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
        var gridColumns: [String: [GridColumn]]
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
                        document: loaded.document, gridColumns: loaded.gridColumns)
                        .padding()
                        .frame(maxWidth: 900, alignment: .leading)
                        .frame(maxWidth: .infinity)
                }
                .refreshable { await load() }
            }
        }
        .navigationTitle(title)
        .toolbar {
            OpenInDeskToolbar(route: .document(doctype: doctype, name: name))
            RefreshToolbar(lastUpdated: lastUpdated) { refreshToken += 1 }
        }
        .autoRefresh(signalDoctype: doctype) { refreshToken += 1 }
        .task(id: "\(model.sourceGeneration)-\(doctype)-\(name)-\(refreshToken)") {
            if case .loading = state,
                let cached: (value: Loaded, savedAt: Date) = model.cache.screen(cacheKey) {
                state = .loaded(cached.value)
                lastUpdated = cached.savedAt
            }
            await load()
        }
    }

    private var cacheKey: String {
        "doc|\(model.sourceGeneration)|\(doctype)|\(name)"
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
            let bundle = try await model.cache.metaBundle(
                for: doctype, using: model.dataSource)
            guard let meta = bundle.metas.first else {
                throw ERPNextError(message: "No metadata for \(doctype)")
            }
            let document = try await model.dataSource.document(doctype, name: name)
            let childMetas = Dictionary(
                uniqueKeysWithValues: bundle.metas.dropFirst().map { ($0.name, $0) })
            let loaded = Loaded(
                meta: meta, childMetas: childMetas, gridColumns: bundle.gridColumns,
                document: document)
            state = .loaded(loaded)
            lastUpdated = Date()
            model.cache.setScreen(cacheKey, loaded)
        } catch {
            // Keep cached content when a refresh fails; only surface errors
            // when the screen is empty.
            if case .loaded = state {} else {
                state = .failed(error.localizedDescription)
            }
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
    let gridColumns: [String: [GridColumn]]
    private let layout: FormLayout
    private let evaluator: DependsOnEvaluator

    @State private var selectedTab = 0

    init(
        meta: DocTypeMeta, childMetas: [String: DocTypeMeta], document: Document,
        gridColumns: [String: [GridColumn]] = [:]
    ) {
        self.meta = meta
        self.childMetas = childMetas
        self.document = document
        self.gridColumns = gridColumns
        self.layout = FormLayout.parse(meta)
        self.evaluator = DependsOnEvaluator(document: document)
    }

    var body: some View {
        // Desk evaluates depends_on on tabs and sections too.
        let visibleTabs = layout.tabs.filter { evaluator.isVisible($0.breakField?.dependsOn) }

        VStack(alignment: .leading, spacing: 16) {
            if visibleTabs.count > 1 {
                Picker("Tab", selection: $selectedTab) {
                    ForEach(visibleTabs) { tab in
                        Text(tab.label).tag(tab.id)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }

            let tab = visibleTabs.first { $0.id == selectedTab } ?? visibleTabs.first
            if let tab {
                ForEach(cards(for: tab)) { card in
                    FormCardView(
                        card: card, childMetas: childMetas, document: document,
                        gridColumns: gridColumns)
                }
            }
        }
    }

    /// Desk renders an unlabeled Section Break as a layout break *inside*
    /// the current visual block — only labeled sections start a new one.
    /// Group sections into cards accordingly, so e.g. a taxes grid and its
    /// totals stay inside the "Taxes and Charges" card instead of splitting
    /// into separate boxes.
    private func cards(for tab: FormLayout.Tab) -> [FormCard] {
        var cards: [FormCard] = []
        for section in tab.sections {
            guard evaluator.isVisible(section.breakField?.dependsOn),
                let prepared = prepare(section)
            else { continue }
            if prepared.label != nil || cards.isEmpty {
                cards.append(FormCard(label: prepared.label, sections: [prepared]))
            } else {
                cards[cards.count - 1].sections.append(prepared)
            }
        }
        return cards
    }

    /// Applies field-level visibility once, so cards with nothing to show
    /// are dropped entirely.
    private func prepare(_ section: FormLayout.Section) -> PreparedSection? {
        let columns = section.columns
            .map { $0.filter(isFieldVisible) }
            .filter { !$0.isEmpty }
        let tables = section.tables.filter { evaluator.isVisible($0.dependsOn) }
        guard !columns.isEmpty || !tables.isEmpty else { return nil }
        return PreparedSection(
            id: section.id, label: section.label, columns: columns, tables: tables)
    }

    private func isFieldVisible(_ field: DocField) -> Bool {
        evaluator.isVisible(field.dependsOn) && !isRedundantBaseTwin(field)
    }

    /// ERPNext convention: `base_*` fields duplicate their twin in company
    /// currency. Desk hides them when the document is already in company
    /// currency (conversion rate 1); mirror that.
    private func isRedundantBaseTwin(_ field: DocField) -> Bool {
        guard field.fieldname.hasPrefix("base_") else { return false }
        let twin = String(field.fieldname.dropFirst("base_".count))
        guard meta.field(named: twin) != nil else { return false }
        return (document["conversion_rate"]?.doubleValue ?? 1) == 1
    }
}

/// A section with visibility already applied.
private struct PreparedSection: Identifiable {
    let id: Int
    var label: String?
    var columns: [[DocField]]
    var tables: [DocField]
}

/// One visual block: a labeled section plus any unlabeled sections that
/// follow it.
private struct FormCard: Identifiable {
    var id: Int { sections.first?.id ?? -1 }
    var label: String?
    var sections: [PreparedSection]
}

private struct FormCardView: View {
    let card: FormCard
    let childMetas: [String: DocTypeMeta]
    let document: Document
    let gridColumns: [String: [GridColumn]]

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 20) {
                ForEach(card.sections) { section in
                    FormSectionContent(
                        section: section, cardLabel: card.label, childMetas: childMetas,
                        document: document, gridColumns: gridColumns)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(4)
        } label: {
            if let label = card.label {
                Text(label)
                    .font(.headline)
                    .padding(.bottom, 2)
            }
        }
    }
}

private struct FormSectionContent: View {
    let section: PreparedSection
    let cardLabel: String?
    let childMetas: [String: DocTypeMeta]
    let document: Document
    let gridColumns: [String: [GridColumn]]

    #if !os(macOS)
        @Environment(\.horizontalSizeClass) private var sizeClass
    #endif

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if !section.columns.isEmpty {
                columnsView(section.columns)
            }
            ForEach(section.tables) { tableField in
                childTable(for: tableField)
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
                title: tableField.label == cardLabel ? nil : tableField.label,
                meta: childMeta, rows: rows, parentValues: document.raw,
                serverColumns: gridColumns[childDoctype])
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
        } else if field.isScanBarcodeField {
            // Desk shows a barcode-scan input here; keep the affordance for
            // visual parity, inert in a read-only client.
            VStack(alignment: .leading, spacing: 3) {
                Text(field.label)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HStack(spacing: 6) {
                    Image(systemName: "barcode.viewfinder")
                    Text(field.label)
                    Spacer()
                }
                .foregroundStyle(.tertiary)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .frame(maxWidth: 320)
                .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))
            }
            .help("Barcode scanning isn't available in a read-only client")
        } else {
            VStack(alignment: .leading, spacing: 3) {
                Text(field.label)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let value = document[field.fieldname] {
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
                } else {
                    // Desk shows empty fields as blank inputs, not gaps —
                    // keep the field visible and reserve its value line.
                    Text(verbatim: " ")
                }
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
    /// Desk's per-user grid configuration for this child DocType, if any.
    let serverColumns: [GridColumn]?

    @Environment(AppModel.self) private var model
    @State private var visibleFieldnames: [String]
    @State private var detailRow: Document?

    init(
        title: String?, meta: DocTypeMeta, rows: [Document],
        parentValues: [String: FrappeValue], serverColumns: [GridColumn]? = nil
    ) {
        self.title = title
        self.meta = meta
        self.rows = rows
        self.parentValues = parentValues
        self.serverColumns = serverColumns
        // Precedence: this device's explicit choice → Desk grid settings →
        // the DocType's in_list_view defaults.
        let stored = UserDefaults.standard.stringArray(forKey: Self.storageKey(meta.name))
        _visibleFieldnames = State(
            initialValue: stored ?? serverColumns?.map(\.fieldname)
                ?? meta.listFields.map(\.fieldname))
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
                visibleFieldnames =
                    serverColumns?.map(\.fieldname) ?? meta.listFields.map(\.fieldname)
                UserDefaults.standard.removeObject(forKey: Self.storageKey(meta.name))
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
