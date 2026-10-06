import ERPNextKit
import SwiftUI

/// Generic list view for any DocType, mirroring Desk's list recipe:
/// **Title (link) → status → configured columns → ID → modified-ago**, sorted
/// by the user's saved sort (falling back to the DocType default), with
/// infinite scroll and a total count. Screens restore instantly from the
/// session cache and refresh silently (ARCHITECTURE.md §11).
struct ListScreen: View {
    let doctype: String
    var initialFilters: [String: String] = [:]

    init(
        doctype: String, initialFilters: [String: String] = [:],
        initialConditions: [FilterCondition] = []
    ) {
        self.doctype = doctype
        self.initialFilters = initialFilters
        _quickFilters = State(initialValue: initialFilters)
        _advancedFilters = State(initialValue: initialConditions)
    }

    @Environment(AppModel.self) private var model
    @State private var state: LoadState<Loaded> = .loading
    @State private var lastUpdated: Date?
    @State private var refreshToken = 0
    @State private var searchText = ""
    /// Active quick-filter values, fieldname → equality value.
    @State private var quickFilters: [String: String] = [:]
    /// User's in-app sort choice; nil = saved/default sort.
    @State private var sortOverride: SortSpec?
    @State private var showingNewDocument = false
    /// Multi-select for bulk operations (W5).
    @State private var selection = Set<String>()
    /// iOS-only manual selection mode (macOS Tables multi-select natively).
    @State private var selectionMode = false
    /// This device's column choice; nil = server List View Settings.
    @State private var columnOverride: [String]?
    @State private var settingsError: String?
    @State private var isLoadingMore = false
    @State private var totalCount: Int?
    /// Detailed filter-editor conditions (Desk's "Filter" popover).
    @State private var advancedFilters: [FilterCondition] = []
    @State private var showingFilterEditor = false
    /// macOS Table header-click sort state, mirrored into `sortOverride`.
    @State private var tableSort: [DocumentFieldComparator] = []

    struct SortSpec: Hashable {
        var fieldname: String
        var descending: Bool
    }

    struct Loaded {
        var meta: DocTypeMeta
        /// Desk's saved List View Settings when present, else `in_list_view`.
        var columns: [DocField]
        var rows: [Document]
        var sort: SortSpec
        var hasMore: Bool

        var statusField: DocField? {
            meta.field(named: "status")
        }

        /// Columns for the middle of the table: everything except the
        /// synthesized title/status/ID columns.
        var middleColumns: [DocField] {
            columns.filter {
                $0.fieldname != meta.titleField && $0.fieldname != "status"
                    && $0.fieldname != "name"
            }
        }

        /// Row whose appearance triggers the next page fetch.
        var loadMoreTriggerID: String? {
            guard hasMore, !rows.isEmpty else { return nil }
            return rows[max(0, rows.count - 10)].id
        }
    }

