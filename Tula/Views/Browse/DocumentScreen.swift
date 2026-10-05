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
    /// Non-nil while a W3 edit is in progress; auto-refresh pauses so the
    /// draft's `modified` token (the optimistic lock) stays coherent.
    @State private var editSession: EditSession?
    /// The TULA_EDIT_PREVIEW hook fires once per screen, so a save or
    /// discard lands back in read mode like a normal launch.
    @State private var didPreviewEdit = false

    struct Loaded {
        var meta: DocTypeMeta
        var childMetas: [String: DocTypeMeta]
        var gridColumns: [String: [GridColumn]]
        var document: Document
        var periphery: DocumentPeriphery
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
                VStack(spacing: 0) {
                    PeripheryBar(
                        periphery: loaded.periphery, documentName: name,
                        actions: DocumentAction.actions(
                            doctype: doctype, name: name, webBase: model.webBaseURL),
                        doctype: doctype,
                        documentRaw: loaded.document.raw,
                        isEditing: editSession != nil,
                        onEdit: EditSession.isEditable(
                            meta: loaded.meta,
                            docstatus: loaded.periphery.docstatus ?? 0)
                            ? { startEditing(loaded) } : nil,
                        onMutate: { refreshToken += 1 })
                    if let session = editSession {
                        EditingBar(
                            session: session,
                            onSave: { save(session) },
                            onDiscard: { editSession = nil },
                            onReload: {
                                editSession = nil
                                refreshToken += 1
                            })
                    }
                    ScrollView {
                        VStack(alignment: .leading, spacing: 16) {
                            DocumentFormView(
                                meta: loaded.meta, childMetas: loaded.childMetas,
                                document: loaded.document, gridColumns: loaded.gridColumns,
                                dashboard: loaded.periphery.connections.isEmpty
                                    && loaded.periphery.stats.isEmpty
                                    && loaded.periphery.reportLinks.isEmpty
                                    ? nil
                                    : DashboardTabView(
                                        periphery: loaded.periphery, documentName: name))
                            PeripheryTrailingSections(
                                periphery: loaded.periphery, documentName: name,
                                doctype: doctype,
                                onMutate: { refreshToken += 1 })
                        }
                        .padding()
                        .frame(maxWidth: 900, alignment: .leading)
                        .frame(maxWidth: .infinity)
                    }
                    .refreshable { await load() }
                }
                .environment(\.editSession, editSession)
            }
        }
        .navigationTitle(title)
        .toolbar {
            SearchToolbar()
            WriteGateToolbar()
            PrintToolbar(doctype: doctype, name: name)
            OpenInDeskToolbar(
                route: .document(doctype: doctype, name: name), placement: .demotedAction)
            RefreshToolbar(lastUpdated: lastUpdated, placement: .demotedAction) {
                refreshToken += 1
            }
        }
        .autoRefresh(signalDoctype: doctype) {
            if editSession == nil { refreshToken += 1 }
        }
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

    private func startEditing(_ loaded: Loaded) {
        // The TULA_EDIT_PREVIEW hook treats the document as a draft so every
        // editor is visible; purely local UI — saving still needs the gate.
        let preview = ProcessInfo.processInfo.environment["TULA_EDIT_PREVIEW"] == "1"
        let session = EditSession(document: loaded.document, docstatus: preview ? 0 : nil)
        if let writeSession = model.writeSession {
            let doctype = doctype
            let name = name
            session.uploadFile = { fileName, data in
                try await writeSession.uploadForField(
                    fileName: fileName, data: data, doctype: doctype, name: name)
            }
        }
        editSession = session
    }

    private func save(_ session: EditSession) {
        guard let writeSession = model.writeSession else {
            session.error = "Writes are locked — open the lock in the toolbar first."
            return
        }
        session.isSaving = true
        session.error = nil
        Task {
            defer { session.isSaving = false }
            do {
                var draft = session.draft
                draft["doctype"] = .string(doctype)
                try await writeSession.save(
                    documentRaw: draft, submitted: session.docstatus == 1)
                editSession = nil
                refreshToken += 1
            } catch let error as ERPNextError where error.isTimestampMismatch {
                session.conflict = true
            } catch {
                session.error = error.localizedDescription
            }
        }
    }

    private var title: String {
        if case .loaded(let loaded) = state {
            return loaded.document.title(using: loaded.meta)
        }
        return name
    }

    private func load() async {
        // An edit in progress pins the screen: refreshing would advance the
        // cached modified token underneath the draft.
        guard editSession == nil else { return }
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
            let childMetas = bundle.childMetas
            var periphery = await DocumentPeriphery.load(
                doctype: doctype, name: name, meta: meta, document: document,
                using: model.dataSource)
            if let workflow = await model.cache.workflow(
                for: doctype, using: model.dataSource) {
                let workflowState =
                    document.raw[workflow.stateField]?.nonEmptyString ?? ""
                periphery.workflowState = workflowState
                periphery.workflowActions = workflow.actions(fromState: workflowState)
            }
            let loaded = Loaded(
                meta: meta, childMetas: childMetas, gridColumns: bundle.gridColumns,
                document: document, periphery: periphery)
            state = .loaded(loaded)
            lastUpdated = Date()
            model.cache.setScreen(cacheKey, loaded)
            // Verification hook: TULA_EDIT_PREVIEW=1 opens the edit UI
            // without a write session (Save stays locked).
            if ProcessInfo.processInfo.environment["TULA_EDIT_PREVIEW"] == "1",
                editSession == nil, !didPreviewEdit {
                didPreviewEdit = true
                startEditing(loaded)
            }
        } catch {
            // Keep cached content when a refresh fails; only surface errors
            // when the screen is empty.
            if case .loaded = state {} else {
                state = .failed(error.localizedDescription)
            }
        }
    }
}

