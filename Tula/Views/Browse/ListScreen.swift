import ERPNextKit
import SwiftUI

/// Generic list view for any DocType: columns come from the metadata's
/// `in_list_view` fields, exactly as Desk builds its list views.
struct ListScreen: View {
    let doctype: String

    @Environment(AppModel.self) private var model
    @State private var state: LoadState<Loaded> = .loading
    @State private var lastUpdated: Date?
    @State private var refreshToken = 0
    @State private var searchText = ""

    struct Loaded {
        var meta: DocTypeMeta
        var rows: [Document]
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
                if loaded.rows.isEmpty {
                    if searchText.isEmpty {
                        ContentUnavailableView("No \(doctype) records", systemImage: "tray")
                    } else {
                        ContentUnavailableView.search(text: searchText)
                    }
                } else {
                    listBody(loaded)
                }
            }
        }
        .navigationTitle(doctype)
        .searchable(text: $searchText, prompt: Text("Search \(doctype)"))
        .toolbar {
            RefreshToolbar(lastUpdated: lastUpdated) { refreshToken += 1 }
        }
        .autoRefresh(signalDoctype: doctype) { refreshToken += 1 }
        .task(id: "\(model.sourceGeneration)-\(doctype)-\(refreshToken)-\(searchText)") {
            // Debounce keystrokes; the task is cancelled and restarted on
            // every change, so only a pause reaches the server.
            if !searchText.isEmpty {
                try? await Task.sleep(for: .milliseconds(300))
                if Task.isCancelled { return }
            }
            await load()
        }
    }

    @ViewBuilder
    private func listBody(_ loaded: Loaded) -> some View {
        #if os(macOS)
            Table(loaded.rows) {
                TableColumn("ID") { document in
                    NavigationLink(
                        value: Route.document(doctype: doctype, name: document.name)
                    ) {
                        Text(document.name).foregroundStyle(.tint)
                    }
                    .buttonStyle(.plain)
                }
                TableColumnForEach(loaded.meta.listFields) { field in
                    TableColumn(field.label) { document in
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
        #else
            List(loaded.rows) { document in
                NavigationLink(value: Route.document(doctype: doctype, name: document.name)) {
                    rowLabel(document, meta: loaded.meta)
                }
            }
            .listStyle(.plain)
            .refreshable { await load() }
        #endif
    }

    #if !os(macOS)
        private func rowLabel(_ document: Document, meta: DocTypeMeta) -> some View {
            VStack(alignment: .leading, spacing: 3) {
                Text(document.title(using: meta))
                    .fontWeight(.medium)
                HStack(spacing: 10) {
                    let secondary = meta.listFields
                        .filter { $0.fieldname != meta.titleField }
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

    private func load() async {
        if case .loaded = state {} else { state = .loading }
        do {
            let bundle = try await model.dataSource.metaBundle(for: doctype)
            guard let meta = bundle.first else {
                throw ERPNextError(message: "No metadata for \(doctype)")
            }
            var filters: [ListFilter] = []
            let trimmed = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                // Desk's list search filters on the title field (or name).
                filters.append(
                    ListFilter(meta.titleField ?? "name", "like", .string("%\(trimmed)%")))
            }
            let rows = try await model.dataSource.list(
                doctype, fields: meta.listFieldnames, filters: filters,
                orderBy: "modified desc", limitStart: 0, limitPageLength: 50)
            state = .loaded(Loaded(meta: meta, rows: rows))
            lastUpdated = Date()
        } catch {
            state = .failed(error.localizedDescription)
        }
    }
}