    var body: some View {
        Group {
            switch state {
            case .loading:
                ProgressView("Loading \(doctype)…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .failed(let message):
                ContentUnavailableView {
                    Label("Couldn't Load \(doctype)", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(message)
                }
            case .loaded(let loaded):
                VStack(spacing: 0) {
                    QuickFiltersBar(meta: loaded.meta, values: $quickFilters)
                    BulkActionsBar(
                        doctype: doctype, isSubmittable: loaded.meta.isSubmittable,
                        selection: $selection,
                        onDone: { refreshToken += 1 })
                    if loaded.rows.isEmpty {
                        emptyState
                    } else {
                        listBody(loaded)
                    }
                }
            }
        }
        .navigationTitle(doctype)
        .searchable(text: $searchText, prompt: Text("Search \(doctype)"))
        .toolbar {
            SearchToolbar()
            NewDocumentToolbar(doctype: doctype, showingNew: $showingNewDocument)
            filterToolbar
            sortToolbar
            columnsToolbar
            #if !os(macOS)
                // Manual selection mode: EditButton's editMode environment
                // leaks to the sidebar list on iPad and clears the sidebar
                // selection, so selection is drawn by hand instead. "Select"
                // waits in the overflow menu (as in Files); "Done" joins the
                // bar while selecting.
                if model.writeSession != nil
                    || ProcessInfo.processInfo.environment["TULA_EDIT_PREVIEW"] == "1" {
                    ToolbarItem(placement: selectionMode ? .primaryAction : .secondaryAction) {
                        Button(selectionMode ? "Done" : "Select") {
                            selectionMode.toggle()
                            if !selectionMode { selection = [] }
                        }
                    }
                }
            #endif
            WriteGateToolbar()
            OpenInDeskToolbar(route: deskRoute, placement: .demotedAction)
            RefreshToolbar(
                lastUpdated: lastUpdated, detail: countDetail, placement: .demotedAction
            ) { refreshToken += 1 }
        }
        .sheet(isPresented: $showingNewDocument) {
            NewDocumentSheet(doctype: doctype) { created in
                model.pendingRoute = .document(doctype: doctype, name: created)
            }
        }
        .alert(
            "Couldn't Save Settings",
            isPresented: Binding(
                get: { settingsError != nil },
                set: { if !$0 { settingsError = nil } })
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(settingsError ?? "")
        }
        .autoRefresh(signalDoctype: doctype) { refreshToken += 1 }
        .task(id: taskKey) {
            // Restore the last-loaded screen instantly, then refresh silently.
            if case .loading = state,
                let cached: (value: Loaded, savedAt: Date) = model.cache.screen(cacheKey) {
                state = .loaded(cached.value)
                lastUpdated = cached.savedAt
            }
            // Debounce keystrokes; the task is cancelled and restarted on
            // every change, so only a pause reaches the server.
            if !searchText.isEmpty {
                try? await Task.sleep(for: .milliseconds(300))
                if Task.isCancelled { return }
            }
            // Verification hook: TULA_NEW_PREVIEW=1 opens the creation
            // sheet (Create stays locked without a write session).
            if ProcessInfo.processInfo.environment["TULA_NEW_PREVIEW"] == "1" {
                showingNewDocument = true
            }
            await load()
        }
    }

    private var taskKey: String {
        "\(cacheKey)-\(refreshToken)-\(searchText)"
    }

    private var cacheKey: String {
        let sort = sortOverride.map { "\($0.fieldname):\($0.descending)" } ?? "auto"
        let columns = columnOverride?.joined(separator: ",") ?? "server"
        return "list|\(model.sourceGeneration)|\(doctype)|\(filtersKey)|\(sort)|\(columns)"
    }

    /// Stable task-id component for both filter mechanisms.
    private var filtersKey: String {
        let quick = quickFilters.sorted { $0.key < $1.key }
            .map { "\($0.key)=\($0.value)" }
            .joined(separator: "&")
        let advanced = advancedFilters.map(\.key).joined(separator: "&")
        return "\(quick)|\(advanced)"
    }

    /// Open in Desk: the list under the filters it's showing (search, quick
    /// filters, filter editor), once they're known — they need the
    /// DocType's metadata.
    private var deskRoute: Route {
        guard case .loaded(let loaded) = state else { return .doctypeList(doctype) }
        return .filteredList(doctype: doctype, conditions: activeFilters(meta: loaded.meta))
    }

    private var countDetail: String? {
        guard case .loaded(let loaded) = state, let totalCount,
            totalCount > loaded.rows.count
        else { return nil }
        return "\(loaded.rows.count) of \(totalCount.formatted())"
    }

    // MARK: Detailed filters

    @ToolbarContentBuilder
    private var filterToolbar: some ToolbarContent {
        if case .loaded(let loaded) = state {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    showingFilterEditor = true
                } label: {
                    Label(
                        "Filter",
                        systemImage: advancedFilters.isEmpty
                            ? "line.3.horizontal.decrease.circle"
                            : "line.3.horizontal.decrease.circle.fill")
                }
                .help("Filter \(doctype)")
                .onAppear {
                    // Headless-verification hook (TULA_AUTOOPEN_FILTER=editor).
                    if ProcessInfo.processInfo.environment["TULA_AUTOOPEN_FILTER"] == "editor" {
                        showingFilterEditor = true
                    }
                }
                .popover(isPresented: $showingFilterEditor, arrowEdge: .bottom) {
                    FilterEditorView(meta: loaded.meta, applied: $advancedFilters)
                        #if !os(macOS)
                            .presentationDetents([.medium, .large])
                        #endif
                }
            }
        }
    }

    // MARK: Sort