/// The strip shown while editing: save/discard, inline errors, and the
/// conflict banner for the optimistic-lock case (draft lost in v1, per the
/// write map).
private struct EditingBar: View {
    let session: EditSession
    let onSave: () -> Void
    let onDiscard: () -> Void
    let onReload: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if session.conflict {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Text("This document changed on the server while you were editing. Reload to see the latest version — this draft can't be saved.")
                        .font(.callout)
                    Spacer()
                    Button("Reload", action: onReload)
                        .buttonStyle(.borderedProminent)
                }
            } else {
                HStack(spacing: 8) {
                    Image(systemName: "pencil.circle.fill")
                        .foregroundStyle(.orange)
                    Text("Editing")
                        .font(.callout.weight(.semibold))
                    if let error = session.error {
                        Text(error)
                            .font(.caption)
                            .foregroundStyle(.red)
                            .lineLimit(2)
                    }
                    Spacer()
                    Button("Discard", action: onDiscard)
                        .disabled(session.isSaving)
                    Button(action: onSave) {
                        if session.isSaving {
                            ProgressView().controlSize(.small)
                        } else {
                            Text("Save")
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(session.isSaving)
                    .keyboardShortcut("s", modifiers: .command)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.orange.opacity(0.08))
    }
}

/// The reusable form body: tabs → sections → columns → fields. Used by
/// `DocumentScreen` for top-level documents and by the child-row detail
/// sheet for table rows.
struct DocumentFormView<DashboardContent: View>: View {
    let meta: DocTypeMeta
    let childMetas: [String: DocTypeMeta]
    let document: Document
    let gridColumns: [String: [GridColumn]]
    /// Desk tucks the form dashboard in as the second tab; the screen passes
    /// it here so the tab strip can host it (nil for child-row sheets).
    let dashboard: DashboardContent?
    private let layout: FormLayout
    private let evaluator: DependsOnEvaluator

    /// Synthetic tab id for the injected Dashboard tab (real tabs are 0…n).
    private static var dashboardTabID: Int { -1 }

    @State private var selectedTab = 0

    init(
        meta: DocTypeMeta, childMetas: [String: DocTypeMeta], document: Document,
        gridColumns: [String: [GridColumn]] = [:], dashboard: DashboardContent?
    ) {
        self.meta = meta
        self.childMetas = childMetas
        self.document = document
        self.gridColumns = gridColumns
        self.dashboard = dashboard
        self.layout = FormLayout.parse(meta)
        self.evaluator = DependsOnEvaluator(document: document)
    }

    @Environment(\.editSession) private var editSession

    var body: some View {
        // Desk evaluates depends_on on tabs and sections too. While editing,
        // the evaluator follows the draft so conditional layout reacts live.
        let evaluator = editSession?.evaluator ?? self.evaluator
        let visibleTabs = layout.tabs.filter { evaluator.isVisible($0.breakField?.dependsOn) }

        let showsTabs = visibleTabs.count > 1 || dashboard != nil

        VStack(alignment: .leading, spacing: 16) {
            #if os(macOS)
                if showsTabs {
                    tabPicker(visibleTabs)
                }
            #endif

            if selectedTab == Self.dashboardTabID, let dashboard {
                dashboard
            } else {
                let tab = visibleTabs.first { $0.id == selectedTab } ?? visibleTabs.first
                if let tab {
                    ForEach(cards(for: tab, evaluator: evaluator)) { card in
                        FormCardView(
                            card: card, childMetas: childMetas, document: document,
                            gridColumns: gridColumns)
                    }
                }
            }
        }
        #if !os(macOS)
            .toolbar {
                if showsTabs {
                    tabToolbar(visibleTabs)
                }
            }
        #endif
    }

    private func tabPicker(_ visibleTabs: [FormLayout.Tab]) -> some View {
        Picker("Tab", selection: $selectedTab) {
            if let first = visibleTabs.first {
                Text(first.label).tag(first.id)
            }
            if dashboard != nil {
                Text("Dashboard").tag(Self.dashboardTabID)
            }
            ForEach(Array(visibleTabs.dropFirst())) { tab in
                Text(tab.label).tag(tab.id)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
    }

    #if !os(macOS)
        /// iOS puts the tab strip in the navigation bar's centre (of the
        /// document screen, or of the child-row sheet's own stack) rather
        /// than atop the scrolling form.
        @ToolbarContentBuilder
        private func tabToolbar(_ visibleTabs: [FormLayout.Tab]) -> some ToolbarContent {
            let item = ToolbarItem(placement: .principal) { tabPicker(visibleTabs) }
            // `axisBehavior` first ships in the iOS 27.1 SDK (SwiftUI
            // 8.0.85.27); older SDKs — CI's and the App Store build's Xcode 26 —
            // can't compile the call, so it's gated at compile time as well
            // as at runtime.
            #if os(iOS) && canImport(SwiftUI, _version: 8.0.85.27)
                if #available(iOS 27.1, *) {
                    // Left automatic, a segmented control may be inferred
                    // horizontal-only and hidden when the iPhone Duo's
                    // vertical bar is the only bar — stranding the other tabs.
                    item.axisBehavior(.verticalPreferred)
                } else {
                    item
                }
            #else
                item
            #endif
        }
    #endif

    /// Desk renders an unlabeled Section Break as a layout break *inside*
    /// the current visual block — only labeled sections start a new one.
    /// Group sections into cards accordingly, so e.g. a taxes grid and its
    /// totals stay inside the "Taxes and Charges" card instead of splitting
    /// into separate boxes.
    private func cards(for tab: FormLayout.Tab, evaluator: DependsOnEvaluator) -> [FormCard] {
        var cards: [FormCard] = []
        for section in tab.sections {
            guard evaluator.isVisible(section.breakField?.dependsOn),
                let prepared = prepare(section, evaluator: evaluator)
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
    private func prepare(
        _ section: FormLayout.Section, evaluator: DependsOnEvaluator
    ) -> PreparedSection? {
        let columns = section.columns
            .map { $0.filter { isFieldVisible($0, evaluator: evaluator) } }
            .filter { !$0.isEmpty }
        let tables = section.tables.filter { evaluator.isVisible($0.dependsOn) }
        guard !columns.isEmpty || !tables.isEmpty else { return nil }
        return PreparedSection(
            id: section.id, label: section.label, columns: columns, tables: tables)
    }

    private func isFieldVisible(_ field: DocField, evaluator: DependsOnEvaluator) -> Bool {
        evaluator.isVisible(field.dependsOn) && !isRedundantBaseTwin(field)
    }

    /// ERPNext convention: `base_*` fields duplicate their twin in company
    /// currency. Desk hides them when the document is already in company
    /// currency (conversion rate 1); mirror that.
    private func isRedundantBaseTwin(_ field: DocField) -> Bool {
        guard field.fieldname.hasPrefix("base_") else { return false }
        let twin = String(field.fieldname.dropFirst("base_".count))
        guard meta.field(named: twin) != nil else { return false }
        let raw = editSession?.draft ?? document.raw
        return (raw["conversion_rate"]?.doubleValue ?? 1) == 1
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

    @Environment(\.editSession) private var editSession

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
                FieldRow(field: field, document: document, childMetas: childMetas)
            }
        }
    }

    @ViewBuilder
    private func childTable(for tableField: DocField) -> some View {
        let rows = editSession.map { session in
            (session.draft[tableField.fieldname]?.arrayValue ?? [])
                .compactMap { $0.objectValue.map(Document.init(raw:)) }
        } ?? document.childRows(for: tableField)
        if let childDoctype = tableField.options,
            let childMeta = childMetas[childDoctype],
            !rows.isEmpty || editSession != nil {
            ChildTableView(
                title: tableField.label == cardLabel ? nil : tableField.label,
                meta: childMeta, rows: rows,
                parentValues: editSession?.draft ?? document.raw,
                serverColumns: gridColumns[childDoctype],
                editFieldname: editSession == nil ? nil : tableField.fieldname)
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
    /// Resolves a Table MultiSelect's child DocType.
    let childMetas: [String: DocTypeMeta]

    @Environment(AppModel.self) private var model
    @Environment(\.editSession) private var editSession

    /// Draft values win while editing so even read-only fields stay
    /// consistent with the edit in progress.
    private var effectiveRaw: [String: FrappeValue] {
        editSession?.draft ?? document.raw
    }

    var body: some View {
        if let session = editSession, session.isEditable(field) {
            editorRow(session)
        } else if field.fieldtype == .check {
            HStack(spacing: 6) {
                FieldValueView(
                    fieldname: field.fieldname,
                    fieldtype: .check,
                    value: effectiveRaw[field.fieldname] ?? .int(0))
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
                if field.fieldtype == .tableMultiSelect {
                    multiSelect(editing: nil)
                } else if let value = effectiveRaw[field.fieldname], !value.isNull {
                    FieldValueView(
                        fieldname: field.fieldname,
                        fieldtype: field.fieldtype,
                        options: field.options,
                        value: value,
                        currencyCode: ValueFormatting.currencyCode(
                            options: field.fieldtype == .currency ? field.options : nil,
                            rowValues: effectiveRaw,
                            fallback: model.fallbackCurrencyCode),
                        precision: field.precision,
                        rowValues: effectiveRaw)
                        .fontWeight(field.bold ? .semibold : .regular)
                } else {
                    // Desk shows empty fields as blank inputs, not gaps —
                    // keep the field visible and reserve its value line.
                    Text(verbatim: " ")
                }
            }
        }
    }

    @ViewBuilder
    private func editorRow(_ session: EditSession) -> some View {
        if field.fieldtype == .check {
            // The Toggle carries its own label, matching the ☑-before-label
            // layout of the display path.
            EditableFieldView(field: field, session: session)
        } else {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 2) {
                    Text(field.label)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if session.isMandatory(field) {
                        Text("*")
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                }
                if field.fieldtype == .tableMultiSelect {
                    multiSelect(editing: session)
                } else {
                    EditableFieldView(field: field, session: session)
                }
            }
        }
    }

    /// Desk's pill input for Table MultiSelect; blank when the child DocType
    /// (or its Link field) didn't come with the bundle.
    @ViewBuilder
    private func multiSelect(editing session: EditSession?) -> some View {
        if let childMeta = field.options.flatMap({ childMetas[$0] }),
            let linkField = childMeta.multiSelectLinkField {
            MultiSelectField(
                field: field, childMeta: childMeta, linkField: linkField,
                rows: effectiveRaw[field.fieldname]?.arrayValue ?? [], session: session)
        } else {
            Text(verbatim: " ")
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
    /// The parent document's fieldname for this table; non-nil while the
    /// enclosing screen is editing, which turns on row editing/add/delete.
    let editFieldname: String?

    @Environment(AppModel.self) private var model
    @Environment(\.editSession) private var editSession
    @State private var visibleFieldnames: [String]
    @State private var detailRow: Document?
    @State private var editingRow: EditingRowSelection?

    struct EditingRowSelection: Identifiable {
        let index: Int
        var id: Int { index }
    }

    init(
        title: String?, meta: DocTypeMeta, rows: [Document],
        parentValues: [String: FrappeValue], serverColumns: [GridColumn]? = nil,
        editFieldname: String? = nil
    ) {
        self.title = title
        self.meta = meta
        self.rows = rows
        self.parentValues = parentValues
        self.serverColumns = serverColumns
        self.editFieldname = editFieldname
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
                if let editFieldname, let session = editSession {
                    Button {
                        var tableRows = session.draft[editFieldname]?.arrayValue ?? []
                        tableRows.append(.object(["doctype": .string(meta.name)]))
                        session.set(editFieldname, .array(tableRows))
                        editingRow = EditingRowSelection(index: tableRows.count - 1)
                    } label: {
                        Label("Add Row", systemImage: "plus")
                            .font(.caption)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
                columnsMenu
            }
            grid
        }
        .sheet(item: $detailRow) { row in
            ChildRowDetailSheet(meta: meta, row: row)
        }
        .sheet(item: $editingRow) { selection in
            if let editFieldname, let session = editSession {
                ChildRowEditor(
                    meta: meta, parentSession: session,
                    tableFieldname: editFieldname, index: selection.index)
            }
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
                // Index identity: new rows have no server name yet, so the
                // document id would collide.
                ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
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
                            if editFieldname != nil {
                                editingRow = EditingRowSelection(index: index)
                            } else {
                                detailRow = row
                            }
                        } label: {
                            Image(systemName: editFieldname == nil ? "info.circle" : "pencil")
                        }
                        .buttonStyle(.borderless)
                        .help(editFieldname == nil ? "Row details" : "Edit row")
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

/// Editable child row (W3): the row is copied into a local edit session
/// rendered through the same generic form; Done writes it back into the
/// parent draft (with the one convention-safe computation, amount =
/// qty × rate), Cancel discards, Delete removes the row.
private struct ChildRowEditor: View {
    let meta: DocTypeMeta
    let parentSession: EditSession
    let tableFieldname: String
    let index: Int

    @State private var localSession: EditSession
    @State private var initialRow: Document
    @Environment(\.dismiss) private var dismiss

    init(meta: DocTypeMeta, parentSession: EditSession, tableFieldname: String, index: Int) {
        self.meta = meta
        self.parentSession = parentSession
        self.tableFieldname = tableFieldname
        self.index = index
        let raw =
            parentSession.draft[tableFieldname]?.arrayValue?[safe: index]?.objectValue ?? [:]
        let row = Document(raw: raw)
        _initialRow = State(initialValue: row)
        let session = EditSession(document: row, docstatus: parentSession.docstatus)
        session.uploadFile = parentSession.uploadFile
        _localSession = State(initialValue: session)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                DocumentFormView(meta: meta, childMetas: [:], document: initialRow)
                    .environment(\.editSession, localSession)
                    .padding()
            }
            .navigationTitle("Edit Row \(index + 1)")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .destructiveAction) {
                    Button(role: .destructive) {
                        var tableRows = parentSession.draft[tableFieldname]?.arrayValue ?? []
                        if tableRows.indices.contains(index) {
                            tableRows.remove(at: index)
                            parentSession.set(tableFieldname, .array(tableRows))
                        }
                        dismiss()
                    } label: {
                        Label("Delete Row", systemImage: "trash")
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        apply()
                        dismiss()
                    }
                }
            }
        }
        #if os(macOS)
            .frame(minWidth: 560, minHeight: 480)
        #endif
    }

    private func apply() {
        var raw = localSession.draft
        // The only client-side math (ARCHITECTURE §12): the row amount
        // convention. Taxes, pricing, and totals come back from the server
        // on save.
        if meta.field(named: "qty") != nil, meta.field(named: "rate") != nil,
            meta.field(named: "amount") != nil,
            let qty = raw["qty"]?.doubleValue, let rate = raw["rate"]?.doubleValue {
            raw["amount"] = .double(qty * rate)
        }
        var tableRows = parentSession.draft[tableFieldname]?.arrayValue ?? []
        if tableRows.indices.contains(index) {
            tableRows[index] = .object(raw)
        } else {
            tableRows.append(.object(raw))
        }
        parentSession.set(tableFieldname, .array(tableRows))
    }
}

extension Array {
    fileprivate subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}

extension DocumentFormView where DashboardContent == EmptyView {
    /// Plain form body without a Dashboard tab (child-row detail sheets).
    init(
        meta: DocTypeMeta, childMetas: [String: DocTypeMeta], document: Document,
        gridColumns: [String: [GridColumn]] = [:]
    ) {
        self.init(
            meta: meta, childMetas: childMetas, document: document,
            gridColumns: gridColumns, dashboard: nil)
    }
}