    @ToolbarContentBuilder
    private var sortToolbar: some ToolbarContent {
        if case .loaded(let loaded) = state {
            ToolbarItem(placement: .demotedAction) {
                Menu {
                    ForEach(sortCandidates(loaded), id: \.fieldname) { candidate in
                        Toggle(isOn: Binding {
                            loaded.sort.fieldname == candidate.fieldname
                        } set: { _ in
                            sortOverride = SortSpec(
                                fieldname: candidate.fieldname,
                                descending: loaded.sort.descending)
                        }) {
                            Text(candidate.label)
                        }
                    }
                    Divider()
                    Toggle(isOn: Binding {
                        loaded.sort.descending
                    } set: { descending in
                        sortOverride = SortSpec(
                            fieldname: loaded.sort.fieldname, descending: descending)
                    }) {
                        Text("Descending")
                    }
                } label: {
                    Label("Sort", systemImage: "arrow.up.arrow.down")
                }
                .menuIndicator(.hidden)
                .help("Sort order")
            }
        }
    }

    // MARK: Columns (W5: the list's gear, persistable to List View Settings)

    @ToolbarContentBuilder
    private var columnsToolbar: some ToolbarContent {
        if case .loaded(let loaded) = state {
            ToolbarItem(placement: .demotedAction) {
                Menu {
                    ForEach(columnCandidates(loaded)) { field in
                        Toggle(isOn: columnBinding(for: field, loaded: loaded)) {
                            Text(field.label)
                        }
                    }
                    Divider()
                    if model.writeSession != nil {
                        Button {
                            saveColumns(loaded)
                        } label: {
                            Label("Save Columns to Server", systemImage: "arrow.up.doc")
                        }
                    }
                    Button("Reset to Server Columns") {
                        columnOverride = nil
                    }
                } label: {
                    Label("Columns", systemImage: "slider.horizontal.3")
                }
                .menuIndicator(.hidden)
                .help("Choose list columns")
            }
        }
    }

    private func columnCandidates(_ loaded: Loaded) -> [DocField] {
        var fields = loaded.meta.fields.filter { $0.fieldtype.isPresentable && !$0.hidden }
        for column in loaded.columns where !fields.contains(where: {
            $0.fieldname == column.fieldname
        }) {
            fields.append(column)
        }
        return fields
    }

    private func columnBinding(for field: DocField, loaded: Loaded) -> Binding<Bool> {
        Binding {
            (columnOverride ?? loaded.columns.map(\.fieldname)).contains(field.fieldname)
        } set: { isOn in
            var current = columnOverride ?? loaded.columns.map(\.fieldname)
            if isOn {
                if !current.contains(field.fieldname) { current.append(field.fieldname) }
            } else {
                current.removeAll { $0 == field.fieldname }
            }
            columnOverride = current
        }
    }

    /// Writes this device's column choice to the DocType's List View
    /// Settings — the same document Desk's gear writes and every Tula
    /// client already reads.
    private func saveColumns(_ loaded: Loaded) {
        guard let session = model.writeSession else { return }
        let fieldnames = columnOverride ?? loaded.columns.map(\.fieldname)
        let labels = Dictionary(
            columnCandidates(loaded).map { ($0.fieldname, $0.label) },
            uniquingKeysWith: { first, _ in first })
        let removed = loaded.columns.map(\.fieldname).filter { !fieldnames.contains($0) }
        Task {
            do {
                try await session.saveListColumns(
                    doctype: doctype, fieldnames: fieldnames, labels: labels,
                    removed: removed)
                columnOverride = nil
                model.cache.invalidateMeta()
                refreshToken += 1
            } catch {
                settingsError = error.localizedDescription
            }
        }
    }

    private func sortCandidates(_ loaded: Loaded) -> [(fieldname: String, label: String)] {
        var seen = Set<String>()
        var candidates: [(String, String)] = []
        func add(_ fieldname: String, _ label: String) {
            guard !seen.contains(fieldname) else { return }
            seen.insert(fieldname)
            candidates.append((fieldname, label))
        }
        add(loaded.meta.sortField, fieldLabel(loaded.meta.sortField, in: loaded.meta))
        for column in loaded.columns {
            add(column.fieldname, column.label)
        }
        add("modified", "Last Modified")
        add("creation", "Created")
        add("name", "ID")
        return candidates
    }

    private func fieldLabel(_ fieldname: String, in meta: DocTypeMeta) -> String {
        switch fieldname {
        case "modified": return "Last Modified"
        case "creation": return "Created"
        case "name": return "ID"
        default:
            return meta.field(named: fieldname)?.label
                ?? fieldname.replacingOccurrences(of: "_", with: " ").capitalized
        }
    }

    // MARK: Empty state

    @ViewBuilder
    private var emptyState: some View {
        if !searchText.isEmpty {
            ContentUnavailableView.search(text: searchText)
        } else if !quickFilters.isEmpty || !advancedFilters.isEmpty {
            ContentUnavailableView {
                Label("No Matches", systemImage: "line.3.horizontal.decrease.circle")
            } description: {
                Text("No \(doctype) records match the current filters.")
            } actions: {
                Button("Clear Filters") {
                    quickFilters = [:]
                    advancedFilters = []
                }
            }
        } else {
            ContentUnavailableView("No \(doctype) records", systemImage: "tray")
        }
    }

    // MARK: Rows

    @ViewBuilder
    private func listBody(_ loaded: Loaded) -> some View {
        #if os(macOS)
            Table(loaded.rows, selection: $selection, sortOrder: $tableSort) {
                TableColumn(
                    "Title",
                    sortUsing: DocumentFieldComparator(
                        fieldname: loaded.meta.titleField ?? "name")
                ) { document in
                    NavigationLink(
                        value: Route.document(doctype: doctype, name: document.name)
                    ) {
                        Text(document.title(using: loaded.meta))
                            .fontWeight(.medium)
                            .foregroundStyle(.tint)
                    }
                    .buttonStyle(.plain)
                    .onAppear { maybeLoadMore(after: document, in: loaded) }
                }
                if let statusField = loaded.statusField {
                    TableColumn(
                        "Status", sortUsing: DocumentFieldComparator(fieldname: "status")
                    ) { document in
                        FieldValueView(
                            fieldname: statusField.fieldname,
                            fieldtype: statusField.fieldtype,
                            options: statusField.options,
                            value: document["status"],
                            linkEnabled: false)
                    }
                }
                TableColumnForEach(loaded.middleColumns) { field in
                    TableColumn(
                        field.label,
                        sortUsing: DocumentFieldComparator(fieldname: field.fieldname)
                    ) { document in
                        FieldValueView(
                            fieldname: field.fieldname,
                            fieldtype: field.fieldtype,
                            options: field.options,
                            value: document[field.fieldname],
                            currencyCode: ValueFormatting.currencyCode(
                                options: field.fieldtype == .currency ? field.options : nil,
                                rowValues: document.raw,
                                fallback: model.fallbackCurrencyCode),
                            linkEnabled: false)
                    }
                }
                TableColumn(
                    "ID", sortUsing: DocumentFieldComparator(fieldname: "name")
                ) { document in
                    Text(document.name)
                        .foregroundStyle(.secondary)
                }
                TableColumn(
                    "Modified", sortUsing: DocumentFieldComparator(fieldname: "modified")
                ) { document in
                    Text(
                        ValueFormatting.relativeModified(
                            document.raw["modified"]?.nonEmptyString) ?? "")
                        .foregroundStyle(.secondary)
                }
            }
            .onChange(of: tableSort) { _, order in
                guard let first = order.first else { return }
                let spec = SortSpec(
                    fieldname: first.fieldname,
                    descending: first.order == .reverse)
                if spec != loaded.sort {
                    sortOverride = spec
                }
            }
        #else
            List(loaded.rows) { document in
                if selectionMode {
                    HStack(spacing: 10) {
                        Image(
                            systemName: selection.contains(document.name)
                                ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(
                                selection.contains(document.name)
                                    ? AnyShapeStyle(.tint) : AnyShapeStyle(.tertiary))
                            .imageScale(.large)
                        rowLabel(document, loaded: loaded)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        if selection.contains(document.name) {
                            selection.remove(document.name)
                        } else {
                            selection.insert(document.name)
                        }
                    }
                    .onAppear { maybeLoadMore(after: document, in: loaded) }
                } else {
                    NavigationLink(
                        value: Route.document(doctype: doctype, name: document.name)
                    ) {
                        rowLabel(document, loaded: loaded)
                    }
                    .onAppear { maybeLoadMore(after: document, in: loaded) }
                }
            }
            .listStyle(.plain)
            // Beta landmine #3: rows that morph between NavigationLink and
            // plain content inside a live List keep the link's touch
            // handling and swallow taps — rebuild the whole List on mode
            // changes instead.
            .id(selectionMode)
            .refreshable { await load() }
        #endif
    }

    #if !os(macOS)
        private func rowLabel(_ document: Document, loaded: Loaded) -> some View {
            VStack(alignment: .leading, spacing: 3) {
                Text(document.title(using: loaded.meta))
                    .fontWeight(.medium)
                HStack(spacing: 10) {
                    let secondary = loaded.columns
                        .filter { $0.fieldname != loaded.meta.titleField }
                        .prefix(3)
                    ForEach(Array(secondary)) { field in
                        if document[field.fieldname] != nil {
                            FieldValueView(
                                fieldname: field.fieldname,
                                fieldtype: field.fieldtype,
                                options: field.options,
                                value: document[field.fieldname],
                                currencyCode: ValueFormatting.currencyCode(
                                    options: field.fieldtype == .currency ? field.options : nil,
                                    rowValues: document.raw,
                                    fallback: model.fallbackCurrencyCode),
                                linkEnabled: false)
                        }
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            .padding(.vertical, 2)
        }
    #endif

    // MARK: Loading

    private static let pageSize = 50

    private func resolvedSort(bundle: MetaBundle, meta: DocTypeMeta) -> SortSpec {
        if let sortOverride { return sortOverride }
        if let saved = bundle.listSortBy, isSortable(saved, in: meta) {
            return SortSpec(
                fieldname: saved, descending: bundle.listSortDescending ?? true)
        }
        if isSortable(meta.sortField, in: meta) {
            return SortSpec(fieldname: meta.sortField, descending: meta.sortDescending)
        }
        return SortSpec(fieldname: "modified", descending: true)
    }

    private func isSortable(_ fieldname: String, in meta: DocTypeMeta) -> Bool {
        ["modified", "creation", "name"].contains(fieldname)
            || meta.field(named: fieldname) != nil
    }

    private func activeFilters(meta: DocTypeMeta) -> [ListFilter] {
        var filters: [ListFilter] = []
        let trimmed = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            // Desk's list search filters on the title field (or name).
            filters.append(
                ListFilter(meta.titleField ?? "name", "like", .string("%\(trimmed)%")))
        }
        for (fieldname, value) in quickFilters {
            // Free-text chips (ID, Title, Data fields) match like Desk's
            // standard filters: substring. Finite chips stay equality.
            let fieldtype = fieldname == "name"
                ? FieldType.data : meta.field(named: fieldname)?.fieldtype
            if fieldtype == .data {
                filters.append(ListFilter(fieldname, "like", .string("%\(value)%")))
            } else {
                filters.append(ListFilter(fieldname, "=", .string(value)))
            }
        }
        for condition in advancedFilters {
            if let filter = condition.listFilter() {
                filters.append(filter)
            }
        }
        return filters
    }

    private func fetchFieldnames(meta: DocTypeMeta, columns: [DocField]) -> [String] {
        var fieldnames = ["name", "modified"]
        if let titleField = meta.titleField, !fieldnames.contains(titleField) {
            fieldnames.append(titleField)
        }
        if meta.field(named: "status") != nil {
            fieldnames.append("status")
        }
        for field in columns where !fieldnames.contains(field.fieldname) {
            fieldnames.append(field.fieldname)
        }
        return fieldnames
    }

    private func load() async {
        if case .loaded = state {} else { state = .loading }
        do {
            let bundle = try await model.cache.metaBundle(
                for: doctype, using: model.dataSource)
            guard let meta = bundle.metas.first else {
                throw ERPNextError(message: "No metadata for \(doctype)")
            }

            var columns = meta.listFields
            if let configured = await model.cache.listViewColumns(
                for: doctype, using: model.dataSource) {
                let mapped = configured.compactMap { fieldname -> DocField? in
                    guard !fieldname.hasPrefix("_"),
                        let field = meta.field(named: fieldname),
                        field.fieldtype.isPresentable, !field.hidden
                    else { return nil }
                    return field
                }
                if !mapped.isEmpty { columns = mapped }
            }
            if let override = columnOverride {
                let mapped = override.compactMap { meta.field(named: $0) }
                if !mapped.isEmpty { columns = mapped }
            }

            let sort = resolvedSort(bundle: bundle, meta: meta)
            let filters = activeFilters(meta: meta)
            // A background refresh re-fetches everything currently on screen
            // (up to a sanity cap) so pagination state survives it.
            let existingCount: Int = {
                if case .loaded(let loaded) = state { return loaded.rows.count }
                return 0
            }()
            let limit = min(max(Self.pageSize, existingCount), 500)

            let rows = try await model.dataSource.list(
                doctype, fields: fetchFieldnames(meta: meta, columns: columns),
                filters: filters,
                orderBy: "\(sort.fieldname) \(sort.descending ? "desc" : "asc")",
                limitStart: 0, limitPageLength: limit)

            let loaded = Loaded(
                meta: meta, columns: columns, rows: rows, sort: sort,
                hasMore: rows.count == limit)
            state = .loaded(loaded)
            tableSort = [
                DocumentFieldComparator(
                    fieldname: sort.fieldname,
                    order: sort.descending ? .reverse : .forward)
            ]
            lastUpdated = Date()
            model.cache.setScreen(cacheKey, loaded)

            // W5: an explicit in-app sort persists to Desk's per-user
            // settings (merged over the existing blob), exactly as changing
            // the sort in Desk would. Best-effort and silent, like Desk.
            if let override = sortOverride, let session = model.writeSession,
                override.fieldname != bundle.listSortBy
                    || override.descending != (bundle.listSortDescending ?? true) {
                let existing = bundle.userSettingsRaw
                Task {
                    try? await session.saveUserListSort(
                        doctype: doctype, existingSettings: existing,
                        sortBy: override.fieldname, descending: override.descending)
                }
            }

            totalCount = try? await model.dataSource.count(doctype, filters: filters)
        } catch {
            // Keep showing cached content when a refresh fails (offline);
            // only surface errors when there's nothing on screen.
            if case .loaded = state {} else {
                state = .failed(error.localizedDescription)
            }
        }
    }

    private func maybeLoadMore(after document: Document, in loaded: Loaded) {
        guard document.id == loaded.loadMoreTriggerID, !isLoadingMore else { return }
        Task { await loadMore() }
    }

    private func loadMore() async {
        guard case .loaded(var loaded) = state, loaded.hasMore, !isLoadingMore else { return }
        isLoadingMore = true
        defer { isLoadingMore = false }
        do {
            let page = try await model.dataSource.list(
                doctype, fields: fetchFieldnames(meta: loaded.meta, columns: loaded.columns),
                filters: activeFilters(meta: loaded.meta),
                orderBy:
                    "\(loaded.sort.fieldname) \(loaded.sort.descending ? "desc" : "asc")",
                limitStart: loaded.rows.count, limitPageLength: Self.pageSize)
            let known = Set(loaded.rows.map(\.name))
            loaded.rows.append(contentsOf: page.filter { !known.contains($0.name) })
            loaded.hasMore = page.count == Self.pageSize
            state = .loaded(loaded)
            model.cache.setScreen(cacheKey, loaded)
        } catch {
            // Silent: the next scroll attempt retries.
        }
    }
}


/// Sort comparator for Table header clicks, keyed by fieldname. The actual
/// ordering is re-fetched server-side; this local comparison only bridges
/// SwiftUI's Table sort mechanism.
struct DocumentFieldComparator: SortComparator {
    var fieldname: String
    var order: SortOrder = .forward

    func compare(_ lhs: Document, _ rhs: Document) -> ComparisonResult {
        let left = lhs.raw[fieldname]
        let right = rhs.raw[fieldname]
        let ascending: ComparisonResult
        if let l = left?.doubleValue, let r = right?.doubleValue {
            ascending = l < r ? .orderedAscending : (l > r ? .orderedDescending : .orderedSame)
        } else {
            let l = left?.stringValue ?? ""
            let r = right?.stringValue ?? ""
            ascending = l < r ? .orderedAscending : (l > r ? .orderedDescending : .orderedSame)
        }
        guard order == .reverse else { return ascending }
        switch ascending {
        case .orderedAscending: return .orderedDescending
        case .orderedDescending: return .orderedAscending
        case .orderedSame: return .orderedSame
        }
    }
}
